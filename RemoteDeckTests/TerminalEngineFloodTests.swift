import AppKit
import Foundation
import Testing
@testable import RemoteDeck

// Review Focus 2 with the real engine: 50 MB of shell output in 64 KB chunks, through the session's
// coalescer and the libghostty-vt adapter (parsed in capped slices across frames). The main actor is
// never blocked for 50 ms, and every byte reaches the parser.
@MainActor
struct TerminalEngineFloodTests {
    @Test(.timeLimit(.minutes(2)))
    func floodThroughTheRealEngineNeverBlocksTheMainActor() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model(attaching: false)
        let surface = GhosttyTerminalSurface()
        model.attach(surface)
        surface.view.setFrameSize(NSSize(width: 1000, height: 700))   // a real grid, about 120 × 40
        model.connect()
        try await harness.connected(model)
        let shell = try #require(harness.last).shell

        // `yes`-like and log-like lines (wrapping, colours, scrolling), 64 KB per chunk.
        var pattern = ""
        var n = 0
        while pattern.utf8.count < 64 * 1024 {
            pattern += n % 5 == 0 ? "\u{1B}[32m\(n) INFO\u{1B}[0m request served in \(n % 97) ms path=/api/v1/items/\(n)\r\n" : "y\r\n"
            n += 1
        }
        let chunk = Data(pattern.utf8.prefix(64 * 1024))
        let chunks = 800
        let total = chunk.count * chunks   // 52 428 800 bytes

        let beat = Heartbeat()
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while beat.ticking {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                beat.longestGap = max(beat.longestGap, now - last)
                last = now
            }
        }
        let start = ContinuousClock.now
        let producer = Task.detached {
            for _ in 0..<chunks { shell.emit(chunk) }
        }
        #expect(await waitUntil(timeout: .seconds(90)) { surface.parsedBytes == total })
        let elapsed = ContinuousClock.now - start
        beat.ticking = false
        await heartbeat.value
        await producer.value

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let throughput = Double(total) / seconds / 1_000_000
        print("[flood] \(total) bytes in \(elapsed), \(String(format: "%.1f", throughput)) MB/s, "
              + "\(surface.framesRun) frames, peak queued \(surface.peakPendingBytes) bytes, "
              + "longest main-actor gap \(beat.longestGap)")
        #expect(surface.parsedBytes == total)
        #expect(surface.pendingBytes == 0)
        #expect(beat.longestGap < .milliseconds(50), "main actor blocked \(beat.longestGap)")
        await model.close()
        #expect(try harness.records().first?.bytesReceived == Int64(total))
    }
}
