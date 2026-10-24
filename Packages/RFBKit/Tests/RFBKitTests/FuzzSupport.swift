import Foundation
@testable import RFBKit

// Deterministic, seedable fuzzing support for `ParserFuzzTests` (T5.5): a PRNG whose sequence never
// depends on the Swift version, run configuration from the environment, a stream builder that records
// where each field lies, and structure-aware mutations that use those field maps.

// MARK: Random

/// SplitMix64 (Steele, Lea, Flood 2014). Every derived value is computed here rather than with the
/// standard library's `random(in:using:)`, whose algorithm may change between Swift versions: a seed
/// must reproduce the same inputs on the CI toolchain (6.3) and locally (6.4).
struct FuzzRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// The seed of input `index` of `target`: independent streams, so any single input can be replayed
    /// (`RFBKIT_FUZZ_START=index RFBKIT_FUZZ_COUNT=1`).
    static func caseSeed(master: UInt64, target: String, index: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a of the target name
        for byte in target.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        var mixer = FuzzRandom(seed: master ^ hash ^ (UInt64(index) &* 0xD1B5_4A32_D192_ED03))
        return mixer.next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<bound` (`bound` > 0; the modulo bias is irrelevant here).
    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + below(range.count) }

    mutating func oneIn(_ n: Int) -> Bool { below(n) == 0 }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    mutating func u16() -> UInt16 { UInt16(truncatingIfNeeded: next()) }

    mutating func u32() -> UInt32 { UInt32(truncatingIfNeeded: next()) }

    mutating func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        // Whole little-endian words, then the tail byte by byte (fast enough in debug builds).
        out.withUnsafeMutableBytes { raw in
            var at = 0
            while at + 8 <= count {
                raw.storeBytes(of: next().littleEndian, toByteOffset: at, as: UInt64.self)
                at += 8
            }
            var word = next()
            while at < count {
                raw[at] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                at += 1
            }
        }
        return out
    }

    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }

    /// Mostly small, sometimes large: 0…`max` with a roughly geometric distribution.
    mutating func smallLength(max: Int) -> Int {
        let bits = below(Int.bitWidth - max.leadingZeroBitCount + 1)
        return min(max, below(1 << bits))
    }
}

// MARK: Configuration

/// How many inputs each fuzz target runs, from which seed. Default: a CI-sized run (about 20 000
/// inputs in all, a few seconds). `RFBKIT_PERF=1`: the full run (more than 1 000 000 inputs).
/// `RFBKIT_FUZZ_SEED` (decimal or 0x-hex), `RFBKIT_FUZZ_START` and `RFBKIT_FUZZ_COUNT` (per target)
/// replay a range; `RFBKIT_FUZZ_TRACE=1` prints every input before it runs, so the last line before a
/// trap names the input that crashed.
enum FuzzConfig {
    static let environment = ProcessInfo.processInfo.environment
    static let defaultSeed: UInt64 = 0x7535_2026_1023_0001

    static let seed: UInt64 = {
        guard let text = environment["RFBKIT_FUZZ_SEED"] else { return defaultSeed }
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) ?? defaultSeed }
        return UInt64(text) ?? defaultSeed
    }()

    static let start = environment["RFBKIT_FUZZ_START"].flatMap { Int($0) } ?? 0
    static let countOverride = environment["RFBKIT_FUZZ_COUNT"].flatMap { Int($0) }
    static let trace = environment["RFBKIT_FUZZ_TRACE"] == "1"
    static let full = perfTestsEnabled

    /// Inputs for one target: `quick` by default, `full` under `RFBKIT_PERF=1`.
    static func count(quick: Int, full fullCount: Int) -> Int {
        countOverride ?? (full ? fullCount : quick)
    }
}

// MARK: Streams with field maps

/// What a recorded field holds, which decides the interesting values a mutation picks for it.
enum FieldKind: Sendable {
    case type, count, length, coordinate, dimension, encoding, flags, compactLength, value
}

struct Field: Sendable {
    var offset: Int
    var size: Int
    var kind: FieldKind
}

/// A server → client byte stream with the position of its fields and of its message boundaries.
struct FuzzSample: Sendable {
    var bytes: [UInt8] = []
    var fields: [Field] = []
    var boundaries: [Int] = [0]

    // MARK: Building

    mutating func boundary() { if boundaries.last != bytes.count { boundaries.append(bytes.count) } }

    mutating func u8(_ value: UInt8, _ kind: FieldKind = .value) {
        fields.append(Field(offset: bytes.count, size: 1, kind: kind))
        bytes.append(value)
    }

    mutating func u16(_ value: UInt16, _ kind: FieldKind = .value) {
        fields.append(Field(offset: bytes.count, size: 2, kind: kind))
        bytes += value.bigEndianBytes
    }

    mutating func u32(_ value: UInt32, _ kind: FieldKind = .value) {
        fields.append(Field(offset: bytes.count, size: 4, kind: kind))
        bytes += value.bigEndianBytes
    }

    mutating func s32(_ value: Int32, _ kind: FieldKind = .value) { u32(UInt32(bitPattern: value), kind) }

    /// A Tight compact length (1–3 bytes).
    mutating func compact(_ value: Int) {
        let encoded = FramebufferMessage.tightCompactLength(value)
        fields.append(Field(offset: bytes.count, size: encoded.count, kind: .compactLength))
        bytes += encoded
    }

    mutating func raw(_ data: [UInt8]) { bytes += data }

    mutating func append(_ other: FuzzSample) {
        let base = bytes.count
        fields += other.fields.map { Field(offset: $0.offset + base, size: $0.size, kind: $0.kind) }
        boundary()
        boundaries += other.boundaries.map { $0 + base }.filter { $0 > base }
        bytes += other.bytes
    }

    // MARK: Editing (keeps the maps in step)

    /// Replaces `bytes[range]` with `replacement`, shifting the fields and boundaries after it.
    mutating func replace(_ range: Range<Int>, with replacement: [UInt8]) {
        let delta = replacement.count - range.count
        bytes.replaceSubrange(range, with: replacement)
        guard delta != 0 else { return }
        fields = fields.compactMap { field in
            if field.offset + field.size <= range.lowerBound { return field }
            if field.offset >= range.upperBound {
                return Field(offset: field.offset + delta, size: field.size, kind: field.kind)
            }
            return nil   // overlapped by the edit
        }
        boundaries = boundaries.compactMap { mark in
            if mark <= range.lowerBound { return mark }
            if mark >= range.upperBound { return mark + delta }
            return nil
        }
    }

    mutating func truncate(at offset: Int) {
        let end = max(0, min(offset, bytes.count))
        bytes.removeSubrange(end...)
        fields.removeAll { $0.offset + $0.size > end }
        boundaries.removeAll { $0 > end }
    }
}

// MARK: Mutation

/// Interesting values per field width: zero, one, sign and size boundaries, and RFBKit's own caps ±1.
enum Interesting {
    static let u8: [UInt64] = [0, 1, 2, 3, 0x0F, 0x10, 0x3F, 0x40, 0x7F, 0x80, 0x81, 0xFE, 0xFF]

    static let u16: [UInt64] = [0, 1, 2, 3, 7, 8, 63, 64, 65, 0x7F, 0x80, 0xFF, 0x100, 0x1FF, 0x200, 0x201,
                                0x3FFF, 0x4000, 0x4001, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF]

    static let u32: [UInt64] = {
        var values: [UInt64] = [0, 1, 2, 3, 4, 0x7F, 0x80, 0xFF, 0x100, 0x3FFF, 0x4000, 0xFFFF, 0x1_0000,
                                0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFFF, 0xFFFF_FFFE, 0xFFFF_FFFC,
                                0xFFFF_FFFB]
        let caps = [RFBHandshake.maxStringLength, ServerMessageDecoder.maxCutTextLength,
                    ExtendedClipboard.maxMessageLength, ExtendedClipboard.maxInflatedLength,
                    TightDecoder.maxCompactLength, RFBHandshake.maxBufferedBytes]
        for cap in caps {
            for value in [cap - 1, cap, cap + 1] {
                values.append(UInt64(value))
                values.append(UInt64(UInt32(bitPattern: Int32(-value))))   // as a negative S32 length
            }
        }
        return values
    }()

    static let compact: [Int] = [0, 1, 11, 12, 13, 0x7F, 0x80, 0x3FFF, 0x4000, TightDecoder.maxCompactLength]

    static let encodings: [Int32] = [Encoding.raw, Encoding.copyRect, Encoding.tight, Encoding.zrle, 2, 5, 6, 8,
                                     15, 17, Encoding.desktopSize, Encoding.cursor, Encoding.extendedDesktopSize,
                                     Encoding.extendedClipboard, -224, -240, -260, -307, -309, Int32.min,
                                     Int32.max, -1]
}

enum Mutator {
    /// Applies 1–4 stacked mutations, structure-aware when the sample has fields and boundaries.
    /// `donors` are other valid samples used for splicing.
    static func mutate(_ sample: inout FuzzSample, donors: [FuzzSample], _ random: inout FuzzRandom) {
        for _ in 0..<random.int(1...4) {
            mutateOnce(&sample, donors: donors, &random)
        }
    }

    static func mutateOnce(_ sample: inout FuzzSample, donors: [FuzzSample], _ random: inout FuzzRandom) {
        let count = sample.bytes.count
        switch random.below(16) {
        case 0...4 where !sample.fields.isEmpty:   // field to an extreme
            setField(&sample, random.pick(sample.fields), &random)
        case 5 where count > 0:                    // bit flip
            let at = random.below(count)
            sample.bytes[at] ^= 1 << UInt8(random.below(8))
        case 6 where count > 0:                    // interesting byte
            sample.bytes[random.below(count)] = UInt8(random.pick(Interesting.u8))
        case 7 where count > 0:                    // truncation, often at or next to a boundary
            if random.oneIn(2), let mark = sample.boundaries.randomElement(using: &random) {
                sample.truncate(at: mark + random.int(-2...2))
            } else {
                sample.truncate(at: random.below(count))
            }
        case 8 where count > 0:                    // delete a range
            let start = random.below(count)
            let length = min(count - start, 1 + random.smallLength(max: 64))
            sample.replace(start..<(start + length), with: [])
        case 9:                                    // insert random or interesting bytes
            let at = random.below(count + 1)
            let inserted = random.oneIn(2) ? random.bytes(1 + random.smallLength(max: 32))
                : [UInt8](repeating: UInt8(random.pick(Interesting.u8)), count: 1 + random.below(8))
            sample.replace(at..<at, with: inserted)
        case 10 where count > 0:                   // duplicate a range (or a whole message)
            let start = random.below(count)
            let length = min(count - start, 1 + random.smallLength(max: 256))
            let at = random.below(count + 1)
            sample.replace(at..<at, with: Array(sample.bytes[start..<(start + length)]))
        case 11, 12:                               // splice at message boundaries with a donor
            guard let donor = donors.randomElement(using: &random), donor.bytes.count > 0 else {
                sample.bytes += random.bytes(1 + random.smallLength(max: 64))
                return
            }
            let cut = sample.boundaries.randomElement(using: &random) ?? random.below(count + 1)
            let from = donor.boundaries.randomElement(using: &random) ?? 0
            var tail = donor
            tail.replace(0..<min(from, tail.bytes.count), with: [])
            sample.truncate(at: cut)
            sample.append(tail)
        case 13 where sample.boundaries.count > 2: // swap two adjacent messages
            let index = random.below(sample.boundaries.count - 2)
            let (a, b, c) = (sample.boundaries[index], sample.boundaries[index + 1], sample.boundaries[index + 2])
            guard c <= count else { break }
            let swapped = Array(sample.bytes[b..<c]) + Array(sample.bytes[a..<b])
            sample.bytes.replaceSubrange(a..<c, with: swapped)
            sample.fields = []   // offsets no longer meaningful
        case 14:                                   // random tail
            sample.bytes += random.bytes(1 + random.smallLength(max: 128))
        default:
            if count > 0 { sample.bytes[random.below(count)] = random.byte() }
        }
    }

    /// Overwrites a field with an interesting value for its width (or ±1 of its current value).
    static func setField(_ sample: inout FuzzSample, _ field: Field, _ random: inout FuzzRandom) {
        guard field.offset + field.size <= sample.bytes.count else { return }
        let range = field.offset..<(field.offset + field.size)
        if field.kind == .compactLength {
            let value = random.oneIn(4) ? random.below(TightDecoder.maxCompactLength + 1) : random.pick(Interesting.compact)
            var encoded = FramebufferMessage.tightCompactLength(value)
            if random.oneIn(8) { encoded = [0xFF, 0xFF, 0xFF] }       // longest form, top bits set
            sample.replace(range, with: encoded)
            return
        }
        let current = sample.bytes[range].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let mask: UInt64 = field.size >= 8 ? .max : (1 << UInt64(8 * field.size)) - 1
        var value: UInt64
        switch random.below(8) {
        case 0: value = current &+ 1
        case 1: value = current &- 1
        case 2: value = random.next()
        case 3 where field.kind == .encoding: value = UInt64(UInt32(bitPattern: random.pick(Interesting.encodings)))
        case 4 where field.kind == .length || field.kind == .count:
            // Exactly, or one more than, the bytes that follow the field.
            value = UInt64(max(0, sample.bytes.count - range.upperBound + random.int(-1...1)))
        default:
            let table = field.size == 1 ? Interesting.u8 : field.size == 2 ? Interesting.u16 : Interesting.u32
            value = random.pick(table)
        }
        value &= mask
        let bytes = (0..<field.size).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (field.size - 1 - $0))) }
        sample.bytes.replaceSubrange(range, with: bytes)
    }

    /// Random chunking: whole, byte by byte, at field edges, or random sizes.
    static func chunks(_ sample: FuzzSample, _ random: inout FuzzRandom) -> [[UInt8]] {
        let bytes = sample.bytes
        guard !bytes.isEmpty else { return [[]] }
        var cuts: [Int]
        switch random.below(6) {
        case 0: return [bytes]
        case 1 where bytes.count <= 4096: return bytes.map { [$0] }
        case 2:   // at field starts and ends, ±1
            cuts = sample.fields.flatMap { [$0.offset, $0.offset + $0.size] }.map { $0 + random.int(-1...1) }
        default:
            cuts = []
            var at = 0
            while at < bytes.count {
                at += 1 + random.smallLength(max: 4096)
                cuts.append(at)
            }
        }
        let sorted = Set(cuts.filter { $0 > 0 && $0 < bytes.count }).sorted()
        var result: [[UInt8]] = []
        var previous = 0
        for cut in sorted + [bytes.count] {
            result.append(Array(bytes[previous..<cut]))
            previous = cut
        }
        // An empty chunk now and then: `receive([])` must be harmless.
        if random.oneIn(16) { result.insert([], at: random.below(result.count + 1)) }
        return result
    }
}

extension Array {
    func randomElement(using random: inout FuzzRandom) -> Element? {
        isEmpty ? nil : self[random.below(count)]
    }
}

// MARK: Field maps of the valid vector streams

/// Walks a valid server → client stream (after ServerInit) and records its fields and message
/// boundaries, so the vectors can be mutated field by field. Written from RFC 6143 and rfbproto, like
/// the vector generators; it stops at the first byte it does not understand.
enum StreamIndex {
    static func sample(_ bytes: [UInt8], width: Int, height: Int) -> FuzzSample {
        var walker = Walker(bytes: bytes)
        walker.walk()
        var sample = FuzzSample()
        sample.bytes = bytes
        sample.fields = walker.fields
        sample.boundaries = walker.boundaries
        return sample
    }

    private struct Walker {
        let bytes: [UInt8]
        var at = 0
        var fields: [Field] = []
        var boundaries: [Int] = [0]

        init(bytes: [UInt8]) { self.bytes = bytes }

        func peek(_ offset: Int, _ size: Int) -> Int? {
            guard at + offset + size <= bytes.count else { return nil }
            return bytes[(at + offset)..<(at + offset + size)].reduce(0) { $0 << 8 | Int($1) }
        }

        mutating func field(_ size: Int, _ kind: FieldKind) -> Int? {
            guard let value = peek(0, size) else { return nil }
            fields.append(Field(offset: at, size: size, kind: kind))
            at += size
            return value
        }

        mutating func skip(_ count: Int) -> Bool {
            guard at + count <= bytes.count else { return false }
            at += count
            return true
        }

        mutating func compact() -> Int? {
            var value = 0
            var size = 0
            for (index, shift) in [0, 7, 14].enumerated() {
                guard let byte = peek(index, 1) else { return nil }
                value |= (index == 2 ? byte : byte & 0x7F) << shift
                size += 1
                if index == 2 || byte & 0x80 == 0 { break }
            }
            fields.append(Field(offset: at, size: size, kind: .compactLength))
            at += size
            return value
        }

        mutating func walk() {
            while at < bytes.count {
                if at != boundaries.last { boundaries.append(at) }
                guard let type = field(1, .type) else { return }
                switch type {
                case 0:
                    guard skip(1), let count = field(2, .count) else { return }
                    for _ in 0..<count {
                        boundaries.append(at)
                        guard rectangle() else { return }
                    }
                case 1:
                    guard skip(1), field(2, .value) != nil, let count = field(2, .count), skip(6 * count) else { return }
                case 2:
                    break
                case 3:
                    guard skip(3), let length = field(4, .length) else { return }
                    let signed = Int(Int32(truncatingIfNeeded: length))
                    if signed < 0 {
                        guard field(4, .flags) != nil, skip(-signed - 4) else { return }
                    } else {
                        guard skip(signed) else { return }
                    }
                default:
                    return
                }
            }
        }

        mutating func rectangle() -> Bool {
            guard field(2, .coordinate) != nil, field(2, .coordinate) != nil, let width = field(2, .dimension),
                  let height = field(2, .dimension), let rawEncoding = field(4, .encoding) else { return false }
            switch Int32(truncatingIfNeeded: rawEncoding) {
            case Encoding.raw: return skip(4 * width * height)
            case Encoding.copyRect: return field(2, .coordinate) != nil && field(2, .coordinate) != nil
            case Encoding.zrle:
                guard let length = field(4, .length) else { return false }
                return skip(length)
            case Encoding.tight: return tight(width: width, height: height)
            case Encoding.desktopSize: return true
            case Encoding.cursor: return skip(4 * width * height + (width + 7) / 8 * height)
            case Encoding.extendedDesktopSize:
                guard let screens = field(1, .count) else { return false }
                return skip(3 + 16 * screens)
            default: return false
            }
        }

        mutating func tight(width: Int, height: Int) -> Bool {
            guard let control = field(1, .flags) else { return false }
            switch control >> 4 {
            case 0x8: return skip(3)
            case 0x9:
                guard let length = compact() else { return false }
                return skip(length)
            case 0xA...: return false
            default: break
            }
            var filter = 0
            if control & 0x40 != 0 {
                guard let value = field(1, .value) else { return false }
                filter = value
            }
            var rawLength = 3 * width * height
            if filter == 1 {
                guard let count = field(1, .count), skip(3 * (count + 1)) else { return false }
                rawLength = (count + 1 == 2 ? (width + 7) / 8 : width) * height
            }
            guard rawLength >= TightDecoder.minCompressedSize else { return skip(rawLength) }
            guard let length = compact() else { return false }
            return skip(length)
        }
    }
}
