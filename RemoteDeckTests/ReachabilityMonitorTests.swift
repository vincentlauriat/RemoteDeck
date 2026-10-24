import AppKit
import Foundation
import os
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// MARK: - Fakes

/// Scripted answers per host; a host in `hanging` never answers until its task is cancelled; one
/// in `stubborn` ignores cancellation and answers only when the test releases it.
final class FakeReachabilityProbe: ReachabilityProbe {
    private struct State {
        var answers: [String: ProbeOutcome] = [:]
        var hanging: Set<String> = []
        var stubborn: Set<String> = []
        var stubbornWaiters: [CheckedContinuation<Void, Never>] = []
        var calls: [String] = []
        var cancelled: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [String] { state.withLock { $0.calls } }
    var cancelled: [String] { state.withLock { $0.cancelled } }

    func set(_ host: String, reachable: Bool) {
        set(host, reachable ? .reachable : .unreachable)
    }

    func set(_ host: String, _ outcome: ProbeOutcome) {
        state.withLock { $0.answers[host] = outcome }
    }

    func stubborn(_ host: String) {
        state.withLock { _ = $0.stubborn.insert(host) }
    }

    func releaseStubborn() {
        let waiters = state.withLock { state in
            defer { state.stubbornWaiters = [] }
            state.stubborn = []
            return state.stubbornWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func hang(_ host: String, _ hangs: Bool = true) {
        state.withLock {
            if hangs { $0.hanging.insert(host) } else { $0.hanging.remove(host) }
        }
    }

    func probe(host: String, port: Int) async -> ProbeOutcome {
        let (hangs, isStubborn, answer) = state.withLock { state in
            state.calls.append(host)
            return (state.hanging.contains(host), state.stubborn.contains(host),
                    state.answers[host, default: .reachable])
        }
        if isStubborn {
            await withCheckedContinuation { continuation in
                state.withLock { $0.stubbornWaiters.append(continuation) }
            }
            return answer
        }
        guard hangs else { return answer }
        try? await Task.sleep(for: .seconds(600))
        state.withLock { $0.cancelled.append(host) }
        return .unreachable
    }
}

/// Sleeps until the test fires that duration; cancellation ends a sleep at once (throws).
@MainActor
final class FakeReachabilityClock: ReachabilityClock {
    private struct Sleeper {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var sleepers: [Sleeper] = []
    private var nextID = 0

    func pending(_ duration: Duration) -> Int {
        sleepers.filter { $0.duration == duration }.count
    }

    var pendingCount: Int { sleepers.count }

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, duration: duration, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Ends every pending sleep of `duration`.
    func fire(_ duration: Duration) {
        let due = sleepers.filter { $0.duration == duration }
        sleepers.removeAll { $0.duration == duration }
        due.forEach { $0.continuation.resume() }
    }

    private func cancel(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class FakeNetworkPath: NetworkPathMonitoring {
    private var onChange: (@MainActor @Sendable (Bool) -> Void)?
    private(set) var cancelled = false

    func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func cancel() {
        cancelled = true
        onChange = nil
    }

    func send(_ available: Bool) {
        onChange?(available)
    }
}

/// Records posts; never Notification Center.
@MainActor
final class FakeNotificationPoster: NotificationPosting {
    var permission: NotificationPermission
    private(set) var posts: [StatusChange] = []
    private(set) var removals: [UUID] = []
    private(set) var statusReads = 0

    init(permission: NotificationPermission = .authorized) {
        self.permission = permission
    }

    func authorizationStatus() async -> NotificationPermission {
        statusReads += 1
        return permission
    }

    func post(_ change: StatusChange) async {
        posts.append(change)
    }

    func removeDelivered(_ machineID: UUID) async {
        removals.append(machineID)
    }
}

// MARK: - Pure debounce

struct WatchStateTests {
    @Test func oneFailureIsNotOfflineTwoAreAndRecoveryReportsOnce() {
        var state = WatchState()
        #expect(state.record(reachable: true, failuresBeforeOffline: 2) == nil)   // unknown → online: silent
        #expect(state.status == .online)
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == nil)
        #expect(state.status == .online)
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == .wentOffline)
        #expect(state.status == .offline)
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == nil)   // still offline: once
        #expect(state.record(reachable: true, failuresBeforeOffline: 2) == .backOnline)
        #expect(state.record(reachable: true, failuresBeforeOffline: 2) == nil)
    }

    /// Watched while already down (or the app launched then): red dot, no "went offline".
    @Test func unknownToOfflineIsSilent() {
        var state = WatchState()
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == nil)
        #expect(state.status == .unknown)
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == nil)
        #expect(state.status == .offline)
        #expect(state.record(reachable: true, failuresBeforeOffline: 2) == .backOnline)
    }

    @Test func forgottenFailuresStartTheCountAgain() {
        var state = WatchState()
        _ = state.record(reachable: true, failuresBeforeOffline: 2)
        _ = state.record(reachable: false, failuresBeforeOffline: 2)
        state.forgetFailures()
        #expect(state.record(reachable: false, failuresBeforeOffline: 2) == nil)
        #expect(state.status == .online)
    }
}

// MARK: - Monitor

/// `ReachabilityMonitor` with a fake probe, clock, path and poster: no socket, no real notification.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReachabilityMonitorTests {
    let probe = FakeReachabilityProbe()
    let clock = FakeReachabilityClock()
    let path = FakeNetworkPath()
    let poster = FakeNotificationPoster()
    let center = NotificationCenter()
    let workspace = NotificationCenter()
    let mini = WatchTarget(machineID: UUID(), name: "Mac mini", host: "mini.local", port: 5900)
    let nas = WatchTarget(machineID: UUID(), name: "NAS", host: "nas.local", port: 5901)
    static let interval: Duration = .seconds(60)
    static let timeout: Duration = .seconds(5)
    static let grace: Duration = .seconds(15)

    @MainActor
    final class Flags {
        var notificationsEnabled = true
        var sessions: [UUID: WatchedSessionState] = [:]
    }

    let flags = Flags()

    func makeMonitor() -> ReachabilityMonitor {
        ReachabilityMonitor(probe: probe, clock: clock, path: path, poster: poster,
                            configuration: .init(interval: Self.interval, timeout: Self.timeout,
                                                 failuresBeforeOffline: 2, maxConcurrentProbes: 4,
                                                 wakeGrace: Self.grace),
                            notificationsEnabled: { [flags] in flags.notificationsEnabled },
                            sessionState: { [flags] id in flags.sessions[id] ?? .noSession },
                            notificationCenter: center, workspaceCenter: workspace)
    }

    /// Waits until `count` probes were made and every loop sleeps again (the round is over).
    func waitForProbes(_ count: Int, loops: Int = 1) async -> Bool {
        await waitUntil { probe.calls.count >= count && clock.pending(Self.interval) == loops }
    }

    /// One more interval for every loop, then the probes of that round.
    func nextRound(_ count: Int, loops: Int = 1) async -> Bool {
        clock.fire(Self.interval)
        return await waitForProbes(count, loops: loops)
    }

    // MARK: Debounce and notifications

    @Test func debouncedOfflineThenOnlineNotifyOnceEach() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .online)

        probe.set("mini.local", reachable: false)
        #expect(await nextRound(2))
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)   // one failure: a Wi-Fi blip
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .online)

        #expect(await nextRound(3))
        await monitor.delivery?.value
        #expect(poster.posts == [StatusChange(machineID: mini.machineID, machineName: "Mac mini", transition: .wentOffline)])
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .offline)

        #expect(await nextRound(4))
        await monitor.delivery?.value
        #expect(poster.posts.count == 1)   // still offline: no repeat

        probe.set("mini.local", reachable: true)
        #expect(await nextRound(5))
        await monitor.delivery?.value
        #expect(poster.posts.map(\.transition) == [.wentOffline, .backOnline])
        #expect(await nextRound(6))
        await monitor.delivery?.value
        #expect(poster.posts.count == 2)
    }

    @Test func notAuthorisedOrTurnedOffPostsNothingButTheDotWorks() async throws {
        poster.permission = .denied
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        probe.set("mini.local", reachable: false)
        #expect(await nextRound(2))
        #expect(await nextRound(3))
        await monitor.delivery?.value
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .offline)
        #expect(poster.posts.isEmpty)
        #expect(poster.statusReads == 1)   // read (never requested), then nothing posted

        // Allowed by macOS but off in Settings.
        poster.permission = .authorized
        flags.notificationsEnabled = false
        probe.set("mini.local", reachable: true)
        #expect(await nextRound(4))
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
    }

    @Test func notWatchedIsNeverProbedAndUnwatchingCancelsTheProbe() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: false) == .notWatched)
        probe.hang("mini.local")
        monitor.update([mini])
        monitor.start()
        #expect(await waitUntil { probe.calls == ["mini.local"] })
        monitor.update([])   // Watch off, or the machine deleted
        #expect(await waitUntil { probe.cancelled == ["mini.local"] })
        #expect(monitor.states[mini.machineID] == nil)
        clock.fire(Self.timeout)
        clock.fire(Self.interval)
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.calls.count == 1)
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
    }

    @Test func newAddressStartsAgainFromUnknown() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        var moved = mini
        moved.host = "mini2.local"
        monitor.update([moved])
        #expect(await waitUntil { probe.calls == ["mini.local", "mini2.local"] })
        // Renaming keeps the loop (no new probe) but the next notification uses the new name.
        var renamed = moved
        renamed.name = "Mini"
        monitor.update([renamed])
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 2)
    }

    // MARK: Network and sleep

    @Test func networkUnavailableCausesNoOfflineStorm() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini, nas])
        monitor.start()
        #expect(await waitForProbes(2, loops: 2))
        probe.set("mini.local", reachable: false)
        probe.set("nas.local", reachable: false)
        #expect(await nextRound(4, loops: 2))   // one failure each

        path.send(false)   // Wi-Fi off
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .networkUnavailable)
        #expect(await waitUntil { clock.pendingCount == 0 })   // every loop stopped
        clock.fire(Self.interval)
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 4)

        // Back: failures before the drop are forgotten, so one more failure is not "offline".
        path.send(true)
        #expect(await waitForProbes(6, loops: 2))
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .online)
    }

    @Test func aProbeStartedBeforeTheDropIsIgnored() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        probe.hang("mini.local")
        clock.fire(Self.interval)
        #expect(await waitUntil { probe.calls.count == 2 })
        path.send(false)
        #expect(await waitUntil { probe.cancelled.count == 1 && clock.pendingCount == 0 })
        // Let whatever the cancelled round would still do run, then check it recorded nothing.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(monitor.states[mini.machineID]?.consecutiveFailures == 0)
        #expect(monitor.states[mini.machineID]?.status == .online)
    }

    @Test func sleepPausesAndWakeWaitsForTheGrace() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await waitUntil { clock.pendingCount == 0 })
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { clock.pending(Self.grace) == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 1)   // not right after wake
        clock.fire(Self.grace)
        #expect(await waitForProbes(2))
    }

    // MARK: Sessions

    @Test func aConnectedSessionCountsAsOnlineWithoutProbing() async throws {
        flags.sessions[mini.machineID] = .connected
        probe.set("mini.local", reachable: false)
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitUntil { clock.pending(Self.interval) == 1 })
        for _ in 0..<3 {
            clock.fire(Self.interval)
            #expect(await waitUntil { clock.pending(Self.interval) == 1 })
        }
        #expect(probe.calls.isEmpty)
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .online)

        // Connecting: the round is skipped, the status kept.
        flags.sessions[mini.machineID] = .connecting
        clock.fire(Self.interval)
        #expect(await waitUntil { clock.pending(Self.interval) == 1 })
        #expect(probe.calls.isEmpty)
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
    }

    // MARK: Timeout, interval, quit

    @Test func aProbeWithoutAnswerTimesOutAsAFailureAndIsCancelled() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        probe.hang("mini.local")
        clock.fire(Self.interval)
        #expect(await waitUntil { probe.calls.count == 2 && clock.pending(Self.timeout) == 1 })
        clock.fire(Self.timeout)
        #expect(await waitUntil { probe.cancelled.count == 1 && clock.pending(Self.interval) == 1 })
        #expect(monitor.states[mini.machineID]?.consecutiveFailures == 1)
    }

    @Test func probesFollowTheIntervalAndQuitStopsEverything() async throws {
        let monitor = makeMonitor()
        monitor.update([mini])
        #expect(probe.calls.isEmpty)   // nothing before start
        monitor.start()
        #expect(await waitForProbes(1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 1)   // no second probe until the interval passes
        #expect(await nextRound(2))

        probe.hang("mini.local")
        clock.fire(Self.interval)
        #expect(await waitUntil { probe.calls.count == 3 })
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!monitor.isRunning)
        #expect(path.cancelled)
        #expect(await waitUntil { probe.cancelled.count == 1 && clock.pendingCount == 0 })
        monitor.start()   // never restarts after quit
        monitor.update([nas])
        clock.fire(Self.interval)
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 3)
    }

    @Test func atMostTheConfiguredProbesRunAtOnce() async throws {
        let targets = (0..<6).map { WatchTarget(machineID: UUID(), name: "M\($0)", host: "m\($0).local", port: 5900) }
        targets.forEach { probe.hang($0.host) }
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update(targets)
        monitor.start()
        #expect(await waitUntil { probe.calls.count == 4 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 4)
        clock.fire(Self.timeout)   // those four time out; the two waiting start
        #expect(await waitUntil { probe.calls.count == 6 })
    }
}

// MARK: - Review fixes

extension ReachabilityMonitorTests {
    /// M1: a probe that ignores its cancellation still frees its slot at the timeout.
    @Test func aStubbornProbeFreesItsSlotAtTheTimeout() async throws {
        let targets = (0..<5).map { WatchTarget(machineID: UUID(), name: "M\($0)", host: "m\($0).local", port: 5900) }
        targets.forEach { probe.stubborn($0.host) }
        let monitor = makeMonitor()
        defer {
            monitor.stop()
            probe.releaseStubborn()
        }
        monitor.update(targets)
        monitor.start()
        #expect(await waitUntil { probe.calls.count == 4 && clock.pending(Self.timeout) == 4 })
        clock.fire(Self.timeout)   // the four never return, but their slots are free
        // Wait on the state, not on the call count: the fifth probe can start before the timed-out
        // results are recorded (the review saw `consecutiveFailures` 0 once).
        let timedOut = { targets.filter { monitor.states[$0.machineID]?.consecutiveFailures == 1 }.count }
        #expect(await waitUntil { probe.calls.count == 5 && timedOut() == 4 })
        #expect(probe.calls.count == 5)
    }

    /// L1: after wake, a path that flaps back to satisfied during the grace starts no probe.
    @Test func thePathFlappingDuringTheWakeGraceStartsNothing() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        path.send(false)
        path.send(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.calls.count == 1)
        #expect(clock.pending(Self.grace) == 1)
        clock.fire(Self.grace)
        #expect(await waitForProbes(2))
    }

    /// L2: an open session brings the dot back to green without a "back online".
    @Test func aSessionBringsItOnlineSilently() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        probe.set("mini.local", reachable: true)
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        probe.set("mini.local", reachable: false)
        #expect(await nextRound(2))
        #expect(await nextRound(3))
        await monitor.delivery?.value
        #expect(poster.posts.map(\.transition) == [.wentOffline])
        flags.sessions[mini.machineID] = .connected
        clock.fire(Self.interval)
        #expect(await waitUntil { monitor.states[mini.machineID]?.status == .online })
        await monitor.delivery?.value
        #expect(poster.posts.map(\.transition) == [.wentOffline])
    }

    /// L5: unwatching (or deleting) withdraws the machine's delivered notification.
    @Test func unwatchingWithdrawsItsNotification() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini, nas])
        monitor.start()
        #expect(await waitForProbes(2, loops: 2))
        monitor.update([nas])
        await monitor.delivery?.value
        #expect(poster.removals == [mini.machineID])
    }

    /// Local Network privacy refusing the probes: never offline, never a notification.
    @Test func localNetworkRefusalIsNotOffline() async throws {
        let monitor = makeMonitor()
        defer { monitor.stop() }
        monitor.update([mini])
        monitor.start()
        #expect(await waitForProbes(1))
        probe.set("mini.local", .localNetworkDenied)
        for count in 2...4 { #expect(await nextRound(count)) }
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .localNetworkDenied)
        #expect(monitor.states[mini.machineID]?.status == .online)
        probe.set("mini.local", .reachable)   // access granted
        #expect(await nextRound(5))
        #expect(monitor.presentation(machineID: mini.machineID, isWatched: true) == .online)
        await monitor.delivery?.value
        #expect(poster.posts.isEmpty)
    }

    @Test func theSidebarDrawsNoDotForAMachineNotWatched() {
        #expect(!StatusPresentation.notWatched.showsSidebarDot)
        for shown in [StatusPresentation.checking, .online, .offline, .networkUnavailable, .localNetworkDenied] {
            #expect(shown.showsSidebarDot)
        }
    }

    /// M2: the watched machines come from the store, whatever window saved them.
    @Test func everySaveOfTheStoreReachesTheMonitor() throws {
        let context = try makeTestContext()
        let monitor = makeMonitor()
        let feed = WatchTargetFeed(context: context, monitor: monitor)
        let machine = Machine(name: "Mac mini", kind: .macARD, host: "mini.local", username: "v")
        context.insert(machine)
        try context.save()
        #expect(monitor.states[machine.id] == nil)   // not watched
        machine.isWatched = true                     // e.g. the editor from a session's Edit credentials
        try context.save()
        #expect(monitor.states[machine.id] != nil)
        machine.isWatched = false
        try context.save()
        #expect(monitor.states[machine.id] == nil)
        withExtendedLifetime(feed) {}
    }
}

// MARK: - Notifications

@MainActor
final class Counter {
    var value = 0
}

@MainActor
struct StatusNotificationTests {
    let id = UUID()

    @Test func contentNamesTheMachineAndNothingSecret() {
        for lang in ["en", "fr"] {
            let t: (String) -> String = { Strings.table[lang]?[$0] ?? $0 }
            let offline = StatusNotificationContent(StatusChange(machineID: id, machineName: "Mac mini", transition: .wentOffline), t)
            let online = StatusNotificationContent(StatusChange(machineID: id, machineName: "Mac mini", transition: .backOnline), t)
            #expect(offline.title.contains("Mac mini") && online.title.contains("Mac mini"))
            #expect(!offline.title.contains("%@") && !online.title.contains("%@"))
            #expect(offline.title != online.title && !offline.body.isEmpty && !online.body.isEmpty)
        }
        let nas = StatusNotificationContent(StatusChange(machineID: id, machineName: "NAS", transition: .wentOffline), english)
        #expect(nas.title == "NAS is offline" && nas.body == "The machine no longer answers on the network.")
        // The payload is the id and the transition only.
        let info = StatusNotificationPayload.userInfo(StatusChange(machineID: id, machineName: "Mac mini", transition: .backOnline))
        #expect(Set(info.keys) == ["machineID", "transition"])
        #expect(StatusNotificationPayload.identifier(id) == "status.\(id.uuidString)")
    }

    /// The click (didReceive → userInfo → router): the right machine, selected only (T5.3: "back
    /// online" no longer connects on its own).
    @Test func clickSelectsTheRightMachineAndNeverConnects() throws {
        let activations = Counter()
        let libraryOpens = Counter()
        let router = StatusNotificationRouter(activate: { activations.value += 1 })
        let other = UUID()
        let info: [AnyHashable: Any] = StatusNotificationPayload.userInfo(
            StatusChange(machineID: id, machineName: "Mac mini", transition: .backOnline))
        let request = try #require(StatusNotificationPayload.request(from: info))
        #expect(request == .init(machineID: id, transition: .backOnline) && request.machineID != other)
        #expect(request.action == .select)

        // Cold launch: the Library Window is not up yet, the request waits for it.
        router.open(request)
        #expect(activations.value == 1)
        router.openLibrary = { libraryOpens.value += 1 }
        #expect(router.take() == request)
        #expect(router.take() == nil)   // consumed once

        // "Offline" selects only.
        router.open(.init(machineID: other, transition: .wentOffline))
        #expect(libraryOpens.value == 1 && activations.value == 2)
        #expect(router.take()?.action == .select)

        #expect(StatusNotificationPayload.request(from: [:]) == nil)
        #expect(StatusNotificationPayload.request(from: ["machineID": "nope", "transition": "online"]) == nil)
        #expect(StatusNotificationPayload.request(from: ["machineID": id.uuidString, "transition": "x"]) == nil)
    }
}

/// "Allow notifications" outside the onboarding: the request only follows `request()`.
@MainActor
struct NotificationPermissionModelTests {
    actor Authorizer: NotificationAuthorizing {
        private(set) var calls = 0
        let answer: NotificationAuthorization
        init(_ answer: NotificationAuthorization) { self.answer = answer }
        func requestAuthorization() async -> NotificationAuthorization {
            calls += 1
            return answer
        }
    }

    @Test func refreshNeverRequestsAndRequestFollowsTheClick() async {
        let poster = FakeNotificationPoster(permission: .notDetermined)
        let authorizer = Authorizer(.granted)
        let model = NotificationPermissionModel(poster: poster, authorizer: authorizer)
        await model.refresh()
        #expect(model.state == .notDetermined)
        #expect(await authorizer.calls == 0)
        await model.request()
        #expect(model.state == .authorized)
        #expect(await authorizer.calls == 1)
        await model.request()   // answered: no second prompt
        #expect(await authorizer.calls == 1)
    }

    @Test func deniedAndFailedAnswers() async {
        let denied = NotificationPermissionModel(poster: FakeNotificationPoster(permission: .denied),
                                                 authorizer: Authorizer(.granted))
        await denied.refresh()
        #expect(denied.state == .denied)
        await denied.request()
        #expect(denied.state == .denied)   // macOS would not ask again

        let failing = NotificationPermissionModel(poster: FakeNotificationPoster(permission: .notDetermined),
                                                  authorizer: Authorizer(.failed))
        await failing.refresh()
        await failing.request()
        #expect(failing.state == .failed)
        await failing.refresh()
        #expect(failing.state == .failed)   // Retry stays offered
    }
}
