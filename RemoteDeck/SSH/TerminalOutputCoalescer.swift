import Foundation
import Synchronization

/// Drains a shell's output off the main actor and hands it to the terminal at most once per display
/// frame, with everything received since (TRD › Performance: `yes` or the `cat` of a 50 MB log keeps
/// the UI responsive, and no byte is ever dropped).
///
/// Two child tasks: the reader appends every chunk to one buffer (and counts the bytes); the
/// deliverer takes the whole buffer when data is there, delivers it on the main actor, then waits a
/// frame before it may deliver again. The first chunk after a quiet spell is delivered at once (a
/// typed key echoes without a frame of delay). When the output ends, what is left is delivered
/// before `run` returns or throws.
final class TerminalOutputCoalescer: Sendable {
    /// One display frame.
    static let frameInterval: Duration = .milliseconds(16)

    private struct State {
        var buffer = Data()
        var total: Int64 = 0
        var failure: (any Error)?
    }

    private let state = Mutex(State())
    private let frameInterval: Duration

    init(frameInterval: Duration = TerminalOutputCoalescer.frameInterval) {
        self.frameInterval = frameInterval
    }

    /// Bytes read from the output so far (SessionRecord.bytesReceived).
    var byteCount: Int64 { state.withLock { $0.total } }

    /// Reads `output` until it ends. Returns when it finished normally (the remote shell ended),
    /// throws its error when it failed (connection lost), in both cases after the last bytes were
    /// delivered. Called once per coalescer (one per shell). Cancelling the calling task stops
    /// reading at once, which closes the shell (`SSHShell`), and delivers nothing more.
    @concurrent
    func run(_ output: AsyncThrowingStream<Data, any Error>,
             deliver: @escaping @MainActor @Sendable (Data) -> Void) async throws {
        // Rings once per chunk; buffering one ring collapses the chunks of a frame into one delivery.
        let (doorbell, ring) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                do {
                    for try await chunk in output {
                        state.withLock { state in
                            state.buffer.append(chunk)
                            state.total += Int64(chunk.count)
                        }
                        ring.yield()
                    }
                } catch {
                    state.withLock { $0.failure = error }
                }
                ring.finish()
            }
            group.addTask { [self, frameInterval] in
                for await _ in doorbell {
                    let chunk = state.withLock { state in
                        let taken = state.buffer
                        state.buffer = Data()
                        return taken
                    }
                    guard !chunk.isEmpty, !Task.isCancelled else { continue }
                    await deliver(chunk)
                    // The next delivery waits a frame; what arrives meanwhile rings once.
                    do { try await Task.sleep(for: frameInterval) } catch { break }
                }
                // The doorbell finished: a ring may have been dropped while a delivery was sleeping
                // and cancelled, or the last chunk came after the last ring was consumed.
                guard !Task.isCancelled else { return }
                let rest = state.withLock { state in
                    let taken = state.buffer
                    state.buffer = Data()
                    return taken
                }
                if !rest.isEmpty { await deliver(rest) }
            }
        }
        if let error = state.withLock({ $0.failure }), !Task.isCancelled { throw error }
    }
}
