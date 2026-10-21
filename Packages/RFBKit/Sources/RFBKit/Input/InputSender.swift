import os

/// Client messages waiting to be sent, with pointer-move coalescing: a move (a PointerEvent whose
/// button mask equals the previous one's) replaces a move still waiting at the tail. Nothing else is
/// merged, dropped or reordered, so key events and button transitions (presses, releases, scroll
/// steps) all reach the server, each at its own position, in order.
struct InputQueue: Sendable {
    private(set) var pending: [ClientMessage] = []
    private var tailIsMove = false
    /// Mask of the last PointerEvent appended, sent or not.
    private var lastMask: UInt8 = 0
    private(set) var isClosed = false

    mutating func append(_ message: ClientMessage) {
        guard !isClosed else { return }
        guard case .pointerEvent(let mask, _, _) = message else {
            pending.append(message)
            tailIsMove = false
            return
        }
        let isMove = mask == lastMask
        lastMask = mask
        if isMove, tailIsMove, !pending.isEmpty {
            pending[pending.count - 1] = message
        } else {
            pending.append(message)
            tailIsMove = isMove
        }
    }

    /// Everything waiting, in order; the queue is empty afterwards.
    mutating func take() -> [ClientMessage] {
        defer {
            pending = []
            tailIsMove = false
        }
        return pending
    }

    /// Drops what is waiting and ignores later appends (the connection failed).
    mutating func close() {
        isClosed = true
        pending = []
    }
}

/// Sends a session's input off the main actor, in order: `enqueue` is synchronous and cheap (callable
/// from an AppKit event handler), and one background task writes everything waiting as a single
/// batch, one batch at a time. Mouse moves that pile up while a batch is being written collapse to
/// the latest (`InputQueue`), so a move flood costs at most one PointerEvent per write.
///
/// The first failed write stops the sender; later input is dropped (the session stream reports the
/// error).
public final class InputSender: Sendable {
    private let queue: OSAllocatedUnfairLock<InputQueue>
    private let wake: AsyncStream<Void>.Continuation
    private let task: Task<Void, Never>

    public convenience init(connection: RFBConnection) {
        self.init { messages in try await connection.send(messages) }
    }

    /// `send` writes one batch; the next batch is not started before it returns.
    public init(send: @escaping @Sendable ([ClientMessage]) async throws -> Void) {
        let queue = OSAllocatedUnfairLock(initialState: InputQueue())
        let (signals, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.queue = queue
        self.wake = wake
        task = Task.detached(priority: .userInitiated) {
            for await _ in signals {
                while true {
                    let batch = queue.withLock { $0.take() }
                    guard !batch.isEmpty else { break }
                    do {
                        try await send(batch)
                    } catch {
                        queue.withLock { $0.close() }
                        return
                    }
                }
            }
        }
    }

    deinit {
        wake.finish()
    }

    public func enqueue(_ messages: [ClientMessage]) {
        guard !messages.isEmpty else { return }
        queue.withLock { queue in
            for message in messages { queue.append(message) }
        }
        wake.yield()
    }

    /// Stops after what is already enqueued has been handed to `send`. Enqueue the release of
    /// everything held (`InputTranslator.releaseAll`, e.g. via `FramebufferView.tearDownInput()`)
    /// before calling it, and close the connection only after `stopped()`.
    public func finish() {
        wake.finish()
    }

    /// Completes once the sender has stopped (after `finish()` or a failed write).
    public func stopped() async {
        await task.value
    }
}
