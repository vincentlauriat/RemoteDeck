import AppKit
import Foundation
import Observation
import SwiftData
import RemoteDeckCore
import SSHKit
import Synchronization

// MARK: - Failures

/// Why a terminal tab is not (or no longer) showing a live shell: its banner (AppFlow › Terminal tab,
/// Terminal errors). Models expose this; the view picks the words (`message`).
enum TerminalFailure: Equatable, Sendable {
    /// `open` or `openShell` failed. `.hostKeyRejected` here is an unknown key the user declined
    /// ("Host key not trusted", Retry; the tab stays open).
    case connect(SSHError)
    /// The credentials could not be produced on this Mac (nothing was sent).
    case credentials(SSHCredentialFailure)
    /// "Key in ~/.ssh" without the folder grant on this Mac: the view asks for the folder ("Grant
    /// access to ~/.ssh…"), then connects again; refused, the banner with Retry.
    case sshFolderAccessNeeded
    /// The server's key differs from the trusted one (own list or `~/.ssh/known_hosts`). No action
    /// continues the connection: the way out is in the Machine Editor. `previousFingerprint` is
    /// `HostKeyDecision.knownHostsConflict` when the conflict is in `known_hosts`, and empty when the
    /// previous key is not known (a re-key presented another key and no list holds the first one).
    case hostKeyChanged(previousFingerprint: String, newFingerprint: String)
    /// The connection ended after the shell was up without the user asking, and the automatic
    /// attempt (if any) did not bring it back.
    case connectionLost

    enum Action: Equatable, Sendable {
        /// Opens the Machine Editor; saving retries.
        case editCredentials
        /// The view asks for `~/.ssh` (`SSHFolderAccessing.requestAccess`), then `connect()`.
        case grantSSHFolder
        case retry
        case reconnect
        /// Only Close: nothing in the banner continues (changed host key).
        case close
    }

    var isAuthentication: Bool {
        switch self {
        case .connect(.authFailed), .sshFolderAccessNeeded: true
        // Never shown as such: an automatic attempt that cannot ask for a passphrase says "Connection
        // lost" (design › Passphrases), the Reconnect then asks.
        case .credentials(.passphraseUnavailable): false
        case .credentials: true
        default: false
        }
    }

    /// An automatic attempt ending on this keeps it: credentials (nothing can be retried without
    /// the user) and a changed host key (never hidden behind "Connection lost", Review Focus 5).
    /// Every other failure of an automatic attempt shows "Connection lost".
    var survivesAutomaticAttempt: Bool {
        if case .hostKeyChanged = self { return true }
        return isAuthentication
    }

    var action: Action {
        switch self {
        case .sshFolderAccessNeeded: .grantSSHFolder
        case .hostKeyChanged: .close
        case .connectionLost: .reconnect
        default: isAuthentication ? .editCredentials : .retry
        }
    }

    /// SessionRecord.outcome. A declined or changed host key is `hostKeyRejected`; credentials are
    /// `authFailed`; every other failure to open is `unreachable`.
    var outcome: SessionOutcome {
        switch self {
        case .connect(.hostKeyRejected), .hostKeyChanged: .hostKeyRejected
        case .connect(.authFailed), .credentials, .sshFolderAccessNeeded: .authFailed
        case .connectionLost: .dropped
        case .connect: .unreachable
        }
    }

    /// Banner text. A changed key gives the headline then both fingerprints, one per line.
    func message(_ t: (String) -> String) -> String {
        func fill(_ key: String, _ value: String) -> String {
            t(key).replacingOccurrences(of: "%@", with: value)
        }
        switch self {
        case .connect(let error):
            switch error {
            case .unreachable: return t("test_unreachable")
            case .timedOut: return t("session_timeout")
            case .connectionClosed: return t("test_closed")
            case .authFailed: return t("test_auth_failed")
            case .hostKeyRejected: return t("terminal_host_key_not_trusted")
            case .channelFailed: return t("terminal_shell_refused")
            case .sftpUnavailable, .portInUse, .fileExists, .noSuchDirectory, .remote: return t("test_unexpected")
            }
        case .credentials(let failure):
            switch failure {
            case .keyFileMissing(let name): return fill("terminal_key_file_missing", name)
            case .keyUnreadable: return t("terminal_key_unreadable")
            case .unsupportedKey(let type): return fill("terminal_key_unsupported", type)
            case .passwordMissing: return t("terminal_password_missing")
            case .passphraseUnavailable: return t("session_connection_lost")
            }
        case .sshFolderAccessNeeded:
            return t("terminal_ssh_folder_needed")
        case .hostKeyChanged(let previous, let new):
            var lines = [t("terminal_host_key_changed")]
            if previous == HostKeyDecision.knownHostsConflict {
                lines.append(t("terminal_host_key_previous_known_hosts"))
            } else if !previous.isEmpty {
                lines.append(fill("terminal_host_key_previous", previous))
            }
            lines.append(fill("terminal_host_key_new", new))
            return lines.joined(separator: "\n")
        case .connectionLost:
            return t("session_connection_lost")
        }
    }
}

// MARK: - Port forwards

/// One saved local forward at run time (AppFlow › Terminal tab › Port forwards): `starting` while
/// the session connects and until the listeners are up, `active`, `failed` (that forward only; the
/// shell and the other forwards go on), `stopped` once the session no longer runs.
enum ForwardState: Equatable, Sendable {
    case starting, active, failed(SSHError), stopped

    var isActive: Bool { self == .active }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The state's words in the forwards menu; a failure says why.
    func message(_ t: (String) -> String) -> String {
        switch self {
        case .starting: return t("forward_state_starting")
        case .active: return t("forward_state_active")
        case .stopped: return t("forward_state_stopped")
        case .failed(let error):
            switch error {
            case .portInUse(let port):
                return t("forward_error_port_in_use").replacingOccurrences(of: "%@", with: String(port))
            case .channelFailed: return t("forward_error_refused")
            default: return t("forward_error_failed")
            }
        }
    }
}

extension PortForward {
    /// The label, or `localhost:8080 → localhost:80`.
    var displayTitle: String {
        if let label, !label.isEmpty { return label }
        return "localhost:\(localPort) → \(remoteHost):\(remotePort)"
    }

    /// What Open in Browser opens.
    var browserURL: URL? { URL(string: "http://localhost:\(localPort)") }
}

/// Hands a URL to the default browser (`NSWorkspace` in the app, a fake in tests).
@MainActor
protocol URLOpening {
    func open(_ url: URL)
}

struct WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: - Session

/// One terminal tab's SSH session (AppFlow › Terminal tab): credentials, host key check, shell,
/// output to the `TerminalSurface`, input to the shell, error banners, Retry/Reconnect, and its
/// SessionRecord. A sibling of `SessionModel` with the same rules (TRD › Architecture › SSH):
///
/// - A generation token makes every late result of a stopped attempt a no-op; it is checked after
///   every await. `suspend` bumps it before the teardown, so the stream ending under the close is
///   not taken for a drop.
/// - Automatic attempts (after a drop, the network back, wake) read every secret with
///   `allowsInteraction: false` and never prompt: an encrypted key without a remembered passphrase
///   or an unknown host key ends in "Connection lost"; a changed host key keeps its banner.
/// - A drop after the shell was up gets one automatic attempt `reconnectDelay` later, re-armed only
///   after `rearmAfter`; sleep closes the session and wake reconnects it; a path loss closes it only
///   after `pathLossGrace` (`SessionResilience`).
/// - Teardown order: stop the forwards (Task 11), close the shell (end the read of its output),
///   then `connection.close()`. Nothing waits for the peer.
///
/// Host keys: the validator runs during key exchange and hops to the main actor, where
/// `TrustedHostKeys.decision` runs (it reads the small `~/.ssh/known_hosts` file at most once per
/// attempt, a few KB: cheap enough for the main actor).
@Observable
@MainActor
final class TerminalSessionModel {
    enum Phase: Equatable {
        case idle
        /// "Connecting to <name>…" (or "Reconnecting…" for an automatic attempt) until the shell is
        /// open; the Host Key and Passphrase sheets show during it.
        case connecting
        case connected
        case failed(TerminalFailure)
        /// No attempt runs and no record is open (T5.1), the last output dimmed under an overlay.
        case waiting(SessionModel.WaitReason)
        /// The remote shell ended by itself (`exit`, logout): no banner, nothing is retried; the view
        /// says so, with Reconnect (`connect()`).
        case ended
        /// Tab closing or closed.
        case closed
    }

    /// The Host Key Sheet: an unknown key on a user's attempt (`trustHostKey` / `rejectHostKey`).
    struct HostKeyPrompt: Equatable {
        let host: String
        let port: Int
        let key: SSHHostKey
    }

    /// `open` timeout per phase (TCP, key exchange, authentication), as a screen session.
    static let openTimeout: Duration = SessionModel.openTimeout
    /// What the remote side is told (remote hosts have no `xterm-ghostty` terminfo).
    static let term = "xterm-256color"
    /// The grid until the surface reports one.
    static let defaultSize = (columns: 80, rows: 24)

    private(set) var phase: Phase = .idle
    private(set) var target: SessionTarget
    private(set) var hostKeyPrompt: HostKeyPrompt?
    /// The Passphrase Sheet is up (`providePassphrase` / `cancelPassphrase`).
    private(set) var needsPassphrase = false
    /// The last passphrase tried (given in the sheet, or the remembered one) did not open the key:
    /// "Wrong passphrase" in the sheet.
    private(set) var passphraseRejected = false
    /// The current attempt was started by the session itself.
    private(set) var isAutomaticAttempt = false
    /// Connected, but this Mac lost its path less than `pathLossGrace` ago.
    private(set) var isPathLost = false
    private(set) var forwardStates: [PortForward.ID: ForwardState] = [:]

    /// The record of the current attempt.
    @ObservationIgnored private(set) var record: SessionRecord?
    /// The engine view of this tab, kept by the model so its scrollback outlives a SwiftUI update.
    @ObservationIgnored private(set) var surface: (any TerminalSurface)?
    /// A Session Window shows this session; a second window for the same machine closes itself.
    @ObservationIgnored var hasWindow = false
    /// Brings that window's tab forward (set by the window).
    @ObservationIgnored var bringWindowForward: (() -> Void)?
    /// Rank of the Connect that opened this session (`SessionManager`): the place of its tab.
    @ObservationIgnored var openOrder = 0
    /// This Mac has a network path (`SessionManager`).
    @ObservationIgnored var isNetworkAvailable: @MainActor () -> Bool = { true }
    /// The separator line drawn after a reconnect, in the app's language (set by the view; English
    /// until then).
    @ObservationIgnored var separatorText: @MainActor () -> String = {
        Strings.table["en"]?["terminal_reconnected_separator"] ?? "Reconnected"
    }

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let resolver: SSHCredentialResolver
    @ObservationIgnored private let trust: any TrustedHostKeys
    @ObservationIgnored private let secrets: any SSHSecretStore
    @ObservationIgnored private let clock: SessionClock
    @ObservationIgnored private let resilience: SessionResilience
    @ObservationIgnored private let reconnectClock: any ReachabilityClock
    @ObservationIgnored private let makeConnection: @MainActor (SessionTarget) -> any SSHSessionConnection
    @ObservationIgnored private let urlOpener: any URLOpening

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startUptime: TimeInterval = 0
    /// Uptime when the current attempt's shell opened (`rearmAfter`).
    @ObservationIgnored private var shellUptime: TimeInterval?
    @ObservationIgnored private var connection: (any SSHSessionConnection)?
    /// The attempt: credentials, `open`, then the shell's output until it ends.
    @ObservationIgnored private var task: Task<Void, Never>?
    /// `open`, the only task that holds the credentials; dropped as soon as it ends.
    @ObservationIgnored private var opening: Task<Void, any Error>?
    @ObservationIgnored private var coalescer: TerminalOutputCoalescer?
    /// Input and resizes to the shell, written one after the other by one task.
    @ObservationIgnored private var input: AsyncStream<ShellInput>.Continuation?
    @ObservationIgnored private var writer: Task<Void, Never>?
    /// The running forwards of the current attempt, and the starts still in flight.
    @ObservationIgnored private var forwardHandles: [PortForward.ID: any LocalForwarding] = [:]
    @ObservationIgnored private var forwardTasks: [PortForward.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var size = TerminalSessionModel.defaultSize
    /// Output that arrived before a surface was attached (the attempt starts before the window's
    /// `onAppear`): fed first by `attach`. Bounded to the last `pendingOutputLimit` bytes, which is far
    /// more than a login banner and prompt; cleared by a new attempt.
    @ObservationIgnored private var pendingOutput = Data()
    static let pendingOutputLimit = 1 << 20
    var pendingOutputCount: Int { pendingOutput.count }
    /// A shell was shown in this tab: the next one gets a separator.
    @ObservationIgnored private var hadShell = false

    // Host key and passphrase prompts.
    @ObservationIgnored private var hostKeyWaiter: (id: Int, continuation: CheckedContinuation<Bool, Never>)?
    @ObservationIgnored private var nextPromptID = 0
    /// Why the validator of attempt `generation` refused the key (the error of `open` does not say).
    @ObservationIgnored private var hostKeyRejection: (generation: Int, reason: HostKeyRejection)?
    @ObservationIgnored private var passphraseWaiter: CheckedContinuation<PassphraseAnswer?, Never>?

    // Resilience.
    @ObservationIgnored private var pendingReconnect: Task<Void, Never>?
    @ObservationIgnored private(set) var suspension: Task<Void, Never>?
    @ObservationIgnored private var reconnectToken = 0
    @ObservationIgnored private var pathLossTimer: Task<Void, Never>?

    private enum ShellInput: Sendable {
        case data(Data)
        case resize(columns: Int, rows: Int)
    }

    private enum HostKeyRejection {
        case declined
        case changed(previous: String, new: String)
        /// Unknown key on an automatic attempt: nobody is asked.
        case unknownWithoutPrompt
    }

    private struct PassphraseAnswer {
        let passphrase: String
        let remember: Bool
    }

    init(machine: Machine, context: ModelContext, resolver: SSHCredentialResolver, trust: any TrustedHostKeys,
         secrets: any SSHSecretStore, clock: SessionClock = .live, resilience: SessionResilience = SessionResilience(),
         reconnectClock: any ReachabilityClock = ContinuousReachabilityClock(),
         urlOpener: any URLOpening = WorkspaceURLOpener(),
         makeConnection: @escaping @MainActor (SessionTarget) -> any SSHSessionConnection) {
        target = SessionTarget(machine)
        self.context = context
        self.resolver = resolver
        self.trust = trust
        self.secrets = secrets
        self.clock = clock
        self.resilience = resilience
        self.reconnectClock = reconnectClock
        self.makeConnection = makeConnection
        self.urlOpener = urlOpener
    }


    var isConnecting: Bool { phase == .connecting }

    var failure: TerminalFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    /// What covers the terminal; the view picks the words.
    var overlay: SessionModel.Overlay? {
        switch phase {
        case .connecting: isAutomaticAttempt ? .reconnecting : .connecting
        case .connected: isPathLost ? .waitingForNetwork : nil
        case .waiting(.network): .waitingForNetwork
        case .waiting: .reconnecting
        case .idle, .failed, .ended, .closed: nil
        }
    }

    // MARK: Surface

    /// The tab's engine view: input goes to the shell, size changes to the server.
    func attach(_ surface: any TerminalSurface) {
        self.surface = surface
        surface.onInput = { [weak self] data in self?.send(data) }
        surface.onResize = { [weak self] columns, rows in self?.resize(columns: columns, rows: rows) }
        if !pendingOutput.isEmpty {
            surface.feed(pendingOutput)
            pendingOutput = Data()
        }
    }

    /// Shell output on the main actor: to the surface, or kept until one is attached.
    private func deliver(_ data: Data) {
        if let surface {
            surface.feed(data)
            return
        }
        pendingOutput.append(data)
        if pendingOutput.count > Self.pendingOutputLimit {
            pendingOutput = Data(pendingOutput.suffix(Self.pendingOutputLimit))
        }
    }

    /// Typed keys, pastes, mouse reports: written in order while the shell is up, dropped otherwise.
    private func send(_ data: Data) {
        guard phase == .connected, !data.isEmpty else { return }
        input?.yield(.data(data))
    }

    private func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, columns != size.columns || rows != size.rows else { return }
        size = (columns, rows)
        if phase == .connected { input?.yield(.resize(columns: columns, rows: rows)) }
    }

    // MARK: Connect

    /// Starts an attempt (tab opened, Retry, Reconnect, credentials saved). The connect time runs
    /// from here: "click to shell open".
    func connect() {
        guard phase != .connecting, phase != .connected, phase != .closed else { return }
        startAttempt(automatic: false)
    }

    private func startAttempt(automatic: Bool) {
        cancelPendingReconnect()
        cancelPathLoss()
        dismissPrompts()
        isAutomaticAttempt = automatic
        shellUptime = nil
        pendingOutput = Data()
        generation += 1
        let generation = self.generation
        if let machine = fetchMachine() { target = SessionTarget(machine) }   // edited credentials
        forwardStates = Dictionary(target.portForwards.map { ($0.id, .starting) }, uniquingKeysWith: { first, _ in first })
        startUptime = clock.uptime()
        phase = .connecting
        let record = SessionRecord(machineID: target.machineID, machineName: target.name,
                                   startedAt: clock.now(), outcome: .cancelled)
        context.insert(record)
        self.record = record
        save()
        task = Task { [weak self] in await self?.run(generation: generation) }
    }

    private func run(generation: Int) async {
        guard let (connection, shell, openedSize) = await establish(generation: generation),
              generation == self.generation else { return }
        shellOpened(shell, size: openedSize)
        startForwards(on: connection, generation: generation)
        guard let coalescer else { return }
        let deliver: @MainActor @Sendable (Data) -> Void = { [weak self] data in
            guard let self, self.generation == generation else { return }
            self.deliver(data)
        }
        do {
            try await coalescer.run(shell.output, deliver: deliver)
            await shellEnded(generation: generation)
        } catch {
            // The output fails whenever the connection ends under the shell; `closed` says why.
            let reason = await Self.endReason(of: connection, within: Self.endReasonLimit)
            guard generation == self.generation else { return }
            if case .hostKeyRejected(let key)? = reason {
                await rekeyRejected(key, generation: generation)
            } else {
                await stop(failing: .connectionLost, generation: generation)
            }
        }
    }

    /// How long a lost shell waits for `closed` to give the reason (it comes right after the output
    /// fails; the bound only keeps a connection that never says from holding the attempt).
    static let endReasonLimit: Duration = .seconds(1)

    /// The connection's end (`closed`'s one value), or nil if it does not come within `limit`. The
    /// only reader of `closed`, once per connection.
    private nonisolated static func endReason(of connection: any SSHSessionConnection, within limit: Duration) async
        -> SSHError? {
        await withTaskGroup(of: SSHError??.self) { group in
            group.addTask {
                for await reason in connection.closed { return .some(reason) }
                return .some(nil)
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Credentials, `open`, then the shell; nil when the attempt stopped (its failure is shown). The
    /// credentials live only in this frame and in the `opening` task, so the long-running read of
    /// the output never holds them (SSHKit's authentication handler keeps its own copy for the
    /// connection's life).
    private func establish(generation: Int) async
        -> (connection: any SSHSessionConnection, shell: any SSHShellChannel, size: (columns: Int, rows: Int))? {
        guard let credentials = await credentials(generation: generation) else { return nil }
        guard generation == self.generation else { return nil }
        let connection = makeConnection(target)
        self.connection = connection
        let validate: @Sendable (SSHHostKey) async -> Bool = { [weak self] key in
            await self?.checkHostKey(key, generation: generation) ?? false
        }
        // Untyped closures: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
        let opening = Task {
            try await connection.open(credentials: credentials, timeout: Self.openTimeout, validateHostKey: validate)
        }
        self.opening = opening
        let shell: any SSHShellChannel
        var openedSize = size
        do {
            try await opening.value
            openingEnded(generation: generation)
            guard generation == self.generation else { return nil }
            openedSize = size
            let size = openedSize
            shell = try await Self.withinTimeout(shellTimeout) {
                try await connection.openShell(term: Self.term, columns: size.columns, rows: size.rows)
            }
        } catch {
            openingEnded(generation: generation)
            guard generation == self.generation else { return nil }   // a stale open leaves newer prompts alone
            dismissPrompts()   // `open` ended under a prompt: the connection died
            await stop(failing: openFailure(error, generation: generation), generation: generation)
            return nil
        }
        return (connection, shell, openedSize)
    }

    /// How long the shell may take to open after authentication (`openTimeout`; shorter in tests).
    /// Past it the attempt fails `.timedOut`, and its teardown closes the connection, which ends the
    /// pending `openShell`.
    @ObservationIgnored var shellTimeout: Duration = TerminalSessionModel.openTimeout

    /// `work`'s result, or `SSHError.timedOut` after `limit`, without waiting for `work` to honour
    /// cancellation (`SSHConnection.openShell` waits on NIO futures, which do not).
    private nonisolated static func withinTimeout<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            once.set(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume(.failure(SSHError.timedOut))
            }
            Task {
                do { once.resume(.success(try await work())) } catch { once.resume(.failure(error)) }
                timer.cancel()
            }
        }
    }

    private func openingEnded(generation: Int) {
        if generation == self.generation { opening = nil }
    }

    /// The credentials of this attempt, or nil when it stopped (failure, cancelled passphrase, or a
    /// newer attempt or close took over). The passphrase is asked only on a user's attempt.
    private func credentials(generation: Int) async -> SSHCredentials? {
        var given: String?
        var remember = false
        /// The remembered passphrase was tried and is wrong.
        var staleRemembered = false
        while true {
            let resolution = await resolver.resolveOffMain(machine: target, passphrase: given,
                                                           allowsInteraction: !isAutomaticAttempt)
            guard generation == self.generation else { return nil }
            switch resolution {
            case .ready(let credentials):
                passphraseRejected = false
                if let given {
                    if remember {
                        rememberPassphrase(given)
                    } else if staleRemembered {
                        forgetRememberedPassphrase()   // it no longer opens the key
                    }
                }
                return credentials
            case .needsPassphrase, .rememberedPassphraseRejected:
                // Defence in depth: the resolver never asks for an automatic attempt.
                guard !isAutomaticAttempt else {
                    await stop(failing: .credentials(.passphraseUnavailable), generation: generation)
                    return nil
                }
                if case .rememberedPassphraseRejected = resolution { staleRemembered = true }
                passphraseRejected = given != nil || staleRemembered
                guard let answer = await askPassphrase(generation: generation) else {
                    guard generation == self.generation else { return nil }
                    cancelAttempt(generation: generation)
                    return nil
                }
                guard generation == self.generation else { return nil }
                given = answer.passphrase
                remember = answer.remember
            case .needsFolderAccess:
                await stop(failing: .sshFolderAccessNeeded, generation: generation)
                return nil
            case .failed(let failure):
                await stop(failing: .credentials(failure), generation: generation)
                return nil
            }
        }
    }

    /// "Remember in Keychain": with an imported key, the synchronizable item beside it; for a key in
    /// `~/.ssh`, a local item on this Mac. Best effort: a failed save only means asking next time.
    private func rememberPassphrase(_ passphrase: String) {
        let id = target.machineID
        switch target.sshAuth {
        case .keyInSSHFolder: try? secrets.setSecret(passphrase, for: .sshLocalKeyPassphrase(id))
        case .importedKey: try? secrets.setSecret(passphrase, for: .sshKeyPassphrase(id))
        case .password: break
        }
    }

    private func forgetRememberedPassphrase() {
        let id = target.machineID
        switch target.sshAuth {
        case .keyInSSHFolder: try? secrets.deleteSecret(.sshLocalKeyPassphrase(id))
        case .importedKey: try? secrets.deleteSecret(.sshKeyPassphrase(id))
        case .password: break
        }
    }

    private func openFailure(_ error: any Error, generation: Int) -> TerminalFailure {
        let error = (error as? SSHError) ?? .connectionClosed
        if case .hostKeyRejected = error, let rejection = hostKeyRejection, rejection.generation == generation {
            switch rejection.reason {
            case .changed(let previous, let new): return .hostKeyChanged(previousFingerprint: previous, newFingerprint: new)
            case .declined, .unknownWithoutPrompt: return .connect(error)
            }
        }
        return .connect(error)
    }

    private func shellOpened(_ shell: any SSHShellChannel, size opened: (columns: Int, rows: Int)) {
        phase = .connected
        shellUptime = clock.uptime()
        record?.outcomeValue = .connected
        record?.connectMillis = Int(((clock.uptime() - startUptime) * 1000).rounded())
        fetchMachine()?.lastConnectedAt = clock.now()
        save()
        if hadShell { surface?.showSeparator(separatorText()) }
        hadShell = true
        coalescer = TerminalOutputCoalescer()
        let (stream, continuation) = AsyncStream.makeStream(of: ShellInput.self)
        input = continuation
        writer = Task {
            for await item in stream {
                switch item {
                case .data(let data):
                    // A failed write fails the output too, which reports the loss.
                    do { try await shell.write(data) } catch { return }
                case .resize(let columns, let rows):
                    await shell.resize(columns: columns, rows: rows)
                }
            }
        }
        // A size reported while the shell was opening goes out now (it was opened with the older one).
        if size != opened { input?.yield(.resize(columns: size.columns, rows: size.rows)) }
    }

    // MARK: Port forwards (Task 11)

    /// Every saved forward, each on its own: one failing never stops the shell nor the others.
    private func startForwards(on connection: any SSHSessionConnection, generation: Int) {
        for forward in target.portForwards { startForward(forward, on: connection, generation: generation) }
    }

    private func startForward(_ forward: PortForward, on connection: any SSHSessionConnection, generation: Int) {
        let id = forward.id
        guard let local = UInt16(exactly: forward.localPort), let remote = UInt16(exactly: forward.remotePort) else {
            forwardStates[id] = .failed(.remote("invalid port"))   // the validator never saves one
            return
        }
        forwardStates[id] = .starting
        let remoteHost = forward.remoteHost
        // Untyped closure: a typed-throws `Task` closure crashes the Swift 6.4 compiler (RFBKit note).
        forwardTasks[id] = Task { [weak self] in
            let result: Result<any LocalForwarding, SSHError>
            do {
                result = .success(try await connection.startLocalForward(localPort: local, remoteHost: remoteHost,
                                                                         remotePort: remote))
            } catch {
                result = .failure((error as? SSHError) ?? .remote("\(error)"))
            }
            guard let self, self.isCurrent(connection, generation: generation) else {
                // The session stopped (or another attempt took over) while the listeners came up:
                // nothing may keep listening for a connection that is gone.
                if case .success(let handle) = result { await handle.stop() }
                return
            }
            self.forwardTasks[id] = nil
            switch result {
            case .success(let handle):
                self.forwardHandles[id] = handle
                self.forwardStates[id] = .active
            case .failure(let error):
                self.forwardStates[id] = .failed(error)
            }
        }
    }

    /// Attempt `generation` still owns `connection` and its shell is up.
    private func isCurrent(_ connection: any SSHSessionConnection, generation: Int) -> Bool {
        generation == self.generation && phase == .connected && self.connection === connection
    }

    /// Forwards menu › Retry: starts that failed forward again on the running connection (a failure
    /// is never retried on its own).
    func retryForward(_ id: PortForward.ID) {
        guard phase == .connected, let connection, forwardStates[id]?.isFailed == true,
              let forward = target.portForwards.first(where: { $0.id == id }) else { return }
        startForward(forward, on: connection, generation: generation)
    }

    /// Forwards menu › Open in Browser: `http://localhost:<port>`, only while the forward listens.
    func openInBrowser(_ id: PortForward.ID) {
        guard forwardStates[id]?.isActive == true,
              let url = target.portForwards.first(where: { $0.id == id })?.browserURL else { return }
        urlOpener.open(url)
    }

    // MARK: Host key

    /// The validator of attempt `generation`, on the main actor. Trusted: go on. Changed: refuse,
    /// whoever started the attempt. Unknown: a user's attempt asks (Host Key Sheet), an automatic one
    /// refuses without asking.
    private func checkHostKey(_ key: SSHHostKey, generation: Int) async -> Bool {
        guard generation == self.generation, phase == .connecting else { return false }
        switch trust.decision(for: key, host: target.host, port: target.port) {
        case .trusted:
            return true
        case .changed(let previous):
            hostKeyRejection = (generation, .changed(previous: previous, new: key.fingerprintSHA256))
            return false
        case .unknown:
            guard !isAutomaticAttempt else {
                hostKeyRejection = (generation, .unknownWithoutPrompt)
                return false
            }
            let accepted = await askHostKey(key)
            return accepted && generation == self.generation
        }
    }

    /// Parks the validator until Trust, Cancel, or anything that ends the attempt (cancellation of
    /// the validator's task included: the connection died).
    private func askHostKey(_ key: SSHHostKey) async -> Bool {
        nextPromptID += 1
        let id = nextPromptID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                hostKeyWaiter = (id, continuation)
                hostKeyPrompt = HostKeyPrompt(host: target.host, port: target.port, key: key)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismissHostKeyPrompt(id: id) }
        }
    }

    /// Host Key Sheet › Trust: remembered for this `host:port` on this Mac at once (so a Retry after
    /// the connection died meanwhile does not ask again), then authentication goes on.
    func trustHostKey() {
        guard let prompt = hostKeyPrompt, let waiter = hostKeyWaiter else { return }
        trust.trust(prompt.key, host: prompt.host, port: prompt.port)
        hostKeyWaiter = nil
        hostKeyPrompt = nil
        waiter.continuation.resume(returning: true)
    }

    /// Host Key Sheet › Cancel: nothing remembered, nothing sent; "Host key not trusted" with Retry.
    func rejectHostKey() {
        guard let waiter = hostKeyWaiter else { return }
        hostKeyRejection = (generation, .declined)
        hostKeyWaiter = nil
        hostKeyPrompt = nil
        waiter.continuation.resume(returning: false)
    }

    private func dismissHostKeyPrompt(id: Int? = nil) {
        guard let waiter = hostKeyWaiter, id == nil || waiter.id == id else { return }
        hostKeyWaiter = nil
        hostKeyPrompt = nil
        waiter.continuation.resume(returning: false)
    }

    // MARK: Passphrase

    private func askPassphrase(generation: Int) async -> PassphraseAnswer? {
        await withCheckedContinuation { continuation in
            guard generation == self.generation else {
                continuation.resume(returning: nil)
                return
            }
            passphraseWaiter = continuation
            needsPassphrase = true
        }
    }

    /// Passphrase Sheet › Connect. A wrong one brings the sheet back (`passphraseRejected`).
    func providePassphrase(_ passphrase: String, remember: Bool) {
        guard let waiter = passphraseWaiter else { return }
        passphraseWaiter = nil
        needsPassphrase = false
        waiter.resume(returning: PassphraseAnswer(passphrase: passphrase, remember: remember))
    }

    /// Passphrase Sheet › Cancel: the attempt ends `cancelled`, nothing was sent; the view closes the
    /// tab (as the screen session's Cancel on its Internet sheet).
    func cancelPassphrase() {
        guard let waiter = passphraseWaiter else { return }
        passphraseWaiter = nil
        needsPassphrase = false
        passphraseRejected = false
        waiter.resume(returning: nil)
    }

    private func dismissPassphrase() {
        guard let waiter = passphraseWaiter else { return }
        passphraseWaiter = nil
        needsPassphrase = false
        passphraseRejected = false
        waiter.resume(returning: nil)
    }

    private func dismissPrompts() {
        dismissHostKeyPrompt()
        dismissPassphrase()
    }

    /// The passphrase was not given: the record ends `cancelled`, no banner.
    private func cancelAttempt(generation: Int) {
        guard generation == self.generation else { return }
        finishRecord(outcome: .cancelled)
        phase = .idle
        task = nil
        for id in forwardStates.keys { forwardStates[id] = .stopped }   // none started: no shell
    }

    // MARK: Stop

    func close() async {
        await completeClose(record: beginClose())
    }

    /// The synchronous part of a close (the click, or ⌘Q): later results of the attempt are ignored,
    /// prompts are dismissed, and the record gets its end now (`cancelled` if the shell never
    /// opened; after it the outcome stays `connected`). Returns the record `completeClose` fills.
    @discardableResult
    func beginClose() -> SessionRecord? {
        guard phase != .closed else { return nil }
        let wasConnecting = phase == .connecting
        let wasRunning = wasConnecting || phase == .connected
        generation += 1
        cancelPendingReconnect()
        cancelPathLoss()
        dismissPrompts()
        phase = .closed
        guard wasRunning else { return nil }
        finishRecord(outcome: wasConnecting ? .cancelled : nil)
        return record
    }

    /// Ordered teardown after `beginClose`, then the bytes received.
    func completeClose(record: SessionRecord?) async {
        let bytes = await tearDown()
        if let record {
            record.bytesReceived = bytes
            save()
        }
    }

    /// A failure of attempt `generation`; ignored once a newer attempt or a close took over, and
    /// once the attempt already stopped.
    private func stop(failing failure: TerminalFailure, generation: Int) async {
        guard generation == self.generation, phase == .connecting || phase == .connected else { return }
        cancelPathLoss()
        dismissPrompts()
        let reconnects = phase == .connected && failure == .connectionLost && mayReconnectAutomatically
        if reconnects {
            phase = .waiting(isNetworkAvailable() ? .retryDelay : .network)
        } else {
            phase = .failed(isAutomaticAttempt && !failure.survivesAutomaticAttempt ? .connectionLost : failure)
        }
        finishRecord(outcome: failure.outcome)
        let record = self.record   // a Retry during the teardown starts a new record
        let bytes = await tearDown()
        record?.bytesReceived = bytes
        save()
        if reconnects, generation == self.generation, phase == .waiting(.retryDelay) { scheduleReconnect() }
    }

    /// A re-key presented another host key (`closed` said `.hostKeyRejected`): blocked like a changed
    /// key at connect, no reconnect.
    private func rekeyRejected(_ key: SSHHostKey, generation: Int) async {
        // The key of this session was trusted, but the list may hold none of the new key's type: then
        // the previous key is not named (never "the one in known_hosts" without knowing it).
        let previous = trustedFingerprint(of: key) ?? ""
        await stop(failing: .hostKeyChanged(previousFingerprint: previous, newFingerprint: key.fingerprintSHA256),
                   generation: generation)
    }

    /// The fingerprint trusted now for this host and key type (or the known_hosts marker), if any.
    private func trustedFingerprint(of key: SSHHostKey) -> String? {
        if case .changed(let previous) = trust.decision(for: key, host: target.host, port: target.port) { return previous }
        return nil
    }

    /// The remote shell ended by itself: not a drop (no automatic attempt). The record keeps
    /// `connected`, with its end.
    private func shellEnded(generation: Int) async {
        guard generation == self.generation, phase == .connected else { return }
        cancelPathLoss()
        phase = .ended
        finishRecord(outcome: nil)
        let record = self.record
        let bytes = await tearDown()
        record?.bytesReceived = bytes
        save()
    }

    /// A user's attempt may always reconnect once; an automatic one only once it held `rearmAfter`.
    private var mayReconnectAutomatically: Bool {
        guard isAutomaticAttempt else { return true }
        guard let shellUptime else { return false }
        return clock.uptime() - shellUptime >= resilience.rearmAfter
    }

    /// Forwards → shell → connection. Returns the shell bytes received.
    private func tearDown() async -> Int64 {
        let (work, coalescer) = beginTearDown()
        await work()
        return coalescer?.byteCount ?? 0
    }

    /// The synchronous part: the session lets go of the attempt's tasks and connection now, so an
    /// attempt started meanwhile can never be torn down by this one, and every forward reads
    /// `stopped` at once. The returned work stops the forwards (each `stop()` is bounded and never
    /// waits for the peer), closes the shell (cancels the read of its output, which closes its
    /// channel) and then the connection. A forward still starting is stopped by its own task, which
    /// finds the attempt gone.
    private func beginTearDown() -> (@MainActor () async -> Void, TerminalOutputCoalescer?) {
        let task = self.task
        let opening = self.opening
        let writer = self.writer
        let connection = self.connection
        let coalescer = self.coalescer
        let forwards = Array(forwardHandles.values)
        let starting = Array(forwardTasks.values)
        forwardHandles = [:]
        forwardTasks = [:]
        for id in forwardStates.keys { forwardStates[id] = .stopped }
        input?.finish()
        input = nil
        self.task = nil
        self.opening = nil
        self.writer = nil
        self.connection = nil
        self.coalescer = nil
        let work: @MainActor () async -> Void = {
            for task in starting { task.cancel() }
            await withTaskGroup(of: Void.self) { group in
                for forward in forwards { group.addTask { await forward.stop() } }
            }
            writer?.cancel()      // a write stuck on a frozen peer must not hold the close
            task?.cancel()        // ends the read of the output: the shell's channel closes
            opening?.cancel()     // an `open` still in flight stops at once
            await connection?.close()
        }
        return (work, coalescer)
    }

    // MARK: Resilience (T5.1)

    /// As `SessionModel.networkLost`: a connected session keeps its socket for `pathLossGrace`, an
    /// automatic attempt in flight stops at once, the delay before one is held.
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
        default: break
        }
    }

    func networkRestored() {
        if isPathLost {
            cancelPathLoss()
            return
        }
        guard phase == .waiting(.network) else { return }
        phase = .waiting(.retryDelay)
        scheduleReconnect()
    }

    /// The Mac goes to sleep: the session closes cleanly now and reconnects after wake. A prompt up
    /// during a user's attempt is dismissed (the attempt after wake is automatic: it never asks).
    func suspendForSleep() {
        switch phase {
        case .connected: suspend(to: .waiting(.asleep), outcome: nil)
        case .connecting: suspend(to: .waiting(.asleep), outcome: .cancelled)
        case .waiting:
            cancelPendingReconnect()
            phase = .waiting(.asleep)
        case .idle, .failed, .ended, .closed: break
        }
    }

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

    /// Stops the running attempt for a cause outside the session (sleep, no network). The generation
    /// is bumped before the teardown, so the output ending under the close is not a drop.
    private func suspend(to next: Phase, outcome: SessionOutcome?) {
        cancelPendingReconnect()
        cancelPathLoss()
        generation += 1
        dismissPrompts()
        phase = next
        finishRecord(outcome: outcome)
        let record = self.record
        let (work, coalescer) = beginTearDown()
        let previous = suspension
        suspension = Task { [weak self] in
            await previous?.value
            await work()
            record?.bytesReceived = coalescer?.byteCount ?? 0
            self?.save()
        }
    }

    // MARK: Record

    /// Sets the end of the current record; `outcome` nil keeps the one already set.
    private func finishRecord(outcome: SessionOutcome?) {
        guard let record else { return }
        if let outcome { record.outcomeValue = outcome }
        record.endedAt = clock.now()
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

/// One continuation resumed once, by whichever of its racers answers first.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func set(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ result: Result<T, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

extension TerminalSessionModel.Phase {
    /// What the Reachability monitor makes of this session (T4.5), as `SessionModel.Phase`.
    var watchedState: WatchedSessionState {
        switch self {
        case .connected: .connected
        case .connecting, .waiting: .connecting
        case .idle, .failed, .ended, .closed: .noSession
        }
    }
}
