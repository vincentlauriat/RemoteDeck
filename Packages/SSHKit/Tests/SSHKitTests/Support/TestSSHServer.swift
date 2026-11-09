import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOPosix
@preconcurrency @testable import NIOSSH
import Synchronization
@testable import SSHKit

/// An in-process SSH server on 127.0.0.1 and a random port, on swift-nio-ssh's server side, for the
/// loopback tests. It authenticates one user by password or authorized public key, opens an echo
/// shell on a pty (`window-change` is echoed back as `"\u{1b}[size cols rows]"`, a line `exit` ends
/// the shell with status 0), forwards `direct-tcpip` channels to allow-listed targets on 127.0.0.1
/// and records what the client asked for. Never reachable from outside the machine, and never
/// reads `~/.ssh`.
final class TestSSHServer: Sendable {
    enum HostKeyKind: Sendable {
        case ed25519, rsa, ecdsa
    }

    struct Configuration: Sendable {
        var hostKey: HostKeyKind = .ed25519
        var user = "tester"
        var password: String? = "s3cret"
        /// Public keys accepted for `user`, as their `.pub` files hold them.
        var authorizedKeys: [SSHHostKey] = []
        /// The `direct-tcpip` targets the server opens, each by connecting to 127.0.0.1 on the
        /// target's port; any other target is refused.
        var forwardTargets: [ForwardTarget] = []
        /// Whether the server's socket to a forward target reads EOF as a half-close. When false,
        /// the target closing makes the server send CHANNEL_EOF then CHANNEL_CLOSE at once.
        var halfCloseTargets = true
    }

    struct ForwardTarget: Hashable, Sendable {
        var host: String
        var port: UInt16
    }

    /// One `direct-tcpip` open request.
    struct DirectTCPIPRequest: Equatable, Sendable {
        var target: ForwardTarget
        var originatorHost: String
        var originatorPort: Int
    }

    /// What the client sent, in order.
    struct Record: Sendable {
        /// One entry per user authentication request: `password`, `publickey <algorithm>`, `none`.
        var userauthRequests: [String] = []
        /// The public key algorithms the server accepted.
        var acceptedKeyAlgorithms: [String] = []
        /// The `TERM` of each pty request.
        var ptyTerms: [String] = []
        /// The number of TCP connections accepted.
        var connections = 0
        /// The number of key exchanges the RSA host key signed (initial plus re-keys).
        var hostKeySignatures = 0
        /// Every `direct-tcpip` open request, accepted or refused.
        var directTCPIPRequests: [DirectTCPIPRequest] = []
    }

    let port: UInt16
    /// The public half of the host key, as `ssh-keygen -y` would print it.
    let hostKey: SSHHostKey
    private let channel: any Channel
    private let state: Shared
    private let rsaHostKey: TestRSAHostPrivateKey?

    private init(port: UInt16, hostKey: SSHHostKey, channel: any Channel, state: Shared, rsaHostKey: TestRSAHostPrivateKey?) {
        self.port = port
        self.hostKey = hostKey
        self.channel = channel
        self.state = state
        self.rsaHostKey = rsaHostKey
    }

    static func start(_ configuration: Configuration = .init()) async throws -> TestSSHServer {
        RSASHA2.register()
        let state = Shared()
        let (privateKey, publicKey, rsaHostKey) = try hostKeys(configuration.hostKey, state: state)
        let auth = AuthDelegate(configuration: configuration, state: state)

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                state.withLock { $0.record.connections += 1 }
                do {
                    let server = SSHServerConfiguration(hostKeys: [privateKey], userAuthDelegate: auth)
                    try channel.pipeline.syncOperations.addHandlers(
                        SilenceHandler(state: state),
                        NIOSSHHandler(role: .server(server), allocator: channel.allocator) { child, type in
                            switch type {
                            case .session:
                                return child.eventLoop.makeCompletedFuture {
                                    try child.pipeline.syncOperations.addHandler(EchoShellHandler(state: state))
                                }
                            case .directTCPIP(let request):
                                return openDirectTCPIP(child, request, configuration: configuration, state: state)
                            default:
                                return child.eventLoop.makeFailedFuture(TestServerError.unsupportedChannel)
                            }
                        },
                        CloseOnErrorHandler()
                    )
                    state.withLock { $0.children.append(channel) }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
        return TestSSHServer(port: UInt16(port), hostKey: publicKey, channel: channel, state: state, rsaHostKey: rsaHostKey)
    }

    var record: Record { state.withLock { $0.record } }

    /// From now on, every byte from every client is dropped: the server no longer answers
    /// anything, keepalives included, like a peer behind a dead network.
    func stopAnswering() {
        state.withLock { $0.silent = true }
    }

    /// While true, every `direct-tcpip` open is refused, allow-listed or not (still recorded).
    func refuseForwards(_ refuse: Bool) {
        state.withLock { $0.refuseForwards = refuse }
    }

    /// Opens a `direct-tcpip` channel the way sshd does: connect to the target first, confirm the
    /// channel only once connected, then glue the two (with half-closure on both sides).
    private static func openDirectTCPIP(
        _ child: any Channel, _ request: SSHChannelType.DirectTCPIP, configuration: Configuration, state: Shared
    ) -> EventLoopFuture<Void> {
        let target = ForwardTarget(host: request.targetHost, port: UInt16(request.targetPort))
        let refused = state.withLock { value in
            value.record.directTCPIPRequests.append(DirectTCPIPRequest(
                target: target,
                originatorHost: request.originatorAddress.ipAddress ?? "?",
                originatorPort: request.originatorAddress.port ?? -1
            ))
            return value.refuseForwards
        }
        guard !refused, configuration.forwardTargets.contains(target) else {
            return child.eventLoop.makeFailedFuture(TestServerError.forwardRefused)
        }
        let (socketGlue, channelGlue) = ForwardGlue.pair()
        let socketHalf = NIOLoopBound(socketGlue, eventLoop: child.eventLoop)
        let channelHalf = NIOLoopBound(channelGlue, eventLoop: child.eventLoop)
        return ClientBootstrap(group: child.eventLoop)
            .channelOption(.allowRemoteHalfClosure, value: configuration.halfCloseTargets)
            .channelInitializer { socket in
                socket.eventLoop.makeCompletedFuture {
                    try socket.pipeline.syncOperations.addHandler(socketHalf.value)
                }
            }
            .connect(host: "127.0.0.1", port: Int(target.port))
            .flatMapThrowing { _ in
                try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                try child.pipeline.syncOperations.addHandlers(SSHChannelDataUnwrapper(), channelHalf.value)
            }
    }

    /// Starts a key re-exchange on every connection (swift-nio-ssh's test-only `_rekey`).
    func rekey() async throws {
        let children = state.withLock { $0.children }
        for child in children {
            try await child.eventLoop.submit {
                try child.pipeline.syncOperations.handler(type: NIOSSHHandler.self)._rekey()
            }.get()
        }
    }

    /// From now on an RSA server signs key exchanges with `id_rsa_encrypted`: a re-key then
    /// presents another host key. The new key's public half is returned.
    func rotateRSAHostKey() throws -> SSHHostKey {
        guard let rsaHostKey else { throw TestServerError.notRSA }
        let next = try SSHPrivateKey.parse(openSSH: try fixture("id_rsa_encrypted"), passphrase: "test-pass")
        guard case .rsa(let key, let body) = next.material else { throw TestServerError.notRSA }
        rsaHostKey.rotate(to: key, body: body)
        return next.publicKey
    }

    func stop() async {
        let children = state.withLock { $0.children }
        for child in children {
            try? await child.close()
        }
        try? await channel.close()
    }

    private static func hostKeys(_ kind: HostKeyKind, state: Shared) throws -> (NIOSSHPrivateKey, SSHHostKey, TestRSAHostPrivateKey?) {
        let file = switch kind {
        case .ed25519: "host_ed25519"
        case .rsa: "id_rsa"
        case .ecdsa: "id_ecdsa"
        }
        let key = try SSHPrivateKey.parse(openSSH: try fixture(file), passphrase: nil)
        switch key.material {
        case .ed25519(let ed):
            return (NIOSSHPrivateKey(ed25519Key: ed), key.publicKey, nil)
        case .rsa(let rsa, let body):
            let host = TestRSAHostPrivateKey(key: rsa, body: body, state: state)
            return (NIOSSHPrivateKey(custom: host), key.publicKey, host)
        case .ecdsaP256(let p256):
            return (NIOSSHPrivateKey(p256Key: p256), key.publicKey, nil)
        }
    }

    final class Shared: Sendable {
        struct Value {
            var record = Record()
            var silent = false
            var refuseForwards = false
            var children: [any Channel] = []
        }

        private let value = Mutex(Value())

        func withLock<T>(_ body: (inout Value) -> T) -> T {
            value.withLock { body(&$0) }
        }
    }
}

enum TestServerError: Error {
    case noPort
    case notRSA
    case unsupportedChannel
    case forwardRefused
}

/// An RSA host key as OpenSSH serves it: negotiated as `rsa-sha2-512`, sent as a blob typed
/// `ssh-rsa`, signing the exchange hash with SHA-512.
final class TestRSAHostPrivateKey: NIOSSHPrivateKeyProtocol, Sendable {
    static let keyPrefix = RSASHA512.name
    private let current: Mutex<(key: _RSA.Signing.PrivateKey, body: RSAPublicBody)>
    private let state: TestSSHServer.Shared

    init(key: _RSA.Signing.PrivateKey, body: RSAPublicBody, state: TestSSHServer.Shared) {
        current = Mutex((key, body))
        self.state = state
    }

    func rotate(to key: _RSA.Signing.PrivateKey, body: RSAPublicBody) {
        current.withLock { $0 = (key, body) }
    }

    var publicKey: NIOSSHPublicKeyProtocol { SSHRSAHostKey(body: current.withLock { $0.body }) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        state.withLock { $0.record.hostKeySignatures += 1 }
        let key = current.withLock { $0.key }
        return RSASHA2Signature<RSASHA512>(rawRepresentation: try RSASHA512.sign(key, Data(data)))
    }
}

/// Password and public key authentication for the one configured user. A key is matched against
/// the authorized keys by its RSA/ECDSA/ed25519 body, so an RSA key offered as `rsa-sha2-512`
/// matches its `ssh-rsa` `.pub` line; an `ssh-rsa` (SHA-1) signature is always refused, as
/// OpenSSH's default `PubkeyAcceptedAlgorithms` does.
private final class AuthDelegate: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let configuration: TestSSHServer.Configuration
    let state: TestSSHServer.Shared

    init(configuration: TestSSHServer.Configuration, state: TestSSHServer.Shared) {
        self.configuration = configuration
        self.state = state
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        switch request.request {
        case .password(let password):
            state.withLock { $0.record.userauthRequests.append("password") }
            let ok = request.username == configuration.user && configuration.password != nil && password.password == configuration.password
            responsePromise.succeed(ok ? .success : .failure)

        case .publicKey(let offer):
            let line = String(openSSHPublicKey: offer.publicKey)
            let algorithm = String(line.prefix { $0 != " " })
            state.withLock { $0.record.userauthRequests.append("publickey \(algorithm)") }
            guard request.username == configuration.user, algorithm != "ssh-rsa",
                  let offered = try? SSHHostKey(openSSHPublicKey: line),
                  configuration.authorizedKeys.contains(where: { Self.sameKey($0, offered) })
            else {
                responsePromise.succeed(.failure)
                return
            }
            state.withLock { $0.record.acceptedKeyAlgorithms.append(algorithm) }
            responsePromise.succeed(.success)

        default:
            state.withLock { $0.record.userauthRequests.append("none") }
            responsePromise.succeed(.failure)
        }
    }

    /// The same key: same family (`rsa-sha2-*` is `ssh-rsa`) and the same blob after the type string.
    private static func sameKey(_ authorized: SSHHostKey, _ offered: SSHHostKey) -> Bool {
        func family(_ algorithm: String) -> String { algorithm.hasPrefix("rsa-sha2-") ? "ssh-rsa" : algorithm }
        func body(_ key: SSHHostKey) -> Data {
            var reader = SSHWireReader(key.blob)
            _ = reader.readString()
            return Data(reader.readRest())
        }
        return family(authorized.algorithm) == family(offered.algorithm) && body(authorized) == body(offered)
    }
}

/// In front of the SSH handler: drops every inbound byte once the server is told to stop answering.
private final class SilenceHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    let state: TestSSHServer.Shared

    init(state: TestSSHServer.Shared) { self.state = state }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !state.withLock({ $0.silent }) else { return }
        context.fireChannelRead(data)
    }
}

private final class CloseOnErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// A session channel: pty and shell requests succeed, input is echoed, `window-change` is reported
/// as `"\u{1b}[size cols rows]"` and a line `exit` ends the shell with exit status 0.
private final class EchoShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let state: TestSSHServer.Shared
    private var line = ""

    init(state: TestSSHServer.Shared) { self.state = state }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            state.withLock { $0.record.ptyTerms.append(request.term) }
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let request as SSHChannelRequestEvent.ShellRequest:
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case let change as SSHChannelRequestEvent.WindowChangeRequest:
            send("\u{1b}[size \(change.terminalCharacterWidth) \(change.terminalRowHeight)]", context: context)
        case let request as SSHChannelRequestEvent.ExecRequest:
            if request.wantReply { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        let text = String(buffer: buffer)
        context.writeAndFlush(wrapOutboundOut(message), promise: nil)
        for character in text {
            if character == "\n" || character == "\r" {
                if line == "exit" {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                    context.close(promise: nil)
                    return
                }
                line = ""
            } else {
                line.append(character)
            }
        }
    }

    private func send(_ text: String, context: ChannelHandlerContext) {
        let data = SSHChannelData(type: .channel, data: .byteBuffer(context.channel.allocator.buffer(string: text)))
        context.writeAndFlush(wrapOutboundOut(data), promise: nil)
    }
}

/// A TCP listener on 127.0.0.1 that accepts connections and never sends a byte: an SSH server that
/// hangs before its version line.
final class SilentTCPServer: Sendable {
    let port: UInt16
    private let channel: any Channel

    private init(port: UInt16, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    static func start() async throws -> SilentTCPServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
        return SilentTCPServer(port: UInt16(port), channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }
}

/// A listener on 127.0.0.1 that never accepts, with its backlog filled by `fillers` connections:
/// a further TCP connect stays pending (the SYN goes unanswered) until the client gives up.
final class StalledTCPServer: Sendable {
    let port: UInt16
    private let channel: any Channel
    private let fillers: [any Channel]

    private init(port: UInt16, channel: any Channel, fillers: [any Channel]) {
        self.port = port
        self.channel = channel
        self.fillers = fillers
    }

    static func start() async throws -> StalledTCPServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 1)
            .serverChannelOption(.autoRead, value: false)
            .bind(host: "127.0.0.1", port: 0).get()
        guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
        var fillers: [any Channel] = []
        for _ in 0 ..< 8 {
            let filler = try? await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.milliseconds(200))
                .connect(host: "127.0.0.1", port: port).get()
            guard let filler else { break }
            fillers.append(filler)
        }
        return StalledTCPServer(port: UInt16(port), channel: channel, fillers: fillers)
    }

    func stop() async {
        for filler in fillers { try? await filler.close() }
        try? await channel.close()
    }
}

/// A port on 127.0.0.1 that nothing listens on: bound by a listener that is closed at once.
func closedLoopbackPort() async throws -> UInt16 {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "127.0.0.1", port: 0).get()
    guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
    try await channel.close()
    return UInt16(port)
}
