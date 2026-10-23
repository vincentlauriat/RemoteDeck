import Foundation
import Network
import os

/// Resumes a continuation at most once, whichever callback fires first.
final class OnceContinuation<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}

/// A result that may arrive before or after the continuation waiting for it: the first result
/// wins, whichever side comes first (a cancellation handler can run before the continuation exists).
final class PendingResult<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, RFBError>?
        var delivered = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let early: Result<Value, RFBError>? = state.withLock { state in
            if let result = state.result {
                state.delivered = true
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early.mapError { $0 }) }
    }

    func resume(with result: Result<Value, RFBError>) {
        let waiting: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard !state.delivered, state.result == nil else { return nil }
            state.result = result
            guard let continuation = state.continuation else { return nil }
            state.delivered = true
            state.continuation = nil
            return continuation
        }
        waiting?.resume(with: result.mapError { $0 })
    }
}

extension NWConnection {
    /// Starts the connection and waits until it is ready.
    ///
    /// `.waiting` is treated as a failure: Network.framework enters it on ECONNREFUSED or an
    /// unreachable host and would otherwise retry until the deadline.
    ///
    /// Cancelling the calling task ends the wait at once with `RFBError.cancelled` (and cancels the
    /// connection), without counting on a state update: a cancel that lands before `start` makes
    /// Network.framework deliver none, and the wait would never end (review M1).
    func startAndWaitUntilReady(queue: DispatchQueue) async throws {
        let pending = PendingResult<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending.attach(continuation)
                stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        pending.resume(with: .success(()))
                    case .waiting(let error), .failed(let error):
                        pending.resume(with: .failure(.network(error.debugDescription)))
                        self?.cancel()
                    case .cancelled:
                        pending.resume(with: .failure(.connectionClosed))
                    default:
                        break
                    }
                }
                start(queue: queue)
            }
        } onCancel: {
            pending.resume(with: .failure(.cancelled))
            cancel()
        }
    }

    /// Receives the next chunk of bytes, or `nil` when the peer closed the connection.
    func receiveChunk(maximumLength: Int = 64 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: RFBError.network(error.debugDescription))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Sends `data` and waits until Network.framework has processed it.
    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBError.network(error.debugDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
