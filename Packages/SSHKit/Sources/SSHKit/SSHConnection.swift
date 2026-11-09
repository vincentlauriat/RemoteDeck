import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Synchronization

/// How a username authenticates.
public enum SSHCredentials: Sendable {
    case password(user: String, password: String)
    case key(user: String, key: SSHPrivateKey)
}

/// Keepalive settings: OpenSSH's `ServerAliveInterval` and `ServerAliveCountMax`.
public struct SSHKeepalive: Sendable {
    /// How often a `keepalive@openssh.com` request is sent once authenticated.
    public var interval: Duration = .seconds(30)
    /// The connection closes when this many requests in a row go unanswered.
    public var maxMissed = 4

    public init(interval: Duration = .seconds(30), maxMissed: Int = 4) {
        self.interval = interval
        self.maxMissed = maxMissed
    }
}

/// One SSH connection to one server: TCP, key exchange, host key check, user authentication, then
/// channels: a pty shell, local port forwards (`LocalForward.swift`) and SFTP (`SSHFileTransfer.swift`).
///
/// The SSH library (swift-nio-ssh) stays behind this actor: its handlers run on a NIO event loop,
/// and only `SSHError`, `SSHHostKey` and SSHKit types cross the boundary.
public actor SSHConnection {
    private let host: String
    private let port: UInt16
    private let keepalive: SSHKeepalive

    private var channel: (any Channel)?
    private var sshHandler: NIOLoopBound<NIOSSHHandler>?
    /// The handshake of `open`, kept so `close()` can abort it in any phase.
    private var handshake: Handshake?
    private var opened = false
    private var ended = false
    /// The local forwards started on this connection; all are stopped when it ends.
    private var forwards: [LocalForwardHandle] = []
    private let closedStream: AsyncStream<SSHError?>
    private let closedContinuation: AsyncStream<SSHError?>.Continuation

    public init(host: String, port: UInt16, keepalive: SSHKeepalive = .init()) {
        self.host = host
        self.port = port
        self.keepalive = keepalive
        (closedStream, closedContinuation) = AsyncStream.makeStream(of: SSHError?.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        channel?.close(promise: nil)
        closedContinuation.finish()
    }

    /// Yields one value when the connection ends, then finishes: nil after `close()`, the
    /// `SSHError` otherwise:
    /// - `.connectionClosed` when the server or the network ended it, or keepalives went unanswered;
    /// - `.hostKeyRejected(newKey)` when a re-key presented another host key;
    /// - the error `open` threw, when it failed: that error is both thrown and yielded here.
    ///
    /// Single consumer: it is one `AsyncStream`, so read it from one place only.
    public nonisolated var closed: AsyncStream<SSHError?> { closedStream }

    /// Connects and authenticates.
    ///
    /// - `timeout` applies per phase, not to the whole call: the TCP connection, then key exchange
    ///   up to the host key, then authentication after the validator answered. The time
    ///   `validateHostKey` takes (a prompt) is never counted.
    /// - `validateHostKey` runs once, during key exchange, before anything is sent to authenticate;
    ///   returning false fails with `.hostKeyRejected(key)`. An RSA host key is `ssh-rsa`, as in
    ///   `known_hosts`, whichever RSA signature algorithm was negotiated. Its task is cancelled when
    ///   the connection dies, on `close()` and when `open`'s task is cancelled: it should honour
    ///   cancellation (dismiss a prompt), and its answer is then ignored. A later re-key is not
    ///   validated again: the server must present the same key, or the connection ends with
    ///   `.hostKeyRejected(newKey)` on `closed`.
    /// - Cancelling the calling task, or calling `close()`, closes the connection at once in any
    ///   phase; `open` then throws `.connectionClosed`.
    public func open(
        credentials: SSHCredentials, timeout: Duration,
        validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool
    ) async throws(SSHError) {
        guard !opened, !ended else { throw .connectionClosed }
        opened = true
        RSASHA2.register()

        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let handshake = Handshake(loop: loop, timeout: TimeAmount(timeout))
        let keepalive = self.keepalive
        let onEnd: @Sendable (SSHError) -> Void = { [weak self] error in
            Task { await self?.finish(error) }
        }

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(TimeAmount(timeout))
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Called once per connection attempt: a name with several addresses gets one
                    // channel per address (Happy Eyeballs). `Handshake` keeps only the winner's events.
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: UserAuthenticator(credentials: credentials),
                        serverAuthDelegate: HostKeyValidator(handshake: handshake, channel: channel, validate: validateHostKey)
                    )
                    let ssh = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    let session = SessionHandler(ssh: ssh, handshake: handshake, keepalive: keepalive)
                    try channel.pipeline.syncOperations.addHandlers(ssh, session)
                    handshake.register(channel)
                    // NIOSSHHandler does not pass channelInactive on, so the end is seen here.
                    channel.closeFuture.whenComplete { _ in
                        handshake.attemptClosed(channel)
                        if handshake.isAuthenticated(channel) {
                            onEnd(handshake.endReason ?? .connectionClosed)
                        } else {
                            handshake.fail(.connectionClosed, on: channel)
                        }
                    }
                }
            }

        self.handshake = handshake
        let host = self.host
        let port = Int(self.port)
        let result: Result<Void, SSHError> = await withTaskCancellationHandler {
            await establish(bootstrap: bootstrap, host: host, port: port, handshake: handshake)
        } onCancel: {
            handshake.abort(local: false)
        }
        if case .failure(let failure) = result {
            handshake.abort(local: false)  // the promise is failed and every attempt closed
            finish(failure)                // no-op after close(): `closed` already yielded nil
            throw failure
        }
    }

    /// The connection and handshake of `open`. Every failure path leaves `handshake` failed.
    private func establish(bootstrap: ClientBootstrap, host: String, port: Int, handshake: Handshake) async -> Result<Void, SSHError> {
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            return .failure(ended || Task.isCancelled ? .connectionClosed : Self.connectError(error))
        }
        guard !ended, !Task.isCancelled else {
            // close() or cancellation while connecting.
            channel.close(promise: nil)
            return .failure(.connectionClosed)
        }
        self.channel = channel
        // The winning attempt: from now on the handshake follows it, under the deadline.
        try? await handshake.loop.submit { handshake.arm(channel) }.get()

        let ssh: NIOLoopBound<NIOSSHHandler>
        do {
            try await handshake.authenticated.futureResult.get()
            ssh = try await channel.pipeline.handler(type: NIOSSHHandler.self).map {
                NIOLoopBound($0, eventLoop: handshake.loop)
            }.get()
        } catch {
            return .failure(ended ? .connectionClosed : (error as? SSHError) ?? .connectionClosed)
        }
        guard !ended, !Task.isCancelled else {
            return .failure(.connectionClosed)
        }
        sshHandler = ssh
        return .success(())
    }

    /// Opens a shell on a pseudo-terminal of `columns` x `rows`, with `TERM` set to `term`.
    public func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> SSHShell {
        guard !ended, let channel, let sshHandler, let handshake else { throw .connectionClosed }
        let (output, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let created = channel.eventLoop.makePromise(of: (any Channel).self)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term, terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:])
        )
        channel.eventLoop.execute {
            sshHandler.value.createChannel(created, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        ShellChannelHandler(request: request, ready: ready, output: continuation, handshake: handshake)
                    )
                }
            }
        }

        let child: any Channel
        do {
            child = try await created.futureResult.get()
            try await ready.futureResult.get()
        } catch {
            ready.fail(SSHError.connectionClosed)
            continuation.finish()
            throw (error as? SSHError) ?? .channelFailed("session channel refused")
        }
        continuation.onTermination = { _ in child.close(promise: nil) }
        return SSHShell(output: output, channel: child)
    }

    /// Closes the connection and stops its local forwards (their ports are free when this
    /// returns); `closed` yields nil. Calling it again does nothing.
    public func close() async {
        guard !ended else { return }
        let channel = self.channel
        let forwards = self.forwards
        finish(nil)
        handshake?.abort(local: true)
        try? await channel?.close()
        for forward in forwards {
            await forward.stop()
        }
    }

    /// Records how the connection ended, once, and stops the local forwards.
    private func finish(_ value: SSHError?) {
        guard !ended else { return }
        ended = true
        channel = nil
        sshHandler = nil
        for forward in forwards {
            forward.shutdown()
        }
        forwards = []
        closedContinuation.yield(value)
        closedContinuation.finish()
    }

    // MARK: For LocalForward.swift and SSHFileTransfer.swift

    /// The authenticated connection's event loop and SSH handler, nil once it ended or before `open`.
    func forwardingContext() -> (loop: any EventLoop, ssh: NIOLoopBound<NIOSSHHandler>)? {
        guard !ended, let channel, let sshHandler else { return nil }
        return (channel.eventLoop, sshHandler)
    }

    /// Keeps `forward` to stop it with the connection; false (and nothing kept) once it ended.
    func adopt(_ forward: LocalForwardHandle) -> Bool {
        guard !ended else { return false }
        forwards.removeAll { $0.isStopped }
        forwards.append(forward)
        return true
    }

    /// A failure to open the TCP connection.
    private static func connectError(_ error: any Error) -> SSHError {
        if case ChannelError.connectTimeout = error { return .timedOut }
        return .unreachable
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}

// MARK: - Handshake

/// The state of one `open` until authentication, shared by its handlers on the event loop: the
/// deadline and the outcome. Events are kept per connection attempt until the bootstrap reports the
/// winning one (`arm`); the other attempts' events are then dropped. Mutated on `loop` only.
final class Handshake: Sendable {
    let loop: any EventLoop
    let timeout: TimeAmount
    /// Succeeds on user authentication success; fails with the `SSHError` that ended the attempt.
    let authenticated: EventLoopPromise<Void>
    private let state: NIOLoopBoundBox<State>

    private struct Attempt {
        var validating = false
        var outcome: Result<Void, SSHError>?
    }

    private struct State {
        var attempts: [ObjectIdentifier: Attempt] = [:]
        var winner: (any Channel)?
        var timer: Scheduled<Void>?
        var done = false
        var succeeded = false
        /// Every connection attempt still open, so an abort can close them all.
        var channels: [ObjectIdentifier: any Channel] = [:]
        /// The caller's validator, running for these attempts.
        var validations: [ObjectIdentifier: Task<Void, Never>] = [:]
        var aborted = false
        var closedLocally = false
        /// Why the authenticated connection ended, when it is not just `.connectionClosed`.
        var endReason: SSHError?
    }

    init(loop: any EventLoop, timeout: TimeAmount) {
        self.loop = loop
        self.timeout = timeout
        authenticated = loop.makePromise(of: Void.self)
        state = .makeBoxSendingValue(State(), as: State.self, eventLoop: loop)
    }

    /// `channel` is the connection the bootstrap kept: apply what it already reported, else start
    /// the deadline (unless its host key is being validated).
    func arm(_ channel: any Channel) {
        guard !state.value.aborted else { return }
        let attempt = state.value.attempts[ObjectIdentifier(channel)] ?? Attempt()
        state.value.winner = channel
        state.value.attempts = [:]
        if let outcome = attempt.outcome {
            complete(outcome)
        } else if !attempt.validating {
            startTimer()
        }
    }

    /// A new connection attempt (one per resolved address).
    func register(_ channel: any Channel) {
        guard !state.value.aborted else {
            channel.close(promise: nil)
            return
        }
        state.value.channels[ObjectIdentifier(channel)] = channel
    }

    /// The attempt's channel closed: its validator is no longer wanted.
    func attemptClosed(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        state.value.channels[id] = nil
        state.value.validations.removeValue(forKey: id)?.cancel()
    }

    /// Keeps the handle of the validator running for `channel`, to cancel it if the attempt ends.
    func track(_ validation: Task<Void, Never>, on channel: any Channel) {
        guard !state.value.aborted, state.value.channels[ObjectIdentifier(channel)] != nil else {
            validation.cancel()
            return
        }
        state.value.validations[ObjectIdentifier(channel)] = validation
    }

    /// Whether another attempt already won: this one must not reach the caller's validator.
    func isLoser(_ channel: any Channel) -> Bool {
        state.value.winner.map { $0 !== channel } ?? false
    }

    /// Ends the attempt from any thread (`close()`, task cancellation): the handshake fails with
    /// `.connectionClosed` unless it is already over, validators are cancelled and every attempt's
    /// channel is closed. `local` marks a `close()`, after which open shells end normally.
    func abort(local: Bool) {
        loop.execute { [self] in
            state.value.aborted = true
            if local { state.value.closedLocally = true }
            complete(.failure(.connectionClosed))
            for validation in state.value.validations.values { validation.cancel() }
            state.value.validations = [:]
            for channel in state.value.channels.values { channel.close(promise: nil) }
            state.value.winner?.close(promise: nil)
        }
    }

    /// Whether `close()` ended the connection. On the loop only.
    var closedLocally: Bool { state.value.closedLocally }

    /// Why the authenticated connection ended. On the loop only.
    var endReason: SSHError? {
        get { state.value.endReason }
        set { state.value.endReason = newValue }
    }

    /// Whether `channel` is the winner and authenticated.
    func isAuthenticated(_ channel: any Channel) -> Bool {
        state.value.succeeded && isWinner(channel)
    }

    /// The host key of `channel` is being validated: that wait is the user's, not the network's.
    func validationStarted(on channel: any Channel) {
        guard !state.value.done else { return }
        if isWinner(channel) {
            cancelTimer()
        } else if state.value.winner == nil {
            state.value.attempts[ObjectIdentifier(channel), default: Attempt()].validating = true
        }
    }

    /// The validator answered: a fresh deadline for authentication.
    func validationEnded(on channel: any Channel) {
        guard !state.value.done else {
            state.value.validations[ObjectIdentifier(channel)] = nil
            return
        }
        state.value.validations[ObjectIdentifier(channel)] = nil
        if isWinner(channel) {
            startTimer()
        } else if state.value.winner == nil {
            state.value.attempts[ObjectIdentifier(channel), default: Attempt()].validating = false
        }
    }

    /// Whether authentication of `channel` is over (succeeded or failed): a later host key check
    /// is a re-key.
    func isSettled(_ channel: any Channel) -> Bool {
        state.value.done && isWinner(channel)
    }

    func succeed(on channel: any Channel) {
        report(.success(()), on: channel)
    }

    func fail(_ error: SSHError, on channel: any Channel) {
        report(.failure(error), on: channel)
    }

    private func report(_ outcome: Result<Void, SSHError>, on channel: any Channel) {
        guard !state.value.done else { return }
        if isWinner(channel) {
            complete(outcome)
        } else if state.value.winner == nil {
            let id = ObjectIdentifier(channel)
            if state.value.attempts[id]?.outcome == nil {
                state.value.attempts[id, default: Attempt()].outcome = outcome
            }
        }
    }

    private func complete(_ outcome: Result<Void, SSHError>) {
        guard !state.value.done else { return }
        state.value.done = true
        cancelTimer()
        switch outcome {
        case .success:
            state.value.succeeded = true
            authenticated.succeed(())
        case .failure(let error):
            authenticated.fail(error)
            state.value.winner?.close(promise: nil)
        }
    }

    private func isWinner(_ channel: any Channel) -> Bool {
        state.value.winner.map { $0 === channel } ?? false
    }

    private func cancelTimer() {
        state.value.timer?.cancel()
        state.value.timer = nil
    }

    private func startTimer() {
        cancelTimer()
        state.value.timer = loop.assumeIsolated().scheduleTask(in: timeout) { [self] in
            complete(.failure(.timedOut))
        }
    }
}

struct HostKeyRejected: Error {
    let key: SSHHostKey
}

struct AuthenticationExhausted: Error {}

/// Hands the server's host key to the caller's validator during key exchange. swift-nio-ssh sends
/// nothing more (no NEWKEYS, so no user authentication) until the promise is completed.
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let handshake: Handshake
    let channel: any Channel
    let validate: @Sendable (SSHHostKey) async -> Bool
    /// The key the caller accepted during the handshake: a re-key must present the same one.
    private let accepted = Mutex<SSHHostKey?>(nil)

    init(handshake: Handshake, channel: any Channel, validate: @escaping @Sendable (SSHHostKey) async -> Bool) {
        self.handshake = handshake
        self.channel = channel
        self.validate = validate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let key = try? SSHHostKey(openSSHPublicKey: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(SSHError.remote("unreadable host key"))
            return
        }
        if handshake.isLoser(channel) {
            // Another connection attempt won: this one never reaches the caller's validator.
            validationCompletePromise.fail(SSHError.connectionClosed)
            return
        }
        if handshake.isSettled(channel) {
            // A re-key: the server must keep the key accepted at connection, and the caller is not
            // asked again. Another key ends the connection with `.hostKeyRejected(newKey)`.
            if accepted.withLock({ $0 }) == key {
                validationCompletePromise.succeed(())
            } else {
                handshake.endReason = .hostKeyRejected(key)
                validationCompletePromise.fail(HostKeyRejected(key: key))
            }
            return
        }

        handshake.validationStarted(on: channel)
        let handshake = self.handshake
        let channel = self.channel
        let validate = self.validate
        let validation = Task { [self] in
            let ok = await validate(key)
            let cancelled = Task.isCancelled
            handshake.loop.execute {
                handshake.validationEnded(on: channel)
                if cancelled {
                    validationCompletePromise.fail(SSHError.connectionClosed)
                } else if ok {
                    self.accepted.withLock { $0 = key }
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(HostKeyRejected(key: key))
                }
            }
        }
        handshake.track(validation, on: channel)
    }
}

/// Offers the password once, or the private key once per signature algorithm (an RSA key as
/// `rsa-sha2-512`, then `rsa-sha2-256`; never SHA-1), then gives up.
private final class UserAuthenticator: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let user: String
    /// The offers not made yet. swift-nio-ssh calls the delegate on the event loop only; the lock
    /// keeps the delegate `Sendable`, as `SSHClientConfiguration` requires.
    private let remaining: Mutex<[NIOSSHUserAuthenticationOffer.Offer]>

    init(credentials: SSHCredentials) {
        switch credentials {
        case .password(let user, let password):
            self.user = user
            remaining = Mutex([.password(.init(password: password))])
        case .key(let user, let key):
            self.user = user
            remaining = Mutex(key.nioSSHPrivateKeys.map { .privateKey(.init(privateKey: $0)) })
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while let offer = remaining.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            let allowed = switch offer {
            case .password: availableMethods.contains(.password)
            case .privateKey: availableMethods.contains(.publicKey)
            default: false
            }
            if allowed {
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: offer))
                return
            }
        }
        nextChallengePromise.fail(AuthenticationExhausted())
    }
}

// MARK: - Connection handler

/// After the SSH handler on the TCP channel: turns the handshake's events into `Handshake`'s
/// outcome, then sends keepalives.
private final class SessionHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let ssh: NIOSSHHandler
    private let handshake: Handshake
    private let keepalive: SSHKeepalive
    private var authenticated = false
    private var missed = 0
    private var keepaliveTimer: Scheduled<Void>?

    init(ssh: NIOSSHHandler, handshake: Handshake, keepalive: SSHKeepalive) {
        self.ssh = ssh
        self.handshake = handshake
        self.keepalive = keepalive
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !authenticated {
            authenticated = true
            handshake.succeed(on: context.channel)
            scheduleKeepalive(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !authenticated {
            handshake.fail(Self.handshakeError(error), on: context.channel)
        }
        context.close(promise: nil)
    }

    private func scheduleKeepalive(context: ChannelHandlerContext) {
        guard keepalive.interval > .zero, keepalive.maxMissed > 0 else { return }
        keepaliveTimer = context.eventLoop.assumeIsolated().scheduleTask(in: TimeAmount(keepalive.interval)) { [self] in
            sendKeepalive(context: context)
        }
    }

    /// OpenSSH's `server_alive_check`: give up once `maxMissed` requests in a row are unanswered,
    /// else send one more. Any reply, `REQUEST_FAILURE` included, resets the count.
    private func sendKeepalive(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        guard missed < keepalive.maxMissed else {
            context.close(promise: nil)
            return
        }
        missed += 1
        let reply = context.eventLoop.makePromise(of: Void.self)
        reply.futureResult.assumeIsolated().whenSuccess { [self] in missed = 0 }
        ssh.sendKeepalive(promise: reply)
        scheduleKeepalive(context: context)
    }

    private static func handshakeError(_ error: any Error) -> SSHError {
        switch error {
        case let error as SSHError: error
        case let error as HostKeyRejected: .hostKeyRejected(error.key)
        case is AuthenticationExhausted: .authFailed
        case ChannelError.eof, ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed: .connectionClosed
        default: .remote(String(describing: error))
        }
    }
}
