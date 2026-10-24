import AppKit
import Network
import ClaudeKit
import Foundation
import Security
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

// T5.1 (TRD › Architecture › Session resilience): dropped connections, sleep and wake, network
// changes. Every timer runs on `FakeReachabilityClock`, so nothing fires unless the test fires it:
// 2 s is the reconnect delay, 5 s the wake grace.

private let reconnectDelay: Duration = .seconds(2)
private let wakeGrace: Duration = .seconds(5)
private let pathLossGrace: Duration = .seconds(3)

// MARK: - SessionModel

@MainActor
struct SessionResilienceTests {
    let container: ModelContainer
    let context: ModelContext
    let passwords = FakePasswordStore()
    let log = SessionLog()
    let clock = FakeClock()
    let reconnectClock = FakeReachabilityClock()
    let machine: Machine
    let surfaces = Surfaces()

    @MainActor final class Surfaces { var all: [FakeSurface] = [] }
    @MainActor final class Made { var count = 0 }

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
        machine = Machine(name: "Mini", kind: .macARD, host: "mini.local", port: 5900, username: "vincent")
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "s3cret"
    }

    /// A session whose attempts use `fakes` in order (the last one again if more are asked for).
    private func session(_ fakes: [FakeSessionConnection]) -> (SessionModel, FakeSurface, Made) {
        let made = Made()
        let model = SessionModel(machine: machine, context: context, passwords: passwords, display: nil,
                                 clock: clock.clock, pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil,
                                 reconnectClock: reconnectClock) { _ in
            defer { made.count += 1 }
            return fakes[min(made.count, fakes.count - 1)]
        }
        let surface = FakeSurface(log: log)
        surface.session = model
        model.surface = surface
        surfaces.all.append(surface)
        return (model, surface, made)
    }

    private func records() throws -> [SessionRecord] {
        try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    private func firstFrame(_ model: SessionModel, _ fake: FakeSessionConnection) async {
        #expect(await waitUntilAsync { await fake.hasEvents })
        clock.now += 1
        clock.uptime += 1
        await fake.emit(frame)
        #expect(await waitUntil { model.phase == .connected })
    }

    @Test func dropGetsOneAutomaticReconnect() async throws {
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log)
        let (model, _, made) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        #expect(!model.isAutomaticAttempt)

        await first.fail(.connectionClosed)
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) && reconnectClock.pending(reconnectDelay) == 1 })
        #expect(model.overlay == .reconnecting)
        #expect(model.failure == nil)
        #expect(made.count == 1)   // nothing before the delay

        clock.now += 2
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        #expect(model.isConnecting && model.isAutomaticAttempt)
        #expect(model.overlay == .reconnecting)
        await firstFrame(model, second)
        #expect(try records().map(\.outcomeValue) == [.dropped, .connected])
        #expect(reconnectClock.pendingCount == 0)
        await model.close()
    }

    @Test func failedAutomaticAttemptShowsTheBannerAndNeverRetries() async throws {
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log, connectResult: .failure(.network("no route")))
        let (model, _, made) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        await first.fail(.network("reset"))
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)

        #expect(await waitUntil { model.failure == .connectionLost })
        #expect(model.failure?.action == .reconnect)
        #expect(model.failure?.message(english) == "Connection lost")
        #expect(model.overlay == nil)
        // The banner is the loss's; the failed attempt keeps its own outcome.
        #expect(try records().map(\.outcomeValue) == [.dropped, .unreachable])
        try await Task.sleep(for: .milliseconds(100))
        #expect(reconnectClock.pendingCount == 0)
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.count == 2)
        #expect(try records().count == 2)
    }

    /// The automatic attempt connects but drops again at once: no second automatic attempt (a server
    /// that drops every session never loops). Held for `rearmAfter`, the next drop gets one again.
    @Test func automaticAttemptDroppingSoonGetsNoOther() async throws {
        let fakes = (0..<4).map { _ in FakeSessionConnection(log: log) }
        let (model, _, made) = session(fakes)
        model.connect()
        await firstFrame(model, fakes[0])
        await fakes[0].fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        await firstFrame(model, fakes[1])

        clock.uptime += 61   // held long enough: re-armed
        await fakes[1].fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        await firstFrame(model, fakes[2])

        clock.uptime += 5    // drops again 5 s after its first frame
        await fakes[2].fail(.connectionClosed)
        #expect(await waitUntil { model.failure == .connectionLost })
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pendingCount == 0)
        #expect(made.count == 3)
        #expect(try records().map(\.outcomeValue) == [.dropped, .dropped, .dropped])
    }

    @Test func authFailureDuringAutomaticReconnectShowsTheAuthBannerAndStops() async throws {
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log, connectResult: .failure(.authFailed(reason: "bad password")))
        let (model, _, made) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        await first.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)

        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .connect(.authFailed(reason: "bad password")))
        #expect(model.failure?.action == .editCredentials)   // the user opens the editor; nothing does it for them
        #expect(try records().map(\.outcomeValue) == [.dropped, .authFailed])
        try await Task.sleep(for: .milliseconds(100))
        #expect(reconnectClock.pendingCount == 0)
        #expect(made.count == 2)
    }

    /// A drop before the first frame is not a drop of a session the user saw: the banner, as before.
    @Test func lossBeforeTheFirstFrameShowsTheBannerAtOnce() async throws {
        let fake = FakeSessionConnection(log: log)
        let (model, _, _) = session([fake])
        model.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.fail(.connectionClosed)
        #expect(await waitUntil { model.failure == .connectionLost })
        #expect(reconnectClock.pendingCount == 0)
    }

    @Test func closingTheWindowDuringTheDelayCancelsTheAttempt() async throws {
        let first = FakeSessionConnection(log: log)
        let (model, _, made) = session([first])
        model.connect()
        await firstFrame(model, first)
        await first.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        #expect(model.beginClose() == nil)   // no record open while waiting
        #expect(await waitUntil { reconnectClock.pendingCount == 0 })   // the delay was cancelled
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.count == 1)
        #expect(model.phase == .closed)
    }

    // MARK: Keychain and keyboard

    /// The automatic attempt reads the password with no dialog allowed; one that would need it fails
    /// with the "password could not be read" banner, and nothing is retried. The user's attempt reads
    /// as before.
    @Test func automaticAttemptNeverShowsAKeychainDialog() async throws {
        let first = FakeSessionConnection(log: log)
        let (model, _, made) = session([first, FakeSessionConnection(log: log)])
        model.connect()
        #expect(passwords.log == ["read.synced"])
        await firstFrame(model, first)
        passwords.interactionRequiredError = KeychainError(status: errSecInteractionNotAllowed)
        await first.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .passwordUnreadable(status: errSecInteractionNotAllowed))
        #expect(model.failure?.action == .editCredentials)
        #expect(passwords.log == ["read.synced", "read.synced.noUI"])
        #expect(made.count == 1)   // no connection without the password
        #expect(try records().map(\.outcomeValue) == [.dropped, .authFailed])
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pendingCount == 0)
    }

    @Test(arguments: [true, false])
    func automaticReconnectRecapturesOnlyIfCapturedBefore(captured: Bool) async throws {
        let first = FakeSessionConnection(log: log)
        let second = FakeSessionConnection(log: log)
        let (model, _, _) = session([first, second])
        model.connect()
        await firstFrame(model, first)
        // What the view reports (FramebufferView.onCaptureChange).
        model.inputStateChanged(capturing: captured, systemShortcutsAvailable: true)
        await first.fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        await firstFrame(model, second)
        #expect(log.all.filter { $0 == "capture" }.count == (captured ? 2 : 1))
        await model.close()
    }

    // MARK: Claude Assistant

    /// A proposal waiting for Confirm when the connection drops: the assistant is stopped before the
    /// input release, and confirming that proposal after the reconnect sends nothing.
    @Test func assistantProposalNeverRunsAfterAReconnect() async throws {
        let first = FakeSessionConnection(log: log, sendDelay: .zero)
        let second = FakeSessionConnection(log: log, sendDelay: .zero)
        await first.setSnapshot(try Framebuffer(width: 1024, height: 768))
        await second.setSnapshot(try Framebuffer(width: 1024, height: 768))
        let (model, surface, _) = session([first, second])
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [memberCall("toolu_1", "left_click", ["coordinate": [10, 20]])]),
        ])
        let assistant = AssistantModel(port: model, client: MessagesClient(transport: http), apiKey: { "sk-ant-x" },
                                       armDelay: .zero)
        model.assistant = assistant
        var phaseAtRelease: AssistantModel.Phase?
        model.connect()
        await firstFrame(model, first)
        assistant.prompt = "click"
        assistant.ask()
        #expect(await waitUntil { assistant.phase == .confirming && assistant.confirmArmed })
        surface.onRelease = { phaseAtRelease = assistant.phase }   // after the assistant's own release

        await first.fail(.connectionClosed)
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) })
        // Stopped (winding down or done) before the teardown released the input.
        #expect(phaseAtRelease == .stopping || phaseAtRelease == .failed(.disconnected))
        #expect(await waitUntil { assistant.phase == .failed(.disconnected) })
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        await firstFrame(model, second)

        assistant.confirm("toolu_1")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await second.sent.isEmpty)
        #expect(assistant.phase == .failed(.disconnected))
        await model.close()
    }

    /// Sleep while an action holds Shift: the assistant releases it first, then the view's release,
    /// then the connection closes.
    @Test func sleepStopsTheAssistantBeforeTheTeardown() async throws {
        let fake = FakeSessionConnection(log: log, sendDelay: .zero)
        await fake.setSnapshot(try Framebuffer(width: 1024, height: 768))
        let (model, surface, _) = session([fake])
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            memberCall("toolu_hold", "hold_key", ["text": "shift", "duration": 30]),
        ])])
        let assistant = AssistantModel(port: model, client: MessagesClient(transport: http), apiKey: { "sk-ant-x" },
                                       armDelay: .zero, sleep: sleepUntilCancelled)
        model.assistant = assistant
        var phaseAtRelease: AssistantModel.Phase?
        model.connect()
        await firstFrame(model, fake)
        assistant.prompt = "hold shift"
        assistant.ask()
        #expect(await waitUntil { assistant.phase == .confirming })
        await confirmWhenArmed(assistant)
        // A proposal takes the keyboard from the remote first (the view's release), then Shift goes down.
        #expect(await waitUntilAsync { await fake.sent.flatMap { $0 }.last == .keyEvent(down: true, key: Keysym.shiftL) })
        #expect(assistant.phase == .running)
        let before = await fake.sent.flatMap { $0 }.count
        surface.onRelease = { phaseAtRelease = assistant.phase }

        model.suspendForSleep()
        #expect(model.phase == .waiting(.asleep))
        #expect(phaseAtRelease == .stopping || phaseAtRelease == .failed(.disconnected))
        #expect(await waitUntil { log.all.last == "close" })
        // Shift up (the assistant), then the view's release, then the close.
        #expect(await Array(fake.sent.flatMap { $0 }.dropFirst(before))
                == [.keyEvent(down: false, key: Keysym.shiftL)] + FakeSurface.release)
        #expect(await waitUntil { assistant.phase == .failed(.disconnected) })
        await model.close()
    }
}

// MARK: - SessionManager: network path, sleep and wake

@MainActor
struct SessionManagerResilienceTests {
    let context: ModelContext
    let machine: Machine
    let log = SessionLog()
    let path = FakeNetworkPath()
    let power = NotificationCenter()
    let quit = NotificationCenter()
    let reconnectClock = FakeReachabilityClock()
    let made = Made()
    let surfaces = SessionResilienceTests.Surfaces()

    @MainActor final class Made {
        var fakes: [FakeSessionConnection] = []
        var count: Int { fakes.count }
    }

    init() throws {
        context = try makeTestContext()
        machine = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(machine)
        try context.save()
    }

    /// `fake(n)` makes the connection of attempt n (0-based); by default one that connects.
    private func manager(_ fake: @escaping @MainActor (Int, SessionLog) -> FakeSessionConnection = { _, log in
        FakeSessionConnection(log: log)
    }) -> SessionManager {
        let passwords = FakePasswordStore()
        passwords.items[machine.id] = "s3cret"
        return SessionManager(context: context, passwords: passwords, tester: FakeConnectionTester(),
                              makeConnection: { [log, made] _ in
                                  let connection = fake(made.count, log)
                                  made.fakes.append(connection)
                                  return connection
                              }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard(),
                              notificationCenter: quit, reconnectClock: reconnectClock,
                              path: path, workspaceCenter: power)
    }

    private func connected(_ manager: SessionManager) async throws -> SessionModel {
        let session = try #require(manager.session(for: machine.id))
        try await deliverFrame(session, made.fakes.last)
        return session
    }

    private func deliverFrame(_ session: SessionModel, _ fake: FakeSessionConnection?) async throws {
        let fake = try #require(fake)
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { session.phase == .connected })
    }

    /// Drops the current connection and runs the automatic attempt (its connection is the next one).
    private func dropAndReconnect(_ session: SessionModel) async throws {
        let count = made.count
        await made.fakes[count - 1].fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == count + 1 })
        #expect(session.isAutomaticAttempt)
    }

    /// The path goes and stays gone past the 3 s grace.
    private func losePath() async {
        path.send(false)
        if reconnectClock.pending(pathLossGrace) == 0 { _ = await waitUntil { reconnectClock.pending(pathLossGrace) == 1 } }
        reconnectClock.fire(pathLossGrace)
    }

    private func records() throws -> [SessionRecord] {
        try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    // MARK: Network path

    @Test func offlineMakesNoAttemptThenOneWhenTheNetworkIsBack() async throws {
        let manager = manager()
        let session = try await connected(manager)

        path.send(false)
        // Within the grace: the socket is kept, the overlay says why the screen is still.
        #expect(session.phase == .connected)
        #expect(session.overlay == .waitingForNetwork)
        #expect(await waitUntil { reconnectClock.pending(pathLossGrace) == 1 })
        #expect(!log.all.contains("close"))
        reconnectClock.fire(pathLossGrace)
        #expect(await waitUntil { session.phase == .waiting(.network) })
        #expect(session.overlay == .waitingForNetwork)
        #expect(session.failure == nil)
        #expect(await waitUntil { log.all.last == "close" })
        #expect(try records().map(\.outcomeValue) == [.dropped])
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pendingCount == 0)   // nothing scheduled while offline
        #expect(made.count == 1)

        path.send(true)
        #expect(session.phase == .waiting(.retryDelay))
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(made.count == 1)                    // the 2 s delay is respected
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        #expect(session.isAutomaticAttempt)
        try await deliverFrame(session, made.fakes.last)
        #expect(try records().map(\.outcomeValue) == [.dropped, .connected])
        #expect(made.count == 2)
        manager.close(machine.id)
        manager.stop()
    }

    @Test func pathBlipShorterThanTheGraceKeepsTheSession() async throws {
        let manager = manager()
        let session = try await connected(manager)
        path.send(false)
        #expect(await waitUntil { reconnectClock.pending(pathLossGrace) == 1 })
        path.send(true)
        #expect(session.phase == .connected)
        #expect(session.overlay == nil)
        #expect(await waitUntil { reconnectClock.pendingCount == 0 })
        reconnectClock.fire(pathLossGrace)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.phase == .connected)
        #expect(!log.all.contains("close"))
        #expect(made.count == 1)
        #expect(try records().map(\.outcomeValue) == [.connected])
        manager.close(machine.id)
        manager.stop()
    }

    /// A flapping Wi-Fi: the second path-triggered loss within 60 s of the automatic reconnect's
    /// first frame shows the banner instead of one more attempt.
    @Test func flappingPathShowsTheBannerAfterTheSecondLoss() async throws {
        let manager = manager()
        let session = try await connected(manager)
        await losePath()
        #expect(await waitUntil { session.phase == .waiting(.network) })
        path.send(true)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        try await deliverFrame(session, made.fakes.last)

        await losePath()   // seconds after the reconnect
        #expect(await waitUntil { session.failure == .connectionLost })
        #expect(await waitUntil { log.all.last == "close" })
        #expect(try records().map(\.outcomeValue) == [.dropped, .dropped])
        path.send(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pendingCount == 0)
        #expect(made.count == 2)
        manager.close(machine.id)
        manager.stop()
    }

    /// A drop while the delay runs, then no network: the delay is held, nothing is tried offline.
    @Test func networkLostDuringTheDelayHoldsTheAttempt() async throws {
        let manager = manager()
        let session = try await connected(manager)
        await made.fakes[0].fail(.network("interface changed"))   // Wi-Fi ↔ Ethernet broke the socket
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        path.send(false)
        #expect(session.phase == .waiting(.network))
        #expect(await waitUntil { reconnectClock.pendingCount == 0 })
        path.send(true)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        manager.close(machine.id)
        manager.stop()
    }

    @Test func networkLostDuringTheAutomaticAttemptCancelsItThenOneAttemptWhenBack() async throws {
        let manager = manager { n, log in FakeSessionConnection(log: log, hangs: n == 1) }
        let session = try await connected(manager)
        try await dropAndReconnect(session)   // attempt 1 hangs while connecting
        path.send(false)
        #expect(session.phase == .waiting(.network))
        #expect(await waitUntil { (try? records().map(\.outcomeValue)) == [.dropped, .cancelled] })
        #expect(try records().last?.endedAt != nil)
        path.send(true)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 3 })
        try await deliverFrame(session, made.fakes.last)
        manager.close(machine.id)
        manager.stop()
    }

    /// The user's own Connect while offline fails with its banner, and the network coming back does
    /// not run it again.
    @Test func userAttemptWhileOfflineKeepsItsBanner() async throws {
        let manager = manager { _, log in FakeSessionConnection(log: log, connectResult: .failure(.network("offline"))) }
        path.send(false)
        let session = try #require(manager.session(for: machine.id))
        #expect(await waitUntil { session.failure != nil })
        #expect(session.failure?.action == .retry)
        path.send(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pendingCount == 0)
        #expect(made.count == 1)
        #expect(session.failure != nil)
        manager.close(machine.id)
        manager.stop()
    }

    /// The banner's Reconnect is a user attempt: its later drop gets one automatic attempt again.
    @Test func bannerReconnectThenDropGetsOneAutomaticAttempt() async throws {
        let manager = manager { n, log in
            FakeSessionConnection(log: log, connectResult: n == 1 ? .failure(.network("x")) : .success(()))
        }
        let session = try await connected(manager)
        try await dropAndReconnect(session)
        #expect(await waitUntil { session.failure == .connectionLost })
        session.connect()   // the banner's Reconnect button (SessionWindowView)
        #expect(await waitUntil { made.count == 3 })
        #expect(!session.isAutomaticAttempt)
        try await deliverFrame(session, made.fakes.last)
        try await dropAndReconnect(session)
        try await deliverFrame(session, made.fakes.last)
        #expect(try records().map(\.outcomeValue) == [.dropped, .unreachable, .dropped, .connected])
        manager.close(machine.id)
        manager.stop()
    }

    // MARK: Sleep and wake

    @Test func sleepThenWakeReconnectsOnce() async throws {
        let manager = manager()
        let session = try await connected(manager)

        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(session.phase == .waiting(.asleep))
        #expect(await waitUntil { log.all.last == "close" })
        let slept = try #require(try records().first)
        #expect(slept.outcomeValue == .connected)   // a clean end, as a Disconnect
        #expect(slept.endedAt != nil)

        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        path.send(false)                    // the network flaps during the grace: still nothing
        path.send(true)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.count == 1)
        #expect(session.phase == .waiting(.asleep))
        reconnectClock.fire(wakeGrace)
        #expect(await waitUntil { made.count == 2 })
        try await deliverFrame(session, made.fakes.last)
        #expect(try records().map(\.outcomeValue) == [.connected, .connected])

        power.post(name: NSWorkspace.didWakeNotification, object: nil)   // a wake without a sleep
        try await Task.sleep(for: .milliseconds(50))
        #expect(reconnectClock.pending(wakeGrace) == 0)
        #expect(made.count == 2)
        manager.close(machine.id)
        manager.stop()
    }

    /// Sleep, wake, the grace ends while the sleep teardown still runs, and the Mac sleeps again: the
    /// reconnect that was waiting for the teardown never starts; the next wake reconnects once.
    @Test func sleepAgainBeforeTheWakeReconnectStarts() async throws {
        let manager = manager { n, log in FakeSessionConnection(log: log, sendDelay: n == 0 ? .milliseconds(800) : .zero) }
        let session = try await connected(manager)
        let surface = FakeSurface(log: log)   // its release makes the sleep teardown take 800 ms
        surface.session = session
        session.surface = surface
        surfaces.all.append(surface)

        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!log.all.contains("close"))   // still tearing down
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await waitUntil { log.all.contains("close") })
        try await Task.sleep(for: .milliseconds(100))
        #expect(made.count == 1)
        #expect(session.phase == .waiting(.asleep))

        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        #expect(await waitUntil { made.count == 2 })
        try await deliverFrame(session, made.fakes.last)
        manager.close(machine.id)
        manager.stop()
    }

    @Test(arguments: [false, true])
    func sleepWhileConnectingCancelsThenReconnectsAtWake(automatic: Bool) async throws {
        let hanging = automatic ? 1 : 0
        let manager = manager { n, log in FakeSessionConnection(log: log, hangs: n == hanging) }
        let session = try #require(manager.session(for: machine.id))
        if automatic {
            try await deliverFrame(session, made.fakes.last)
            try await dropAndReconnect(session)
        }
        #expect(session.isConnecting)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(session.phase == .waiting(.asleep))
        let expected: [SessionOutcome] = automatic ? [.dropped, .cancelled] : [.cancelled]
        #expect(await waitUntil { (try? records().map(\.outcomeValue)) == expected })
        #expect(try records().last?.endedAt != nil)
        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        #expect(await waitUntil { made.count == hanging + 2 })
        try await deliverFrame(session, made.fakes.last)
        manager.close(machine.id)
        manager.stop()
    }

    @Test func windowClosedDuringSleepNeverReconnects() async throws {
        let manager = manager()
        _ = try await connected(manager)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        manager.close(machine.id)
        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(100))
        #expect(made.count == 1)
        #expect(manager.sessions.isEmpty)
        manager.stop()
    }

    @Test func wakeWithoutNetworkWaitsForIt() async throws {
        let manager = manager()
        let session = try await connected(manager)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        path.send(false)
        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        #expect(await waitUntil { session.phase == .waiting(.network) })
        #expect(made.count == 1)
        path.send(true)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        manager.close(machine.id)
        manager.stop()
    }

    /// A session showing a banner is left alone by sleep, wake and the network.
    @Test func failedSessionIsLeftAlone() async throws {
        let manager = manager { _, log in FakeSessionConnection(log: log, connectResult: .failure(.network("x"))) }
        let session = try #require(manager.session(for: machine.id))
        #expect(await waitUntil { session.failure != nil })
        path.send(false)
        path.send(true)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { reconnectClock.pending(wakeGrace) == 1 })
        reconnectClock.fire(wakeGrace)
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(100))
        #expect(made.count == 1)
        #expect(session.failure != nil)
        manager.close(machine.id)
        manager.stop()
    }

    // MARK: Quit, close, history

    @Test func quitWhileWaitingCancelsTheAttempt() async throws {
        let manager = manager()
        let session = try await connected(manager)
        await made.fakes[0].fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        quit.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(session.phase == .closed)
        #expect(await waitUntil { reconnectClock.pendingCount == 0 })
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.count == 1)
        #expect(try records().map(\.outcomeValue) == [.dropped])
        #expect(try records().first?.endedAt != nil)
        manager.close(machine.id)
        manager.stop()
    }

    @Test func quitDuringTheAutomaticAttemptEndsItsRecord() async throws {
        let manager = manager { n, log in FakeSessionConnection(log: log, hangs: n == 1) }
        let session = try await connected(manager)
        try await dropAndReconnect(session)
        quit.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(session.phase == .closed)
        let all = try records()
        #expect(all.map(\.outcomeValue) == [.dropped, .cancelled])
        #expect(all.allSatisfy { $0.endedAt != nil })
        manager.close(machine.id)
        manager.stop()
    }

    @Test func tabClosedDuringTheAutomaticAttemptEndsIt() async throws {
        let manager = manager { n, log in FakeSessionConnection(log: log, hangs: n == 1) }
        let session = try await connected(manager)
        try await dropAndReconnect(session)
        manager.close(machine.id)
        #expect(session.phase == .closed)
        #expect(manager.sessions.isEmpty)
        #expect(try records().map(\.outcomeValue) == [.dropped, .cancelled])
        #expect(await waitUntil { log.all.last == "close" })
        path.send(false)
        path.send(true)
        reconnectClock.fire(reconnectDelay)
        try await Task.sleep(for: .milliseconds(50))
        #expect(made.count == 2)
        manager.stop()
    }

    /// No record is open while a session waits; the automatic attempt's is "In progress".
    @Test func liveRecordsFollowTheAttempts() async throws {
        let manager = manager { n, log in FakeSessionConnection(log: log, hangs: n == 1) }
        let session = try await connected(manager)
        await made.fakes[0].fail(.connectionClosed)
        #expect(await waitUntil { reconnectClock.pending(reconnectDelay) == 1 })
        #expect(session.phase == .waiting(.retryDelay))
        #expect(manager.liveRecordIDs.isEmpty)
        reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { made.count == 2 })
        #expect(session.isAutomaticAttempt)
        let record = try #require(session.record)
        #expect(manager.liveRecordIDs == [record.id])
        manager.close(machine.id)
        manager.stop()
    }

    @Test func stopLeavesThePathAndPowerAlone() async throws {
        let manager = manager()
        let session = try await connected(manager)
        manager.stop()
        #expect(path.cancelled)
        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        path.send(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.phase == .connected)
        #expect(reconnectClock.pendingCount == 0)
        manager.close(machine.id)
    }

    // MARK: Pure mappings

    /// Reachability (T4.5) skips the probe of a machine whose session waits to reconnect.
    @Test func waitingSessionCountsAsConnectingForReachability() {
        #expect(SessionModel.Phase.waiting(.retryDelay).watchedState == .connecting)
        #expect(SessionModel.Phase.waiting(.network).watchedState == .connecting)
        #expect(SessionModel.Phase.waiting(.asleep).watchedState == .connecting)
        #expect(SessionModel.Phase.connecting.watchedState == .connecting)
        #expect(SessionModel.Phase.connected.watchedState == .connected)
        #expect(SessionModel.Phase.failed(.connectionLost).watchedState == .noSession)
        #expect(SessionModel.Phase.closed.watchedState == .noSession)
        #expect(SessionModel.Phase.idle.watchedState == .noSession)
    }

    /// Sessions count a path that requires a connection (VPN on demand) as there; probes do not.
    @Test func requiresConnectionCountsForSessionsOnly() {
        #expect(NWNetworkPathMonitor.isAvailable(.requiresConnection, countingRequiresConnection: true))
        #expect(!NWNetworkPathMonitor.isAvailable(.requiresConnection, countingRequiresConnection: false))
        #expect(NWNetworkPathMonitor.isAvailable(.satisfied, countingRequiresConnection: false))
        #expect(!NWNetworkPathMonitor.isAvailable(.unsatisfied, countingRequiresConnection: true))
    }
}
