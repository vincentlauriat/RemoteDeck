import Darwin
import Foundation
import NIOCore
import NIOPosix
@testable import SSHKit

/// The far end of a forward in the loopback tests: an HTTP/1.0 listener on 127.0.0.1 that answers
/// every request with `body`, then closes. A client's half-close does not cut the response short.
final class TinyHTTPServer: Sendable {
    let port: UInt16
    private let channel: any Channel
    private let written: Locked<Int>

    private init(port: UInt16, channel: any Channel, written: Locked<Int>) {
        self.port = port
        self.channel = channel
        self.written = written
    }

    /// The number of responses fully handed to the kernel: a response stays unwritten while the
    /// path to the client is full.
    var responsesWritten: Int { written.withLock { $0 } }

    static func start(body: Data) async throws -> TinyHTTPServer {
        let written = Locked(0)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(HTTPResponder(body: body, written: written))
                }
            }
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
        return TinyHTTPServer(port: UInt16(port), channel: channel, written: written)
    }

    /// The bytes a client receives for one request.
    static func response(_ body: Data) -> Data {
        Data("HTTP/1.0 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }

    func stop() async {
        try? await channel.close()
    }
}

private final class HTTPResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let body: Data
    private let written: Locked<Int>
    private var request = Data()
    private var answered = false

    init(body: Data, written: Locked<Int>) {
        self.body = body
        self.written = written
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        request.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        guard !answered, request.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        answered = true
        let channel = context.channel
        let written = self.written
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(bytes: TinyHTTPServer.response(body)))).whenComplete { result in
            if case .success = result { written.withLock { $0 += 1 } }
            channel.close(promise: nil)
        }
    }
}

/// A TCP echo listener on 127.0.0.1: sends back every byte; after the client's EOF, closes once
/// everything is echoed.
final class EchoTCPServer: Sendable {
    let port: UInt16
    private let channel: any Channel

    private init(port: UInt16, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    static func start() async throws -> EchoTCPServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Echoer())
                }
            }
            .bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).get()
        guard let port = channel.localAddress?.port else { throw TestServerError.noPort }
        return EchoTCPServer(port: UInt16(port), channel: channel)
    }

    func stop() async {
        try? await channel.close()
    }
}

private final class Echoer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case ChannelEvent.inputClosed = event else { return }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(ByteBuffer())).whenComplete { _ in channel.close(promise: nil) }
    }
}

/// A plain TCP client for the forwarded port: collects every byte it receives until EOF.
final class TestTCPClient: Sendable {
    private let channel: any Channel
    private let received: Locked<(data: Data, ended: Bool)>

    private init(channel: any Channel, received: Locked<(data: Data, ended: Bool)>) {
        self.channel = channel
        self.received = received
    }

    /// `autoRead` false: nothing is read (the kernel buffers fill up) until `resumeReading()`.
    /// `receiveBuffer`: SO_RCVBUF, to keep the kernel from absorbing what the client does not read.
    static func connect(_ ip: String, _ port: UInt16, autoRead: Bool = true, receiveBuffer: Int32? = nil) async throws -> TestTCPClient {
        let received = Locked<(data: Data, ended: Bool)>((Data(), false))
        var bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        if let receiveBuffer {
            // Small reads too: each `read()` then takes at most 2 kB.
            bootstrap = bootstrap.channelOption(.socketOption(.so_rcvbuf), value: SocketOptionValue(receiveBuffer))
                .channelOption(.maxMessagesPerRead, value: 1)
                .channelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2048))
        }
        let channel = try await bootstrap
            .connectTimeout(.seconds(2))
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelOption(.autoRead, value: autoRead)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(Collector(received: received))
                }
            }
            .connect(to: SocketAddress(ipAddress: ip, port: Int(port))).get()
        return TestTCPClient(channel: channel, received: received)
    }

    /// The error a connection attempt to `ip`:`port` fails with, nil if it connects.
    static func connectError(_ ip: String, _ port: UInt16) async -> (any Error)? {
        do {
            let client = try await connect(ip, port)
            await client.close()
            return nil
        } catch {
            return error
        }
    }

    var localPort: Int? { channel.localAddress?.port }

    func send(_ data: Data) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }

    /// With `autoRead` off: one read every `interval` until the peer closes, a slow consumer.
    func trickle(every interval: Duration) {
        let channel = self.channel
        let received = self.received
        Task {
            while !received.withLock({ $0.ended }), channel.isActive {
                channel.read()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func resumeReading() async throws {
        try await channel.setOption(.autoRead, value: true)
    }

    /// Half-closes: the peer reads EOF, this client keeps reading.
    func shutdownOutput() async throws {
        try await channel.close(mode: .output)
    }

    /// Everything received, once the peer closed within `limit`; nil if it did not.
    func readToEnd(within limit: Duration = .seconds(5)) async -> Data? {
        guard await poll(within: limit, { self.received.withLock { $0.ended } }) else { return nil }
        return received.withLock { $0.data }
    }

    /// Whether the peer closed within `limit`.
    func ended(within limit: Duration) async -> Bool {
        await poll(within: limit) { self.received.withLock { $0.ended } }
    }

    func close() async {
        try? await channel.close()
    }
}

private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let received: Locked<(data: Data, ended: Bool)>

    init(received: Locked<(data: Data, ended: Bool)>) { self.received = received }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        received.withLock { $0.data.append(contentsOf: buffer.readableBytesView) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event {
            received.withLock { $0.ended = true }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        received.withLock { $0.ended = true }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Whether a connection attempt was actively refused (RST), not timed out or failed otherwise.
func isConnectionRefused(_ error: (any Error)?) -> Bool {
    switch error {
    case let error as IOError: error.errnoCode == ECONNREFUSED
    case let error as NIOConnectionError: !error.connectionErrors.isEmpty && error.connectionErrors.allSatisfy { isConnectionRefused($0.error) }
    default: false
    }
}

/// A listener the test holds on `ip`:`port` (0 = any free port), as another app would; no
/// SO_REUSEADDR, like most servers that bind a fixed port.
func holdPort(_ ip: String, _ port: UInt16 = 0) async throws -> (channel: any Channel, port: UInt16) {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
        .bind(to: SocketAddress(ipAddress: ip, port: Int(port))).get()
    guard let bound = channel.localAddress?.port else { throw TestServerError.noPort }
    return (channel, UInt16(bound))
}

/// The first IPv4 address of an up, non-loopback interface (`en*` first), nil if the Mac has none.
func firstNonLoopbackIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var found: [(name: String, ip: String)] = []
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(entry.pointee.ifa_flags)
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
        else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        found.append((String(cString: entry.pointee.ifa_name), String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
    }
    return (found.first { $0.name.hasPrefix("en") } ?? found.first)?.ip
}
