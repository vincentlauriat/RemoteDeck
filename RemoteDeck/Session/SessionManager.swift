import AppKit
import Metal
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit

/// The open sessions, one per machine, each in its own tab of the Session Window (`SessionTabs`), with
/// its own connection. Connect on a machine that already has a session selects its tab and opens no
/// second tab or connection. This does not rely on `openWindow(value:)` finding the existing window:
/// two Connects in a row (measured with `-LibraryDemo session`) opened two windows for the same value.
/// A session ends only when its own tab (window) closes (`close`); the other tabs are untouched.
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [UUID: SessionModel] = [:]

    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let passwords: any MachinePasswordStore
    @ObservationIgnored let tester: any ConnectionTester
    @ObservationIgnored private let clock: SessionClock
    @ObservationIgnored private let makeConnection: @MainActor (SessionTarget) -> any SessionConnection
    @ObservationIgnored private let makeDisplay: @MainActor () -> SessionDisplayModel?
    @ObservationIgnored private let pasteboard: any ClipboardPasteboard
    @ObservationIgnored private let makeAssistant: @MainActor (SessionModel) -> AssistantModel?
    @ObservationIgnored private let resilience: SessionResilience
    @ObservationIgnored private let reconnectClock: any ReachabilityClock
    /// "Connect anyway" confirmations (T5.3 H1); in memory unless the app passes the UserDefaults one.
    @ObservationIgnored let publicConsents: any PublicAddressConsents
    @ObservationIgnored private let path: (any NetworkPathMonitoring)?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private let workspaceCenter: NotificationCenter?
    /// The last path state reported (`NetworkPathMonitoring`); available until told otherwise.
    @ObservationIgnored private(set) var isNetworkAvailable = true
    @ObservationIgnored private var isAsleep = false
    /// After wake, before the sessions closed for sleep reconnect.
    @ObservationIgnored private var wakeGrace: Task<Void, Never>?

    /// `path` and `workspaceCenter` (sleep and wake) are nil under the hosted tests unless a test
    /// passes fakes: nothing then watches the network or the power state.
    init(context: ModelContext, passwords: any MachinePasswordStore, tester: any ConnectionTester,
         clock: SessionClock = .live,
         makeConnection: @escaping @MainActor (SessionTarget) -> any SessionConnection = SessionManager.rfbConnection,
         makeDisplay: @escaping @MainActor () -> SessionDisplayModel? = SessionManager.metalDisplay,
         pasteboard: any ClipboardPasteboard,
         makeAssistant: @escaping @MainActor (SessionModel) -> AssistantModel? = { _ in nil },
         notificationCenter: NotificationCenter = .default,
         resilience: SessionResilience = SessionResilience(),
         reconnectClock: any ReachabilityClock = ContinuousReachabilityClock(),
         path: (any NetworkPathMonitoring)? = nil,
         workspaceCenter: NotificationCenter? = nil,
         publicConsents: any PublicAddressConsents = InMemoryPublicAddressConsents()) {
        self.publicConsents = publicConsents
        self.resilience = resilience
        self.reconnectClock = reconnectClock
        self.path = path
        self.workspaceCenter = workspaceCenter
        self.pasteboard = pasteboard
        self.makeAssistant = makeAssistant
        self.context = context
        self.passwords = passwords
        self.tester = tester
        self.clock = clock
        self.makeConnection = makeConnection
        self.makeDisplay = makeDisplay
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        if let workspaceCenter {
            workspaceObservers = [
                workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemWillSleep() }
                },
                workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemDidWake() }
                },
            ]
        }
        path?.start { [weak self] available in self?.networkChanged(available: available) }
    }

    // MARK: Resilience (T5.1)

    /// Stops watching the network path and sleep/wake (end of a test; the app's manager lives until
    /// quit). Sessions are left as they are.
    func stop() {
        workspaceObservers.forEach { workspaceCenter?.removeObserver($0) }
        workspaceObservers = []
        path?.cancel()
        wakeGrace?.cancel()
        wakeGrace = nil
    }

    /// No path: every session stops trying (`SessionModel.networkLost`); back: one attempt each.
    func networkChanged(available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        for session in sessions.values {
            if available { session.networkRestored() } else { session.networkLost() }
        }
    }

    /// Every running session closes cleanly before the Mac sleeps, and remembers to reconnect.
    func systemWillSleep() {
        isAsleep = true
        wakeGrace?.cancel()
        wakeGrace = nil
        sessions.values.forEach { $0.suspendForSleep() }
    }

    /// `wakeGrace` after wake, even if the path flaps back meanwhile, the sessions still open (a window
    /// closed during sleep is no longer in `sessions`) reconnect once each.
    func systemDidWake() {
        guard isAsleep else { return }
        isAsleep = false
        let clock = reconnectClock
        let grace = resilience.wakeGrace
        wakeGrace = Task { [weak self] in
            guard (try? await clock.sleep(for: grace)) != nil, let self else { return }
            self.wakeGrace = nil
            self.sessions.values.forEach { $0.resumeAfterWake() }
        }
    }

    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    /// Sessions opened so far (`SessionModel.openOrder`).
    @ObservationIgnored private var openCount = 0

    /// ⌘Q with sessions open: their records get their end at once (`SessionModel.beginClose`), with no
    /// network teardown. Sessions whose window was closing already did so in `close`, so a quit always
    /// leaves an end time, whether the window's `willClose` came before `willTerminate` or not.
    func appWillTerminate() {
        sessions.values.forEach { $0.beginClose() }
    }

    /// The real connection. The port was validated (1–65535) when the machine was saved.
    nonisolated static func rfbConnection(_ target: SessionTarget) -> any SessionConnection {
        RFBConnection(host: target.host, port: UInt16(clamping: target.port))
    }

    /// The Metal renderer behind the window's `FramebufferView`; `nil` without Metal.
    static func metalDisplay() -> SessionDisplayModel? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? FramebufferRenderer(device: device) else { return nil }
        return SessionDisplayModel(renderer: renderer)
    }

    /// The machine's session, started on first use; `nil` if the machine no longer exists.
    func session(for machineID: UUID) -> SessionModel? {
        if let session = sessions[machineID] { return session }
        guard let machine = try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == machineID }))
            .first else { return nil }
        let session = SessionModel(machine: machine, context: context, passwords: passwords, display: makeDisplay(),
                                   clock: clock, pasteboard: pasteboard, resilience: resilience,
                                   reconnectClock: reconnectClock, publicConsents: publicConsents,
                                   makeConnection: makeConnection)
        session.isNetworkAvailable = { [weak self] in self?.isNetworkAvailable ?? true }
        openCount += 1
        session.openOrder = openCount
        session.assistant = makeAssistant(session)
        sessions[machineID] = session
        session.connect()
        return session
    }

    /// Connect from the Library: `true` when the caller must open a Session Window (the session is
    /// created and connecting already); `false` when the machine has one, which is brought forward,
    /// or no longer exists.
    func requestWindow(for machineID: UUID) -> Bool {
        if let session = sessions[machineID] {
            session.bringWindowForward?()
            return false
        }
        return session(for: machineID) != nil
    }

    /// Library row spinner (AppFlow › Connect: "Row spinner").
    func isConnecting(_ machineID: UUID) -> Bool {
        sessions[machineID]?.isConnecting ?? false
    }

    /// Its tab (window) closed: forget the session at once (a new Connect starts a fresh one), end its
    /// record now (`beginClose`), and tear it down in order in the background.
    func close(_ machineID: UUID) {
        guard let session = sessions.removeValue(forKey: machineID) else { return }
        let record = session.beginClose()
        Task { await session.completeClose(record: record) }
    }
}

extension SessionModel.Phase {
    /// What the Reachability monitor makes of this session (T4.5): a session waiting to reconnect
    /// (T5.1) counts as connecting, so its machine is not probed and posts no offline or back-online
    /// notification while the session itself handles it.
    var watchedState: WatchedSessionState {
        switch self {
        case .connected: .connected
        case .connecting, .waiting: .connecting
        case .idle, .failed, .closed: .noSession
        }
    }
}
