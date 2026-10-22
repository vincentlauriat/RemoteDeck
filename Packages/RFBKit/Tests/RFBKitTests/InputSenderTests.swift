import Foundation
import os
import Testing
@testable import RFBKit

private func move(_ mask: UInt8, _ x: UInt16) -> ClientMessage { .pointerEvent(buttonMask: mask, x: x, y: 0) }

struct InputQueueTests {
    @Test func movesCollapseToTheLatest() {
        var queue = InputQueue()
        for x in 0..<100 { queue.append(move(0, UInt16(x))) }
        #expect(queue.take() == [move(0, 99)])
    }

    @Test func buttonTransitionsAndKeysAreNeverMerged() {
        var queue = InputQueue()
        let messages: [ClientMessage] = [
            move(0, 1), move(0, 2),            // moves → 2
            move(1, 2),                        // press
            move(1, 3), move(1, 4),            // drag → 4
            .keyEvent(down: true, key: 0x61),
            move(1, 5), move(1, 6),            // drag after a key: a new tail → 6
            move(0, 6),                        // release
            move(8, 6), move(0, 6),            // scroll step: press + release, same position
            move(8, 6), move(0, 6),            // second step
            move(0, 7), move(0, 8),            // moves → 8
        ]
        for message in messages { queue.append(message) }
        #expect(queue.take() == [move(0, 2), move(1, 2), move(1, 4), .keyEvent(down: true, key: 0x61), move(1, 6),
                                 move(0, 6), move(8, 6), move(0, 6), move(8, 6), move(0, 6), move(0, 8)])
    }

    @Test func aTakenMoveIsNotReplaced() {
        var queue = InputQueue()
        queue.append(move(0, 1))
        #expect(queue.take() == [move(0, 1)])
        queue.append(move(0, 2))
        #expect(queue.take() == [move(0, 2)])
    }
}

/// Collects what an `InputSender` hands to its `send` closure.
private final class SendLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (batches: [[ClientMessage]](), times: [ContinuousClock.Instant]()))

    func record(_ batch: [ClientMessage]) {
        let now = ContinuousClock.now
        state.withLock {
            $0.batches.append(batch)
            $0.times += Array(repeating: now, count: batch.count)
        }
    }

    var batches: [[ClientMessage]] { state.withLock { $0.batches } }
    var times: [ContinuousClock.Instant] { state.withLock { $0.times } }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InputSenderTests {
    @Test func movesQueuedDuringASlowWriteCollapse() async throws {
        let log = SendLog()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let sender = InputSender { batch in
            log.record(batch)
            if log.batches.count == 1 {
                signalStarted.yield()
                var iterator = gate.makeAsyncIterator()
                _ = await iterator.next()   // the first write is slow
            }
        }
        sender.enqueue([move(1, 0)])
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        for x in 1...500 { sender.enqueue([move(1, UInt16(x))]) }
        sender.enqueue([move(0, 500), .keyEvent(down: true, key: 0x61)])
        open.yield()
        sender.finish()
        await sender.stopped()
        #expect(log.batches == [[move(1, 0)], [move(1, 500), move(0, 500), .keyEvent(down: true, key: 0x61)]])
    }

    @Test func aFailedWriteStopsTheSender() async {
        let log = SendLog()
        let sender = InputSender { batch in
            log.record(batch)
            throw RFBError.connectionClosed
        }
        sender.enqueue([.keyEvent(down: true, key: 1)])
        await sender.stopped()
        sender.enqueue([.keyEvent(down: true, key: 2)])
        #expect(log.batches == [[.keyEvent(down: true, key: 1)]])
    }

    /// T3.3 latency budget (TRD › Performance: event → bytes sent ≤ 50 ms), measured from `enqueue` to
    /// the completion of the `NWConnection` write over loopback, for 60 events 2 ms apart (key
    /// presses, releases and pointer transitions, which are never coalesced). The bound asserted is
    /// loose so a loaded CI runner cannot flake; the measured values are printed.
    @Test func enqueueToWriteLatencyOverLoopback() async throws {
        let events: [ClientMessage] = (0..<60).map { (index: Int) -> ClientMessage in
            if index.isMultiple(of: 2) { return .keyEvent(down: index % 4 == 0, key: 0x61) }
            let mask: UInt8 = index % 4 == 1 ? 1 : 0
            return .pointerEvent(buttonMask: mask, x: UInt16(index), y: 7)
        }
        let byteCount = events.reduce(0) { $0 + $1.wireBytes.count }
        let server = try await FakeRFBServer(script: SessionLoopbackTests.handshake(width: 64, height: 64) + [
            .receive(byteCount),
        ])
        defer { server.stop() }
        let connection = RFBConnection(host: "127.0.0.1", port: server.port)
        _ = try await connection.open(credentials: .none, timeout: SessionLoopbackTests.timeout)

        let log = SendLog()
        let sender = InputSender { batch in
            try await connection.send(batch)
            log.record(batch)
        }
        var enqueued: [ContinuousClock.Instant] = []
        for event in events {
            enqueued.append(.now)
            sender.enqueue([event])
            try await Task.sleep(for: .milliseconds(2))
        }
        sender.finish()
        await sender.stopped()

        let received = try await server.received()
        #expect(received.last == events.flatMap(\.wireBytes))   // after the handshake blobs, in order
        let sent = log.times
        try #require(sent.count == events.count)
        let latencies = zip(enqueued, sent).map { ($1 - $0) / .microseconds(1) }.sorted()
        let p50 = latencies[latencies.count / 2], p95 = latencies[latencies.count * 95 / 100], worst = latencies.last!
        print(String(format: "input-latency enqueue→written over loopback: p50=%.0f µs p95=%.0f µs max=%.0f µs (n=%d)",
                     p50, p95, worst, latencies.count))
        #expect(p50 < 50_000)
        await connection.close()
    }
}
