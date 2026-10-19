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

extension NWConnection {
    /// Starts the connection and waits until it is ready.
    ///
    /// `.waiting` is treated as a failure: Network.framework enters it on ECONNREFUSED or an
    /// unreachable host and would otherwise retry until the deadline.
    func startAndWaitUntilReady(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OnceContinuation(continuation)
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case .waiting(let error), .failed(let error):
                    once.resume(with: .failure(RFBError.network(error.debugDescription)))
                    self?.cancel()
                case .cancelled:
                    once.resume(with: .failure(RFBError.connectionClosed))
                default:
                    break
                }
            }
            start(queue: queue)
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
