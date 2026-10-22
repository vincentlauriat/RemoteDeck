import Foundation
import Network
import Testing
@testable import RFBKit

/// In-process fake RFB server on 127.0.0.1 that plays a scripted handshake and records what the
/// client sends, so the `NWConnection` driver can be checked end to end without a real Mac.
///
/// Read the transcript with `received(within:)`, never by awaiting `transcript` directly: if the
/// client fails before it reaches the server (or stops talking), the script waits for bytes that
/// never come, and only a bounded wait turns that into a failure instead of a hung test run.
final class FakeRFBServer: Sendable {
    enum Failure: Error, Equatable {
        /// No client connected before the server was stopped.
        case noClient
        /// `received(within:)` gave up: the script was still waiting.
        case timedOut(Duration)
    }

    enum Step: Sendable {
        case send([UInt8])
        /// Read exactly this many bytes from the client and record them.
        case receive(Int)
        /// Close the connection.
        case close
        /// Keep the connection open without sending anything.
        case stall
        /// Wait until the client closes the socket (EOF or error); records an empty blob.
        case expectClose
        /// Drop the connection abruptly (`forceCancel`), aiming for a TCP reset.
        case reset
    }

    let listener: NWListener
    let port: UInt16
    /// Blobs received for each `.receive` step, in order.
    let transcript: Task<[[UInt8]], any Error>

    init(script: [Step]) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "FakeRFBServer")
        let (connections, continuation) = AsyncStream.makeStream(of: NWConnection.self)
        listener.newConnectionHandler = { continuation.yield($0) }

        port = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
            let once = OnceContinuation(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(with: .success(listener.port?.rawValue ?? 0))
                case .failed(let error): once.resume(with: .failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener

        transcript = Task {
            var iterator = connections.makeAsyncIterator()
            // Ends with nil when the task is cancelled (`stop`).
            guard let connection = await iterator.next() else { throw Failure.noClient }
            // NWConnection callbacks ignore task cancellation: cancelling the connection is what
            // completes a pending receive or send once `stop` cancels this task.
            return try await withTaskCancellationHandler {
                try await Self.play(script, on: connection, queue: queue)
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private static func play(_ script: [Step], on connection: NWConnection,
                             queue: DispatchQueue) async throws -> [[UInt8]] {
        try await connection.startAndWaitUntilReady(queue: queue)
        var received: [[UInt8]] = []
        var pending: [UInt8] = []
        for step in script {
            switch step {
            case .send(let bytes):
                try await connection.sendAll(Data(bytes))
            case .receive(let count):
                while pending.count < count {
                    guard let chunk = try await connection.receiveChunk() else { throw RFBError.connectionClosed }
                    pending += chunk
                }
                received.append(Array(pending.prefix(count)))
                pending.removeFirst(count)
            case .close:
                connection.cancel()
                return received
            case .stall:
                try await Task.sleep(for: .seconds(5))
            case .expectClose:
                while true {
                    guard let chunk = try? await connection.receiveChunk() else { break }
                    if chunk.isEmpty { continue }
                }
                received.append([])
                connection.cancel()
                return received
            case .reset:
                connection.forceCancel()
                return received
            }
        }
        // Let the client read the last bytes before the socket goes away.
        try await Task.sleep(for: .milliseconds(200))
        connection.cancel()
        return received
    }

    /// The bytes received for each `.receive` step, once the script has run. Stops the server and
    /// throws `Failure.timedOut` if it has not finished within `timeout`. Cancelling the caller (the
    /// suite's time limit) stops the server too: awaiting `transcript.value` alone would ignore it.
    func received(within timeout: Duration = .seconds(20)) async throws -> [[UInt8]] {
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            stop()
        }
        do {
            let received = try await withTaskCancellationHandler {
                try await transcript.value
            } onCancel: {
                stop()
            }
            watchdog.cancel()
            return received
        } catch {
            watchdog.cancel()
            if case .success = await watchdog.result { throw Failure.timedOut(timeout) }
            throw error
        }
    }

    func stop() {
        transcript.cancel()
        listener.cancel()
    }
}

/// Loopback suites carry a time limit: a hang becomes a failure instead of a stuck CI run.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RFBConnectionTests {
    static let vnc = AuthVectors.vnc[0]
    static let dh = AuthVectors.appleDH.first { $0.keyLength == 128 }!
    /// Loopback handshakes take ~0.2 s; the generous deadline keeps a loaded CI runner from flaking.
    static let generousTimeout = Duration.seconds(30)

    @Test func vncAuthOverLoopback() async throws {
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .send([2, 1, 2]), .receive(1),
            .send([UInt8](hex: Self.vnc.challenge)), .receive(16),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "loopback") + [2]),
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        let result = try await connection.open(credentials: RFBCredentials(password: Self.vnc.password),
                                               timeout: Self.generousTimeout)
        #expect(result.serverInit.name == "loopback")
        #expect(result.securityType == 2)
        let received = try await server.received()
        #expect(received == [Array("RFB 003.008\n".utf8), [2], [UInt8](hex: Self.vnc.response), [1]])
        await connection.close()
    }

    @Test func appleDHOverLoopback() async throws {
        let vector = Self.dh
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.889\n")), .receive(12),
            .send([2, 2, 30]), .receive(1),
            .send(vector.serverParametersMessage), .receive(128 + vector.keyLength),
            .send(ServerMessage.securityResult(0)), .receive(1),
            .send(ServerMessage.serverInit(name: "minim6")),
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        let result = try await connection.open(credentials: vector.credentials, timeout: Self.generousTimeout,
                                               entropy: vector.entropy)
        #expect(result.securityType == 30)
        #expect(result.serverVersion == ProtocolVersion(major: 3, minor: 889))
        let received = try await server.received()
        #expect(received == [Array("RFB 003.008\n".utf8), [30], vector.expectedClientResponse, [1]])
        await connection.close()
    }

    @Test func wrongPasswordIsCleanAuthFailure() async throws {
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .send([1, 2]), .receive(1),
            .send([UInt8](hex: Self.vnc.challenge)), .receive(16),
            .send(ServerMessage.securityResult(1) + ServerMessage.string("Authentication failure")),
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.authFailed(reason: "Authentication failure")) {
            try await connection.open(credentials: RFBCredentials(password: "wrong"), timeout: Self.generousTimeout)
        }
        let received = try await server.received()
        #expect(received[2] != [UInt8](hex: Self.vnc.response))  // the wrong password gave another response
    }

    @Test func serverClosingAfterCredentialsIsAuthFailure() async throws {
        let vector = Self.dh
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.889\n")), .receive(12),
            .send([1, 30]), .receive(1),
            .send(vector.serverParametersMessage), .receive(128 + vector.keyLength),
            .close,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.authFailed(reason: nil)) {
            try await connection.open(credentials: vector.credentials, timeout: Self.generousTimeout, entropy: vector.entropy)
        }
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await FakeRFBServer(script: [.stall])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        let start = ContinuousClock.now
        await #expect(throws: RFBError.timeout) {
            try await connection.open(credentials: .none, timeout: .milliseconds(300))
        }
        // Fails only if the deadline is ignored; loose so a loaded runner cannot flake.
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func refusedConnectionFailsFastWithoutWaitingForTimeout() async throws {
        // Bind a port, then release it so nothing listens there.
        let placeholder = try await FakeRFBServer(script: [])
        let port = placeholder.port
        placeholder.stop()
        try await Task.sleep(for: .milliseconds(100))

        let connection = RFBConnection(host: "127.0.0.1", port: port)
        let start = ContinuousClock.now
        do {
            _ = try await connection.open(credentials: .none, timeout: Self.generousTimeout)
            Issue.record("expected the connection to be refused")
        } catch {
            #expect(error != .timeout)
            guard case .network = error else {
                Issue.record("expected a network error, got \(error)")
                return
            }
        }
        // A `.network` error (not `.timeout`) already proves the deadline was not awaited.
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func cancellingMidHandshakeClosesPromptly() async throws {
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .expectClose,  // server then stays silent until the client hangs up
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        // Untyped task closure: a typed-throws `Task` closure crashes the Swift 6.4 compiler (IRGen).
        let task = Task { try await connection.open(credentials: .none, timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let result = await task.result
        let latency = ContinuousClock.now - cancelledAt
        print("cancellation latency: \(latency)")

        #expect(throws: RFBError.cancelled) { _ = try result.get() }
        #expect(latency < .seconds(2))
        #expect(await connection.isOpen == false)
        let received = try await server.received()
        #expect(received == [Array("RFB 003.008\n".utf8), []])  // [] = the server saw the socket close
    }

    @Test func resetAfterCredentialsIsAuthFailure() async throws {
        let server = try await FakeRFBServer(script: [
            .send(ServerMessage.banner("RFB 003.008\n")), .receive(12),
            .send([1, 2]), .receive(1),
            .send([UInt8](hex: Self.vnc.challenge)), .receive(16),
            .reset,
        ])
        defer { server.stop() }

        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        await #expect(throws: RFBError.authFailed(reason: nil)) {
            try await connection.open(credentials: RFBCredentials(password: "wrong"), timeout: Self.generousTimeout)
        }
    }

    /// The RST path does not depend on whether `forceCancel` really sends a reset: the mapping itself.
    @Test func failureMappingPriorities() throws {
        var afterCredentials = RFBHandshake(credentials: RFBCredentials(password: "x"))
        _ = try afterCredentials.receive(ServerMessage.banner("RFB 003.008\n") + [1, 2] + [UInt8](hex: Self.vnc.challenge))
        let reset = RFBError.network("POSIXErrorCode(rawValue: 54): Connection reset by peer")
        #expect(RFBConnection.failure(reset, handshake: afterCredentials, expired: false, cancelled: false)
            == .authFailed(reason: nil))
        #expect(RFBConnection.failure(reset, handshake: afterCredentials, expired: true, cancelled: false) == .timeout)
        #expect(RFBConnection.failure(reset, handshake: afterCredentials, expired: true, cancelled: true) == .cancelled)

        var beforeCredentials = RFBHandshake(credentials: .none)
        _ = try beforeCredentials.receive(ServerMessage.banner("RFB 003.008\n"))
        #expect(RFBConnection.failure(reset, handshake: beforeCredentials, expired: false, cancelled: false) == reset)
        // A real auth failure stays an auth failure, never a timeout, once frozen as not expired.
        #expect(RFBConnection.failure(RFBError.authFailed(reason: "bad"), handshake: afterCredentials,
                                      expired: false, cancelled: false) == .authFailed(reason: "bad"))
    }
}
