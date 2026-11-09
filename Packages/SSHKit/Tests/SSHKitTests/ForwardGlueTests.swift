import NIOCore
import NIOEmbedded
import Testing
@testable import SSHKit

/// `ForwardGlue` on two `EmbeddedChannel`s sharing one loop: the policies a loopback run cannot
/// reach on demand.
@Suite(.timeLimit(.minutes(1)))
struct ForwardGlueTests {
    /// swift-nio-ssh fails a channel write made during a key re-exchange instead of queueing it.
    /// The forwarded stream must then end, never go on without those bytes.
    @Test func aFailedWriteClosesBothSides() async throws {
        let (loop, socket, ssh) = try await gluedPair(sshWrites: FailingWrites())
        try socket.writeInbound(ByteBuffer(string: "lost"))
        loop.run()
        #expect(!ssh.isActive)
        #expect(!socket.isActive)
    }

    /// Positive control: the same pair passes bytes on while writes succeed.
    @Test func bytesPassWhileWritesSucceed() async throws {
        let (loop, socket, ssh) = try await gluedPair(sshWrites: nil)
        try socket.writeInbound(ByteBuffer(string: "kept"))
        loop.run()
        #expect(try ssh.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "kept"))
        #expect(ssh.isActive)
        #expect(socket.isActive)
        _ = try? socket.finish()
        _ = try? ssh.finish()
    }

    private func gluedPair(sshWrites: (any ChannelOutboundHandler & Sendable)?) async throws -> (EmbeddedEventLoop, EmbeddedChannel, EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let (socketGlue, channelGlue) = ForwardGlue.pair()
        let socket = EmbeddedChannel(loop: loop)
        let ssh = EmbeddedChannel(loop: loop)
        if let sshWrites { try ssh.pipeline.syncOperations.addHandler(sshWrites) }
        try ssh.pipeline.syncOperations.addHandler(channelGlue)
        try socket.pipeline.syncOperations.addHandler(socketGlue)
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1)
        try await socket.connect(to: address).get()
        try await ssh.connect(to: address).get()
        return (loop, socket, ssh)
    }
}

/// Fails every write, as swift-nio-ssh does for channel data sent mid re-key.
private final class FailingWrites: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.ioOnClosedChannel)
    }
}
