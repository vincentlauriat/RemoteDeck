import Foundation
import Network
import dnssd
import os
import Testing
@testable import RFBKit

/// Accepts every loopback connection and keeps it open, silent.
final class LoopbackAcceptor: Sendable {
    let listener: NWListener
    let port: UInt16

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LoopbackAcceptor")
        listener.newConnectionHandler = { $0.start(queue: queue) }
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
    }

    func stop() { listener.cancel() }
}

/// Runs `count` operations, each cancelled at once or after a random 0–60 µs, 50 at a time (thousands of
/// loopback connections at once would slow the other suites down), and returns how many had not
/// finished (stopping at the first batch with one): a lost cancellation hangs forever, so each batch waits at most `batchDeadline` and the
/// hung tasks are left behind rather than awaited.
func unfinishedAfterRandomCancel(count: Int, batchDeadline: Duration = .seconds(2),
                                 _ operation: @escaping @Sendable () async -> Void) async -> Int {
    let finished = OSAllocatedUnfairLock(initialState: 0)
    var launched = 0
    var hung = 0
    while launched < count {
        let batch = min(50, count - launched)
        for _ in 0..<batch {
            let task = Task {
                await operation()
                finished.withLock { $0 += 1 }
            }
            // Half are cancelled before they even start (onCancel runs before the state handler
            // exists: the deterministic case), the others after a random 0–60 µs.
            if Bool.random() {
                task.cancel()
            } else {
                usleep(UInt32.random(in: 0...60))
                task.cancel()
            }
        }
        launched += batch
        let end = ContinuousClock.now + batchDeadline
        while finished.withLock({ $0 }) + hung < launched, ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
        hung = launched - finished.withLock { $0 }
        if hung > 0 { return hung }   // one lost cancellation is enough
    }
    return 0
}

/// `TCPProbe` against in-process loopback servers only (never a real host).
@Suite(.timeLimit(.minutes(1)))
struct TCPProbeTests {
    /// An open port answers, and the probe closes the connection at once without sending a byte:
    /// the server's first read hits EOF (`.connectionClosed`), not data.
    @Test func openPortIsReachableAndClosedAtOnceWithoutAByte() async throws {
        let server = try await FakeRFBServer(script: [.receive(1)])
        let start = ContinuousClock.now
        let outcome = await TCPProbe.probe(host: "127.0.0.1", port: server.port)
        #expect(outcome == .reachable)
        await #expect(throws: RFBError.connectionClosed) {
            _ = try await server.received(within: .seconds(5))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// Nothing listens any more (Screen Sharing turned off): refused, fast.
    @Test func closedPortIsUnreachable() async throws {
        let server = try await FakeRFBServer(script: [])
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        #expect(await TCPProbe.probe(host: "127.0.0.1", port: port) == .unreachable)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func portZeroAndCancelledCallerAreUnreachable() async {
        #expect(await TCPProbe.probe(host: "127.0.0.1", port: 0) == .unreachable)
        let task = Task { () -> TCPProbe.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await TCPProbe.probe(host: "127.0.0.1", port: 5900)
        }
        #expect(await task.value == .unreachable)
    }

    @Test func localNetworkRefusalIsToldApart() {
        #expect(TCPProbe.classify(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)), path: nil) == .localNetworkDenied)
        #expect(TCPProbe.classify(.posix(.ECONNREFUSED), path: nil) == .unreachable)
        #expect(TCPProbe.classify(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)), path: nil) == .unreachable)
    }
}

/// Review M1: a cancel landing before the state handler is installed must still end the attempt.
/// Serialized: thousands of loopback connections at once would slow the other tests down.
/// 100 cancellations by default; the full 2000-run stress only with `RFBKIT_PERF=1`. At 2000 it
/// saturates the CPU while the wall-clock loopback suites run in parallel, and makes them flaky.
/// The deterministic proof of the cancel-before-start fix is `aResultBeforeTheWaiterIsDelivered`.
let cancelRaceCount = perfTestsEnabled ? 2000 : 100

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConnectionCancelRaceTests {
    @Test func probesCancelledAtRandomTinyDelaysAllReturn() async throws {
        let acceptor = try await LoopbackAcceptor()
        defer { acceptor.stop() }
        let port = acceptor.port
        let unfinished = await unfinishedAfterRandomCancel(count: cancelRaceCount) {
            _ = await TCPProbe.probe(host: "127.0.0.1", port: port)
        }
        #expect(unfinished == 0, "\(unfinished) of \(cancelRaceCount) did not return")
    }

    /// The shared helper behind `RFBConnection.open`.
    @Test func openCancelledAtRandomTinyDelaysAlwaysReturns() async throws {
        let acceptor = try await LoopbackAcceptor()
        defer { acceptor.stop() }
        let port = acceptor.port
        let unfinished = await unfinishedAfterRandomCancel(count: cancelRaceCount) {
            let connection = RFBConnection(host: "127.0.0.1", port: port)
            _ = try? await connection.open(credentials: RFBCredentials(password: ""), timeout: .seconds(30))
        }
        #expect(unfinished == 0, "\(unfinished) of \(cancelRaceCount) did not return")
    }
}

/// Review M1, deterministic part: the result reaches the waiter whichever side comes first, once.
struct PendingResultTests {
    @Test func aResultBeforeTheWaiterIsDelivered() async throws {
        let pending = PendingResult<Int>()
        pending.resume(with: .failure(.cancelled))   // the cancellation handler ran first
        pending.resume(with: .success(1))            // a late state update: ignored
        await #expect(throws: RFBError.cancelled) {
            try await withCheckedThrowingContinuation { pending.attach($0) }
        }
    }

    @Test func aResultAfterTheWaiterIsDeliveredOnce() async throws {
        let pending = PendingResult<Int>()
        async let value = withCheckedThrowingContinuation { pending.attach($0) }
        try await Task.sleep(for: .milliseconds(20))
        pending.resume(with: .success(7))
        pending.resume(with: .failure(.cancelled))
        #expect(try await value == 7)
    }
}
