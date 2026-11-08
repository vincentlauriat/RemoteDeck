import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// An interactive shell on a pseudo-terminal, opened by `SSHConnection.openShell`.
public final class SSHShell: Sendable {
    /// The terminal's output. It ends normally when the remote shell exits, and throws
    /// `SSHError.connectionClosed` if the connection ends under it. Ending the iteration closes
    /// the shell.
    public let output: AsyncThrowingStream<Data, any Error>
    private let channel: any Channel

    init(output: AsyncThrowingStream<Data, any Error>, channel: any Channel) {
        self.output = output
        self.channel = channel
    }

    /// Sends input (keystrokes, pasted text) to the shell.
    public func write(_ data: Data) async throws(SSHError) {
        let message = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data)))
        do {
            try await channel.writeAndFlush(message)
        } catch {
            throw .connectionClosed
        }
    }

    /// Tells the server the terminal's new size (`window-change`). Nothing happens once the shell
    /// has ended.
    public func resize(columns: Int, rows: Int) async {
        let change = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        try? await channel.triggerUserOutboundEvent(change)
    }
}

/// The session channel of a shell: asks for the pty, then the shell, then forwards the output.
final class ShellChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private enum Phase {
        case starting, awaitingPTY, awaitingShell, running, ended
    }

    private let request: SSHChannelRequestEvent.PseudoTerminalRequest
    private let ready: EventLoopPromise<Void>
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private var phase = Phase.starting
    /// The server said the shell is over (exit status or signal, or end of its output): a close
    /// after that is the shell's normal end, not a lost connection.
    private var remoteEnded = false

    init(request: SSHChannelRequestEvent.PseudoTerminalRequest, ready: EventLoopPromise<Void>, output: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.request = request
        self.ready = ready
        self.output = output
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard phase == .starting else { return }
        phase = .awaitingPTY
        context.triggerUserOutboundEvent(request, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch phase {
            case .awaitingPTY:
                phase = .awaitingShell
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
            case .awaitingShell:
                phase = .running
                ready.succeed(())
            default:
                break
            }
        case is ChannelFailureEvent:
            switch phase {
            case .awaitingPTY: refuse("pty request refused", context: context)
            case .awaitingShell: refuse("shell request refused", context: context)
            default: break
            }
        case is SSHChannelRequestEvent.ExitStatus, is SSHChannelRequestEvent.ExitSignal, ChannelEvent.inputClosed:
            remoteEnded = true
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        output.yield(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        end(remoteEnded || context.channel.parent?.isActive == true ? nil : .connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func refuse(_ reason: String, context: ChannelHandlerContext) {
        phase = .ended
        ready.fail(SSHError.channelFailed(reason))
        output.finish()
        context.close(promise: nil)
    }

    private func end(_ error: SSHError?) {
        guard phase != .ended else { return }
        let wasRunning = phase == .running
        phase = .ended
        ready.fail(error ?? .channelFailed("session channel closed"))
        if wasRunning, let error {
            output.finish(throwing: error)
        } else {
            output.finish()
        }
    }
}
