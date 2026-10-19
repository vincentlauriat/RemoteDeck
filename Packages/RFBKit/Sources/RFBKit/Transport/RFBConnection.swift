import Foundation
import Network
import os

/// Opens an RFB session over TCP: runs `RFBHandshake` on an `NWConnection` until ServerInit.
///
/// - The `timeout` covers the TCP connection *and* the whole handshake, so a server that accepts
///   the connection and then stays silent cannot hang the caller.
/// - Cancelling the calling task closes the connection at once and throws `RFBError.cancelled`.
/// - `RFBHandshake.receive` runs on a dedicated dispatch queue, not on the actor: Apple DH does
///   two modular exponentiations (up to ~1 s each for 2048 bits in a debug build) that would
///   otherwise block a thread of Swift's small cooperative pool.
public actor RFBConnection {
    public nonisolated let host: String
    public nonisolated let port: UInt16
    private let networkQueue = DispatchQueue(label: "RFBKit.RFBConnection.network")
    private let handshakeQueue = DispatchQueue(label: "RFBKit.RFBConnection.handshake", qos: .userInitiated)
    private var connection: NWConnection?
    /// Bytes received after ServerInit, kept for the framebuffer protocol (T3.1).
    private(set) var pendingBytes = Data()

    /// Whether a connection is currently held (open or being opened).
    var isOpen: Bool { connection != nil }

    public init(host: String, port: UInt16 = 5900) {
        self.host = host
        self.port = port
    }

    /// Connects and authenticates. On failure the connection is closed and a typed error thrown.
    public func open(credentials: RFBCredentials, shared: Bool = true, timeout: Duration = .seconds(10),
                     entropy: HandshakeEntropy = .system) async throws(RFBError) -> HandshakeResult {
        guard connection == nil else { throw .protocolViolation("connection already opened") }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw .network("invalid port \(port)") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection

        let deadline = Deadline()
        networkQueue.asyncAfter(deadline: .now() + timeout.timeInterval) {
            if deadline.expire() { connection.cancel() }
        }

        var handshake = RFBHandshake(credentials: credentials, shared: shared, entropy: entropy)
        let outcome: Result<HandshakeResult, any Error> = await withTaskCancellationHandler {
            do {
                try await connection.startAndWaitUntilReady(queue: networkQueue)
                while true {
                    guard !Task.isCancelled else { throw RFBError.cancelled }
                    guard let chunk = try await connection.receiveChunk() else {
                        throw handshake.errorForClosedConnection()
                    }
                    let step: HandshakeStep
                    (handshake, step) = try await Self.receive(chunk, into: handshake, on: handshakeQueue)
                    guard !Task.isCancelled else { throw RFBError.cancelled }
                    if !step.outgoing.isEmpty {
                        try await connection.sendAll(step.outgoing)
                    }
                    if let result = step.result {
                        return .success(result)
                    }
                }
            } catch {
                return .failure(error)
            }
        } onCancel: {
            connection.cancel()
        }

        // Freeze the race with the deadline once: whatever happens later cannot rewrite the outcome.
        let expired = !deadline.complete()
        let cancelled = Task.isCancelled
        switch outcome {
        case .success(let result) where !expired && !cancelled:
            pendingBytes = result.remainder
            return result
        case .success:
            release(connection)
            throw cancelled ? .cancelled : .timeout
        case .failure(let error):
            release(connection)
            throw Self.failure(error, handshake: handshake, expired: expired, cancelled: cancelled)
        }
    }

    /// Closes the connection.
    public func close() {
        connection?.cancel()
        connection = nil
    }

    /// Cancels `connection` and forgets it, unless `close()` and a newer `open()` already replaced it
    /// while this call was suspended (actor reentrancy).
    private func release(_ connection: NWConnection) {
        connection.cancel()
        if self.connection === connection { self.connection = nil }
    }

    /// The error reported for a failed `open`, by priority: cancellation, deadline, then the error
    /// itself. A transport error (e.g. ECONNRESET) right after the credentials were sent goes through
    /// the same EOF heuristic as a clean close (`RFBHandshake.errorForClosedConnection`).
    static func failure(_ error: any Error, handshake: RFBHandshake, expired: Bool, cancelled: Bool) -> RFBError {
        if cancelled { return .cancelled }
        if expired { return .timeout }
        let error = (error as? RFBError) ?? .network(String(describing: error))
        if case .network = error, case .authFailed = handshake.errorForClosedConnection() {
            return handshake.errorForClosedConnection()
        }
        return error
    }

    /// Runs `handshake.receive(chunk)` on `queue` and hands back the advanced state machine.
    private static func receive(_ chunk: Data, into handshake: RFBHandshake,
                                on queue: DispatchQueue) async throws -> (RFBHandshake, HandshakeStep) {
        let (advanced, result) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(RFBHandshake, Result<HandshakeStep, RFBError>), Never>) in
            queue.async {
                var handshake = handshake
                let result: Result<HandshakeStep, RFBError>
                do throws(RFBError) {
                    result = .success(try handshake.receive(chunk))
                } catch {
                    result = .failure(error)
                }
                continuation.resume(returning: (handshake, result))
            }
        }
        return (advanced, try result.get())
    }
}

/// One-shot race between the handshake completing and the timeout firing.
private final class Deadline: Sendable {
    private enum Outcome { case pending, completed, expired }
    private let outcome = OSAllocatedUnfairLock(initialState: Outcome.pending)

    /// Marks the deadline as passed; `true` if the handshake had not completed.
    func expire() -> Bool {
        outcome.withLock { outcome in
            guard outcome == .pending else { return false }
            outcome = .expired
            return true
        }
    }

    /// Marks the attempt as finished; `false` if the deadline had already passed.
    func complete() -> Bool {
        outcome.withLock { outcome in
            guard outcome == .pending else { return false }
            outcome = .completed
            return true
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
