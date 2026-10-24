import ClaudeKit
import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

// T5.3 security review fixes, app side. Fakes only: no network, no Keychain, no pasteboard, no API.

// MARK: - H1 public Internet, M1 clipboard on a public session

@MainActor
struct PublicInternetSessionTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let log = SessionLog()
    let clock = FakeClock()
    let machine: Machine
    let surfaces = Holder()
    let reconnectClock = FakeReachabilityClock()
    let consents = InMemoryPublicAddressConsents()
    static let publicAddress = RemoteAddress(text: "203.0.113.5", scope: .publicInternet)

    @MainActor final class Holder { var all: [FakeSurface] = [] }
    @MainActor final class Counter { var value = 0 }

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
        machine = Machine(name: "Cloud", kind: .macARD, host: "cloud.example.com", username: "vincent",
                          sharedClipboard: true)
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "s3cret"
    }

    private func session(_ fakes: [FakeSessionConnection]) -> (SessionModel, Counter) {
        let counter = Counter()
        let model = SessionModel(machine: machine, context: context, passwords: passwords, display: nil,
                                 clock: clock.clock, pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil,
                                 reconnectClock: reconnectClock, publicConsents: consents) { _ in
            defer { counter.value += 1 }
            return fakes[min(counter.value, fakes.count - 1)]
        }
        let surface = FakeSurface(log: log)
        surface.session = model
        model.surface = surface
        surfaces.all.append(surface)
        return (model, counter)
    }

    private func records() throws -> [SessionRecord] {
        try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    private func firstFrame(_ model: SessionModel, _ fake: FakeSessionConnection) async {
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { model.phase == .connected })
    }

    /// A first connection to a public address stops before any RFB byte and asks; Connect anyway is
    /// remembered and connects; the badge shows and the shared clipboard is off.
    @Test func firstPublicConnectAsksThenConnectsAnyway() async throws {
        let first = FakeSessionConnection(log: log, address: Self.publicAddress)
        let second = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, made) = session([first, second])
        model.connect()
        #expect(await waitUntil { model.publicAddressConsent == "203.0.113.5" })
        #expect(model.phase == .idle && model.failure == nil)
        #expect(await first.allowedPublic == [false])
        #expect(await first.hasEvents == false)   // never past `connect`
        #expect(try records().map(\.outcomeValue) == [.cancelled])
        #expect(try records().first?.endedAt != nil)
        #expect(!consents.hasConfirmed(machine.id, host: machine.host))

        model.connectOverPublicInternet()
        #expect(model.publicAddressConsent == nil)
        #expect(consents.hasConfirmed(machine.id, host: machine.host))
        #expect(await waitUntil { made.value == 2 })
        await firstFrame(model, second)
        #expect(await second.allowedPublic == [true])
        #expect(model.isOverPublicInternet)
        #expect(model.remoteAddress == Self.publicAddress)
        // M1: forced off for the public session, before the events started.
        #expect(!model.clipboardSharing)
        #expect(await second.clipboardSharing.first == false)
        #expect(try records().map(\.outcomeValue) == [.cancelled, .connected])
        await model.close()
    }

    @Test func aConfirmedMachineConnectsWithoutAsking() async throws {
        consents.confirm(machine.id, host: machine.host)
        let fake = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, _) = session([fake])
        model.connect()
        await firstFrame(model, fake)
        #expect(model.publicAddressConsent == nil)
        #expect(await fake.allowedPublic == [true])
        #expect(model.isOverPublicInternet)
        await model.close()
    }

    @Test func aLANSessionKeepsItsClipboardAndShowsNoBadge() async throws {
        let fake = FakeSessionConnection(log: log)   // 192.168.1.20
        let (model, _) = session([fake])
        model.connect()
        await firstFrame(model, fake)
        #expect(!model.isOverPublicInternet)
        #expect(model.clipboardSharing)
        #expect(await fake.clipboardSharing == [true])
        await model.close()
    }

    @Test func cancelRemembersNothing() async throws {
        let fake = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, made) = session([fake])
        model.connect()
        #expect(await waitUntil { model.publicAddressConsent != nil })
        model.declinePublicInternet()
        #expect(model.publicAddressConsent == nil)
        #expect(!consents.hasConfirmed(machine.id, host: machine.host))
        #expect(made.value == 1)
        await model.close()
    }

    /// The user's own toolbar choice holds for the session, an automatic reconnect included.
    @Test func turningTheClipboardOnInTheToolbarHoldsAcrossAReconnect() async throws {
        consents.confirm(machine.id, host: machine.host)
        let first = FakeSessionConnection(log: log, address: Self.publicAddress)
        let second = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, made) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        #expect(!model.clipboardSharing)
        model.setClipboardSharingFromToolbar(true)
        #expect(model.clipboardSharing)
        #expect(await waitUntilAsync { await first.clipboardSharing.last == true })

        await first.fail(.connectionClosed)
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) && reconnectClock.pending(.seconds(2)) == 1 })
        reconnectClock.fire(.seconds(2))
        #expect(await waitUntil { made.value == 2 })
        await firstFrame(model, second)
        #expect(model.clipboardSharing)
        #expect(await second.clipboardSharing == [true])
        await model.close()
    }

    /// A reconnect that now lands on a public address (a name resolving elsewhere off the VPN) is
    /// refused before any RFB byte and asks, like a first connect.
    @Test func anAutomaticReconnectToANewPublicAddressAsks() async throws {
        let first = FakeSessionConnection(log: log)   // LAN
        let second = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, made) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        await first.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(.seconds(2)) == 1 })
        reconnectClock.fire(.seconds(2))
        #expect(await waitUntil { made.value == 2 && model.publicAddressConsent != nil })
        #expect(await second.allowedPublic == [false])
        #expect(model.phase == .idle && model.failure == nil)
        await model.close()
    }

    @Test func deletingTheMachineForgetsTheConfirmation() throws {
        consents.confirm(machine.id, host: machine.host)
        let library = MachineLibraryModel(context: context, passwords: passwords, publicConsents: consents)
        library.delete(machine)
        #expect(consents.confirmed.isEmpty)
    }

    @Test func confirmationsLiveInUserDefaultsPerMachine() throws {
        let suite = "RemoteDeckTests.publicConsents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPublicAddressConsents(defaults: defaults)
        let other = UUID()
        #expect(!store.hasConfirmed(machine.id, host: "cloud.example.com"))
        store.confirm(machine.id, host: " Cloud.Example.com ")
        #expect(store.hasConfirmed(machine.id, host: "cloud.example.com"))
        #expect(!store.hasConfirmed(other, host: "cloud.example.com"))
        #expect(defaults.string(forKey: "publicInternetConfirmed.\(machine.id.uuidString)") == "cloud.example.com")
        // A second instance on the same defaults (next launch) sees it.
        #expect(UserDefaultsPublicAddressConsents(defaults: defaults).hasConfirmed(machine.id, host: "cloud.example.com"))
        // T5.3 review: bound to the host; an edited host is unconfirmed.
        #expect(!store.hasConfirmed(machine.id, host: "other.example.com"))
        store.forget(machine.id)
        #expect(!store.hasConfirmed(machine.id, host: "cloud.example.com"))
    }
}

// MARK: - M4 Apple DH for a Mac with a user name, L8 server strings

@MainActor
struct ARDAuthenticationTests {
    @Test func aMacWithAUserNameRequiresAppleDH() {
        #expect(RFBCredentials(kind: .macARD, username: "vincent", password: "pw").requiredSecurityType == 30)
        #expect(RFBCredentials(kind: .macARD, username: " vincent ", password: nil).requiredSecurityType == 30)
        #expect(RFBCredentials(kind: .macARD, username: "  ", password: "pw").requiredSecurityType == nil)
        #expect(RFBCredentials(kind: .macARD, username: nil, password: "pw").requiredSecurityType == nil)
        #expect(RFBCredentials(kind: .vnc, username: "vincent", password: "pw").requiredSecurityType == nil)
        #expect(RFBCredentials(kind: .anthropicVM, username: "vincent", password: nil).requiredSecurityType == nil)
    }

    @Test func theBannerExplainsTheMissingAppleAuthentication() throws {
        let error = RFBError.requiredSecurityTypeMissing(required: 30, offered: [1, 2])
        let failure = try #require(SessionFailure(openError: error))
        #expect(failure == .connect(.appleAuthenticationMissing(offered: [1, 2])))
        #expect(failure.isAuthentication)
        #expect(failure.action == .editCredentials)
        #expect(failure.outcome == .authFailed)
        for language in ["fr", "en"] {
            let t: (String) -> String = { Strings.table[language]?[$0] ?? $0 }
            let text = failure.message(t)
            #expect(text.contains("30") && text.hasSuffix("(1, 2)"), "\(language): \(text)")
            #expect(!text.contains("test_ard_requires_apple_auth"))
        }
    }

    /// The Test button reports it the same way.
    @Test func theMachineEditorTestReportsItToo() {
        #expect(TestConnectionFailure(.requiredSecurityTypeMissing(required: 30, offered: [2]))
            == .appleAuthenticationMissing(offered: [2]))
    }

    /// L8: a server's reason is bounded and its invisible scalars are shown.
    @Test func serverReasonsAreSanitizedBeforeDisplay() {
        let t: (String) -> String = { Strings.table["en"]?[$0] ?? $0 }
        let hostile = "Wrong\u{202E}drowssap\nfake line" + String(repeating: "x", count: 500)
        let text = TestConnectionFailure.authFailed(reason: hostile).message(t)
        #expect(!text.contains("\u{202E}") && !text.contains("\n"))
        #expect(text.contains("\\u{202E}") && text.contains("\\u{A}"))
        #expect(text.hasSuffix("…"))
        #expect(text.count < 260)
        #expect(TestConnectionFailure.refused(reason: "bu\u{200B}sy").message(t).hasSuffix("bu\\u{200B}sy"))
    }
}

// MARK: - M1 editor default per kind, H1 public literal in the editor

@MainActor
struct MachineEditorSecurityTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func editor(_ machine: Machine? = nil, appDefault: Bool = true) -> MachineEditorModel {
        MachineEditorModel(machine: machine, context: context, passwords: FakePasswordStore(),
                           tester: FakeConnectionTester(), defaultSharedClipboard: appDefault)
    }

    @Test func aNewAnthropicVMStartsWithTheClipboardOff() {
        let model = editor()
        #expect(model.sharedClipboard)
        model.kind = .anthropicVM
        #expect(!model.sharedClipboard)
        model.kind = .vnc
        #expect(model.sharedClipboard)
        model.kind = .anthropicVM
        model.sharedClipboard = true   // the user's choice
        model.kind = .macARD
        model.kind = .anthropicVM
        #expect(model.sharedClipboard)
    }

    @Test func theSettingsDefaultStillAppliesToOtherKinds() {
        let model = editor(appDefault: false)
        #expect(!model.sharedClipboard)
        model.kind = .vnc
        #expect(!model.sharedClipboard)
    }

    @Test func anExistingMachineKeepsItsValue() throws {
        let machine = Machine(name: "VM", kind: .anthropicVM, host: "127.0.0.1", sharedClipboard: true)
        context.insert(machine)
        let model = editor(machine)
        #expect(model.sharedClipboard)
        model.kind = .vnc
        model.kind = .anthropicVM
        #expect(model.sharedClipboard)
    }

    @Test func aDiscoveredMachineFollowsItsKind() {
        let discovered = DiscoveredMachine(host: "pi.local", name: "Pi", port: 5901, services: [.rfb])
        let model = MachineEditorModel(machine: nil, context: context, passwords: FakePasswordStore(),
                                       tester: FakeConnectionTester(), defaultSharedClipboard: true,
                                       discovered: discovered)
        #expect(model.sharedClipboard)
        model.kind = .anthropicVM
        #expect(!model.sharedClipboard)
    }

    @Test func aPublicIPLiteralIsFlagged() {
        let model = editor()
        for (host, flagged) in [("203.0.113.5", true), ("2001:db8::1", true), (" 8.8.8.8 ", true),
                                ("192.168.1.2", false), ("100.101.102.103", false), ("fd7a:115c::1", false),
                                ("127.0.0.1", false), ("mini.local", false), ("", false)] {
            model.host = host
            #expect(model.hostIsPublicAddress == flagged, "\(host)")
        }
    }
}

// MARK: - M3 pause after 8 steps without an action, M2 reveal before Confirm

@MainActor
struct AssistantSecurityTests {
    let port = FakeAssistantPort()

    private func model(_ http: ScriptedHTTP) -> AssistantModel {
        AssistantModel(port: port, client: MessagesClient(transport: http, retry: RetryPolicy(maxRetries: 0)),
                       apiKey: { "sk-ant-test" }, armDelay: .zero, sleep: { _ in })
    }

    private static func screenshotTurn(_ n: Int) -> ScriptedHTTP.Reply {
        apiMessage(stop: "tool_use", content: [memberCall("toolu_shot_\(n)", "screenshot")])
    }

    private static let done = apiMessage(stop: "end_turn", content: [["type": "text", "text": "Done."]])

    @Test func pausesAfterEightTurnsWithoutAnActionThenContinues() async throws {
        let http = ScriptedHTTP((0..<10).map(Self.screenshotTurn) + [Self.done])
        let model = model(http)
        model.prompt = "look around"
        model.ask()
        #expect(await waitUntil { model.phase == .paused })
        #expect(await http.requests.count == 8)
        #expect(model.stepsWithoutAction == 8)
        #expect(model.phase.isBusy && !model.canAsk)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await http.requests.count == 8)   // nothing more while paused

        model.continueAfterPause()
        #expect(await waitUntil { model.phase == .done })
        #expect(await http.requests.count == 11)
        // The 9th request opens with the 8th turn's result, alone, then alternation holds.
        let bodies = await http.bodies
        let ninth = bodies[8]
        #expect(ninth.lastMessageContent.map { $0["tool_use_id"] } == ["toolu_shot_7"])
        let roles = ninth["messages"]?.arrayValue?.map { $0["role"]?.stringValue ?? "" } ?? []
        #expect(zip(roles, roles.dropFirst()).allSatisfy { $0 != $1 })
        #expect(model.stepsWithoutAction == 2)
    }

    @Test func aConfirmedActionResetsTheCount() async throws {
        let click = apiMessage(stop: "tool_use", content: [memberCall("toolu_click", "left_click", ["coordinate": [1, 1]])])
        let http = ScriptedHTTP((0..<7).map(Self.screenshotTurn) + [click] + (10..<17).map(Self.screenshotTurn) + [Self.done])
        let model = model(http)
        model.prompt = "do it"
        model.ask()
        #expect(await waitUntil { model.phase == .confirming })
        #expect(model.stepsWithoutAction == 7)
        await confirmWhenArmed(model)
        #expect(await waitUntil { model.phase == .done })
        #expect(await http.requests.count == 16)   // never paused: 7 + click + 7 + done
        #expect(model.stepsWithoutAction == 7)
    }

    /// Skips count: no confirmed action.
    @Test func skippedProposalsCountAsSteps() async throws {
        let replies: [ScriptedHTTP.Reply] = (0..<8).map {
            apiMessage(stop: "tool_use", content: [memberCall("toolu_click_\($0)", "left_click", ["coordinate": [1, 1]])])
        }
        let http = ScriptedHTTP(replies + [Self.done])
        let model = model(http)
        model.prompt = "click"
        model.ask()
        for n in 0..<8 {
            #expect(await waitUntil { model.awaitingID == "toolu_click_\(n)" })
            model.skip("toolu_click_\(n)")
        }
        #expect(await waitUntil { model.phase == .paused })
        #expect(port.sent.isEmpty)
    }

    /// Stop while paused: the turn's results wait for the next Ask, which sends them first.
    @Test func stopWhilePausedKeepsTheResultsForTheNextAsk() async throws {
        let http = ScriptedHTTP((0..<8).map(Self.screenshotTurn) + [Self.done])
        let model = model(http)
        model.prompt = "look"
        model.ask()
        #expect(await waitUntil { model.phase == .paused })
        model.stop()
        #expect(model.phase == .stopped)
        model.prompt = "and now?"
        model.ask()
        #expect(await waitUntil { model.phase == .done })
        let last = await http.bodies[8].lastMessageContent
        #expect(last.first?["tool_use_id"] == "toolu_shot_7")
        #expect(last.last?["type"] == "text")
        #expect(model.stepsWithoutAction == 0)
    }

    @Test func aLongTypeTextMustBeOpenedBeforeConfirmArms() async throws {
        let text = String(repeating: "a", count: 81)
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [memberCall("toolu_type", "type", ["text": .string(text)])]),
                                 Self.done])
        let model = model(http)
        model.prompt = "type it"
        model.ask()
        #expect(await waitUntil { model.phase == .confirming })
        let id = try #require(model.awaitingID)
        #expect(model.awaitingNeedsReveal && !model.awaitingRevealed)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!model.confirmArmed)
        model.confirm(id)   // ignored: not armed
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.phase == .confirming && port.sent.isEmpty)
        model.reveal("toolu_other")   // a stale id changes nothing
        #expect(!model.awaitingRevealed)
        model.reveal(id)
        #expect(await waitUntil { model.confirmArmed })
        model.confirm(id)
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent.count == 1)
    }

    @Test(arguments: [("echo hi", false), ("uptime\n", false), ("line one\nline two", true),
                      ("a\r\nb", true), ("a\u{2028}b", true), (String(repeating: "x", count: 80), false),
                      (String(repeating: "x", count: 81), true),
                      (String(repeating: "🇫🇷", count: 40), false), (String(repeating: "🇫🇷", count: 41), true)])
    func whichTypeTextsMustBeOpened(_ text: String, _ needsReveal: Bool) {
        #expect(AssistantModel.typeTextNeedsReveal(text) == needsReveal)
    }

    /// The proposal shows the whole text, invisible scalars visible: never the old 80-character cut.
    @Test func theProposalShowsTheWholeTextVisibly() {
        let t: (String) -> String = { Strings.table["en"]?[$0] ?? $0 }
        func item(_ text: String) -> AssistantModel.ActionItem {
            .init(toolUseID: "t", name: "type", action: .type(text), targets: [], status: .awaiting)
        }
        #expect(AssistantCopy.describe(item("rm\u{202E}fdp.exe\t\n"), t) == "Type “rm\\u{202E}fdp.exe⇥⏎\n”")
        #expect(AssistantCopy.describe(item(String(repeating: "x", count: 4000)), t) == "Type a text of 4000 characters")
        // Counted in scalars: 41 flags are 82 scalars, so over the inline limit.
        #expect(AssistantCopy.describe(item(String(repeating: "🇫🇷", count: 41)), t) == "Type a text of 82 characters")
        // `key` / `hold_key` text is Claude's too: escaped.
        let key = AssistantModel.ActionItem(toolUseID: "k", name: "key", action: .key("ctrl+\u{202E}c\n", repeat: 1),
                                            targets: [], status: .awaiting)
        #expect(!AssistantCopy.describe(key, t).contains("\u{202E}") && AssistantCopy.describe(key, t).contains("\\u{202E}"))
        let hold = AssistantModel.ActionItem(toolUseID: "h", name: "hold_key", action: .holdKey("shift\u{200B}", duration: 1),
                                             targets: [], status: .awaiting)
        #expect(AssistantCopy.describe(hold, t).contains("shift\\u{200B}"))
    }
}

// MARK: - Independent review of T5.3

@MainActor
struct T53ReviewTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let log = SessionLog()
    let clock = FakeClock()
    let machine: Machine
    let surfaces = PublicInternetSessionTests.Holder()
    let reconnectClock = FakeReachabilityClock()
    let consents = InMemoryPublicAddressConsents()
    static let publicAddress = PublicInternetSessionTests.publicAddress

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
        machine = Machine(name: "Cloud", kind: .macARD, host: "cloud.example.com", username: "vincent")
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "s3cret"
    }

    private func session(_ fakes: [FakeSessionConnection]) -> (SessionModel, PublicInternetSessionTests.Counter) {
        let counter = PublicInternetSessionTests.Counter()
        let model = SessionModel(machine: machine, context: context, passwords: passwords, display: nil,
                                 clock: clock.clock, pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil,
                                 reconnectClock: reconnectClock, publicConsents: consents) { _ in
            defer { counter.value += 1 }
            return fakes[min(counter.value, fakes.count - 1)]
        }
        let surface = FakeSurface(log: log)
        surface.session = model
        model.surface = surface
        surfaces.all.append(surface)
        return (model, counter)
    }

    private func firstFrame(_ model: SessionModel, _ fake: FakeSessionConnection) async {
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { model.phase == .connected })
    }

    private func editor(tester: FakeConnectionTester) -> MachineEditorModel {
        MachineEditorModel(machine: machine, context: context, passwords: passwords, tester: tester,
                           defaultSharedClipboard: true, publicConsents: consents)
    }

    /// 3: the Test button stops at an unconfirmed public address, before any credential, and says so.
    @Test func theEditorTestRefusesAnUnconfirmedPublicAddress() async throws {
        let tester = FakeConnectionTester(address: Self.publicAddress)
        let model = editor(tester: tester)
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.publicAddressNotConfirmed) })
        #expect(await tester.calls.map(\.allowsPublicInternet) == [false])
        for language in ["fr", "en"] {
            let t: (String) -> String = { Strings.table[language]?[$0] ?? $0 }
            let text = TestConnectionFailure.publicAddressNotConfirmed.message(t)
            #expect(text != "test_public_not_confirmed" && text.count > 30, "\(language)")
        }

        consents.confirm(machine.id, host: machine.host)
        model.testConnection()
        #expect(await waitUntil { model.testState == .succeeded })
        #expect(await tester.calls.last?.allowsPublicInternet == true)

        // 5: a new host is unconfirmed.
        model.host = "elsewhere.example.com"
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.publicAddressNotConfirmed) })
        #expect(await tester.calls.last?.allowsPublicInternet == false)
    }

    @Test func aNewMachineIsNeverConfirmed() async throws {
        let tester = FakeConnectionTester(address: Self.publicAddress)
        let model = MachineEditorModel(machine: nil, context: context, passwords: passwords, tester: tester,
                                       defaultSharedClipboard: true, publicConsents: consents)
        model.name = "New"
        model.host = "203.0.113.9"
        model.username = "v"
        model.testConnection()
        #expect(await waitUntil { model.testState == .failed(.publicAddressNotConfirmed) })
    }

    /// 5: the session asks again after the host was edited.
    @Test func aHostEditInvalidatesTheConfirmation() async throws {
        consents.confirm(machine.id, host: "old.example.com")
        let fake = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, _) = session([fake])
        model.connect()
        #expect(await waitUntil { model.publicAddressConsent != nil })
        #expect(await fake.allowedPublic == [false])
        await model.close()
    }

    /// 11: a new attempt clears the sheet before it runs.
    @Test func aNewAttemptClearsThePendingConsent() async throws {
        let refused = FakeSessionConnection(log: log, address: Self.publicAddress)
        let hanging = FakeSessionConnection(log: log, hangs: true)
        let (model, made) = session([refused, hanging])
        model.connect()
        #expect(await waitUntil { model.publicAddressConsent != nil })
        model.connect()   // e.g. a Connect from the Library while the sheet is up
        #expect(await waitUntil { made.value == 2 })
        #expect(model.publicAddressConsent == nil)
        #expect(model.isConnecting)
        await model.close()
    }

    /// 12a: a toolbar choice made on the LAN does not carry onto a reconnect that lands on the Internet.
    @Test func aLANToolbarChoiceDoesNotCarryOntoAPublicReconnect() async throws {
        consents.confirm(machine.id, host: machine.host)
        let lan = FakeSessionConnection(log: log)
        let pub = FakeSessionConnection(log: log, address: Self.publicAddress)
        let (model, made) = session([lan, pub])
        model.connect()
        await firstFrame(model, lan)
        model.setClipboardSharingFromToolbar(false)
        model.setClipboardSharingFromToolbar(true)
        #expect(model.clipboardSharing)
        await lan.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(.seconds(2)) == 1 })
        reconnectClock.fire(.seconds(2))
        #expect(await waitUntil { made.value == 2 })
        await firstFrame(model, pub)
        #expect(!model.clipboardSharing)
        #expect(await pub.clipboardSharing.first == false)
        await model.close()
    }

    /// 4: a password set and a server offering no authentication only: its own banner.
    @Test func noPasswordAuthenticationHasItsBanner() throws {
        let failure = try #require(SessionFailure(openError: .requiredSecurityTypeMissing(required: 2, offered: [1])))
        #expect(failure == .connect(.passwordAuthenticationMissing(offered: [1])))
        #expect(failure.action == .editCredentials && failure.outcome == .authFailed)
        for language in ["fr", "en"] {
            let t: (String) -> String = { Strings.table[language]?[$0] ?? $0 }
            let text = failure.message(t)
            #expect(text.hasSuffix("(1)") && !text.contains("test_password_auth_missing"), "\(language): \(text)")
        }
        // Apple DH missing keeps its own wording.
        #expect(TestConnectionFailure(.requiredSecurityTypeMissing(required: 30, offered: [1]))
            == .appleAuthenticationMissing(offered: [1]))
    }
}
