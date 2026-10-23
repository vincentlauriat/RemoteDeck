import Foundation
import Testing
@testable import RFBKit

/// Inputs found by `ParserFuzzTests` (T5.5), minimised, with the exact bytes.
struct FuzzRegressionTests {
    /// Region pixels returned by one `receive`, summed over its updates.
    static func copiedPixels(_ events: [RFBEvent]) -> Int {
        events.reduce(0) { total, event in
            guard case .framebufferUpdate(let update) = event else { return total }
            return total + update.regions.reduce(0) { $0 + $1.pixels.count }
        }
    }

    /// Applies the events to a copy, as a consumer does (resizes keep the top-left content).
    static func display(_ events: [RFBEvent], from start: Framebuffer) throws -> Framebuffer {
        var display = start
        for event in events {
            switch event {
            case .desktopResized(let width, let height):
                try display.resize(width: width, height: height)
            case .framebufferUpdate(let update):
                for region in update.regions {
                    for row in 0..<region.rect.height {
                        let start = (region.rect.y + row) * display.width + region.rect.x
                        let line = region.pixels[(row * region.rect.width)..<((row + 1) * region.rect.width)]
                        display.pixels.replaceSubrange(start..<(start + region.rect.width), with: line)
                    }
                }
            default:
                break
            }
        }
        return display
    }

    /// One FramebufferUpdate holding one full-frame Tight fill: 20 bytes.
    static func fullFrameFill(width: Int, height: Int, colour: UInt8) -> [UInt8] {
        FramebufferMessage.update(FramebufferMessage.rect(0, 0, width, height, encoding: Encoding.tight)
                                  + [0x80, colour, colour, colour])
    }

    /// Fuzzer seed 0x7535202610230001, decoder-grammar (the "flood" message): every 20-byte update
    /// repainting the whole screen became its own event with its own copy of the framebuffer, so one
    /// 64 KiB network chunk returned 3276 copies — 26 GiB at 1920 × 1080, enough to get the app killed.
    /// One call now copies at most `maxCopiedFramebuffersPerCall` framebuffers; the updates past that
    /// are merged into one, so the consumer still ends on the right picture and requests the next one.
    @Test func aFloodOfFullFrameUpdatesIsMergedWithinTheCopyBudget() throws {
        let (width, height) = (64, 64)
        var decoder = try ServerMessageDecoder(width: width, height: height)
        let chunk = (0..<(65536 / 20)).flatMap { Self.fullFrameFill(width: width, height: height, colour: UInt8($0 & 0xFF)) }
        let events = try decoder.receive(chunk)
        #expect(Self.copiedPixels(events) <= ServerMessageDecoder.maxCopiedFramebuffersPerCall * width * height)
        #expect(try Self.display(events, from: Framebuffer(width: width, height: height)) == decoder.framebuffer)
        guard case .framebufferUpdate(let last)? = events.last else {
            Issue.record("the call does not end with an update")
            return
        }
        #expect(last.completesMessage)   // so `RFBSessionEvents` asks for the next update
        #expect(decoder.pendingRegionCount == 0)
    }

    /// The minimised input (from decoder-grammar index 240, a 1 × 1 framebuffer): five 20-byte updates
    /// of one full-frame Tight fill each, in one chunk. Five framebuffer copies came out; the budget is four.
    @Test func minimisedFloodOnOnePixel() throws {
        let update: [UInt8] = [0x00, 0x00, 0x00, 0x01,                          // FramebufferUpdate, 1 rectangle
                               0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01,  // 0,0 1x1
                               0x00, 0x00, 0x00, 0x07,                          // Tight
                               0x80, 0x01, 0x02, 0x03]                          // fill R 1, G 2, B 3
        var decoder = try ServerMessageDecoder(width: 1, height: 1)
        let events = try decoder.receive(Array([[UInt8]](repeating: update, count: 5).joined()))
        #expect(Self.copiedPixels(events) <= ServerMessageDecoder.maxCopiedFramebuffersPerCall)
        #expect(events.last == .framebufferUpdate(FramebufferUpdate(
            width: 1, height: 1, regions: [.init(rect: RFBRect(x: 0, y: 0, width: 1, height: 1), pixels: [0xFF01_0203])])))
    }

    /// Same flood with a DesktopSize between fills: each resize handed out the regions decoded so far
    /// (a framebuffer copy per 32 bytes). Past the budget they are dropped for one full-frame update
    /// of the final size.
    @Test func aFloodOfResizesIsMergedWithinTheCopyBudget() throws {
        var decoder = try ServerMessageDecoder(width: 64, height: 64)
        var chunk: [UInt8] = []
        for index in 0..<2000 {
            let height = 64 - index % 2
            chunk += FramebufferMessage.update(
                FramebufferMessage.rect(0, 0, 64, height, encoding: Encoding.tight) + [0x80, 9, 9, UInt8(index & 0xFF)],
                FramebufferMessage.rect(0, 0, 64, 127 - height, encoding: Encoding.desktopSize))
        }
        let events = try decoder.receive(chunk)
        #expect(Self.copiedPixels(events) <= ServerMessageDecoder.maxCopiedFramebuffersPerCall * 64 * 64)
        #expect(try Self.display(events, from: Framebuffer(width: 64, height: 64)) == decoder.framebuffer)
        #expect(events.filter { if case .desktopResized = $0 { true } else { false } }.count == 2000)
        #expect(decoder.pendingRegionCount == 0)
    }

    /// What stays accepted (TRD › Security › Hostile server input): a resize reallocates the
    /// framebuffer, so 12-byte DesktopSize rectangles alternating near the cap cost CPU in proportion
    /// to the framebuffer, with memory still within the copy budget. Measures that cost; opt-in.
    @Test(.enabled(if: perfTestsEnabled, "set RFBKIT_PERF=1 to run timing tests"))
    func resizeFloodCostAtTheCap() throws {
        var decoder = try ServerMessageDecoder(width: 8192, height: 8192)
        let resizes = 20
        let chunk = [0, 0] + UInt16(resizes).bigEndianBytes + (0..<resizes).flatMap {
            FramebufferMessage.rect(0, 0, 8192, 8191 + $0 % 2, encoding: Encoding.desktopSize)
        }
        let clock = ContinuousClock()
        var events: [RFBEvent] = []
        let elapsed = try clock.measure { events = try decoder.receive(chunk) }
        print("resize flood at 8192 x 8192: \(resizes) resizes in \(elapsed), \(elapsed / resizes) each")
        #expect(events.filter { if case .desktopResized = $0 { true } else { false } }.count == resizes)
        #expect(Self.copiedPixels(events) <= ServerMessageDecoder.maxCopiedFramebuffersPerCall * 8192 * 8192)
    }

    /// A few updates in one call (a server answering queued requests) are still delivered one by
    /// one, each with its own pixels: merging starts only past the budget.
    @Test func updatesWithinTheBudgetAreNotMerged() throws {
        var decoder = try ServerMessageDecoder(width: 64, height: 64)
        let count = ServerMessageDecoder.maxCopiedFramebuffersPerCall - 1
        let chunk = (0..<count).flatMap { Self.fullFrameFill(width: 64, height: 64, colour: UInt8(1 + $0)) }
        let events = try decoder.receive(chunk)
        #expect(events.count == count)
        for (index, event) in events.enumerated() {
            guard case .framebufferUpdate(let update) = event else {
                Issue.record("event \(index) is not an update")
                continue
            }
            let colour = UInt32(1 + index)
            #expect(update.regions.map(\.pixels) == [[UInt32](repeating: 0xFF00_0000 | colour << 16 | colour << 8 | colour,
                                                                count: 64 * 64)])
        }
    }
}
