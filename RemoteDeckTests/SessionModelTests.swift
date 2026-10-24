import AppKit
import Foundation
import os
import Security
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

// MARK: - Fakes

/// One ordered log shared by the fake surface (main actor) and the fake connection (its own actor and
/// the sender's task), so the teardown order can be asserted across both.
final class SessionLog: Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// A scripted `SessionConnection`: `connect` answers `connectResult` (or hangs until cancelled or
/// closed), events are pushed by the test, sends are slow so a close that does not wait for them shows.
actor FakeSessionConnection: SessionConnection {
    let log: SessionLog
    private var connectResult: Result<Void, RFBError>
    private let hangs: Bool
    private let sendDelay: Duration
    private(set) var credentials: RFBCredentials?
    private(set) var sent: [[ClientMessage]] = []
    private var continuation: AsyncThrowingStream<RFBEvent, any Error>.Continuation?
    private var closed = false
    var bytes: Int64 = 4242

    init(log: SessionLog, connectResult: Result<Void, RFBError> = .success(()), hangs: Bool = false,
         sendDelay: Duration = .milliseconds(50)) {
        self.log = log
        self.connectResult = connectResult
        self.hangs = hangs
        self.sendDelay = sendDelay
    }

    func connect(credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
        self.credentials = credentials
        log.append("connect")
        if hangs {
            // Like RFBConnection.open: cancellation (or a close) ends the attempt.
            while !closed && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw closed ? .network("closed") : .cancelled
        }
        try connectResult.get()
    }

    func events() async throws(RFBError) -> any AsyncSequence<RFBEvent, any Error> & Sendable {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RFBEvent.self)
        // Like RFBSessionEvents: a consumer that stops iterating (task cancelled) closes the socket.
        continuation.onTermination = { [log] reason in
            if case .cancelled = reason { log.append("close (stream dropped)") }
        }
        self.continuation = continuation
        return stream
    }

    func send(_ messages: [ClientMessage]) async throws(RFBError) {
        try? await Task.sleep(for: sendDelay)
        sent.append(messages)
        log.append("send \(messages.count)")
    }

    func close() {
        closed = true
        log.append("close")
        continuation?.finish()
        continuation = nil
    }

    var receivedByteCount: Int64 { bytes }

    private(set) var clipboardSharing: [Bool] = []
    private(set) var sharedTexts: [String] = []

    func setClipboardSharing(_ on: Bool) { clipboardSharing.append(on) }

    /// A share that never returns, as on a frozen peer (not even when closed).
    var shareHangs = false

    /// Like `RFBConnection`: refused (nothing sent) unless sharing was turned on first.
    func shareClipboard(_ text: String) async throws(RFBError) -> ClipboardShare {
        guard clipboardSharing.last == true else { return .notSharing }
        sharedTexts.append(text)
        while shareHangs { try? await Task.sleep(for: .milliseconds(5)) }
        return .sent(echo: text)
    }

    func setShareHangs(_ hangs: Bool) { shareHangs = hangs }

    var hasEvents: Bool { continuation != nil }

    /// What `framebufferSnapshot` returns (the Claude Assistant's screenshot).
    var snapshot: Framebuffer?
    func framebufferSnapshot() -> Framebuffer? { snapshot }
    func setSnapshot(_ framebuffer: Framebuffer?) { snapshot = framebuffer }

    func emit(_ event: RFBEvent) { continuation?.yield(event) }

    func fail(_ error: RFBError) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

/// Records what the session asks of its view. Releasing or tearing down enqueues one key release
/// through the session, as `FramebufferView` does (InputTranslator.releaseAll).
@MainActor
final class FakeSurface: SessionSurface {
    let log: SessionLog
    weak var session: SessionModel?
    static let release: [ClientMessage] = [.keyEvent(down: false, key: Keysym.altL)]
    /// Runs as the release starts (the assistant's state at that moment, T5.1).
    var onRelease: (() -> Void)?

    init(log: SessionLog) { self.log = log }

    func startCapture() { log.append("capture") }

    func releaseCapture() {
        onRelease?()
        log.append("release")
        session?.sendInput(Self.release)
    }

    func tearDownInput() {
        log.append("tearDown")
        session?.sendInput(Self.release)
    }
}

@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var uptime: TimeInterval = 100
    var clock: SessionClock { SessionClock(now: { self.now }, uptime: { self.uptime }) }
}

let frame = RFBEvent.framebufferUpdate(FramebufferUpdate(
    width: 2, height: 2, regions: [.init(rect: RFBRect(x: 0, y: 0, width: 2, height: 2), pixels: [0, 0, 0, 0])]))

// MARK: - Tests

@MainActor
struct SessionModelTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let log = SessionLog()
    let clock = FakeClock()
    let machine: Machine
    /// `SessionModel.surface` is weak, as the real view owns itself: the test keeps its fakes alive.
    let surfaces = SurfaceHolder()
    /// The reconnect delay (T5.1) only ends when a test fires it.
    let reconnectClock = FakeReachabilityClock()

    @MainActor final class SurfaceHolder { var all: [FakeSurface] = [] }

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
        machine = Machine(name: "Mini", kind: .macARD, host: "mini.local", port: 5900, username: "vincent",
                          scalingMode: .actual)
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "s3cret"
    }

    /// A session whose connections are `fakes` (one per attempt, in order).
    private func session(_ fakes: [FakeSessionConnection], pasteboard: InMemoryPasteboard = InMemoryPasteboard())
        -> (SessionModel, FakeSurface, Counter) {
        let counter = Counter()
        let model = SessionModel(machine: machine, context: context, passwords: passwords, display: nil,
                                 clock: clock.clock, pasteboard: pasteboard, clipboardPollInterval: nil,
                                 reconnectClock: reconnectClock) { _ in
            defer { counter.value += 1 }
            return fakes[min(counter.value, fakes.count - 1)]
        }
        let surface = FakeSurface(log: log)
        surface.session = model
        model.surface = surface
        surfaces.all.append(surface)
        return (model, surface, counter)
    }

    @MainActor final class Counter { var value = 0 }

    private func records() throws -> [SessionRecord] {
        try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    /// Connects `model` through `fake` and delivers the first frame `elapsed` seconds after the click.
    private func connectToFirstFrame(_ model: SessionModel, _ fake: FakeSessionConnection,
                                     elapsed: TimeInterval = 1.234) async throws {
        model.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        clock.uptime += elapsed
        clock.now += elapsed
        await fake.emit(frame)
        #expect(await waitUntil { model.phase == .connected })
    }

    // MARK: Connect and record

    @Test func firstFrameRecordsConnectTimeAndStartsCapture() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        #expect(model.scalingMode == .actual)
        #expect(model.target.modifierProfile == .appleRemoteDesktop)

        model.connect()
        #expect(model.phase == .connecting)
        let started = try #require(try records().first)
        #expect(started.outcomeValue == .cancelled)   // until the first frame (a kill mid-connect)
        #expect(started.machineID == machine.id && started.machineName == "Mini")
        #expect(started.startedAt == clock.now)

        #expect(await waitUntilAsync { await fake.hasEvents })
        #expect(model.opening == nil)   // the only task holding the credentials is gone
        clock.uptime += 1.234
        clock.now += 1.234
        await fake.emit(frame)
        #expect(await waitUntil { model.phase == .connected })

        let record = try #require(try records().first)
        #expect(record.outcomeValue == .connected)
        #expect(record.connectMillis == 1234)
        #expect(record.endedAt == nil)
        #expect(machine.lastConnectedAt == clock.now)
        #expect(machine.lastConnectedAt != record.startedAt)
        #expect(log.all == ["connect", "capture"])
        let credentials = try #require(await fake.credentials)
        #expect(credentials.username == "vincent" && credentials.password == "s3cret")
    }

    @Test func localPasswordIsUsedWhenNoSyncedItem() async throws {
        passwords.items[machine.id] = nil
        passwords.localItems[machine.id] = "local-only"
        passwords.syncedReadError = .missingEntitlement
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntilAsync { await fake.credentials != nil })
        #expect(await fake.credentials?.password == "local-only")
    }

    // MARK: Shared Clipboard (T4.1)

    /// Machine.sharedClipboard on: the connection is told before its events start, remote text lands
    /// on the (fake) pasteboard, and local text goes out only once the window is key.
    @Test func sharedClipboardBothWays() async throws {
        let pasteboard = InMemoryPasteboard()
        pasteboard.content = .text("local")
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake], pasteboard: pasteboard)
        try await connectToFirstFrame(model, fake)
        #expect(await fake.clipboardSharing == [true])
        #expect(pasteboard.reads == 0)   // window not key yet

        model.windowKeyChanged(true)
        #expect(await waitUntilAsync { await fake.sharedTexts == ["local"] })

        await fake.emit(.serverCutText("from remote"))
        #expect(await waitUntil { pasteboard.content == .text("from remote") })
        model.clipboard.poll()   // the text just written is not sent back
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.sharedTexts == ["local"])
        await model.close()
    }

    @Test func sharedClipboardOffExchangesNothing() async throws {
        machine.sharedClipboard = false
        let pasteboard = InMemoryPasteboard()
        pasteboard.content = .text("local")
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake], pasteboard: pasteboard)
        try await connectToFirstFrame(model, fake)
        #expect(await fake.clipboardSharing == [false])
        model.windowKeyChanged(true)
        await fake.emit(.serverCutText("from remote"))
        await fake.emit(frame)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pasteboard.content == .text("local"))
        #expect(pasteboard.reads == 0)
        #expect(await fake.sharedTexts.isEmpty)

        // The toolbar toggle turns it on for this session only.
        model.clipboardSharing = true
        #expect(await waitUntilAsync { await fake.sharedTexts == ["local"] })
        #expect(await fake.clipboardSharing == [false, true])
        #expect(machine.sharedClipboard == false)
        await model.close()
    }

    /// A share stuck on a frozen peer does not hold up the next connection (each connect starts a
    /// fresh clipboard chain).
    @Test func stuckShareDoesNotDelayTheNextConnection() async throws {
        let pasteboard = InMemoryPasteboard()
        pasteboard.content = .text("local")
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log)
        await first.setShareHangs(true)
        let (model, _, _) = session([first, second], pasteboard: pasteboard)
        try await connectToFirstFrame(model, first)
        model.windowKeyChanged(true)
        #expect(await waitUntilAsync { await first.sharedTexts == ["local"] })   // and stuck there
        await first.fail(.network("gone"))
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) && reconnectClock.pendingCount == 1 })
        reconnectClock.fire(.seconds(2))   // the automatic attempt (T5.1)
        #expect(await waitUntilAsync { await second.hasEvents })
        #expect(await second.clipboardSharing == [true])
        await first.setShareHangs(false)
        await model.close()
    }

    // MARK: Teardown order (TRD › Input)

    @Test func closeReleasesInputThenFinishesSenderThenClosesConnection() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        try await connectToFirstFrame(model, fake)
        clock.now += 60

        await model.close()

        #expect(log.all == ["connect", "capture", "tearDown", "send 1", "close"])
        #expect(await fake.sent == [FakeSurface.release])
        #expect(model.phase == .closed)
        let record = try #require(try records().first)
        #expect(record.outcomeValue == .connected)
        #expect(record.endedAt == clock.now)
        #expect(record.bytesReceived == 4242)
        // Input after the close goes nowhere.
        model.sendInput(FakeSurface.release)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fake.sent.count == 1)
    }

    /// A drop releases the input before closing, records `dropped`, and waits for the automatic
    /// attempt (T5.1) without a banner; Reconnect from there starts a new connection and record.
    @Test func connectionLostReleasesBeforeClosingAndWaitsToReconnect() async throws {
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log)
        let (model, _, counter) = session([first, second])
        try await connectToFirstFrame(model, first)

        await first.fail(.connectionClosed)
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) })
        #expect(await waitUntil { log.all.last == "close" })
        #expect(log.all == ["connect", "capture", "release", "send 1", "close"])
        #expect(model.failure == nil)
        #expect(model.overlay == .reconnecting)
        #expect(SessionFailure.connectionLost.action == .reconnect)
        #expect(SessionFailure.connectionLost.message(english) == "Connection lost")
        #expect(try records().first?.outcomeValue == .dropped)
        #expect(await waitUntil { (try? records().first?.bytesReceived) == 4242 })

        // The automatic attempt (the overlay offers no Reconnect): a new connection and a new record.
        #expect(await waitUntil { reconnectClock.pending(.seconds(2)) == 1 })
        reconnectClock.fire(.seconds(2))
        #expect(await waitUntil { counter.value == 2 })
        #expect(await waitUntilAsync { await second.hasEvents })
        await second.emit(frame)
        #expect(await waitUntil { model.phase == .connected })
        let all = try records()
        #expect(all.map(\.outcomeValue) == [.dropped, .connected])
    }

    @Test func streamEndingWithoutErrorIsAConnectionLoss() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        try await connectToFirstFrame(model, fake)
        await fake.close()   // the stream finishes with nil, but the user did not ask
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) })
        #expect(try records().first?.outcomeValue == .dropped)
    }

    // MARK: Cancel

    @Test func cancelWhileConnectingRecordsCancelled() async throws {
        let fake = FakeSessionConnection(log: log, hangs: true)
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntilAsync { await fake.credentials != nil })
        clock.now += 3

        await model.close()

        #expect(model.phase == .closed)
        #expect(model.failure == nil)
        let record = try #require(try records().first)
        #expect(record.outcomeValue == .cancelled)
        #expect(record.connectMillis == nil)
        #expect(record.endedAt == clock.now)
        // The attempt's late error never turns into a banner.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .closed)
    }

    /// endedAt is the moment of the click, not the end of the teardown.
    @Test func endTimeIsTheClickNotTheTeardown() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        try await connectToFirstFrame(model, fake)
        clock.now += 30
        let clicked = clock.now
        let record = try #require(model.beginClose())
        #expect(record.endedAt == clicked)
        clock.now += 5
        await model.completeClose(record: record)
        #expect(record.endedAt == clicked)
        #expect(record.outcomeValue == .connected)
        #expect(record.bytesReceived == 4242)
    }

    /// Cancel and the first frame in the same turn: Cancel wins, nothing says "connected".
    @Test func cancelRacingTheFirstFrameStaysCancelled() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        let record = try #require(model.beginClose())
        await fake.emit(frame)
        try await Task.sleep(for: .milliseconds(100))
        #expect(record.outcomeValue == .cancelled)
        #expect(record.connectMillis == nil)
        #expect(machine.lastConnectedAt == nil)
        #expect(!log.all.contains("capture"))
        await model.completeClose(record: record)
    }

    @Test func connectWhileConnectingIsIgnored() async throws {
        let fake = FakeSessionConnection(log: log, hangs: true)
        let (model, _, counter) = session([fake])
        model.connect()
        model.connect()
        #expect(counter.value == 1)
        #expect(try records().count == 1)
        await model.close()
    }

    /// A peer that never takes the queued input (send stuck) cannot hold the close: after
    /// `stopTimeout` the connection is closed anyway.
    @Test(.timeLimit(.minutes(1))) func frozenPeerDoesNotBlockTheClose() async throws {
        let fake = FakeSessionConnection(log: log, sendDelay: .seconds(3600))
        let (model, _, _) = session([fake])
        model.stopTimeout = .milliseconds(200)
        try await connectToFirstFrame(model, fake)
        let start = ContinuousClock.now
        await model.close()
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(log.all.last == "close")
        #expect(await fake.sent.isEmpty)
    }

    /// Reconnect from the banner while the failed attempt is still tearing down: the failed record
    /// still gets its bytes. (A loss before the first frame, so the banner shows at once: after it,
    /// the automatic attempt comes first, T5.1.)
    @Test func retryDuringTheFailureTeardownKeepsTheBytes() async throws {
        let first = FakeSessionConnection(log: log, sendDelay: .milliseconds(300))
        let second = FakeSessionConnection(log: log, hangs: true)
        let (model, _, _) = session([first, second])
        model.connect()
        #expect(await waitUntilAsync { await first.hasEvents })
        await first.fail(.connectionClosed)
        #expect(await waitUntil { model.failure == .connectionLost })
        clock.now += 1
        model.connect()   // the banner's Reconnect, before the release has been written
        #expect(!log.all.contains("close"))
        #expect(await waitUntil { log.all.contains("close") })
        // The bytes are read from the connection after its close: poll for them (fails if never set).
        #expect(await waitUntil { (try? records().first?.bytesReceived) == 4242 })
        let all = try records()
        #expect(all.count == 2)
        #expect(all.first?.outcomeValue == .dropped)
        await model.close()
    }

    // MARK: Errors → banner

    @Test func authFailureOffersEditCredentials() async throws {
        let fake = FakeSessionConnection(log: log, connectResult: .failure(.authFailed(reason: nil)))
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .connect(.authFailed(reason: nil)))
        #expect(model.failure?.action == .editCredentials)
        #expect(model.failure?.message(english) == "Authentication failed")
        #expect(model.opening == nil)
        #expect(await waitUntil { log.all.last == "close" })
        let record = try #require(try records().first)
        #expect(record.outcomeValue == .authFailed)
        #expect(record.endedAt != nil)
        #expect(record.connectMillis == nil)
    }

    @Test func unreadablePasswordIsAnAuthenticationProblem() async throws {
        passwords.readError = .interactionNotAllowed
        let fake = FakeSessionConnection(log: log)
        let (model, _, counter) = session([fake])
        model.connect()
        #expect(model.failure == .passwordUnreadable(status: errSecInteractionNotAllowed))
        #expect(model.failure?.action == .editCredentials)
        #expect(counter.value == 0)   // nothing was sent
        #expect(try records().first?.outcomeValue == .authFailed)
    }

    @Test func unreachableOffersRetryAndRetryConnectsAgain() async throws {
        let failing = FakeSessionConnection(log: log, connectResult: .failure(.network("no route")))
        let working = FakeSessionConnection(log: log)
        let (model, _, counter) = session([failing, working])
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure?.action == .retry)
        #expect(model.failure?.message(english) == english("test_unreachable"))
        #expect(try records().first?.outcomeValue == .unreachable)

        model.connect()
        #expect(model.phase == .connecting)
        #expect(counter.value == 2)
        #expect(await waitUntilAsync { await working.hasEvents })
    }

    @Test func retryUsesEditedMachine() async throws {
        let failing = FakeSessionConnection(log: log, connectResult: .failure(.authFailed(reason: nil)))
        let working = FakeSessionConnection(log: log)
        let (model, _, _) = session([failing, working])
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        machine.username = "admin"
        passwords.items[machine.id] = "fixed"
        model.connect()
        #expect(await waitUntilAsync { await working.credentials != nil })
        #expect(await working.credentials?.username == "admin")
        #expect(await working.credentials?.password == "fixed")
    }

    /// Every RFBError maps to a banner, an action and an outcome (BackendSchema › SessionRecord).
    @Test func failureMapping() {
        let cases: [(RFBError, SessionFailure.Action, SessionOutcome, String)] = [
            (.authFailed(reason: "bad"), .editCredentials, .authFailed, "Authentication failed — bad"),
            (.credentialsRequired(securityType: 30), .editCredentials, .authFailed, english("test_needs_username_password")),
            (.credentialsRequired(securityType: 2), .editCredentials, .authFailed, english("test_needs_password")),
            (.credentialTooLong, .editCredentials, .authFailed, english("test_credential_too_long")),
            (.network("x"), .retry, .unreachable, english("test_unreachable")),
            (.timeout, .retry, .unreachable, "Unreachable — no answer within 10 s"),
            (.connectionClosed, .retry, .unreachable, english("test_closed")),
            (.connectionRefused(reason: nil), .retry, .unreachable, english("test_refused")),
            (.unsupportedSecurityTypes([5]), .retry, .unreachable, "\(english("test_unsupported")) (5)"),
            (.unsupportedVersion("SSH-2.0"), .retry, .unreachable, english("test_not_rfb")),
            (.protocolViolation("x"), .retry, .unreachable, english("test_unexpected")),
        ]
        for (error, action, outcome, message) in cases {
            let failure = SessionFailure(openError: error)
            #expect(failure?.action == action, "\(error)")
            #expect(failure?.outcome == outcome, "\(error)")
            #expect(failure?.message(english) == message, "\(error)")
        }
        #expect(SessionFailure(openError: .cancelled) == nil)
        #expect(SessionFailure.connectionLost.outcome == .dropped)
    }

    // MARK: Machine kind

    @Test func modifierProfileAndCredentialsFollowTheKind() {
        let vm = Machine(name: "VM", kind: .anthropicVM, host: "127.0.0.1", username: "ignored")
        let vnc = Machine(name: "NAS", kind: .vnc, host: "nas.local")
        #expect(SessionTarget(vm).modifierProfile == .x11)
        #expect(SessionTarget(vnc).modifierProfile == .x11)
        #expect(SessionTarget(machine).modifierProfile == .appleRemoteDesktop)

        let vmCredentials = RFBCredentials(kind: .anthropicVM, username: "ignored", password: "pw")
        #expect(vmCredentials.username == nil && vmCredentials.password == "pw")
        let blank = RFBCredentials(kind: .macARD, username: "  ", password: "")
        #expect(blank.username == nil && blank.password == nil)
        let ard = RFBCredentials(kind: .macARD, username: " vincent ", password: "pw")
        #expect(ard.username == "vincent")
    }

    /// AC4 path: an Anthropic VM with no stored password (or an empty one) connects with no
    /// credentials at all, so `RFBHandshake` picks security type 1 when the server offers it.
    @Test(arguments: [nil, ""] as [String?])
    func anthropicVMWithoutPasswordConnectsWithNoCredentials(stored: String?) async throws {
        machine.kindValue = .anthropicVM
        machine.username = "left-over"
        passwords.items[machine.id] = stored
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        #expect(model.target.modifierProfile == .x11)
        model.connect()
        #expect(await waitUntilAsync { await fake.credentials != nil })
        let credentials = try #require(await fake.credentials)
        #expect(credentials.username == nil && credentials.password == nil)
        await model.close()
    }

    /// A VNC-password-only server and no password: the banner says a password is needed and offers
    /// Edit credentials (AppFlow › Session Window).
    @Test func anthropicVMOnPasswordOnlyServerAsksForCredentials() async throws {
        machine.kindValue = .anthropicVM
        passwords.items[machine.id] = nil
        let fake = FakeSessionConnection(log: log, connectResult: .failure(.credentialsRequired(securityType: 2)))
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .connect(.credentialsRequired(username: false)))
        #expect(model.failure?.action == .editCredentials)
        #expect(model.failure?.message(english) == english("test_needs_password"))
        #expect(try records().first?.outcomeValue == .authFailed)
    }
}

// MARK: - Connect validation

@MainActor
struct ConnectValidationTests {
    /// The Library toolbar, double-click/Return and the detail pane share `Machine.canConnect`.
    @Test func hostAndPortAreRequired() {
        #expect(Machine(name: "A", host: "mini.local", port: 5900).canConnect)
        #expect(Machine(name: "A", host: "mini.local", port: 65535).canConnect)
        #expect(!Machine(name: "A", host: "  ", port: 5900).canConnect)
        #expect(!Machine(name: "A", host: "mini.local", port: 0).canConnect)
        #expect(!Machine(name: "A", host: "mini.local", port: 70000).canConnect)
    }
}

// MARK: - SessionManager

@MainActor
struct SessionManagerTests {
    @Test func oneSessionPerMachineUntilItsWindowCloses() async throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(machine)
        try context.save()
        let log = SessionLog()
        var made = 0
        let manager = SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                                     makeConnection: { _ in
                                         made += 1
                                         return FakeSessionConnection(log: log, hangs: true)
                                     }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard())

        let first = try #require(manager.session(for: machine.id))
        let again = try #require(manager.session(for: machine.id))
        #expect(first === again)          // Connect on an open machine reuses (and focuses) its window
        #expect(made == 1)
        #expect(manager.isConnecting(machine.id))

        manager.close(machine.id)
        #expect(manager.sessions.isEmpty)
        #expect(await waitUntil { first.phase == .closed })
        let fresh = try #require(manager.session(for: machine.id))
        #expect(fresh !== first)
        #expect(made == 2)
        manager.close(machine.id)

        #expect(manager.session(for: UUID()) == nil)   // deleted machine
    }

    /// ⌘Q: a session still connecting ends `cancelled`, and one whose window was closing already has
    /// its end time (written when the window closed, not after its teardown).
    @Test func quitAlwaysLeavesAnEndTime() async throws {
        let context = try makeTestContext()
        let connecting = Machine(name: "Mini", host: "mini.local", username: "vincent")
        let closing = Machine(name: "Studio", host: "studio.local", username: "vincent")
        context.insert(connecting)
        context.insert(closing)
        try context.save()
        let center = NotificationCenter()
        let manager = SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                                     makeConnection: { _ in FakeSessionConnection(log: SessionLog(), hangs: true) },
                                     makeDisplay: { nil }, pasteboard: InMemoryPasteboard(),
                                     notificationCenter: center)
        _ = try #require(manager.session(for: connecting.id))
        _ = try #require(manager.session(for: closing.id))

        manager.close(closing.id)   // window closed; its teardown runs later
        let records = { try context.fetch(FetchDescriptor<SessionRecord>()) }
        let closedRecord = try #require(try records().first { $0.machineID == closing.id })
        #expect(closedRecord.endedAt != nil)
        #expect(closedRecord.outcomeValue == .cancelled)

        center.post(name: NSApplication.willTerminateNotification, object: nil)
        let quitRecord = try #require(try records().first { $0.machineID == connecting.id })
        #expect(quitRecord.endedAt != nil)
        #expect(quitRecord.outcomeValue == .cancelled)
        #expect(manager.sessions[connecting.id]?.phase == .closed)
        manager.close(connecting.id)
    }

    /// Connect twice (double-click then Return, or two Connects in one run-loop turn): one window,
    /// one connection; the second brings the window forward.
    @Test func secondConnectBringsTheWindowForward() async throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(machine)
        try context.save()
        var made = 0
        let manager = SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                                     makeConnection: { _ in
                                         made += 1
                                         return FakeSessionConnection(log: SessionLog(), hangs: true)
                                     }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard())

        #expect(manager.requestWindow(for: machine.id))   // open a window
        let session = try #require(manager.sessions[machine.id])
        #expect(session.isConnecting)                    // connecting before the window appears
        var broughtForward = 0
        session.bringWindowForward = { broughtForward += 1 }
        #expect(!manager.requestWindow(for: machine.id))  // no second window
        #expect(broughtForward == 1)
        #expect(made == 1)
        #expect(!manager.requestWindow(for: UUID()))
        manager.close(machine.id)
    }
}

/// Polls an async condition (actor state) up to `timeout`.
@MainActor
func waitUntilAsync(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
