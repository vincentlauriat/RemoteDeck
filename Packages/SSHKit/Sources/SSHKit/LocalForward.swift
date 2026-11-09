import Darwin
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Synchronization

extension SSHConnection {
    /// Listens on `localPort` on the loopback interfaces only, 127.0.0.1 and [::1] (never on
    /// another interface), and forwards each accepted connection to `remoteHost`:`remotePort` as
    /// seen from the server, through its own `direct-tcpip` channel (OpenSSH's `ssh -L`).
    ///
    /// - `localPort` 0 picks a free port: `LocalForwardHandle.localPort` is the port bound.
    /// - Throws `.portInUse(localPort)` when either loopback address is taken on that port, or
    ///   another app listens on it on all interfaces (0.0.0.0 or [::]); nothing is left listening,
    ///   and the connection and its shells stay usable. A Mac without IPv6 loopback (::1
    ///   unavailable) forwards on 127.0.0.1 alone.
    /// - Throws `.connectionClosed` if the connection is not open, `.remote` for any other failure
    ///   to listen (a sandbox without `network.server` refuses every bind).
    /// - A channel the server refuses (`AllowTcpForwarding no`, a target it cannot reach) closes
    ///   that one local socket; the forward keeps listening.
    /// - Backpressure: each side reads only while the other can take more (socket watermarks, the
    ///   peer's SSH window), so neither direction buffers without bound. Half-closes are passed on.
    /// - The forward runs until `LocalForwardHandle.stop()`, `close()` or the connection's loss.
    public func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError) -> LocalForwardHandle {
        guard let (loop, ssh) = forwardingContext() else { throw .connectionClosed }
        let sockets = ForwardSockets(loop: loop)
        let target = ForwardTarget(host: remoteHost, port: remotePort)

        // Everything on the connection's loop: the glue joins sockets and SSH channels directly.
        let bootstrap = ServerBootstrap(group: loop, childGroup: loop)
            // Without it, a port that just forwarded traffic stays unbindable while its sockets are
            // in TIME_WAIT. The cost, binding over another app's wildcard listener, is checked
            // separately (`LoopbackListeners.wildcardTaken`).
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { listener in
                listener.eventLoop.makeCompletedFuture { try sockets.admit(listener) }
            }
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { local in
                local.eventLoop.makeCompletedFuture {
                    try sockets.admit(local)
                    let (socketGlue, channelGlue) = ForwardGlue.pair()
                    // The glue holds every read until the SSH channel is open and glued.
                    try local.pipeline.syncOperations.addHandlers(
                        ForwardOpener(ssh: ssh, target: target, glue: channelGlue, sockets: sockets),
                        socketGlue
                    )
                }
            }

        let port = try await LoopbackListeners.bind(bootstrap, port: localPort, sockets: sockets)
        let handle = LocalForwardHandle(localPort: port, sockets: sockets)
        guard adopt(handle) else {
            // close() or a lost connection while binding.
            await handle.stop()
            throw .connectionClosed
        }
        return handle
    }
}

/// A local forward started by `SSHConnection.startLocalForward`.
public final class LocalForwardHandle: Sendable {
    /// The port bound on 127.0.0.1 and [::1].
    public let localPort: UInt16
    private let sockets: ForwardSockets
    private let stopRequested = Atomic(false)

    init(localPort: UInt16, sockets: ForwardSockets) {
        self.localPort = localPort
        self.sockets = sockets
    }

    /// Stops listening and closes every forwarded connection; returns once the port is free.
    /// Calling it again, or after the connection ended, does nothing.
    public func stop() async {
        stopRequested.store(true, ordering: .relaxed)
        let sockets = self.sockets
        try? await sockets.loop.flatSubmit { sockets.stop() }.get()
    }

    /// `stop()` without waiting, for the connection's synchronous end.
    func shutdown() {
        stopRequested.store(true, ordering: .relaxed)
        let sockets = self.sockets
        sockets.loop.execute { _ = sockets.stop() }
    }

    var isStopped: Bool { stopRequested.load(ordering: .relaxed) }

    /// The listeners, accepted sockets and SSH channels still open, for the tests.
    var openChannelCount: Int {
        get async {
            let sockets = self.sockets
            return (try? await sockets.loop.submit { sockets.openCount }.get()) ?? -1
        }
    }
}

struct ForwardTarget: Sendable {
    let host: String
    let port: UInt16
}

struct ForwardStopped: Error {}

/// Every channel of one forward (its listeners, accepted sockets and their SSH channels), so
/// stopping can close them all. Mutated on `loop` only.
///
/// `stop()` waits for the TCP channels only (listeners, local sockets), which close at once. An
/// SSH channel closes only when the server answers CHANNEL_CLOSE, and one still opening buffers
/// its close until the server answers the open (sshd's connect to the target can take minutes):
/// those are closed without being waited for, and the SSH connection's close bounds them.
final class ForwardSockets: Sendable {
    let loop: any EventLoop
    private let state: NIOLoopBoundBox<State>

    private struct State {
        var open: [ObjectIdentifier: (channel: any Channel, awaited: Bool)] = [:]
        /// Set by the first `stop()`: completes once every channel is closed.
        var stopped: EventLoopFuture<Void>?
    }

    init(loop: any EventLoop) {
        self.loop = loop
        state = .makeBoxSendingValue(State(), as: State.self, eventLoop: loop)
    }

    /// Tracks a channel until it closes; throws once stopped (the caller's channel then closes).
    /// `awaited`: whether `stop()` waits for it to close (TCP channels, not SSH channels).
    func admit(_ channel: any Channel, awaited: Bool = true) throws {
        guard state.value.stopped == nil else { throw ForwardStopped() }
        let id = ObjectIdentifier(channel)
        state.value.open[id] = (channel, awaited)
        channel.closeFuture.whenComplete { [self] _ in
            state.value.open[id] = nil
        }
    }

    /// The number of channels open (listeners included), for the tests. On the loop only.
    var openCount: Int { state.value.open.count }

    /// Closes every channel; completes once the TCP ones are closed. The same future on every call.
    func stop() -> EventLoopFuture<Void> {
        if let stopped = state.value.stopped { return stopped }
        let entries = Array(state.value.open.values)
        for entry in entries { entry.channel.close(promise: nil) }
        let stopped = EventLoopFuture.andAllComplete(entries.filter(\.awaited).map(\.channel.closeFuture), on: loop)
        state.value.stopped = stopped
        return stopped
    }
}

/// First on an accepted local socket: once it is active (registered, so reads are not lost),
/// opens its `direct-tcpip` channel and glues it. A refused channel closes the socket; a socket
/// closed before the channel opened closes the channel.
private final class ForwardOpener: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let ssh: NIOLoopBound<NIOSSHHandler>
    private let target: ForwardTarget
    private let glue: ForwardGlue
    private let sockets: ForwardSockets
    private var started = false

    init(ssh: NIOLoopBound<NIOSSHHandler>, target: ForwardTarget, glue: ForwardGlue, sockets: ForwardSockets) {
        self.ssh = ssh
        self.target = target
        self.glue = glue
        self.sockets = sockets
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        let local = context.channel
        guard let originator = local.remoteAddress else {
            local.close(promise: nil)
            return
        }
        let created = context.eventLoop.makePromise(of: (any Channel).self)
        let glue = NIOLoopBound(self.glue, eventLoop: context.eventLoop)
        let sockets = self.sockets
        let type = SSHChannelType.directTCPIP(.init(targetHost: target.host, targetPort: Int(target.port), originatorAddress: originator))
        ssh.value.createChannel(created, channelType: type) { child, _ in
            child.eventLoop.makeCompletedFuture {
                try sockets.admit(child, awaited: false)
                try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                try child.pipeline.syncOperations.addHandlers(SSHChannelDataUnwrapper(), glue.value)
            }
        }
        created.futureResult.whenComplete { result in
            switch result {
            case .success(let child):
                if !local.isActive { child.close(promise: nil) }
            case .failure:
                local.close(promise: nil)
            }
        }
    }
}

/// Binding a forward's two loopback listeners.
enum LoopbackListeners {
    /// Binds 127.0.0.1 then [::1] on the same port (`port` 0: a free one, retried if ::1 has it
    /// taken) and returns that port. On failure nothing stays bound; `.portInUse` names the port
    /// requested, or with 0 the last one tried.
    static func bind(_ bootstrap: ServerBootstrap, port requested: UInt16, sockets: ForwardSockets) async throws(SSHError) -> UInt16 {
        var lastTried = requested
        for _ in 0 ..< (requested == 0 ? 8 : 1) {
            let v4: any Channel
            switch await listen(bootstrap, "127.0.0.1", requested) {
            case .success(let channel): v4 = channel
            case .failure(let error): throw error.sshError(port: requested)
            }
            guard let bound = v4.localAddress?.port.map(UInt16.init) else {
                try? await v4.close()
                throw .remote("listener has no port")
            }
            lastTried = bound
            if wildcardTaken(port: bound, family: AF_INET) || wildcardTaken(port: bound, family: AF_INET6) {
                try? await v4.close()
                continue
            }
            switch await listen(bootstrap, "::1", bound) {
            case .success:
                return bound
            case .failure(.unavailable):
                return bound  // no IPv6 loopback on this Mac: 127.0.0.1 alone
            case .failure(let error):
                try? await v4.close()
                guard case .inUse = error else { throw error.sshError(port: requested) }
            }
        }
        throw .portInUse(lastTried)
    }

    enum Failure: Error {
        case inUse, unavailable
        case other(String)

        func sshError(port: UInt16) -> SSHError {
            switch self {
            case .inUse: .portInUse(port)
            case .unavailable: .remote("loopback address unavailable")
            case .other(let reason): .remote(reason)
            }
        }
    }

    private static func listen(_ bootstrap: ServerBootstrap, _ ip: String, _ port: UInt16) async -> Result<any Channel, Failure> {
        do {
            return .success(try await bootstrap.bind(to: SocketAddress(ipAddress: ip, port: Int(port))).get())
        } catch let error as IOError {
            switch error.errnoCode {
            case EADDRINUSE: return .failure(.inUse)
            case EADDRNOTAVAIL, EAFNOSUPPORT: return .failure(.unavailable)
            default: return .failure(.other("cannot listen on \(ip) port \(port): \(error)"))
            }
        } catch {
            return .failure(.other("cannot listen on \(ip) port \(port): \(error)"))
        }
    }

    /// Whether another socket holds the wildcard address (0.0.0.0, or [::] IPv6-only) on `port`:
    /// with SO_REUSEADDR, macOS lets a loopback bind succeed over it and take its loopback traffic.
    /// A probe bind of the wildcard with SO_REUSEADDR fails only then: not for TIME_WAIT sockets,
    /// nor for listeners on specific addresses (this forward's own 127.0.0.1 one included).
    static func wildcardTaken(port: UInt16, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size) == 0 else { return false }
        let result: Int32
        if family == AF_INET6 {
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, size) == 0 else { return false }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}

// MARK: - Glue

/// Joins two channels on the same event loop, both carrying `ByteBuffer`s (an SSH child channel
/// through `SSHChannelDataUnwrapper`). Backpressure: a side reads only while its partner is
/// writable, so neither direction buffers more than one read past the partner's watermark (a TCP
/// socket) or the peer's SSH window (an SSH channel). EOF is passed on as a half-close; a side that
/// closes makes its partner close once the bytes already written to it are sent.
final class ForwardGlue: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum Side {
        /// A TCP socket: NIO's `close(mode: .output)` escalates to a full close (dropping pending
        /// writes) once the input is closed, so pending writes are drained first.
        case socket
        /// An SSH child channel: `close(mode: .output)` (CHANNEL_EOF) is queued after the pending writes.
        case sshChannel
    }

    private let side: Side
    private var partner: ForwardGlue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// Completes once this side's output is closed, after the bytes written before it.
    private var outputClosed: EventLoopFuture<Void>?
    private var closing = false

    private init(side: Side) {
        self.side = side
    }

    /// The glue for a local socket and the glue for its SSH child channel.
    static func pair() -> (socket: ForwardGlue, sshChannel: ForwardGlue) {
        let socket = ForwardGlue(side: .socket)
        let sshChannel = ForwardGlue(side: .sshChannel)
        socket.partner = sshChannel
        sshChannel.partner = socket
        return (socket, sshChannel)
    }

    // MARK: Called by the partner

    private func partnerWrite(_ buffer: ByteBuffer) {
        guard let context, !closing else { return }
        // A failed write must end the stream, never leave a hole in it: swift-nio-ssh fails channel
        // data sent during a key re-exchange instead of queueing it. Closing this side closes the
        // partner through `channelInactive`.
        let channel = context.channel
        context.write(wrapOutboundOut(buffer)).whenFailure { _ in channel.close(promise: nil) }
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        _ = closeOutput()
    }

    private func partnerClosed() {
        guard let context, !closing else { return }
        closing = true
        let channel = context.channel
        let drained = closeOutput() ?? context.eventLoop.makeSucceededVoidFuture()
        drained.whenComplete { _ in channel.close(promise: nil) }
    }

    private func partnerBecameWritable() {
        guard pendingRead else { return }
        pendingRead = false
        context?.read()
    }

    private var isWritable: Bool {
        context?.channel.isWritable ?? false
    }

    /// Closes this side's output after what was written to it; the same future on later calls.
    private func closeOutput() -> EventLoopFuture<Void>? {
        if let outputClosed { return outputClosed }
        guard let context else { return nil }
        let promise = context.eventLoop.makePromise(of: Void.self)
        switch side {
        case .sshChannel:
            context.close(mode: .output, promise: promise)
        case .socket:
            // Writes complete in order: when this empty one is done, so are the ones before it.
            let channel = context.channel
            let marker = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(ByteBuffer()), promise: marker)
            marker.futureResult.whenComplete { _ in channel.close(mode: .output, promise: promise) }
        }
        outputClosed = promise.futureResult
        return promise.futureResult
    }

    // MARK: ChannelDuplexHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerClosed()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Our channel is unusable: close it, which closes the partner through `channelInactive`.
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.isWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// On an SSH child channel, in front of `ForwardGlue`: channel data in, `ByteBuffer`s out, and back.
/// Extended data (stderr) is not part of a TCP stream and is dropped.
final class SSHChannelDataUnwrapper: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))
        context.write(wrapOutboundOut(message), promise: promise)
    }
}
