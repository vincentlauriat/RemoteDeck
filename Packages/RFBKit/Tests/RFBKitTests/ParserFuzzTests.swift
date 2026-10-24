import Darwin
import Foundation
import Testing
@testable import RFBKit

/// T5.5: deterministic, structure-aware fuzzing of every parser that reads server bytes —
/// `RFBHandshake` (all versions and security types, hostile Apple DH groups), `ServerMessageDecoder`
/// (every encoding, DesktopSize, Cursor, cut text, Extended Clipboard), `ExtendedClipboard.parse`,
/// `TightDecoder.measure` and `Inflater`.
///
/// Default run: about 20 000 inputs in a few seconds. Full run (more than 1 000 000 inputs):
/// `RFBKIT_PERF=1 swift test -c release -Xswiftc -enable-testing --filter ParserFuzzTests`.
/// Replay: `RFBKIT_FUZZ_SEED`, `RFBKIT_FUZZ_START`, `RFBKIT_FUZZ_COUNT`; `RFBKIT_FUZZ_TRACE=1` names
/// each input on stderr before it runs (a trap ends the process, so the last line is the culprit).
///
/// Properties checked on every input, besides "does not trap":
/// - errors are typed: the decoder throws only `protocolViolation`; the handshake never a transport
///   error, and never one that prints the password;
/// - errors are sticky: after a throw, `receive([])` and `receive(more)` throw the same error, and the
///   decoder holds no buffered bytes;
/// - buffered bytes stay within the largest message the current framebuffer allows (decoder) or
///   `RFBHandshake.maxBufferedBytes`;
/// - memory per call is bounded: one `receive` returns region copies of at most
///   `ServerMessageDecoder.maxCopiedFramebuffersPerCall` framebuffers, every region lies inside its
///   update, an update's regions add up to at most one framebuffer, cursors and texts stay within
///   their caps;
/// - the consumer's picture is right: applying the events to a copy (resizes included) gives the
///   decoder's framebuffer whenever no region is pending;
/// - chunking does not matter: the same stream fed whole and in random chunks gives the same error,
///   the same non-update events and the same framebuffer (handshake: the same bytes sent, result and
///   remainder);
/// - every input finishes within `FuzzRunner.slowLimit` (the hang detector: nothing preempts a case).
///   `RFBKIT_FUZZ_SLOW_SECONDS` raises it (60 under AddressSanitizer, which slows modPow about 150×).
@Suite(.serialized)
struct ParserFuzzTests {
    @Test func decoderMutatedVectors() async throws {
        let log = try await FuzzRunner.run("decoder-vectors", quick: 4000, full: 300_000) { random, index, log in
            let seed = random.pick(FuzzCorpus.decoderSeeds)
            var sample = seed.sample
            Mutator.mutate(&sample, donors: FuzzCorpus.decoderSeeds.map(\.sample), &random)
            DecoderOracle.compareChunkings(sample, width: seed.width, height: seed.height, index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    @Test func decoderGrammar() async throws {
        let log = try await FuzzRunner.run("decoder-grammar", quick: 2500, full: 300_000) { random, index, log in
            let width = random.oneIn(10) ? 1 : random.int(1...200)
            let height = random.oneIn(10) ? 1 : random.int(1...150)
            var generator = DecoderStreamGenerator(width: width, height: height)
            var sample = generator.stream(&random)
            if random.oneIn(3) { Mutator.mutate(&sample, donors: [], &random) }
            DecoderOracle.compareChunkings(sample, width: width, height: height, index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    @Test func handshake() async throws {
        let log = try await FuzzRunner.run("handshake", quick: 2500, full: 150_000) { random, index, log in
            var fuzzCase = HandshakeGenerator.generate(&random)
            if random.oneIn(2) { Mutator.mutate(&fuzzCase.sample, donors: [], &random) }
            HandshakeOracle.compareChunkings(fuzzCase, index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    @Test func clipboard() async throws {
        let log = try await FuzzRunner.run("clipboard", quick: 3000, full: 150_000) { random, index, log in
            var sample = FuzzSample()
            for _ in 0..<random.int(1...3) {
                sample.boundary()
                if random.oneIn(2) {
                    var seed = random.pick(FuzzCorpus.clipboardSeeds)
                    Mutator.mutate(&seed, donors: FuzzCorpus.clipboardSeeds, &random)
                    sample.append(seed)
                } else {
                    sample.append(ClipboardGenerator.extendedMessage(&random))
                }
            }
            if random.oneIn(2) {
                sample.boundary()
                sample.u8(2, .type)   // a Bell after: a dropped message must not desynchronise the stream
            }
            ClipboardOracle.check(sample, index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    @Test func randomBytes() async throws {
        let log = try await FuzzRunner.run("random-bytes", quick: 6000, full: 100_000) { random, index, log in
            RandomBytesOracle.check(index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    @Test func inflater() async throws {
        let log = try await FuzzRunner.run("inflater", quick: 1000, full: 30_000) { random, index, log in
            InflaterOracle.check(index: index, &log, &random)
        }
        FuzzRunner.report(log)
    }

    /// Framebuffers near the size caps (up to 256 MiB of pixels): hostile rectangles and floods of
    /// full-frame updates must stay within the documented memory bounds. Few inputs: each allocates.
    @Test func largeFramebuffers() async throws {
        // The quick run takes the first three (a debug build needs seconds per 256 MiB framebuffer).
        let sizes = [(1920, 1080), (4096, 4096), (16384, 1), (1, 16384), (8192, 8192), (16384, 4096)]
        let log = try await FuzzRunner.run("large-framebuffers", quick: 3, full: 120, maxCount: 120,
                                           slowLimit: .seconds(60)) { random, index, log in
            let (width, height) = sizes[index % sizes.count]
            var generator = DecoderStreamGenerator(width: width, height: height)
            generator.maxDimension = 16384
            var sample = FuzzSample()
            if random.oneIn(2) { generator.flood(&sample, &random) }
            sample.append(generator.stream(&random, messages: random.int(1...3)))
            if random.oneIn(3) { Mutator.mutate(&sample, donors: [], &random) }
            var chunks = Mutator.chunks(sample, &random)
            if chunks.count > 64 { chunks = [sample.bytes] }
            _ = DecoderOracle.run(width: width, height: height, chunks: chunks, index: index, &log, &random,
                                  keepEvents: false)
        }
        FuzzRunner.report(log)
    }
}

// MARK: Runner

/// What one fuzz loop saw: counts, the slowest input and the failures (only the first few are kept).
struct FuzzLog: Sendable {
    let target: String
    var inputs = 0
    var rejected = 0
    var events: [String: Int] = [:]
    var failureCount = 0
    var failures: [String] = []
    var slowestIndex = 0
    var slowest = Duration.zero
    var maxBuffered = 0
    var maxCopiedFramebuffers = 0.0
    var elapsed = Duration.zero

    init(target: String) { self.target = target }

    mutating func fail(_ index: Int, _ message: String) {
        failureCount += 1
        if failures.count < 12 {
            failures.append("fuzz \(target) seed 0x\(String(FuzzConfig.seed, radix: 16)) index \(index): \(message)")
        }
    }

    mutating func saw(_ event: RFBEvent) {
        let name = switch event {
        case .framebufferUpdate: "update"
        case .desktopResized: "resize"
        case .bell: "bell"
        case .serverCutText: "cutText"
        case .extendedClipboard: "extendedClipboard"
        case .cursor: "cursor"
        }
        events[name, default: 0] += 1
    }
}

enum FuzzRunner {
    /// An input slower than this is reported as a hang (generous: debug builds and sanitizers).
    static let slowLimit = Duration.seconds(Double(FuzzConfig.environment["RFBKIT_FUZZ_SLOW_SECONDS"] ?? "") ?? 5)

    /// `maxCount` caps `RFBKIT_FUZZ_COUNT` for targets whose inputs are expensive.
    static func run(_ target: String, quick: Int, full: Int, maxCount: Int = .max,
                    slowLimit: Duration = FuzzRunner.slowLimit,
                    _ body: @escaping @Sendable (inout FuzzRandom, Int, inout FuzzLog) -> Void) async throws -> FuzzLog {
        let count = min(FuzzConfig.count(quick: quick, full: full), maxCount)
        let start = FuzzConfig.start
        // CPU-bound: off the cooperative pool, so loopback suites running in parallel keep their threads.
        return try await offCooperativePool {
            var log = FuzzLog(target: target)
            let clock = ContinuousClock()
            let began = clock.now
            for index in start..<(start + count) {
                if FuzzConfig.trace { FileHandle.standardError.write(Data("fuzz \(target) \(index)\n".utf8)) }
                var random = FuzzRandom(seed: FuzzRandom.caseSeed(master: FuzzConfig.seed, target: target, index: index))
                let caseStart = clock.now
                body(&random, index, &log)
                let duration = clock.now - caseStart
                if duration > log.slowest { (log.slowest, log.slowestIndex) = (duration, index) }
                if duration > slowLimit { log.fail(index, "took \(duration) (limit \(slowLimit))") }
                log.inputs += 1
            }
            log.elapsed = clock.now - began
            return log
        }
    }

    static func report(_ log: FuzzLog) {
        let events = log.events.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let footprint = Footprint.current().map { "footprint \($0.current >> 20) MiB, peak \($0.peak >> 20) MiB" } ?? ""
        print("fuzz \(log.target): \(log.inputs) inputs from #\(FuzzConfig.start), seed 0x\(String(FuzzConfig.seed, radix: 16)), "
              + "\(log.elapsed); rejected \(log.rejected); events: \(events); slowest #\(log.slowestIndex) \(log.slowest); "
              + "max buffered \(log.maxBuffered) B; max copied per call \(String(format: "%.2f", log.maxCopiedFramebuffers)) "
              + "framebuffers; \(footprint); failures \(log.failureCount)")
        for failure in log.failures { Issue.record(Comment(rawValue: failure)) }
        if log.failureCount > log.failures.count {
            Issue.record(Comment(rawValue: "fuzz \(log.target): \(log.failureCount - log.failures.count) more failures"))
        }
    }
}

/// Physical footprint of the test process (the figure jetsam and Activity Monitor use).
enum Footprint {
    static func current() -> (current: UInt64, peak: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}

// MARK: Decoder

struct DecoderRun {
    var events: [RFBEvent] = []
    var error: RFBError?
    var framebuffer: Framebuffer?
}

enum DecoderOracle {
    /// Largest number of bytes the decoder may hold unparsed for `framebuffer`: the largest single
    /// message or rectangle it accepts (each length is checked before its payload is awaited).
    static func pendingBound(_ framebuffer: Framebuffer) -> Int {
        let pixels = framebuffer.width * framebuffer.height
        let full = RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
        let tightBasic = 3 * pixels + (3 * pixels >> 12) + (3 * pixels >> 14) + (3 * pixels >> 25) + 13 + 64
        return [
            12 + 4 * pixels,                                                   // Raw
            12 + 4 + ZRLEDecoder.maxCompressedLength(full),                    // ZRLE
            12 + 3 + 3 * 256 + 3 + max(tightBasic, TightDecoder.maxCompactLength),   // Tight (JPEG: any rect)
            12 + 4 * CursorShape.maxDimension * CursorShape.maxDimension
                + (CursorShape.maxDimension + 7) / 8 * CursorShape.maxDimension,    // Cursor
            12 + 4 + 16 * 255,                                                  // ExtendedDesktopSize
            6 + 6 * Int(UInt16.max),                                            // SetColourMapEntries
            8 + ServerMessageDecoder.maxCutTextLength,
            8 + ExtendedClipboard.maxMessageLength,
        ].max()!
    }

    /// Feeds the sample whole and in random chunks and compares the outcomes.
    static func compareChunkings(_ sample: FuzzSample, width: Int, height: Int, index: Int,
                                 _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        let chunks = Mutator.chunks(sample, &random)
        guard let split = run(width: width, height: height, chunks: chunks, index: index, &log, &random) else { return }
        guard chunks.count > 1,
              let whole = run(width: width, height: height, chunks: [sample.bytes], index: index, &log, &random) else { return }
        guard whole.error == split.error else {
            log.fail(index, "whole stream: \(String(describing: whole.error)), \(chunks.count) chunks: \(String(describing: split.error))")
            return
        }
        guard whole.error == nil else { return }
        if nonUpdates(whole.events) != nonUpdates(split.events) {
            log.fail(index, "non-update events differ between whole and chunked input")
        }
        if whole.framebuffer != split.framebuffer {
            log.fail(index, "framebuffer differs between whole and chunked input")
        }
    }

    static func nonUpdates(_ events: [RFBEvent]) -> [RFBEvent] {
        events.filter { if case .framebufferUpdate = $0 { false } else { true } }
    }

    /// Runs `chunks` through a new decoder, checking every property after every call. `nil` when the
    /// initial size is rejected (with a typed error).
    static func run(width: Int, height: Int, chunks: [[UInt8]], index: Int,
                    _ log: inout FuzzLog, _ random: inout FuzzRandom, keepEvents: Bool = true) -> DecoderRun? {
        var decoder: ServerMessageDecoder
        do {
            decoder = try ServerMessageDecoder(width: width, height: height)
        } catch {
            if case .protocolViolation = error {} else { log.fail(index, "init threw \(error)") }
            return nil
        }
        var display = decoder.framebuffer   // what a consumer applying the events would show
        var outcome = DecoderRun()
        for chunk in chunks {
            let pixelsBefore = decoder.framebuffer.pixels.count
            let events: [RFBEvent]
            do {
                events = try decoder.receive(chunk)
            } catch {
                checkFailure(error, &decoder, index, &log, &random)
                outcome.error = error
                log.rejected += 1
                break
            }
            var largest = pixelsBefore
            var copied = 0
            for event in events {
                log.saw(event)
                check(event, &display, &largest, &copied, index, &log)
            }
            let framebuffers = Double(copied) / Double(largest)
            log.maxCopiedFramebuffers = max(log.maxCopiedFramebuffers, framebuffers)
            if copied > ServerMessageDecoder.maxCopiedFramebuffersPerCall * largest {
                log.fail(index, "one receive of \(chunk.count) bytes returned \(copied) pixels of regions "
                         + "(\(String(format: "%.1f", framebuffers)) framebuffers of \(largest) pixels)")
            }
            let buffered = decoder.bufferedCount
            log.maxBuffered = max(log.maxBuffered, buffered)
            if buffered > pendingBound(decoder.framebuffer) {
                log.fail(index, "\(buffered) bytes buffered, beyond \(pendingBound(decoder.framebuffer))")
            }
            if keepEvents { outcome.events += events }
        }
        outcome.framebuffer = decoder.framebuffer
        guard outcome.error == nil else { return outcome }
        if display.width != decoder.framebuffer.width || display.height != decoder.framebuffer.height {
            log.fail(index, "events announce \(display.width)x\(display.height), framebuffer is "
                     + "\(decoder.framebuffer.width)x\(decoder.framebuffer.height)")
        } else if decoder.pendingRegionCount == 0, display.pixels != decoder.framebuffer.pixels {
            log.fail(index, "applying the updates does not reproduce the framebuffer")
        }
        return outcome
    }

    /// Sticky, typed error: the same error again, for no bytes and for more bytes; nothing buffered.
    static func checkFailure(_ error: RFBError, _ decoder: inout ServerMessageDecoder, _ index: Int,
                             _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        if case .protocolViolation = error {} else { log.fail(index, "decoder threw \(error)") }
        if decoder.bufferedCount != 0 { log.fail(index, "\(decoder.bufferedCount) bytes kept after \(error)") }
        for more in [[], random.bytes(1 + random.below(32))] {
            do {
                let events = try decoder.receive(more)
                log.fail(index, "receive after \(error) returned \(events.count) events")
            } catch let again {
                if again != error { log.fail(index, "error not sticky: \(error), then \(again)") }
            }
        }
    }

    static func check(_ event: RFBEvent, _ display: inout Framebuffer, _ largest: inout Int, _ copied: inout Int,
                      _ index: Int, _ log: inout FuzzLog) {
        switch event {
        case .framebufferUpdate(let update):
            guard update.width == display.width, update.height == display.height else {
                log.fail(index, "update for \(update.width)x\(update.height) on a \(display.width)x\(display.height) framebuffer")
                return
            }
            var area = 0
            for region in update.regions {
                let rect = region.rect
                guard rect.x >= 0, rect.y >= 0, rect.width >= 0, rect.height >= 0,
                      rect.x + rect.width <= update.width, rect.y + rect.height <= update.height,
                      region.pixels.count == rect.width * rect.height else {
                    log.fail(index, "bad region \(rect) with \(region.pixels.count) pixels in \(update.width)x\(update.height)")
                    return
                }
                area += rect.width * rect.height
                for row in 0..<rect.height {
                    let start = (rect.y + row) * display.width + rect.x
                    display.pixels.replaceSubrange(start..<(start + rect.width),
                                                   with: region.pixels[(row * rect.width)..<((row + 1) * rect.width)])
                }
            }
            if area > update.width * update.height {
                log.fail(index, "one update's regions hold \(area) pixels, beyond its \(update.width * update.height)")
            }
            copied += area
        case .desktopResized(let width, let height):
            do {
                try display.resize(width: width, height: height)
            } catch {
                log.fail(index, "resized to \(width)x\(height), beyond the caps")
            }
            largest = max(largest, width * height)
        case .cursor(let shape):
            if shape.width > CursorShape.maxDimension || shape.height > CursorShape.maxDimension
                || shape.pixels.count != shape.width * shape.height
                || !(0...max(0, shape.width - 1)).contains(shape.hotspotX)
                || !(0...max(0, shape.height - 1)).contains(shape.hotspotY) {
                log.fail(index, "bad cursor \(shape.width)x\(shape.height) hotspot \(shape.hotspotX),\(shape.hotspotY)")
            }
        case .serverCutText(let text):
            if text.unicodeScalars.count > ServerMessageDecoder.maxCutTextLength {
                log.fail(index, "cut text of \(text.unicodeScalars.count) characters")
            }
        case .extendedClipboard(let message):
            if case .provide(let text?) = message, text.unicodeScalars.count > ServerMessageDecoder.maxCutTextLength + 1 {
                log.fail(index, "extended text of \(text.unicodeScalars.count) characters")
            }
        case .bell:
            break
        }
    }
}

// MARK: Handshake

struct HandshakeRun {
    var outgoing: [UInt8] = []
    var result: HandshakeResult?
    var error: RFBError?
    /// Remainder of the result plus the chunks not fed after it.
    var rest: [UInt8] = []
}

enum HandshakeOracle {
    /// Banner + security type + VNC response or Apple DH ciphertext and public key + ClientInit.
    static let maxOutgoing = 12 + 1 + max(VNCAuth.challengeLength, AppleDHAuth.credentialBlockLength + AppleDHAuth.maxKeyLength) + 1

    static func compareChunkings(_ fuzzCase: HandshakeGenerator.Case, index: Int, _ log: inout FuzzLog,
                                 _ random: inout FuzzRandom) {
        let chunks = Mutator.chunks(fuzzCase.sample, &random)
        let split = run(fuzzCase, chunks: chunks, index: index, &log, &random)
        if chunks.count > 1 {
            let whole = run(fuzzCase, chunks: [fuzzCase.sample.bytes], index: index, &log, &random)
            // A throwing `receive` returns nothing, so after an error only the errors compare.
            if whole.error != split.error || whole.error == nil && (whole.outgoing != split.outgoing
                || whole.rest != split.rest || whole.result.map(comparable) != split.result.map(comparable)) {
                log.fail(index, "handshake outcome depends on chunking: \(String(describing: whole.error)) vs "
                         + "\(String(describing: split.error))")
            }
        }
        // As `RFBConnection` does: the remainder goes to a decoder sized by ServerInit.
        guard let result = split.result else { return }
        let width = Int(result.serverInit.width)
        let height = Int(result.serverInit.height)
        guard width * height <= 1 << 20 else { return }   // large sizes: `largeFramebuffers`
        _ = DecoderOracle.run(width: width, height: height, chunks: [split.rest], index: index, &log, &random)
    }

    /// The result without its remainder, which depends on where the chunks end.
    static func comparable(_ result: HandshakeResult) -> [String] {
        [result.serverVersion.description, result.version.description, "\(result.securityType)",
         "\(result.serverInit)"]
    }

    static func run(_ fuzzCase: HandshakeGenerator.Case, chunks: [[UInt8]], index: Int, _ log: inout FuzzLog,
                    _ random: inout FuzzRandom) -> HandshakeRun {
        var handshake = RFBHandshake(credentials: fuzzCase.credentials,
                                     entropy: HandshakeGenerator.entropy(seed: fuzzCase.entropySeed))
        var outcome = HandshakeRun()
        for chunk in chunks {
            if outcome.result != nil {
                outcome.rest += chunk
                continue
            }
            do {
                let step = try handshake.receive(chunk)
                outcome.outgoing += step.outgoing
                log.maxBuffered = max(log.maxBuffered, handshake.bufferedCount)
                if handshake.bufferedCount > RFBHandshake.maxBufferedBytes {
                    log.fail(index, "handshake holds \(handshake.bufferedCount) bytes")
                }
                if let result = step.result {
                    outcome.result = result
                    outcome.rest = Array(result.remainder)
                    checkResult(result, &handshake, index, &log)
                }
            } catch {
                checkFailure(error, &handshake, index, &log, &random)
                outcome.error = error
                log.rejected += 1
                break
            }
        }
        if outcome.outgoing.count > maxOutgoing {
            log.fail(index, "handshake sent \(outcome.outgoing.count) bytes")
        }
        return outcome
    }

    static func checkResult(_ result: HandshakeResult, _ handshake: inout RFBHandshake, _ index: Int,
                            _ log: inout FuzzLog) {
        log.events["connected", default: 0] += 1
        if !SecurityType.supported.contains(result.securityType) {
            log.fail(index, "connected with security type \(result.securityType)")
        }
        if result.serverInit.name.unicodeScalars.count > RFBHandshake.maxStringLength {
            log.fail(index, "desktop name of \(result.serverInit.name.unicodeScalars.count) characters")
        }
        do {
            _ = try handshake.receive([])
            log.fail(index, "receive after the result succeeded")
        } catch {
            if error != .protocolViolation("handshake already complete") { log.fail(index, "after the result: \(error)") }
        }
    }

    static func checkFailure(_ error: RFBError, _ handshake: inout RFBHandshake, _ index: Int,
                             _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        switch error {
        case .timeout, .cancelled, .connectionClosed, .network, .cryptoFailure:
            log.fail(index, "handshake threw \(error)")
        default:
            break
        }
        if String(describing: error).contains(HandshakeGenerator.password) {
            log.fail(index, "error prints the password")
        }
        if handshake.errorForClosedConnection() != error {
            log.fail(index, "errorForClosedConnection \(handshake.errorForClosedConnection()) after \(error)")
        }
        for more in [[], random.bytes(1 + random.below(32))] {
            do {
                _ = try handshake.receive(more)
                log.fail(index, "receive after \(error) succeeded")
            } catch let again {
                if again != error { log.fail(index, "error not sticky: \(error), then \(again)") }
            }
        }
    }
}

// MARK: Clipboard

enum ClipboardOracle {
    static func check(_ sample: FuzzSample, index: Int, _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        DecoderOracle.compareChunkings(sample, width: 8, height: 8, index: index, &log, &random)
        guard let run = DecoderOracle.run(width: 8, height: 8, chunks: [sample.bytes], index: index, &log, &random) else {
            return
        }
        // What `RFBConnection` does with each event: replies must encode, texts stay within the caps.
        var negotiation = ClipboardNegotiation(sharing: !random.oneIn(4))
        if random.oneIn(3) { _ = negotiation.share(random.oneIn(2) ? "partag\u{E9}\r\n" : String(repeating: "x", count: 70)) }
        for event in run.events {
            let (replies, text) = negotiation.handle(event)
            for reply in replies where reply.wireBytes.count > 16 + ServerMessageDecoder.maxCutTextLength * 2 {
                log.fail(index, "reply of \(reply.wireBytes.count) bytes")
            }
            if let text, text.unicodeScalars.count > ServerMessageDecoder.maxCutTextLength + 1 {
                log.fail(index, "text of \(text.unicodeScalars.count) characters for the app")
            }
            if let text, text.unicodeScalars.contains("\r") {
                log.fail(index, "text for the app keeps a CR")
            }
        }
        // `ExtendedClipboard.parse` directly on the payload of a well-formed extended message.
        let bytes = sample.bytes
        guard bytes.count >= 12, bytes[0] == 3 else { return }
        let length = Int32(bitPattern: bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) })
        guard length < 0, -Int(length) <= bytes.count - 8, -Int(length) <= ExtendedClipboard.maxMessageLength else { return }
        let payload = Array(bytes[8..<(8 - Int(length))])
        let parsed = payload.withUnsafeBytes { ExtendedClipboard.parse($0) }
        // A message `parse` drops produces no event, so only a parsed one is compared.
        let delivered = run.events.first.flatMap { if case .extendedClipboard(let message) = $0 { message } else { nil } }
        if let parsed, run.error == nil, parsed != delivered {
            log.fail(index, "decoder delivered \(String(describing: delivered)), parse gives \(String(describing: parsed))")
        }
    }
}

// MARK: Random bytes

enum RandomBytesOracle {
    static func check(index: Int, _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        var bytes = random.bytes(random.smallLength(max: 4096))
        switch index % 4 {
        case 0:   // decoder, often starting with a valid message type
            if !bytes.isEmpty, random.oneIn(2) { bytes[0] = UInt8(random.below(4)) }
            var sample = FuzzSample()
            sample.bytes = bytes
            DecoderOracle.compareChunkings(sample, width: random.int(1...64), height: random.int(1...64), index: index,
                                           &log, &random)
        case 1:   // handshake, often after a valid banner
            var sample = FuzzSample()
            if random.oneIn(2) { sample.bytes = Array(random.pick(["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n", "RFB 003.889\n"]).utf8) }
            sample.bytes += bytes
            let fuzzCase = HandshakeGenerator.Case(sample: sample, credentials: HandshakeGenerator.credentials(&random),
                                                   entropySeed: random.next())
            HandshakeOracle.compareChunkings(fuzzCase, index: index, &log, &random)
        case 2:   // ExtendedClipboard.parse, flags biased towards the actions
            if bytes.count >= 4, random.oneIn(2) {
                let flags = random.pick([ExtendedClipboard.provide, ExtendedClipboard.caps, ExtendedClipboard.notify])
                    | ExtendedClipboard.text
                bytes.replaceSubrange(0..<4, with: flags.bigEndianBytes)
            }
            let message = bytes.withUnsafeBytes { ExtendedClipboard.parse($0) }
            if case .provide(let text?)? = message, text.unicodeScalars.count > ServerMessageDecoder.maxCutTextLength + 1 {
                log.fail(index, "parse returned \(text.unicodeScalars.count) characters")
            }
        default:  // TightDecoder.measure on any bytes and rectangle
            let rect = RFBRect(x: 0, y: 0, width: random.int(0...300), height: random.int(0...300))
            do {
                guard let layout = try bytes.withUnsafeBytes({ try TightDecoder.measure($0, rect: rect) }) else { return }
                let raw = 3 * rect.width * rect.height
                let bound = max(raw + (raw >> 12) + (raw >> 14) + (raw >> 25) + 13 + 64, TightDecoder.maxCompactLength)
                if layout.dataLength > bound || layout.dataOffset > 3 + 3 * 256 + 3 || layout.dataLength < 0 {
                    log.fail(index, "Tight layout offset \(layout.dataOffset) length \(layout.dataLength) for \(rect)")
                }
            } catch let error as RFBError {
                if case .protocolViolation = error {} else { log.fail(index, "measure threw \(error)") }
                log.rejected += 1
            } catch {
                log.fail(index, "measure threw an untyped \(error)")
            }
        }
    }
}

// MARK: Inflater

enum InflaterOracle {
    /// Round trips through `Inflater` against the test-side `Deflater` (one persistent stream, several
    /// pieces), then hostile variants: tight or short output limits, flipped and truncated data.
    static func check(index: Int, _ log: inout FuzzLog, _ random: inout FuzzRandom) {
        let deflater = Deflater(level: Int32(random.int(0...9)))
        let inflater = Inflater()
        for _ in 0..<random.int(1...3) {
            let length = random.smallLength(max: 1 << 16)
            let plain = random.oneIn(2) ? random.bytes(length)
                : (0..<length).map { UInt8(truncatingIfNeeded: $0 / max(1, random.below(64) + 1)) }
            var compressed = deflater.compress(plain)
            let mode = compressed.isEmpty ? 4 : random.below(6)
            var maxOutput = plain.count
            switch mode {
            case 0 where !plain.isEmpty: maxOutput = plain.count - 1
            case 1: maxOutput = plain.count + random.int(1...4096)
            case 2: compressed[random.below(compressed.count)] ^= UInt8(1 << random.below(8))
            case 3: compressed.removeLast(1 + random.below(compressed.count))
            default: break
            }
            do {
                let output = try compressed.withUnsafeBytes {
                    Array(try inflater.inflate($0, maxOutput: maxOutput, "fuzz"))
                }
                if output.count > maxOutput { log.fail(index, "inflated \(output.count) bytes, limit \(maxOutput)") }
                if mode != 2, mode != 3, output != plain {
                    log.fail(index, "round trip of \(plain.count) bytes gave \(output.count) different bytes (mode \(mode))")
                }
                if mode == 0, !plain.isEmpty { log.fail(index, "an output limit one short was accepted") }
                if mode == 2 || mode == 3 { return }   // accepted damaged data: later pieces are out of step
            } catch let error as RFBError {
                if case .protocolViolation = error {} else { log.fail(index, "inflate threw \(error)") }
                if mode == 1 || mode == 4 || mode == 5 { log.fail(index, "valid data rejected: \(error)") }
                log.rejected += 1
                return   // the stream is out of step now
            } catch {
                log.fail(index, "inflate threw an untyped \(error)")
                return
            }
        }
    }
}
