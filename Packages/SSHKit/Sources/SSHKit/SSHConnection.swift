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
/// channels (a pty shell here; port forwards and SFTP extend it).
///
/// The SSH library (swift-nio-ssh) stays behind this actor: its handlers run on a NIO event loop,
/// and only `SSHError`, `SSHHostKey` and SSHKit types cross the boundary.
public actor SSHConnection {
    private let host: String
    private let port: UInt16
    private let keepalive: SSHKeepalive

    private var channel: (any Channel)?
    private var sshHandler: NIOLoopBound<NIOSSHHandler>?
    private var opened = false
    private var ended = false
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
    /// `SSHError` otherwise (`.connectionClosed` when the server or the network ended it, or the
    /// error `open` threw).
    public var closed: AsyncStream<SSHError?> { closedStream }

    /// Connects and authenticates.
    ///
    /// - `timeout` bounds each network wait: the TCP connection and key exchange up to the host
    ///   key, then authentication after it. The time `validateHostKey` takes (a prompt) is not
    ///   counted.
    /// - `validateHostKey` runs during key exchange, before anything is sent to authenticate;
    ///   returning false fails with `.hostKeyRejected(key)`. An RSA host key is `ssh-rsa`, as in
    ///   `known_hosts`, whichever RSA signature algorithm was negotiated.
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
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: UserAuthenticator(credentials: credentials),
                        serverAuthDelegate: HostKeyValidator(handshake: handshake, validate: validateHostKey)
                    )
                    let ssh = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    let session = SessionHandler(ssh: ssh, handshake: handshake, keepalive: keepalive)
                    try channel.pipeline.syncOperations.addHandlers(ssh, session)
                    handshake.arm(channel: channel)
                    // NIOSSHHandler does not pass channelInactive on, so the end is seen here.
                    channel.closeFuture.whenComplete { _ in
                        if handshake.isDone, handshake.recorded == nil {
                            onEnd(.connectionClosed)
                        } else {
                            handshake.fail(.connectionClosed)
                        }
                    }
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: Int(port)).get()
        } catch {
            // Our deadline closing the channel shows as a failed connect: report the deadline.
            let failure = await handshake.recordedFailure() == .timedOut ? .timedOut : Self.connectError(error)
            handshake.authenticated.fail(failure)  // never left pending, when no handler was added
            finish(failure)
            throw failure
        }
        guard !ended else {
            // close() ran while connecting.
            channel.close(promise: nil)
            throw .connectionClosed
        }
        self.channel = channel

        let ssh: NIOLoopBound<NIOSSHHandler>
        do {
            try await handshake.authenticated.futureResult.get()
            ssh = try await channel.pipeline.handler(type: NIOSSHHandler.self).map {
                NIOLoopBound($0, eventLoop: loop)
            }.get()
        } catch {
            channel.close(promise: nil)
            let failure = (error as? SSHError) ?? .connectionClosed
            finish(failure)
            throw failure
        }
        guard !ended else {
            // close() ran while authenticating.
            channel.close(promise: nil)
            throw .connectionClosed
        }
        sshHandler = ssh
    }

    /// Opens a shell on a pseudo-terminal of `columns` x `rows`, with `TERM` set to `term`.
    public func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> SSHShell {
        guard !ended, let channel, let sshHandler else { throw .connectionClosed }
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
                        ShellChannelHandler(request: request, ready: ready, output: continuation)
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

    /// Closes the connection; `closed` yields nil. Calling it again does nothing.
    public func close() async {
        guard !ended else { return }
        let channel = self.channel
        finish(nil)
        try? await channel?.close()
    }

    /// Records how the connection ended, once.
    private func finish(_ value: SSHError?) {
        guard !ended else { return }
        ended = true
        channel = nil
        sshHandler = nil
        closedContinuation.yield(value)
        closedContinuation.finish()
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

/// The state of one connection attempt until authentication, shared by its handlers on the event
/// loop: the deadline and the outcome. Mutated on `loop` only.
final class Handshake: Sendable {
    let loop: any EventLoop
    let timeout: TimeAmount
    /// Succeeds on user authentication success; fails with the `SSHError` that ended the attempt.
    let authenticated: EventLoopPromise<Void>
    private let state: NIOLoopBoundBox<State>

    private struct State {
        var channel: (any Channel)?
        var timer: Scheduled<Void>?
        var failure: SSHError?
        var done = false
    }

    init(loop: any EventLoop, timeout: TimeAmount) {
        self.loop = loop
        self.timeout = timeout
        authenticated = loop.makePromise(of: Void.self)
        state = .makeBoxSendingValue(State(), as: State.self, eventLoop: loop)
    }

    /// The failure recorded so far, read on the loop.
    func recordedFailure() async -> SSHError? {
        try? await loop.submit { self.state.value.failure }.get()
    }

    /// Whether authentication succeeded or the attempt failed. On the loop only.
    var isDone: Bool { state.value.done }

    /// The failure recorded, if the attempt failed. On the loop only.
    var recorded: SSHError? { state.value.failure }

    /// Starts the deadline for the network wait up to the host key.
    func arm(channel: any Channel) {
        state.value.channel = channel
        startTimer()
    }

    /// The host key is being validated: that wait is the user's, not the network's.
    func pauseDeadline() {
        state.value.timer?.cancel()
        state.value.timer = nil
    }

    /// The validator answered: a fresh deadline for authentication.
    func resumeDeadline() {
        guard !state.value.done else { return }
        startTimer()
    }

    func succeed() {
        guard !state.value.done else { return }
        state.value.done = true
        pauseDeadline()
        authenticated.succeed(())
    }

    func fail(_ error: SSHError) {
        guard !state.value.done else { return }
        state.value.done = true
        state.value.failure = error
        pauseDeadline()
        authenticated.fail(error)
        state.value.channel?.close(promise: nil)
    }

    private func startTimer() {
        state.value.timer?.cancel()
        state.value.timer = loop.assumeIsolated().scheduleTask(in: timeout) { [self] in
            fail(.timedOut)
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
    let validate: @Sendable (SSHHostKey) async -> Bool

    init(handshake: Handshake, validate: @escaping @Sendable (SSHHostKey) async -> Bool) {
        self.handshake = handshake
        self.validate = validate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let key = try? SSHHostKey(openSSHPublicKey: String(openSSHPublicKey: hostKey)) else {
            validationCompletePromise.fail(SSHError.remote("unreadable host key"))
            return
        }
        // A re-key after authentication is validated too, without touching the handshake deadline.
        let duringHandshake = !handshake.isDone
        if duringHandshake { handshake.pauseDeadline() }
        let handshake = self.handshake
        let validate = self.validate
        Task {
            let accepted = await validate(key)
            handshake.loop.execute {
                if duringHandshake { handshake.resumeDeadline() }
                if accepted {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(HostKeyRejected(key: key))
                }
            }
        }
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

    init(ssh: NIOSSHHandler, handshake: Handshake, keepalive: SSHKeepalive) {
        self.ssh = ssh
        self.handshake = handshake
        self.keepalive = keepalive
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !authenticated {
            authenticated = true
            handshake.succeed()
            scheduleKeepalive(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !authenticated {
            handshake.fail(Self.handshakeError(error))
        }
        context.close(promise: nil)
    }

    private func scheduleKeepalive(context: ChannelHandlerContext) {
        guard keepalive.interval > .zero, keepalive.maxMissed > 0 else { return }
        context.eventLoop.assumeIsolated().scheduleTask(in: TimeAmount(keepalive.interval)) { [self] in
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
