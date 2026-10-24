import ClaudeKit
import Foundation
import Observation
import SwiftData
import RemoteDeckCore
import RFBKit

// MARK: - Dependencies

/// One RFB connection as the Session Window uses it. `RFBConnection` in the app; a fake in tests
/// (the hosted tests cannot listen on loopback). A new instance per attempt.
protocol SessionConnection: AnyObject, Sendable {
    /// Connects and authenticates (`RFBConnection.open`) and returns the address reached. Without
    /// `allowsPublicInternet`, an address on the public Internet is refused right after TCP, before any
    /// RFB byte (`RFBError.publicAddressNotAdmitted`): the user confirms first (T5.3 H1).
    func connect(credentials: RFBCredentials, timeout: Duration, allowsPublicInternet: Bool) async throws(RFBError)
        -> RemoteAddress
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
    /// The current framebuffer, for the Claude Assistant's screenshots (`RFBConnection.framebufferSnapshot`).
    func framebufferSnapshot() async -> Framebuffer?
}

extension RFBConnection: SessionConnection {
    func connect(credentials: RFBCredentials, timeout: Duration, allowsPublicInternet: Bool) async throws(RFBError)
        -> RemoteAddress {
        _ = try await open(credentials: credentials, timeout: timeout, allowsPublicInternet: allowsPublicInternet)
        // `open` sets it before returning; the fallback (public) only satisfies the type.
        return remoteAddress ?? RemoteAddress(text: host, scope: .publicInternet)
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
    /// them: no user name for an Anthropic VM, a blank user name or password counts as none. A Mac
    /// (ARD) with a user name requires Apple DH (type 30, T5.3 M4): its macOS password never goes out
    /// as a VNC DES response, and the session never falls back to no authentication.
    init(kind: MachineKind, username: String?, password: String?) {
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUser = kind == .anthropicVM || user?.isEmpty != false ? nil : user
        self.init(username: effectiveUser,
                  password: password?.isEmpty == false ? password : nil,
                  requiredSecurityType: kind == .macARD && effectiveUser != nil ? SecurityType.appleDiffieHellman : nil)
    }
}

/// Automatic reconnection (T5.1, TRD › Architecture › Session resilience).
struct SessionResilience: Sendable {
    /// From a drop (or the network coming back) to the one automatic attempt.
    var reconnectDelay: Duration = .seconds(2)
    /// After wake, before the sessions closed for sleep reconnect (the network may still be coming back).
    var wakeGrace: Duration = .seconds(5)
    /// An automatic attempt that drops again sooner than this after its first frame gets no other
    /// automatic attempt: the banner shows (a server that drops every session never loops).
    var rearmAfter: TimeInterval = 60
    /// A connected session is closed for a lost network path only if the path stays lost this long:
    /// a shorter blip keeps the session (the overlay says "Waiting for network…" meanwhile).
    var pathLossGrace: Duration = .seconds(3)
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
        // A missing Apple authentication (T5.3 M4) is a credentials matter too: Edit credentials (the
        // kind or user name), recorded `authFailed`, and never turned into "Connection lost" after an
        // automatic attempt (a downgrade during a reconnect keeps its own banner).
        case .connect(.authFailed), .connect(.credentialsRequired), .connect(.credentialTooLong),
             .connect(.appleAuthenticationMissing), .connect(.passwordAuthenticationMissing), .passwordUnreadable:
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
///
/// Resilience (T5.1): a drop after the first frame gets one automatic attempt `reconnectDelay` later
/// (the overlay says "Reconnecting…" over the last frame); if it fails, the "Connection lost" banner
/// (credentials keep their own banner). No network: no attempt until the path is back
/// (`networkLost`/`networkRestored`). Sleep closes the session cleanly and wake reconnects it
/// (`suspendForSleep`/`resumeAfterWake`). The assistant is always stopped before any teardown.
@Observable
@MainActor
final class SessionModel {
    enum Phase: Equatable {
        case idle
        /// Overlay "Connecting to <name>…" with Cancel, until the first framebuffer update (an
        /// automatic attempt says "Reconnecting to <name>…": `isAutomaticAttempt`).
        case connecting
        case connected
        case failed(SessionFailure)
        /// No attempt runs and no record is open, without a banner: the last frame stays dimmed under
        /// an overlay until the automatic attempt (T5.1).
        case waiting(WaitReason)
        /// Window closing or closed.
        case closed
    }

    enum WaitReason: Equatable, Sendable {
        /// Lost after the first frame: the automatic attempt starts after `reconnectDelay`.
        case retryDelay
        /// This Mac has no network: nothing is tried until the path is back.
        case network
        /// Closed for sleep: reconnects after wake.
        case asleep
    }

    /// What covers the remote screen; the view picks the words.
    enum Overlay: Equatable {
        case connecting
        case reconnecting
        case waitingForNetwork
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
    /// The address the last attempt reached, once TCP was up (T5.3 H1): a public one shows the orange
    /// badge in the toolbar.
    private(set) var remoteAddress: RemoteAddress?
    /// The last attempt stopped before any RFB byte because the address reached is on the public
    /// Internet and this machine was never confirmed: the "Unencrypted connection over the Internet"
    /// sheet, with the address. Connect anyway (`connectOverPublicInternet`) or Cancel (the tab closes).
    private(set) var publicAddressConsent: String?

    var isOverPublicInternet: Bool { remoteAddress?.scope.isPublicInternet == true }

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
    /// Machines whose connection across the Internet the user confirmed (per Mac, T5.3 H1).
    @ObservationIgnored private let publicConsents: any PublicAddressConsents
    /// The user set the shared clipboard in the toolbar during this session: a public address no
    /// longer turns it off (T5.3 M1).
    @ObservationIgnored private var clipboardChosenInSession = false

    @ObservationIgnored private var connection: (any SessionConnection)?
    @ObservationIgnored private var sender: InputSender?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The `open` of the current attempt, the only task that holds the credentials; dropped as soon as
    /// it ends, so the password does not live as long as the session.
    @ObservationIgnored private(set) var opening: Task<RemoteAddress, any Error>?
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
    /// The Claude Assistant of this session (set by `SessionManager`).
    @ObservationIgnored var assistant: AssistantModel?
    /// Framebuffer updates received in this attempt (the assistant waits for one after an action).
    @ObservationIgnored private(set) var frameCount = 0
    /// `frameCount` when the assistant last sent input, until its next screenshot.
    @ObservationIgnored private var assistantInputFrame: Int?
    /// Buttons held by the view's own input, as last sent (a release passes while an action runs).
    @ObservationIgnored private var viewButtonMask: UInt8 = 0
    /// Longest wait for the remote to redraw before a screenshot that follows an action.
    @ObservationIgnored var assistantSettleLimit: Duration = .seconds(1)

    /// The current attempt was started by the session itself (after a drop, the network back, wake).
    private(set) var isAutomaticAttempt = false
    /// This Mac has a network path (`SessionManager`); no automatic attempt starts without one.
    @ObservationIgnored var isNetworkAvailable: @MainActor () -> Bool = { true }
    @ObservationIgnored private let resilience: SessionResilience
    /// Sleeps for the reconnect delay; a fake in tests.
    @ObservationIgnored private let reconnectClock: any ReachabilityClock
    /// The delay before the automatic attempt.
    @ObservationIgnored private var pendingReconnect: Task<Void, Never>?
    /// The teardown of a session stopped for sleep or for the network; the next attempt waits for it.
    @ObservationIgnored private(set) var suspension: Task<Void, Never>?
    /// Uptime of the current attempt's first frame (`SessionResilience.rearmAfter`).
    @ObservationIgnored private var firstFrameUptime: TimeInterval?
    /// Bumped by `cancelPendingReconnect`: a pending task that wakes up with an older token does nothing.
    @ObservationIgnored private var reconnectToken = 0
    /// Connected, but this Mac lost its path less than `pathLossGrace` ago: the socket is kept.
    private(set) var isPathLost = false
    @ObservationIgnored private var pathLossTimer: Task<Void, Never>?
    /// The keyboard was captured when the session was lost: the automatic attempt captures it again.
    @ObservationIgnored private var recapturesAfterReconnect = false

    init(machine: Machine, context: ModelContext, passwords: any MachinePasswordStore,
         display: SessionDisplayModel?, clock: SessionClock = .live,
         pasteboard: any ClipboardPasteboard, clipboardPollInterval: Duration? = .milliseconds(500),
         resilience: SessionResilience = SessionResilience(),
         reconnectClock: any ReachabilityClock = ContinuousReachabilityClock(),
         publicConsents: any PublicAddressConsents = InMemoryPublicAddressConsents(),
         makeConnection: @escaping @MainActor (SessionTarget) -> any SessionConnection) {
        self.publicConsents = publicConsents
        self.resilience = resilience
        self.reconnectClock = reconnectClock
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

    var overlay: Overlay? {
        switch phase {
        case .connecting: isAutomaticAttempt ? .reconnecting : .connecting
        case .connected: isPathLost ? .waitingForNetwork : nil
        case .waiting(.network): .waitingForNetwork
        case .waiting: .reconnecting
        case .idle, .failed, .closed: nil
        }
    }

    // MARK: Connect

    /// Starts an attempt (window opened, Retry, Reconnect, credentials saved). The connect time runs
    /// from here, before the Keychain read: "click to first frame".
    func connect() {
        guard phase != .connecting, phase != .connected, phase != .closed else { return }
        startAttempt(automatic: false)
    }

    private func startAttempt(automatic: Bool) {
        cancelPendingReconnect()
        cancelPathLoss()
        publicAddressConsent = nil   // a new attempt decides again
        isAutomaticAttempt = automatic
        firstFrameUptime = nil
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
            // An automatic attempt never brings up a Keychain dialog nobody asked for: it fails instead
            // (errSecInteractionNotAllowed → the "password could not be read" banner).
            password = try passwords.storedPassword(for: target.machineID, allowsInteraction: !automatic)?.password
        } catch {
            finishRecord(outcome: SessionFailure.passwordUnreadable(status: error.status).outcome, bytes: 0)
            phase = .failed(.passwordUnreadable(status: error.status))
            return
        }
        let credentials = RFBCredentials(kind: target.kind, username: target.username, password: password)
        // Checked at each attempt: an automatic reconnect that now lands on a public address (a name
        // resolving elsewhere off the VPN) stops for the same confirmation.
        let allowsPublicInternet = publicConsents.hasConfirmed(target.machineID, host: target.host)
        let connection = makeConnection(target)
        self.connection = connection
        // A fresh chain: a share stuck on the previous (frozen) peer must not hold this one up.
        clipboardSend = nil
        // Untyped closures: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
        let opening = Task {
            try await connection.connect(credentials: credentials, timeout: Self.openTimeout,
                                         allowsPublicInternet: allowsPublicInternet)
        }
        self.opening = opening
        task = Task { [weak self] in
            let events: any AsyncSequence<RFBEvent, any Error> & Sendable
            let address: RemoteAddress
            do {
                address = try await opening.value
                self?.openingEnded(generation: generation)
            } catch {
                self?.openingEnded(generation: generation)
                if case .publicAddressNotAdmitted(let text)? = error as? RFBError {
                    await self?.askPublicConsent(address: text, generation: generation)
                    return
                }
                let failure = (error as? RFBError).flatMap(SessionFailure.init(openError:)) ?? .connect(.unexpectedResponse)
                if (error as? RFBError) != .cancelled { await self?.stop(failing: failure, generation: generation) }
                return
            }
            // Before the clipboard is applied: a public address turns sharing off first.
            self?.addressReached(address, generation: generation)
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

    // MARK: Public Internet (T5.3 H1, M1)

    /// The address of a connection that opened. On the public Internet the shared clipboard is turned
    /// off for the session, unless the user set it in the toolbar during this session.
    private func addressReached(_ address: RemoteAddress, generation: Int) {
        guard generation == self.generation else { return }
        // Landing on the Internet after a LAN address (or for the first time): a toolbar choice made on
        // the LAN does not carry over.
        if address.scope.isPublicInternet, remoteAddress?.scope.isPublicInternet != true { clipboardChosenInSession = false }
        remoteAddress = address
        if address.scope.isPublicInternet, !clipboardChosenInSession { clipboardSharing = false }
    }

    /// `open` refused the address before any RFB byte: the record ends `cancelled` (nothing was
    /// connected), no banner, and the sheet asks.
    private func askPublicConsent(address: String, generation: Int) async {
        guard generation == self.generation else { return }
        finishRecord(outcome: .cancelled, bytes: nil)
        let record = self.record
        phase = .idle
        publicAddressConsent = address
        let bytes = await tearDown(windowClosing: false)
        record?.bytesReceived = bytes
        save()
    }

    /// "Connect anyway": remembered for this machine on this Mac, then a new attempt.
    func connectOverPublicInternet() {
        guard publicAddressConsent != nil, phase == .idle else { return }
        publicAddressConsent = nil
        publicConsents.confirm(target.machineID, host: target.host)
        startAttempt(automatic: false)
    }

    /// "Cancel": nothing is remembered; the view closes the tab.
    func declinePublicInternet() {
        publicAddressConsent = nil
    }

    /// The toolbar's Shared Clipboard toggle: the user's choice holds for this session, a public
    /// address included.
    func setClipboardSharingFromToolbar(_ on: Bool) {
        clipboardChosenInSession = true
        clipboardSharing = on
    }

    private func consume(_ events: some AsyncSequence<RFBEvent, any Error>, generation: Int) async throws {
        for try await event in events {
            guard self.generation == generation else { return }
            display?.handle(event)
            if case .serverCutText(let text) = event { clipboard.receive(text) }
            if case .framebufferUpdate = event {
                frameCount += 1
                if phase == .connecting { didReceiveFirstFrame() }
            }
        }
    }

    private func didReceiveFirstFrame() {
        phase = .connected
        firstFrameUptime = clock.uptime()
        let millis = Int(((clock.uptime() - startUptime) * 1000).rounded())
        record?.outcomeValue = .connected
        record?.connectMillis = millis
        fetchMachine()?.lastConnectedAt = clock.now()
        save()
        // A reconnect takes the keyboard back only if it was captured when the session was lost.
        if !isAutomaticAttempt || recapturesAfterReconnect { surface?.startCapture() }
        recapturesAfterReconnect = false
        clipboard.sessionStarted()
    }

    // MARK: Input

    /// Input messages from the view, in order. Dropped when no session is running, and while a
    /// confirmed Claude Assistant action runs: a mouse move over the view would otherwise land between
    /// the steps of a drag or a held key and change what the remote sees.
    func sendInput(_ messages: [ClientMessage]) {
        let running = assistant?.phase == .running
        var passing: [ClientMessage] = []
        for message in messages {
            // While an action runs only releases go through: key-ups, and the pointer event that lifts a
            // button the view pressed before; moves and presses wait.
            if running {
                switch message {
                case .keyEvent(let down, _) where !down: break
                case .pointerEvent(let mask, _, _) where mask == 0 && viewButtonMask != 0: break
                default: continue
                }
            }
            if case .pointerEvent(let mask, _, _) = message { viewButtonMask = mask }
            passing.append(message)
        }
        guard !passing.isEmpty else { return }
        sender?.enqueue(passing)
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
        cancelPendingReconnect()   // nothing reconnects a closed window
        cancelPathLoss()
        // The assistant's releases go into the input sender before the view's and before `finish()`.
        assistant?.sessionEnded()
        phase = .closed
        publicAddressConsent = nil
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
    /// A drop after the first frame waits for the automatic attempt instead of showing the banner,
    /// unless that attempt was itself automatic and dropped too soon (`rearmAfter`). A failed
    /// automatic attempt shows "Connection lost" (its record keeps its own outcome), except a
    /// credential problem, which shows its own banner: nothing is retried after it.
    private func stop(failing failure: SessionFailure, generation: Int) async {
        guard generation == self.generation else { return }
        cancelPathLoss()
        if phase == .connected { recapturesAfterReconnect = isCapturing }
        assistant?.sessionEnded()
        let reconnects = phase == .connected && failure == .connectionLost && mayReconnectAutomatically
        if reconnects {
            phase = .waiting(isNetworkAvailable() ? .retryDelay : .network)
        } else {
            phase = .failed(isAutomaticAttempt && !failure.isAuthentication ? .connectionLost : failure)
        }
        finishRecord(outcome: failure.outcome, bytes: nil)
        let record = self.record   // a Retry during the teardown starts a new record
        let bytes = await tearDown(windowClosing: false)
        record?.bytesReceived = bytes
        save()
        // Not if the window closed, the network went away or the user reconnected meanwhile.
        if reconnects, generation == self.generation, phase == .waiting(.retryDelay) { scheduleReconnect() }
    }

    /// A user's attempt may always reconnect once; an automatic one only once it held `rearmAfter`.
    private var mayReconnectAutomatically: Bool {
        guard isAutomaticAttempt else { return true }
        guard let firstFrameUptime else { return false }
        return clock.uptime() - firstFrameUptime >= resilience.rearmAfter
    }

    /// Input release → `finish()` → `stopped()` → close. Returns the bytes received.
    private func tearDown(windowClosing: Bool) async -> Int64 {
        let (sender, connection) = beginTearDown(windowClosing: windowClosing)
        return await finishTearDown(sender: sender, connection: connection)
    }

    /// The synchronous part: the input is released and the sender finished now, and the session lets
    /// go of both, so an attempt started meanwhile can never be torn down by this one.
    private func beginTearDown(windowClosing: Bool) -> (InputSender?, (any SessionConnection)?) {
        if windowClosing { surface?.tearDownInput() } else { surface?.releaseCapture() }
        clipboard.sessionStopped()
        let sender = self.sender
        let connection = self.connection
        task = nil
        self.sender = nil
        self.connection = nil
        sender?.finish()
        return (sender, connection)
    }

    private func finishTearDown(sender: InputSender?, connection: (any SessionConnection)?) async -> Int64 {
        if let sender { await Self.waitUntilStopped(sender, limit: stopTimeout) }
        guard let connection else { return 0 }
        await connection.close()
        return await connection.receivedByteCount
    }

    // MARK: Resilience (T5.1)

    /// This Mac lost its network path. A connected session keeps its socket for `pathLossGrace`
    /// ("Waiting for network…" over it) and is closed only if the path is still lost then (record
    /// `dropped`); an automatic attempt in flight is stopped at once (`cancelled`), and the delay
    /// before one is held: no attempt and no banner while offline. A user's own attempt is left to
    /// fail with its banner.
    func networkLost() {
        switch phase {
        case .connected:
            guard !isPathLost else { return }
            isPathLost = true
            let generation = self.generation
            let clock = reconnectClock
            let grace = resilience.pathLossGrace
            pathLossTimer = Task { [weak self] in
                guard (try? await clock.sleep(for: grace)) != nil, !Task.isCancelled, let self,
                      self.generation == generation, self.isPathLost, self.phase == .connected else { return }
                self.pathLossTimer = nil
                self.isPathLost = false
                // Same anti-flap rule as a drop: an automatic attempt lost again within `rearmAfter`
                // shows the banner instead of waiting for one more.
                if self.mayReconnectAutomatically {
                    self.suspend(to: .waiting(.network), outcome: .dropped)
                } else {
                    self.suspend(to: .failed(.connectionLost), outcome: .dropped)
                }
            }
        case .connecting where isAutomaticAttempt: suspend(to: .waiting(.network), outcome: .cancelled)
        case .waiting(.retryDelay):
            cancelPendingReconnect()
            phase = .waiting(.network)
        default: break   // asleep: wake decides; failed, idle, closed: nothing runs
        }
    }

    /// The path is back: a blip shorter than `pathLossGrace` changes nothing; otherwise one automatic
    /// attempt, after `reconnectDelay`.
    func networkRestored() {
        if isPathLost {
            cancelPathLoss()
            return
        }
        guard phase == .waiting(.network) else { return }
        phase = .waiting(.retryDelay)
        scheduleReconnect()
    }

    /// The Mac goes to sleep: the session closes cleanly now (assistant stopped, input released, then
    /// the connection closed), and is reconnected after wake. A connected record keeps `connected`
    /// with its end (as a Disconnect), one still connecting becomes `cancelled`. A session showing a
    /// banner stays as it is.
    func suspendForSleep() {
        switch phase {
        case .connected: suspend(to: .waiting(.asleep), outcome: nil)
        case .connecting: suspend(to: .waiting(.asleep), outcome: .cancelled)
        case .waiting:
            cancelPendingReconnect()
            phase = .waiting(.asleep)
        case .idle, .failed, .closed: break
        }
    }

    /// After wake (and its grace, `SessionManager`): one automatic attempt, once the sleep teardown is
    /// over; without a network path, it waits for it. A sleep (or anything that cancels it) before
    /// the teardown ends leaves it without effect.
    func resumeAfterWake() {
        guard phase == .waiting(.asleep) else { return }
        cancelPendingReconnect()
        let token = reconnectToken
        let suspension = self.suspension
        pendingReconnect = Task { [weak self] in
            await suspension?.value
            guard !Task.isCancelled, let self, self.reconnectToken == token,
                  self.phase == .waiting(.asleep) else { return }
            self.pendingReconnect = nil
            if self.isNetworkAvailable() {
                self.startAttempt(automatic: true)
            } else {
                self.phase = .waiting(.network)
            }
        }
    }

    /// The automatic attempt, `reconnectDelay` from now, once any suspension teardown is over.
    private func scheduleReconnect() {
        cancelPendingReconnect()
        let token = reconnectToken
        let clock = reconnectClock
        let delay = resilience.reconnectDelay
        pendingReconnect = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            await self?.suspension?.value
            guard !Task.isCancelled, let self, self.reconnectToken == token,
                  self.phase == .waiting(.retryDelay) else { return }
            self.pendingReconnect = nil
            self.startAttempt(automatic: true)
        }
    }

    private func cancelPendingReconnect() {
        reconnectToken += 1
        pendingReconnect?.cancel()
        pendingReconnect = nil
    }

    private func cancelPathLoss() {
        isPathLost = false
        pathLossTimer?.cancel()
        pathLossTimer = nil
    }

    /// Stops the running attempt for a cause outside the session (sleep, no network): later results of
    /// the attempt are ignored, so the stream ending under the close is not taken for a drop; the
    /// assistant is stopped before the input release; the teardown runs in the usual order.
    private func suspend(to next: Phase, outcome: SessionOutcome?) {
        cancelPendingReconnect()
        cancelPathLoss()
        if phase == .connected { recapturesAfterReconnect = isCapturing }
        generation += 1
        assistant?.sessionEnded()
        phase = next
        finishRecord(outcome: outcome, bytes: nil)
        let record = self.record
        let task = self.task
        let opening = self.opening
        self.opening = nil
        let (sender, connection) = beginTearDown(windowClosing: false)
        let previous = suspension
        suspension = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let bytes = await self.finishTearDown(sender: sender, connection: connection)
            task?.cancel()   // after the close, as in `completeClose`
            opening?.cancel()
            record?.bytesReceived = bytes
            self.save()
        }
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

// MARK: - Claude Assistant

extension SessionModel: AssistantSessionPort {
    var assistantCanAct: Bool { phase == .connected && sender != nil }

    var assistantDesktop: RemoteDesktopKind { target.kind == .macARD ? .mac : .x11 }

    var assistantProfile: ModifierProfile { target.modifierProfile }

    func assistantSnapshot() async -> Framebuffer? {
        await connection?.framebufferSnapshot()
    }

    /// The same path as the view's input: `InputSender`, in order, released on teardown.
    func assistantSend(_ messages: [ClientMessage]) {
        guard !messages.isEmpty else { return }
        if assistantInputFrame == nil { assistantInputFrame = frameCount }
        sender?.enqueue(messages)
    }

    /// Waits for a framebuffer update newer than the last assistant input, at most
    /// `assistantSettleLimit`; at once if no input was sent since the last screenshot.
    func assistantSettle() async {
        guard let mark = assistantInputFrame else { return }
        assistantInputFrame = nil
        let deadline = ContinuousClock.now + assistantSettleLimit
        while frameCount <= mark, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction? {
        guard let record else { return nil }
        let action = AssistantAction(session: record, createdAt: clock.now(), kind: kind, payload: payload,
                                     decision: decision)
        context.insert(action)
        save()
        return action
    }

    func assistantSave() {
        save()
    }

    func assistantAddTokens(_ count: Int) {
        record?.assistantTokens += count
    }

    func assistantReleaseKeyboard() {
        surface?.releaseCapture()
    }
}
