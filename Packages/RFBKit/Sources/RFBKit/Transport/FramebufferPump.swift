import Dispatch
import Foundation

/// Owns a `ServerMessageDecoder` and runs it on a dedicated serial queue: the actor's executor is
/// that queue, so decoding (zlib, tile loops, JPEG) never occupies a thread of Swift's cooperative
/// pool, and the non-`Sendable` decoder state never leaves the actor.
actor FramebufferPump {
    private let queue: DispatchSerialQueue
    private var decoder: ServerMessageDecoder

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(width: Int, height: Int) throws(RFBError) {
        queue = DispatchSerialQueue(label: "RFBKit.RFBConnection.decode", qos: .userInitiated)
        decoder = try ServerMessageDecoder(width: width, height: height)
    }

    func receive(_ chunk: Data) throws(RFBError) -> [RFBEvent] {
        try decoder.receive(chunk)
    }

    var framebufferSize: (width: Int, height: Int) {
        (decoder.framebuffer.width, decoder.framebuffer.height)
    }

    /// A copy of the whole framebuffer (e.g. for a screenshot).
    var framebuffer: Framebuffer { decoder.framebuffer }
}
