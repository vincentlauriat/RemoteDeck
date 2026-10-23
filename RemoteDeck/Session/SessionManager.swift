import AppKit
import Metal
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit

/// The open sessions, one per machine (one Session Window each; tabs are T4.2). Connect on a machine
/// that already has a session brings its window forward and opens no second window or connection.
/// This does not rely on `openWindow(value:)` finding the existing window: two Connects in a row
/// (measured with `-LibraryDemo session`) opened two windows for the same value.
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

    init(context: ModelContext, passwords: any MachinePasswordStore, tester: any ConnectionTester,
         clock: SessionClock = .live,
         makeConnection: @escaping @MainActor (SessionTarget) -> any SessionConnection = SessionManager.rfbConnection,
         makeDisplay: @escaping @MainActor () -> SessionDisplayModel? = SessionManager.metalDisplay,
         pasteboard: any ClipboardPasteboard,
         notificationCenter: NotificationCenter = .default) {
        self.pasteboard = pasteboard
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
    }

    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// ⌘Q with sessions open: their records get their end at once (`SessionModel.beginClose`), with no
    /// network teardown. Sessions whose window was closing already did so in `close`, so a quit always
    /// leaves an end time, whether SwiftUI ran `onDisappear` before `willTerminate` or not.
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
                                   clock: clock, pasteboard: pasteboard, makeConnection: makeConnection)
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

    /// The window closed: forget the session at once (a new Connect starts a fresh one), end its
    /// record now (`beginClose`), and tear it down in order in the background.
    func close(_ machineID: UUID) {
        guard let session = sessions.removeValue(forKey: machineID) else { return }
        let record = session.beginClose()
        Task { await session.completeClose(record: record) }
    }
}
