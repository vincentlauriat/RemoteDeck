import Foundation
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit

// MARK: - Dependencies

/// One RFB connection as the Session Window uses it. `RFBConnection` in the app; a fake in tests
/// (the hosted tests cannot listen on loopback). A new instance per attempt.
protocol SessionConnection: AnyObject, Sendable {
    /// Connects and authenticates (`RFBConnection.open`).
    func connect(credentials: RFBCredentials, timeout: Duration) async throws(RFBError)
    /// Starts the framebuffer protocol. The sequence is consumed as is: taking an update is what asks
    /// the server for the next one (`RFBSessionEvents`), so it must never be re-buffered.
    func events() async throws(RFBError) -> any AsyncSequence<RFBEvent, any Error> & Sendable
    /// One batch of input messages, in order (`InputSender`).
    func send(_ messages: [ClientMessage]) async throws(RFBError)
    func close() async
    /// Bytes received from the server so far (SessionRecord.bytesReceived).
    var receivedByteCount: Int64 { get async }
    /// Shared Clipboard on or off (`RFBConnection.setClipboardSharing`); off until set.
    func setClipboardSharing(_ on: Bool) async
    /// Local clipboard text to the server (`RFBConnection.shareClipboard`).
    @discardableResult
    func shareClipboard(_ text: String) async throws(RFBError) -> ClipboardShare
}

extension RFBConnection: SessionConnection {
    func connect(credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
        _ = try await open(credentials: credentials, timeout: timeout)
    }

    func events() async throws(RFBError) -> any AsyncSequence<RFBEvent, any Error> & Sendable {
        try await startSession()
    }

    var receivedByteCount: Int64 { bytesReceived }
}

/// What the session needs from its `FramebufferView` (a fake in tests).
@MainActor
protocol SessionSurface: AnyObject {
    /// First frame: take the keyboard (first responder + capture), as a new session starts captured.
    func startCapture()
    /// The session stopped but the window stays (error banner): release the capture, which emits the
    /// release of everything held on the remote.
    func releaseCapture()
    /// The window goes away: removes the key monitor and the tap, and emits the releases.
    func tearDownInput()
}

/// Wall clock for the record's dates, uptime for the connect time; replaceable in tests.
struct SessionClock {
    var now: @MainActor () -> Date
    /// Seconds on a monotonic clock.
    var uptime: @MainActor () -> TimeInterval

    static let live = SessionClock(now: { Date.now }, uptime: { ProcessInfo.processInfo.systemUptime })
}

/// The machine as it was when the attempt started: a Sendable copy, so a Task never holds the
/// `@Model` object and an edit or delete mid-session changes nothing until the next attempt.
struct SessionTarget: Equatable, Sendable {
    let machineID: UUID
    var name: String
    var kind: MachineKind
    var host: String
    var port: Int
    var username: String?
    var scalingMode: ScalingMode

    init(_ machine: Machine) {
        machineID = machine.id
        name = machine.name
        kind = machine.kindValue
        host = machine.host
        port = machine.port
        username = machine.username
        scalingMode = machine.scalingModeValue
    }

    /// ⌘ and ⌥ per machine kind (TRD › Input): Mac ARD → Alt/Meta, VNC and Anthropic VM → X11 Super/Alt.
    var modifierProfile: ModifierProfile {
        kind == .macARD ? .appleRemoteDesktop : .x11
    }
}

extension RFBCredentials {
    /// The credentials for a machine of `kind`, as the Machine Editor's Test and the session both use
    /// them: no user name for an Anthropic VM, a blank user name or password counts as none.
    init(kind: MachineKind, username: String?, password: String?) {
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(username: kind == .anthropicVM || user?.isEmpty != false ? nil : user,
                  password: password?.isEmpty == false ? password : nil)
    }
}

// MARK: - Failures

/// Why a session is not (or no longer) showing the remote screen: the Session Window's error banner
/// (AppFlow › Session Window, Empty and blocked states).
enum SessionFailure: Equatable, Sendable {
    /// `open` failed: wording shared with the Machine Editor's Test (`TestConnectionFailure`).
    case connect(TestConnectionFailure)
    /// The stored password could not be read (Keychain status); nothing was sent.
    case passwordUnreadable(status: Int32)
    /// The session ended after authentication without the user asking: server gone, network error,
    /// malformed data.
    case connectionLost

    enum Action: Equatable, Sendable {
        /// Opens the Machine Editor; saving retries.
        case editCredentials
        /// Tries again (unreachable and other connection failures).
        case retry
        /// Connects again after a drop.
        case reconnect
    }

    /// `nil` for `.cancelled`: the user stopped it, there is nothing to show.
    init?(openError: RFBError) {
        guard let failure = TestConnectionFailure(openError) else { return nil }
        self = .connect(failure)
    }

    var isAuthentication: Bool {
        switch self {
        case .connect(.authFailed), .connect(.credentialsRequired), .connect(.credentialTooLong), .passwordUnreadable:
            true
        default:
            false
        }
    }

    var action: Action {
        if isAuthentication { return .editCredentials }
        return self == .connectionLost ? .reconnect : .retry
    }

    /// SessionRecord.outcome. Credential problems are `authFailed`; every other failure to open
    /// (network, timeout, refused, not an RFB server, unsupported security type…) is `unreachable`.
    var outcome: SessionOutcome {
        if isAuthentication { return .authFailed }
        return self == .connectionLost ? .dropped : .unreachable
    }

    /// Banner text. The open timeout differs from the Test's 5 s, so it has its own copy.
    func message(_ t: (String) -> String) -> String {
        switch self {
        case .connect(.timedOut): t("session_timeout")
        case .connect(let failure): failure.message(t)
        case .passwordUnreadable(let status): t("session_password_unreadable").replacingOccurrences(of: "%@", with: String(status))
        case .connectionLost: t("session_connection_lost")
        }
    }
}

// MARK: - Session

/// One Session Window's connection (AppFlow › Session Window): connecting overlay, first frame,
/// input, error banners, Retry/Reconnect, and its SessionRecord.
///
/// Stopping always runs in this order (TRD › Input, teardown order): release the input
/// (`SessionSurface.releaseCapture` or `tearDownInput`, which enqueue the release of everything held),
/// `InputSender.finish()`, `await stopped()`, then close the connection. The event loop is never
/// cancelled before that: ending the event sequence would close the socket under the releases. A
/// generation token makes every late result of a stopped attempt a no-op.
@Observable
@MainActor
final class SessionModel {
    enum Phase: Equatable {
        case idle
        /// Overlay "Connecting to <name>…" with Cancel, until the first framebuffer update.
        case connecting
        case connected
        case failed(SessionFailure)
        /// Window closing or closed.
        case closed
    }

    /// `open` timeout. Longer than the Test's 5 s: a session on a slow VPN should not fail where it
    /// would have connected; the PRD's ≤ 5 s p90 is measured, not enforced.
    static let openTimeout: Duration = .seconds(10)

    private(set) var phase: Phase = .idle
    private(set) var target: SessionTarget
    /// Fit ↔ actual size (⌥⌘S); starts from Machine.scalingMode, not saved back.
    var scalingMode: ScalingMode
    /// The keyboard is captured (toolbar pill).
    private(set) var isCapturing = false
    /// The system-shortcut tap can run (Accessibility access).
    private(set) var systemShortcutsAvailable = true
    /// Shared Clipboard for this session (toolbar toggle); starts from Machine.sharedClipboard, not
    /// saved back. Off: nothing is read from or written to the local pasteboard, nothing is sent.
    var clipboardSharing: Bool {
        didSet {
            guard clipboardSharing != oldValue else { return }
            // The connection hears of it before the bridge can send (same serial chain), so the text
            // the bridge sends at once when turned on is not refused.
            if let connection { applyClipboardSharing(to: connection) }
            clipboard.isEnabled = clipboardSharing
        }
    }
    /// "Clipboard too large" toast, for 2 s.
    private(set) var clipboardTooLarge = false

    /// The record of the current attempt (one per connect, BackendSchema › SessionRecord).
    @ObservationIgnored private(set) var record: SessionRecord?
    @ObservationIgnored weak var surface: (any SessionSurface)?
    /// A Session Window shows this session; a second window for the same machine closes itself.
    @ObservationIgnored var hasWindow = false
    /// Brings that window forward (set by the window).
    @ObservationIgnored var bringWindowForward: (() -> Void)?
    /// Rank of the Connect that opened this session (`SessionManager`): the place of its tab.
    @ObservationIgnored var openOrder = 0
    @ObservationIgnored let display: SessionDisplayModel?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let passwords: any MachinePasswordStore
    @ObservationIgnored private let makeConnection: @MainActor (SessionTarget) -> any SessionConnection
    @ObservationIgnored private let clock: SessionClock

    @ObservationIgnored private var connection: (any SessionConnection)?
    @ObservationIgnored private var sender: InputSender?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The `open` of the current attempt, the only task that holds the credentials; dropped as soon as
    /// it ends, so the password does not live as long as the session.
    @ObservationIgnored private(set) var opening: Task<Void, any Error>?
    /// How long a stop waits for the input already queued to be written before closing anyway (a
    /// frozen peer must not keep the socket and tasks alive after the window closed).
    @ObservationIgnored var stopTimeout: Duration = .seconds(2)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startUptime: TimeInterval = 0
    /// Local pasteboard ↔ remote (TRD › Clipboard).
    @ObservationIgnored let clipboard: ClipboardBridge
    /// Clipboard sends run one after the other, in order.
    @ObservationIgnored private var clipboardSend: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(machine: Machine, context: ModelContext, passwords: any MachinePasswordStore,
         display: SessionDisplayModel?, clock: SessionClock = .live,
         pasteboard: any ClipboardPasteboard, clipboardPollInterval: Duration? = .milliseconds(500),
         makeConnection: @escaping @MainActor (SessionTarget) -> any SessionConnection) {
        target = SessionTarget(machine)
        scalingMode = machine.scalingModeValue
        clipboardSharing = machine.sharedClipboard
        self.context = context
        self.passwords = passwords
        self.display = display
        self.clock = clock
        self.makeConnection = makeConnection
        clipboard = ClipboardBridge(pasteboard: pasteboard, isEnabled: machine.sharedClipboard,
                                    pollInterval: clipboardPollInterval)
        clipboard.send = { [weak self] text in self?.shareClipboard(text) }
        clipboard.onTooLarge = { [weak self] in self?.showClipboardTooLarge() }
    }

    var isConnecting: Bool { phase == .connecting }

    var failure: SessionFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    // MARK: Connect

    /// Starts an attempt (window opened, Retry, Reconnect, credentials saved). The connect time runs
    /// from here, before the Keychain read: "click to first frame".
    func connect() {
        guard phase != .connecting, phase != .connected, phase != .closed else { return }
        generation += 1
        let generation = self.generation
        if let machine = fetchMachine() { target = SessionTarget(machine) }   // edited credentials
        startUptime = clock.uptime()
        phase = .connecting
        let record = SessionRecord(machineID: target.machineID, machineName: target.name,
                                   startedAt: clock.now(), outcome: .cancelled)
        context.insert(record)
        self.record = record
        save()

        let password: String?
        do {
            password = try passwords.storedPassword(for: target.machineID)?.password
        } catch {
            finishRecord(outcome: SessionFailure.passwordUnreadable(status: error.status).outcome, bytes: 0)
            phase = .failed(.passwordUnreadable(status: error.status))
            return
        }
        let credentials = RFBCredentials(kind: target.kind, username: target.username, password: password)
        let connection = makeConnection(target)
        self.connection = connection
        // A fresh chain: a share stuck on the previous (frozen) peer must not hold this one up.
        clipboardSend = nil
        // Untyped closures: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
        let opening = Task {
            try await connection.connect(credentials: credentials, timeout: Self.openTimeout)
        }
        self.opening = opening
        task = Task { [weak self] in
            let events: any AsyncSequence<RFBEvent, any Error> & Sendable
            do {
                try await opening.value
                self?.openingEnded(generation: generation)
            } catch {
                self?.openingEnded(generation: generation)
                let failure = (error as? RFBError).flatMap(SessionFailure.init(openError:)) ?? .connect(.unexpectedResponse)
                if (error as? RFBError) != .cancelled { await self?.stop(failing: failure, generation: generation) }
                return
            }
            // Before the events start, so no clipboard text arrives or leaves while it is off; a toggle
            // during the connection goes through the same chain after it.
            await self?.applyClipboardSharing(to: connection).value
            do {
                events = try await connection.events()
            } catch {
                await self?.stop(failing: .connectionLost, generation: generation)
                return
            }
            guard let self, self.generation == generation else { return }
            self.sender = InputSender { messages in try await connection.send(messages) }
            // Ending without an error is a loss too unless this attempt was stopped, which `stop`
            // tells by the generation.
            try? await self.consume(events, generation: generation)
            await self.stop(failing: .connectionLost, generation: generation)
        }
    }

    private func openingEnded(generation: Int) {
        if generation == self.generation { opening = nil }
    }

    private func consume(_ events: some AsyncSequence<RFBEvent, any Error>, generation: Int) async throws {
        for try await event in events {
            guard self.generation == generation else { return }
            display?.handle(event)
            if case .serverCutText(let text) = event { clipboard.receive(text) }
            if case .framebufferUpdate = event, phase == .connecting { didReceiveFirstFrame() }
        }
    }

    private func didReceiveFirstFrame() {
        phase = .connected
        let millis = Int(((clock.uptime() - startUptime) * 1000).rounded())
        record?.outcomeValue = .connected
        record?.connectMillis = millis
        fetchMachine()?.lastConnectedAt = clock.now()
        save()
        surface?.startCapture()
        clipboard.sessionStarted()
    }

    // MARK: Input

    /// Input messages from the view, in order. Dropped when no session is running.
    func sendInput(_ messages: [ClientMessage]) {
        sender?.enqueue(messages)
    }

    /// The Session Window became or stopped being key: the clipboard is read only while it is.
    func windowKeyChanged(_ key: Bool) {
        clipboard.windowKeyChanged(key)
    }

    private func shareClipboard(_ text: String) {
        guard let connection else { return }
        enqueueClipboard { [weak self] in
            // A failed write fails the event loop too, which reports the loss.
            let outcome = (try? await connection.shareClipboard(text)) ?? .notSharing
            await self?.clipboard.shared(text, outcome: outcome)
        }
    }

    /// Tells the connection the current toggle, in order with the sends.
    @discardableResult
    private func applyClipboardSharing(to connection: any SessionConnection) -> Task<Void, Never> {
        let on = clipboardSharing
        return enqueueClipboard { await connection.setClipboardSharing(on) }
    }

    /// Clipboard work for the connection runs one step after the other, in order.
    @discardableResult
    private func enqueueClipboard(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = clipboardSend
        let task = Task {
            await previous?.value
            await work()
        }
        clipboardSend = task
        return task
    }

    private func showClipboardTooLarge() {
        clipboardTooLarge = true
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.clipboardTooLarge = false
        }
    }

    func inputStateChanged(capturing: Bool, systemShortcutsAvailable: Bool) {
        isCapturing = capturing
        self.systemShortcutsAvailable = systemShortcutsAvailable
    }

    // MARK: Stop

    /// The window is closing (Disconnect, Cancel, close button): `beginClose`, then the ordered
    /// teardown.
    func close() async {
        await completeClose(record: beginClose())
    }

    /// The synchronous part of a close, at the moment of the click (or of ⌘Q): later results of the
    /// attempt are ignored (a first frame racing Cancel is not recorded), and the record gets its end
    /// now (`cancelled` if the first frame never came; after it the outcome stays `connected`).
    /// Returns the record whose bytes `completeClose` fills in.
    @discardableResult
    func beginClose() -> SessionRecord? {
        guard phase != .closed else { return nil }
        let wasConnecting = phase == .connecting
        let wasRunning = wasConnecting || phase == .connected
        generation += 1
        phase = .closed
        guard wasRunning else { return nil }
        finishRecord(outcome: wasConnecting ? .cancelled : nil, bytes: nil)
        return record
    }

    /// Ordered teardown after `beginClose`, then the bytes received.
    func completeClose(record: SessionRecord?) async {
        let task = self.task
        let opening = self.opening
        let bytes = await tearDown(windowClosing: true)
        task?.cancel()   // after the close: only an `open` still in flight is left to stop
        opening?.cancel()
        self.opening = nil
        if let record {
            record.bytesReceived = bytes
            save()
        }
    }

    /// A failure from the attempt `generation`; ignored once a newer attempt or a close took over.
    private func stop(failing failure: SessionFailure, generation: Int) async {
        guard generation == self.generation else { return }
        phase = .failed(failure)
        finishRecord(outcome: failure.outcome, bytes: nil)
        let record = self.record   // a Retry during the teardown starts a new record
        let bytes = await tearDown(windowClosing: false)
        record?.bytesReceived = bytes
        save()
    }

    /// Input release → `finish()` → `stopped()` → close. Returns the bytes received.
    private func tearDown(windowClosing: Bool) async -> Int64 {
        if windowClosing { surface?.tearDownInput() } else { surface?.releaseCapture() }
        clipboard.sessionStopped()
        let sender = self.sender
        let connection = self.connection
        task = nil
        if let sender {
            sender.finish()
            await Self.waitUntilStopped(sender, limit: stopTimeout)
        }
        if self.sender === sender { self.sender = nil }
        guard let connection else { return 0 }
        await connection.close()
        if self.connection === connection { self.connection = nil }
        return await connection.receivedByteCount
    }

    /// `sender.stopped()`, but at most `limit`: then the connection is closed anyway, which also ends
    /// a write stuck on a frozen peer.
    private static func waitUntilStopped(_ sender: InputSender, limit: Duration) async {
        let (signal, continuation) = AsyncStream.makeStream(of: Void.self)
        let stopped = Task {
            await sender.stopped()
            continuation.yield()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield()
        }
        var iterator = signal.makeAsyncIterator()
        _ = await iterator.next()
        timer.cancel()
        stopped.cancel()
        continuation.finish()
    }

    // MARK: Record

    /// Sets the end of the current record; `outcome` nil keeps the one already set.
    private func finishRecord(outcome: SessionOutcome?, bytes: Int64?) {
        guard let record else { return }
        if let outcome { record.outcomeValue = outcome }
        record.endedAt = clock.now()
        if let bytes { record.bytesReceived = bytes }
        save()
    }

    private func fetchMachine() -> Machine? {
        let id = target.machineID
        return try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.id == id })).first
    }

    /// History is best effort: a failed save never breaks the session.
    private func save() {
        try? context.save()
    }
}
