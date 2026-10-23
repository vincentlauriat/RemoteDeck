import AppKit
import Foundation
import Network
import Observation
import RFBKit

// MARK: - Vocabulary

/// A watched machine as the monitor sees it: a Sendable copy, never the `@Model` object.
struct WatchTarget: Equatable, Sendable {
    let machineID: UUID
    var name: String
    var host: String
    var port: Int

    struct Address: Equatable, Sendable {
        let host: String
        let port: Int
    }

    var address: Address { Address(host: host, port: port) }
}

enum ReachabilityStatus: Equatable, Sendable {
    /// Not probed yet, or not enough failures to call it offline (grey dot).
    case unknown
    case online
    case offline
}

/// A debounced change worth a notification.
enum StatusTransition: String, Equatable, Sendable {
    case wentOffline = "offline"
    case backOnline = "online"
}

/// A watched machine changed state (what a Status Notification says).
struct StatusChange: Equatable, Sendable {
    let machineID: UUID
    let machineName: String
    let transition: StatusTransition
}

/// What the Library shows for a machine (DesignBrief › Sidebar rows: the status dot).
enum StatusPresentation: Equatable, Sendable {
    case notWatched
    /// Watched, status not known yet.
    case checking
    case online
    case offline
    /// No network on this Mac: probes are paused, nothing is claimed about the machine.
    case networkUnavailable
    /// macOS refused the probe (Local Network privacy off for the app): nothing is known.
    case localNetworkDenied
}

/// The machine's session, which is truth while it is connected (TRD › Reachability).
enum WatchedSessionState: Equatable, Sendable {
    case noSession
    /// Being opened: this round's probe is skipped (the session will tell).
    case connecting
    /// Connected: the machine counts as online, no probe.
    case connected
}

/// One watched machine's debounced status. Pure: the monitor feeds it probe results.
struct WatchState: Equatable, Sendable {
    private(set) var status: ReachabilityStatus = .unknown
    private(set) var consecutiveFailures = 0
    /// The last probe was refused by Local Network privacy (shown as such, never as offline).
    private(set) var localNetworkDenied = false

    /// Records one probe. Offline only after `failuresBeforeOffline` failures in a row; back online
    /// at the first success. Only online → offline and offline → online notify: the first answer
    /// (unknown → anything) sets the dot silently.
    mutating func record(reachable: Bool, failuresBeforeOffline: Int) -> StatusTransition? {
        localNetworkDenied = false
        if reachable {
            consecutiveFailures = 0
            let previous = status
            status = .online
            return previous == .offline ? .backOnline : nil
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= failuresBeforeOffline, status != .offline else { return nil }
        let previous = status
        status = .offline
        return previous == .online ? .wentOffline : nil
    }

    /// A refusal says nothing about the machine: no failure counted, the status kept, no notification.
    mutating func recordLocalNetworkDenied() {
        localNetworkDenied = true
        consecutiveFailures = 0
    }

    /// Failures counted before a pause (no network, sleep) say nothing about the machine.
    mutating func forgetFailures() {
        consecutiveFailures = 0
    }
}

// MARK: - Dependencies

typealias ProbeOutcome = TCPProbe.Outcome

/// One reachability check of `host:port`. Runs off the main actor; should return promptly once the
/// calling task is cancelled (the monitor's timeout cancels it, and frees its slot without waiting).
protocol ReachabilityProbe: Sendable {
    func probe(host: String, port: Int) async -> ProbeOutcome
}

/// The real probe: a TCP connect, closed at once (`TCPProbe`, RFBKit).
struct TCPReachabilityProbe: ReachabilityProbe {
    func probe(host: String, port: Int) async -> ProbeOutcome {
        await TCPProbe.probe(host: host, port: UInt16(clamping: port))
    }
}

/// Sleeps for the probe interval, the probe timeout and the grace after wake. Throws when cancelled.
@MainActor
protocol ReachabilityClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousReachabilityClock: ReachabilityClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Whether this Mac has a usable network path (`NWPathMonitor`: `.satisfied`).
@MainActor
protocol NetworkPathMonitoring: AnyObject {
    func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void)
    func cancel()
}

@MainActor
final class NWNetworkPathMonitor: NetworkPathMonitoring {
    private var monitor: NWPathMonitor?

    func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            MainActor.assumeIsolated { onChange(available) }   // delivered on the main queue
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func cancel() {
        monitor?.cancel()
        monitor = nil
    }
}

// MARK: - Monitor

/// Status Notifications (PRD › Status Notifications, AC9; TRD › Performance › Reachability probe):
/// probes every watched machine every `interval`, reports it offline after `failuresBeforeOffline`
/// consecutive failures, and posts a notification on each debounced online ↔ offline change.
///
/// - One loop per watched machine, cancelled when it stops being watched, is deleted or changes
///   address (`update`); at most `maxConcurrentProbes` probes at once; each probe is raced against
///   `timeout` on the injected clock and runs off the main actor.
/// - A connected session counts as online (no probe); a connecting one skips the round.
/// - No network (path not satisfied) or the Mac asleep: every loop stops, failures are forgotten
///   and results of probes started before are dropped, so a Wi-Fi drop never posts an "offline"
///   storm. Probes resume when the path is back, or `wakeGrace` after wake.
/// - Never runs before `start()`: not under XCTest, nor in demo modes other than `watch`.
@Observable
@MainActor
final class ReachabilityMonitor {
    struct Configuration: Sendable {
        var interval: Duration = .seconds(60)
        var timeout: Duration = .seconds(5)
        var failuresBeforeOffline = 2
        var maxConcurrentProbes = 4
        var wakeGrace: Duration = .seconds(15)
    }

    private(set) var states: [UUID: WatchState] = [:]
    private(set) var isNetworkAvailable = true
    /// Started and not stopped.
    private(set) var isRunning = false

    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored private let probe: any ReachabilityProbe
    @ObservationIgnored private let clock: any ReachabilityClock
    @ObservationIgnored private let path: any NetworkPathMonitoring
    @ObservationIgnored private let poster: any NotificationPosting
    @ObservationIgnored private let notificationsEnabled: @MainActor () -> Bool
    @ObservationIgnored private let sessionState: @MainActor (UUID) -> WatchedSessionState
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let workspaceCenter: NotificationCenter

    @ObservationIgnored private var targets: [UUID: WatchTarget] = [:]
    @ObservationIgnored private var loops: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var isAsleep = false
    /// After wake: no probe until it ends, whatever the path does meanwhile.
    @ObservationIgnored private var wakeGrace: Task<Void, Never>?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var freeSlots: Int
    @ObservationIgnored private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Notifications are delivered one after the other, in order (the tests await it).
    @ObservationIgnored private(set) var delivery: Task<Void, Never>?

    init(probe: any ReachabilityProbe, clock: any ReachabilityClock = ContinuousReachabilityClock(),
         path: any NetworkPathMonitoring, poster: any NotificationPosting,
         configuration: Configuration = Configuration(),
         notificationsEnabled: @escaping @MainActor () -> Bool,
         sessionState: @escaping @MainActor (UUID) -> WatchedSessionState,
         notificationCenter: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.probe = probe
        self.clock = clock
        self.path = path
        self.poster = poster
        self.configuration = configuration
        self.notificationsEnabled = notificationsEnabled
        self.sessionState = sessionState
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        freeSlots = max(1, configuration.maxConcurrentProbes)
    }

    /// Starts probing the watched machines, the path monitor and the sleep/wake/quit observers.
    func start() {
        guard !isRunning, !stopped else { return }
        isRunning = true
        observe(notificationCenter, NSApplication.willTerminateNotification) { $0.stop() }
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        path.start { [weak self] available in self?.networkChanged(available: available) }
        reconcileLoops()
    }

    /// Quit (or end of a test): every loop and probe is cancelled; nothing restarts afterwards.
    func stop() {
        guard !stopped else { return }
        stopped = true
        isRunning = false
        wakeGrace?.cancel()
        wakeGrace = nil
        cancelLoops()
        path.cancel()
        observers.forEach { center, token in center.removeObserver(token) }
        observers = []
    }

    /// The watched machines, as the Library has them now. A machine no longer in the list (unwatched,
    /// deleted) stops at once and forgets its status; a new one, or one whose address changed, is
    /// probed at once from an unknown status. A rename changes only the notification's name.
    func update(_ newTargets: [WatchTarget]) {
        let new = Dictionary(newTargets.map { ($0.machineID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in targets.keys where new[id] == nil {
            loops.removeValue(forKey: id)?.task.cancel()
            states[id] = nil
            // Its notification would point at a machine no longer watched (or gone).
            if isRunning { withdraw(id) }
        }
        let previous = targets
        targets = new
        for (id, target) in new where previous[id]?.address != target.address {
            loops.removeValue(forKey: id)?.task.cancel()
            states[id] = WatchState()
            if isActive { startLoop(for: id, address: target.address) }
        }
    }

    func presentation(machineID: UUID, isWatched: Bool) -> StatusPresentation {
        guard isWatched else { return .notWatched }
        guard isRunning else { return .checking }
        guard isNetworkAvailable else { return .networkUnavailable }
        if states[machineID]?.localNetworkDenied == true { return .localNetworkDenied }
        switch states[machineID]?.status ?? .unknown {
        case .unknown: return .checking
        case .online: return .online
        case .offline: return .offline
        }
    }

    // MARK: Pauses

    func networkChanged(available: Bool) {
        guard isRunning, available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        if available {
            forgetFailures()
            reconcileLoops()
        } else {
            cancelLoops()
        }
    }

    func systemWillSleep() {
        guard isRunning else { return }
        isAsleep = true
        wakeGrace?.cancel()
        wakeGrace = nil
        cancelLoops()
    }

    /// The network may still be coming back: no probe for `wakeGrace`, even if the path flaps back
    /// to satisfied meanwhile (review L1).
    func systemDidWake() {
        guard isRunning, isAsleep else { return }
        isAsleep = false
        forgetFailures()
        let clock = self.clock
        let grace = configuration.wakeGrace
        wakeGrace = Task { [weak self] in
            guard (try? await clock.sleep(for: grace)) != nil, let self else { return }
            self.wakeGrace = nil
            self.reconcileLoops()
        }
    }

    // MARK: Loops

    private var isActive: Bool { isRunning && isNetworkAvailable && !isAsleep && wakeGrace == nil }

    private func reconcileLoops() {
        guard isActive else { return }
        for (id, target) in targets where loops[id] == nil {
            startLoop(for: id, address: target.address)
        }
    }

    private func cancelLoops() {
        loops.values.forEach { $0.task.cancel() }
        loops = [:]
    }

    private func forgetFailures() {
        for id in states.keys { states[id]?.forgetFailures() }
    }

    private func startLoop(for id: UUID, address: WatchTarget.Address) {
        let token = UUID()
        let clock = self.clock
        let interval = configuration.interval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(id, address: address, token: token)
                guard (try? await clock.sleep(for: interval)) != nil else { return }
            }
        }
        loops[id] = (token, task)
    }

    private func isCurrent(_ id: UUID, _ token: UUID) -> Bool {
        !Task.isCancelled && loops[id]?.token == token
    }

    private func check(_ id: UUID, address: WatchTarget.Address, token: UUID) async {
        guard isCurrent(id, token) else { return }
        switch sessionState(id) {
        case .connected:
            // Online, but no "back online" for a machine the user is looking at (review L2).
            record(.reachable, for: id, notifies: false)
            return
        case .connecting:
            return
        case .noSession:
            break
        }
        await acquireSlot()
        guard isCurrent(id, token) else {
            releaseSlot()
            return
        }
        let outcome = await probeWithTimeout(address)   // releases the slot itself
        guard isCurrent(id, token) else { return }
        record(outcome, for: id)
    }

    /// The probe against `timeout` on the injected clock: whichever ends first; the probe is then
    /// cancelled. The concurrency slot is released as soon as the answer is known (the timeout
    /// included), without waiting for a probe that is slow to honour its cancellation (review M1).
    private func probeWithTimeout(_ address: WatchTarget.Address) async -> ProbeOutcome {
        let probe = self.probe
        let clock = self.clock
        let timeout = configuration.timeout
        let answer = FirstAnswer()
        let probing = Task { await probe.probe(host: address.host, port: address.port) }
        let timer = Task { try? await clock.sleep(for: timeout) }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeOutcome, Never>) in
                answer.continuation = continuation
                Task { answer.resolve(await probing.value) }
                Task {
                    await timer.value
                    answer.resolve(.unreachable)
                }
            }
        } onCancel: {
            Task { @MainActor in answer.resolve(.unreachable) }
        }
        probing.cancel()
        timer.cancel()
        releaseSlot()
        return outcome
    }

    private func record(_ outcome: ProbeOutcome, for id: UUID, notifies: Bool = true) {
        guard var state = states[id], let target = targets[id] else { return }
        var transition: StatusTransition?
        switch outcome {
        case .reachable, .unreachable:
            transition = state.record(reachable: outcome == .reachable,
                                      failuresBeforeOffline: configuration.failuresBeforeOffline)
        case .localNetworkDenied:
            state.recordLocalNetworkDenied()
        }
        if state != states[id] { states[id] = state }
        guard notifies, let transition else { return }
        deliver(StatusChange(machineID: id, machineName: target.name, transition: transition))
    }

    /// Posted only when Settings › Notifications is on and macOS allows it; never asks for permission.
    private func deliver(_ change: StatusChange) {
        let previous = delivery
        delivery = Task { [poster, notificationsEnabled] in
            await previous?.value
            guard notificationsEnabled(), await poster.authorizationStatus() == .authorized else { return }
            await poster.post(change)
        }
    }

    /// Removes the machine's delivered notification, after any post still queued.
    private func withdraw(_ id: UUID) {
        let previous = delivery
        delivery = Task { [poster] in
            await previous?.value
            await poster.removeDelivered(id)
        }
    }

    // MARK: Concurrency limit

    private func acquireSlot() async {
        if freeSlots > 0 {
            freeSlots -= 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            freeSlots += 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    /// The first of the probe and the timeout; later answers are ignored.
    @MainActor
    private final class FirstAnswer {
        var continuation: CheckedContinuation<ProbeOutcome, Never>?

        func resolve(_ outcome: ProbeOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (ReachabilityMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, token))
    }
}
