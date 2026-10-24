import CoreGraphics
import Foundation
import ImageIO
import zlib
@testable import RFBKit

// Seed corpus and grammar generators for `ParserFuzzTests`. Valid streams come from the independent
// vectors (DecoderVectors, ClipboardVectors, AuthVectors); the generators build streams message by
// message with interesting field values, compressing hostile *plain* ZRLE tiles and Tight data with
// a real zlib stream so the fuzzing reaches the tile and filter parsers behind the inflate.

enum FuzzCorpus {
    struct DecoderSeed: Sendable {
        var sample: FuzzSample
        var width: Int
        var height: Int
    }

    /// Every decoder vector with its field map.
    static let decoderSeeds: [DecoderSeed] = DecoderVectors.all.map {
        DecoderSeed(sample: StreamIndex.sample($0.streamBytes, width: $0.width, height: $0.height),
                    width: $0.width, height: $0.height)
    }

    /// Every server clipboard vector (one message each) with its field map.
    static let clipboardSeeds: [FuzzSample] = ClipboardVectors.server.map {
        StreamIndex.sample(base64Bytes($0.message), width: 8, height: 8)
    }

    /// Small JPEGs (ImageIO, quality 0.5) of a few sizes, for Tight JPEG rectangles.
    static let jpegs: [(width: Int, height: Int, data: [UInt8])] = [(1, 1), (8, 8), (16, 8), (7, 3)].map { size in
        (size.0, size.1, makeJPEG(width: size.0, height: size.1))
    }

    private static func makeJPEG(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        for index in pixels.indices { pixels[index] = 0xFF00_0000 | UInt32(index &* 0x01_03_07) & 0xFF_FFFF }
        let data = NSMutableData()
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.noneSkipFirst.rawValue)!
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image,
                                       [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
        }
        return [UInt8](data as Data)
    }
}

// MARK: Decoder stream generator

/// Builds server → client streams (after ServerInit) message by message. It tracks the framebuffer
/// size it believes the decoder has, and mirrors the decoder's zlib streams (one for ZRLE, four for
/// Tight with the reset bits) so most compressed rectangles inflate and reach the tile parsers.
struct DecoderStreamGenerator {
    var width: Int
    var height: Int
    // Created on first use: a deflate stream costs a few hundred KiB to set up.
    private var zrleStream: Deflater?
    private var tightStreams: [Deflater?] = [nil, nil, nil, nil]
    /// Largest size a DesktopSize may pick (large framebuffers have their own, slower test).
    var maxDimension = 256

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    mutating func stream(_ random: inout FuzzRandom, messages: Int? = nil) -> FuzzSample {
        var sample = FuzzSample()
        for _ in 0..<(messages ?? random.int(1...6)) {
            sample.boundary()
            message(&sample, &random)
        }
        return sample
    }

    mutating func message(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        switch random.below(100) {
        case 0..<58: update(&s, &random)
        case 58..<62: flood(&s, &random)
        case 62..<66:   // SetColourMapEntries
            s.u8(1, .type)
            s.raw([0])
            s.u16(random.u16(), .value)
            let count = random.oneIn(10) ? Int(random.pick(Interesting.u16)) : random.below(8)
            s.u16(UInt16(count), .count)
            s.raw(random.bytes(min(6 * count, 6 * 8)))
        case 66..<71:
            s.u8(2, .type)
        case 71..<78:   // legacy ServerCutText
            s.u8(3, .type)
            s.raw([0, 0, 0])
            let text = random.bytes(random.smallLength(max: 300))
            if random.oneIn(8) {
                s.u32(UInt32(ServerMessageDecoder.maxCutTextLength + random.int(1...3)), .length)
            } else {
                s.u32(UInt32(text.count), .length)
            }
            s.raw(text)
        case 78..<96:
            s.append(ClipboardGenerator.extendedMessage(&random))
        default:        // unknown message type
            s.u8(UInt8(random.int(4...255)), .type)
            s.raw(random.bytes(random.below(8)))
        }
    }

    /// One FramebufferUpdate repeated many times: many full-frame fills in one chunk, the cheapest
    /// way to make the decoder copy the framebuffer over and over.
    mutating func flood(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        let copies = random.int(8...64)
        let colour = random.bytes(3)
        for _ in 0..<copies {
            s.boundary()
            s.u8(0, .type)
            s.raw([0])
            s.u16(1, .count)
            rectHeader(&s, x: 0, y: 0, width: width, height: height, encoding: Encoding.tight)
            s.u8(0x80, .flags)
            s.raw(colour)
        }
    }

    mutating func update(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        s.u8(0, .type)
        s.raw([0])
        let rects = random.int(0...8)
        s.u16(random.oneIn(16) ? random.pick([0, 0xFFFF, UInt16(rects + 1)]) : UInt16(rects), .count)
        for _ in 0..<rects {
            s.boundary()
            rectangle(&s, &random)
        }
    }

    private func rectHeader(_ s: inout FuzzSample, x: Int, y: Int, width: Int, height: Int, encoding: Int32) {
        s.u16(UInt16(truncatingIfNeeded: x), .coordinate)
        s.u16(UInt16(truncatingIfNeeded: y), .coordinate)
        s.u16(UInt16(truncatingIfNeeded: width), .dimension)
        s.u16(UInt16(truncatingIfNeeded: height), .dimension)
        s.s32(encoding, .encoding)
    }

    /// A rectangle inside the framebuffer most of the time; zero-area, full-frame, one past the edge
    /// or extreme otherwise.
    private func geometry(_ random: inout FuzzRandom) -> (x: Int, y: Int, width: Int, height: Int) {
        switch random.below(12) {
        case 0..<7:
            let w = random.int(1...min(width, 64))
            let h = random.int(1...min(height, 64))
            return (random.int(0...(width - w)), random.int(0...(height - h)), w, h)
        case 7:   // zero area, possibly at the far edge
            let zeroWidth = random.oneIn(2)
            return (random.int(0...width), random.int(0...height), zeroWidth ? 0 : random.int(0...width),
                    zeroWidth ? random.int(0...height) : 0)
        case 8, 9:
            return (0, 0, width, height)
        case 10:
            let w = random.int(1...width)
            return (width - w + 1, 0, w, random.int(1...height))
        default:
            return (Int(random.pick(Interesting.u16)), Int(random.pick(Interesting.u16)),
                    Int(random.pick(Interesting.u16)), Int(random.pick(Interesting.u16)))
        }
    }

    mutating func rectangle(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        var (x, y, w, h) = geometry(&random)
        let roll = random.below(100)
        switch roll {
        case 0..<10:
            rectHeader(&s, x: x, y: y, width: w, height: h, encoding: Encoding.raw)
            let length = 4 * w * h
            s.raw(random.bytes(min(random.oneIn(8) ? random.below(length + 1) : length, 1 << 16)))
        case 10..<18:
            rectHeader(&s, x: x, y: y, width: w, height: h, encoding: Encoding.copyRect)
            let sourceX = random.oneIn(6) ? Int(random.pick(Interesting.u16)) : random.int(0...max(0, width - w))
            let sourceY = random.oneIn(6) ? Int(random.pick(Interesting.u16)) : random.int(0...max(0, height - h))
            s.u16(UInt16(truncatingIfNeeded: sourceX), .coordinate)
            s.u16(UInt16(truncatingIfNeeded: sourceY), .coordinate)
        case 18..<42:
            if w * h > 1 << 16 { (w, h) = (min(w, 256), min(h, 256)) }
            rectHeader(&s, x: x, y: y, width: w, height: h, encoding: Encoding.zrle)
            zrleBody(&s, width: w, height: h, &random)
        case 42..<74:
            if w * h > 1 << 16 { (w, h) = (min(w, 256), min(h, 256)) }
            rectHeader(&s, x: x, y: y, width: w, height: h, encoding: Encoding.tight)
            tightBody(&s, width: w, height: h, &random)
        case 74..<80:   // DesktopSize
            let newWidth = random.oneIn(12) ? Int(random.pick([0, 16385, 0xFFFF])) : random.int(1...maxDimension)
            let newHeight = random.oneIn(12) ? Int(random.pick([0, 16385, 0xFFFF])) : random.int(1...maxDimension)
            rectHeader(&s, x: Int(random.u16()), y: Int(random.u16()), width: newWidth, height: newHeight,
                       encoding: Encoding.desktopSize)
            if (1...16384).contains(newWidth), (1...16384).contains(newHeight) {
                (width, height) = (newWidth, newHeight)
            }
        case 80..<86:   // ExtendedDesktopSize
            let newWidth = random.int(1...maxDimension)
            let newHeight = random.int(1...maxDimension)
            let status = random.oneIn(4) ? Int(random.u16()) : 0
            rectHeader(&s, x: random.below(3), y: status, width: newWidth, height: newHeight,
                       encoding: Encoding.extendedDesktopSize)
            let screens = random.oneIn(10) ? 255 : random.int(0...2)
            s.u8(UInt8(screens), .count)
            s.raw([0, 0, 0])
            s.raw(random.bytes(16 * min(screens, 3)))
            if status == 0 { (width, height) = (newWidth, newHeight) }
        case 86..<92:   // Cursor
            let cw = random.oneIn(10) ? random.pick([512, 513, 0, 0xFFFF]) : random.int(0...32)
            let ch = random.oneIn(10) ? random.pick([512, 513, 0, 0xFFFF]) : random.int(0...32)
            rectHeader(&s, x: Int(random.u16()), y: Int(random.u16()), width: cw, height: ch, encoding: Encoding.cursor)
            let length = 4 * cw * ch + (cw + 7) / 8 * ch
            s.raw(random.bytes(min(length, 1 << 14)))
        default:        // any other encoding number
            let encoding = random.oneIn(2) ? random.pick(Interesting.encodings) : Int32(bitPattern: random.u32())
            rectHeader(&s, x: x, y: y, width: w, height: h, encoding: encoding)
            s.raw(random.bytes(random.below(16)))
        }
    }

    // MARK: ZRLE

    private mutating func zrleBody(_ s: inout FuzzSample, width w: Int, height h: Int, _ random: inout FuzzRandom) {
        var plain: [UInt8] = []
        var tileY = 0
        while tileY < h {
            let tileHeight = min(64, h - tileY)
            var tileX = 0
            while tileX < w {
                plain += zrleTile(width: min(64, w - tileX), height: tileHeight, &random)
                tileX += 64
            }
            tileY += 64
        }
        if random.oneIn(10) { plain += random.bytes(1 + random.below(4)) }   // bytes after the last tile
        if random.oneIn(10), !plain.isEmpty { plain.removeLast(1 + random.below(min(plain.count, 4))) }
        if zrleStream == nil { zrleStream = Deflater() }
        var compressed = random.oneIn(25) ? random.bytes(random.below(64)) : zrleStream!.compress(plain)
        if random.oneIn(25), !compressed.isEmpty { compressed[random.below(compressed.count)] ^= 0x10 }
        let length = random.oneIn(20) ? random.pick(Interesting.u32) : UInt64(compressed.count)
        s.u32(UInt32(truncatingIfNeeded: length), .length)
        s.raw(compressed)
    }

    /// One tile's plain bytes, mostly valid for its subencoding, sometimes not.
    private func zrleTile(width w: Int, height h: Int, _ random: inout FuzzRandom) -> [UInt8] {
        let count = w * h
        let subencoding: Int = random.oneIn(20) ? random.int(17...127) : random.pick([0, 1, 2, 3, 4, 5, 15, 16, 128, 129, 130, 131, 140, 255])
        var tile: [UInt8] = [UInt8(subencoding)]
        switch subencoding {
        case 0: tile += random.bytes(3 * count)
        case 1: tile += random.bytes(3)
        case 2...16:
            let bits = subencoding == 2 ? 1 : subencoding <= 4 ? 2 : 4
            tile += random.bytes(3 * subencoding)
            tile += random.bytes((w * bits + 7) / 8 * h)   // indices may exceed the palette
        case 128:
            var filled = 0
            while filled < count {
                tile += random.bytes(3)
                let run = random.oneIn(30) ? count - filled + 1 : random.int(1...max(1, min(count - filled, 600)))
                var left = run - 1
                while left >= 255 {
                    tile.append(255)
                    left -= 255
                }
                tile.append(UInt8(left))
                filled += run
            }
        case 130...255:
            let size = subencoding - 128
            tile += random.bytes(3 * size)
            var filled = 0
            while filled < count {
                let entry = random.oneIn(40) ? random.below(128) : random.below(size)
                if random.oneIn(2) {
                    tile.append(UInt8(entry))
                    filled += 1
                } else {
                    tile.append(UInt8(entry) | 0x80)
                    let run = random.int(1...max(1, min(count - filled, 300)))
                    var left = run - 1
                    while left >= 255 {
                        tile.append(255)
                        left -= 255
                    }
                    tile.append(UInt8(left))
                    filled += run
                }
            }
        default:
            tile += random.bytes(random.below(8))
        }
        return tile
    }

    // MARK: Tight

    private mutating func tightBody(_ s: inout FuzzSample, width w: Int, height h: Int, _ random: inout FuzzRandom) {
        let resets = random.oneIn(4) ? UInt8(random.below(16)) : 0
        for index in 0..<4 where resets & (1 << index) != 0 { tightStreams[index] = nil }
        switch random.below(10) {
        case 0, 1:   // fill
            s.u8(0x80 | resets, .flags)
            s.raw(random.bytes(3))
        case 2:      // JPEG
            s.u8(0x90 | resets, .flags)
            var data: [UInt8]
            if random.oneIn(3), let match = FuzzCorpus.jpegs.first(where: { $0.width == w && $0.height == h }) {
                data = match.data
            } else {
                data = random.pick(FuzzCorpus.jpegs).data
            }
            if random.oneIn(3) {
                for _ in 0..<random.int(1...8) { data[random.below(data.count)] = random.byte() }
            }
            if random.oneIn(8) { data = [0xFF, 0xD8] + random.bytes(random.below(64)) }
            if random.oneIn(10) { data.removeLast(random.below(data.count)) }
            s.compact(data.count)
            s.raw(data)
        case 3 where random.oneIn(4):
            s.u8(UInt8(0xA0 + random.below(0x60)) | resets, .flags)   // PNG and beyond: invalid
            s.raw(random.bytes(random.below(8)))
        default:     // basic compression
            let stream = random.below(4)
            // Without the explicit-filter bit the filter is copy.
            let explicitFilter = !random.oneIn(4)
            var filter: UInt8 = 0
            if explicitFilter { filter = random.oneIn(30) ? UInt8(random.int(3...255)) : UInt8(random.below(3)) }
            let control = UInt8(stream << 4) | resets | (explicitFilter ? 0x40 : 0)
            s.u8(control, .flags)
            if explicitFilter { s.u8(filter, .value) }
            var plain: [UInt8]
            var rawLength: Int
            if filter == 1 {
                let size = random.oneIn(6) ? random.int(1...256) : random.pick([1, 2, 2, 3, 4, 16])
                s.u8(UInt8(size - 1), .count)
                s.raw(random.bytes(3 * size))
                if size == 2 {
                    rawLength = (w + 7) / 8 * h
                    plain = random.bytes(rawLength)
                } else {
                    rawLength = w * h
                    plain = (0..<rawLength).map { _ in UInt8(random.oneIn(50) ? random.below(256) : random.below(size)) }
                }
            } else {
                rawLength = 3 * w * h
                plain = random.bytes(rawLength)
            }
            if random.oneIn(12), !plain.isEmpty { plain.removeLast(1 + random.below(plain.count)) }
            if random.oneIn(12) { plain += random.bytes(1 + random.below(8)) }
            guard rawLength >= TightDecoder.minCompressedSize else {
                s.raw(plain)
                return
            }
            if tightStreams[stream] == nil { tightStreams[stream] = Deflater() }
            var compressed = random.oneIn(25) ? random.bytes(random.below(64)) : tightStreams[stream]!.compress(plain)
            if random.oneIn(25), !compressed.isEmpty { compressed[random.below(compressed.count)] ^= 0x04 }
            let length = random.oneIn(20) ? random.pick(Interesting.compact) : compressed.count
            s.compact(length)
            s.raw(compressed)
        }
    }
}

// MARK: Clipboard messages

enum ClipboardGenerator {
    /// An extended ServerCutText: caps, request, peek, notify or provide, with hostile sizes and flags.
    static func extendedMessage(_ random: inout FuzzRandom) -> FuzzSample {
        var flags: UInt32
        var payload: [UInt8] = []
        switch random.below(10) {
        case 0, 1:   // caps with one size per format bit (sometimes missing ones)
            let formats = random.oneIn(2) ? UInt32(random.u16()) : ExtendedClipboard.text | (random.oneIn(2) ? 6 : 0)
            flags = ExtendedClipboard.caps | formats | (random.u32() & ExtendedClipboard.actionMask)
            for _ in 0..<(formats.nonzeroBitCount - (random.oneIn(5) ? 1 : 0)) {
                payload += UInt32(truncatingIfNeeded: random.pick(Interesting.u32)).bigEndianBytes
            }
        case 2: flags = ExtendedClipboard.request | UInt32(random.u16())
        case 3: flags = ExtendedClipboard.peek
        case 4: flags = ExtendedClipboard.notify | UInt32(random.u16())
        case 5:      // several actions, or reserved bits only
            flags = random.u32() & ~ExtendedClipboard.caps
        default:     // provide
            let formats = random.oneIn(4) ? UInt32(random.u16()) : ExtendedClipboard.text
            flags = ExtendedClipboard.provide | formats
            payload = provideData(formats: formats, &random)
        }
        if random.oneIn(10) { flags |= random.u32() & 0xE0FF_0000 }   // reserved bits
        var s = FuzzSample()
        s.u8(3, .type)
        s.raw([0, 0, 0])
        let correct = Int32(-(4 + payload.count))
        let length: Int32 = random.oneIn(8)
            ? random.pick([Int32.min, Int32(-(ExtendedClipboard.maxMessageLength + 1)),
                           Int32(-ExtendedClipboard.maxMessageLength), 0, -1, -3, -4, correct + 1, correct - 1, -correct])
            : correct
        s.s32(length, .length)
        s.u32(flags, .flags)
        s.raw(payload)
        return s
    }

    /// The zlib-compressed U32 size + data of each format bit set, with hostile sizes, bombs and
    /// broken compression now and then.
    static func provideData(formats: UInt32, _ random: inout FuzzRandom) -> [UInt8] {
        var plain: [UInt8] = []
        for bit in 0..<16 where formats & (1 << UInt32(bit)) != 0 {
            var data: [UInt8]
            switch random.below(64) {
            // At the 1 MiB cap ±: rare, a megabyte of text is slow to check in debug builds.
            case 0: data = [UInt8](repeating: 0x41, count: ServerMessageDecoder.maxCutTextLength + random.int(-1...2))
            case 1..<9: data = Array("ligne\r\nsuivante\rfin\n\r\r\n".utf8) + [0]
            case 9..<25: data = random.bytes(random.smallLength(max: 2000))   // invalid UTF-8, NULs inside
            default: data = Array("texte \u{2014} \u{1F600} caf\u{E9}".utf8) + random.bytes(random.below(4)) + [0]
            }
            let size = random.oneIn(6)
                ? UInt32(truncatingIfNeeded: random.pick([0, UInt64(data.count + 1), 0xFFFF_FFFF,
                                                          UInt64(ServerMessageDecoder.maxCutTextLength + 1),
                                                          UInt64(ServerMessageDecoder.maxCutTextLength + 2)]))
                : UInt32(data.count)
            plain += size.bigEndianBytes + data
            if random.oneIn(3) { break }
        }
        if random.oneIn(24) { plain += [UInt8](repeating: 0, count: ExtendedClipboard.maxInflatedLength + random.int(-4...4)) }   // bomb
        switch random.below(12) {
        case 0: return []
        case 1: return random.bytes(random.smallLength(max: 64))
        case 2:
            var compressed = ExtendedClipboard.compress(plain)
            compressed.removeLast(random.below(compressed.count))
            return compressed
        case 3:
            var compressed = ExtendedClipboard.compress(plain)
            compressed[random.below(compressed.count)] ^= UInt8(1 << random.below(8))
            return compressed
        case 4, 5: return Deflater().compress(plain)   // sync-flushed, never ended
        default: return ExtendedClipboard.compress(plain)
        }
    }
}

// MARK: Handshake streams

/// Builds a server's side of a handshake for a random version, security path and credentials, with
/// hostile Apple DH parameters, followed by the start of the normal protocol.
enum HandshakeGenerator {
    static let password = "fuzz-secret-pw"

    struct Case: Sendable {
        var sample: FuzzSample
        var credentials: RFBCredentials
        var entropySeed: UInt64
    }

    static func credentials(_ random: inout FuzzRandom) -> RFBCredentials {
        switch random.below(6) {
        case 0: .none
        case 1: RFBCredentials(password: password)
        case 2: RFBCredentials(username: "", password: password)
        case 3: RFBCredentials(username: String(repeating: "u", count: 64), password: password)
        default: RFBCredentials(username: "fuzzuser", password: password)
        }
    }

    /// Deterministic entropy that always returns exactly the requested number of bytes.
    static func entropy(seed: UInt64) -> HandshakeEntropy {
        HandshakeEntropy(privateKey: { count in
            var random = FuzzRandom(seed: seed)
            return random.bytes(count)
        }, credentialPadding: { count in
            var random = FuzzRandom(seed: ~seed)
            return random.bytes(count)
        })
    }

    static func string(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        let text = random.oneIn(3) ? random.bytes(random.smallLength(max: 64)) : Array("refused \u{E9}".utf8)
        let length = random.oneIn(6)
            ? UInt32(truncatingIfNeeded: random.pick([UInt64(RFBHandshake.maxStringLength),
                                                      UInt64(RFBHandshake.maxStringLength + 1), 0xFFFF_FFFF,
                                                      0x8000_0000, UInt64(text.count + 1)]))
            : UInt32(text.count)
        s.u32(length, .length)
        s.raw(text)
        if length == RFBHandshake.maxStringLength { s.raw([UInt8](repeating: 0x61, count: Int(length) - text.count)) }
    }

    static func generate(_ random: inout FuzzRandom) -> Case {
        let credentials = credentials(&random)
        var s = FuzzSample()
        let banners = ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n", "RFB 003.889\n", "RFB 003.005\n",
                       "RFB 004.001\n", "RFB 003.002\n", "RFB 03.0008\n", "RFB +03.+08\n", "RFX 003.008\n"]
        let banner = random.oneIn(8) ? random.pick(banners) : random.pick(Array(banners.prefix(4)))
        for byte in banner.utf8 { s.u8(byte, .value) }
        s.boundary()
        let version = ProtocolVersion(banner: Data(banner.utf8))?.negotiated()
        var selected: UInt8?
        if version == .v3_3 {
            let type: UInt32 = random.oneIn(6) ? random.pick([0, 30, 3, 256, 0xFFFF_FFFF]) : random.pick([1, 2])
            s.u32(type, .value)
            if type == 0 { string(&s, &random) }
            selected = type == 1 || (type == 2 && credentials.password != nil) ? UInt8(type) : nil
        } else {
            let pool: [UInt8] = [1, 2, 30, 30, 33, 35, 36, 0, 16, 18, 19, 255]
            let count = random.oneIn(10) ? 0 : random.int(1...4)
            s.u8(UInt8(count), .count)
            var offered: [UInt8] = []
            for _ in 0..<count {
                let type = random.oneIn(5) ? random.byte() : random.pick(pool)
                offered.append(type)
                s.u8(type, .value)
            }
            if count == 0 { string(&s, &random) }
            selected = count == 0 ? nil : try? RFBHandshake.selectSecurityType(offered: offered, credentials: credentials)
        }
        s.boundary()
        guard let selected else {
            if random.oneIn(2) { s.raw(random.bytes(random.smallLength(max: 64))) }
            return Case(sample: s, credentials: credentials, entropySeed: random.next())
        }
        switch selected {
        case SecurityType.vncAuthentication: s.raw(random.bytes(VNCAuth.challengeLength))
        case SecurityType.appleDiffieHellman: dhParameters(&s, &random)
        default: break
        }
        s.boundary()
        // SecurityResult: always in 3.8, after type 2 or 30 in 3.3/3.7.
        if version == .v3_8 || selected != SecurityType.none {
            let result: UInt32 = random.oneIn(6) ? random.pick([1, 2, 0xFFFF_FFFF]) : 0
            s.u32(result, .value)
            if result != 0 {
                if version == .v3_8 { string(&s, &random) }
                return Case(sample: s, credentials: credentials, entropySeed: random.next())
            }
        }
        s.boundary()
        serverInit(&s, &random)
        return Case(sample: s, credentials: credentials, entropySeed: random.next())
    }

    static func serverInit(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        let width = random.oneIn(8) ? UInt16(random.pick(Interesting.u16)) : UInt16(random.int(1...200))
        let height = random.oneIn(8) ? UInt16(random.pick(Interesting.u16)) : UInt16(random.int(1...200))
        s.u16(width, .dimension)
        s.u16(height, .dimension)
        s.raw(random.oneIn(4) ? random.bytes(16) : PixelFormat.bgra32.wireBytes)
        let name = random.oneIn(3) ? random.bytes(random.smallLength(max: 80)) : Array("minim6 \u{2014} Mac".utf8)
        let length: UInt32 = random.oneIn(8)
            ? UInt32(truncatingIfNeeded: random.pick([UInt64(RFBHandshake.maxStringLength + 1), 0xFFFF_FFFF,
                                                      UInt64(name.count + 1), 0]))
            : UInt32(name.count)
        s.u32(length, .length)
        s.raw(name)
        s.boundary()
        // The start of the normal protocol, for the size just announced.
        if (1...200).contains(Int(width)), (1...200).contains(Int(height)), random.oneIn(2) {
            var generator = DecoderStreamGenerator(width: Int(width), height: Int(height))
            s.append(generator.stream(&random, messages: random.int(1...3)))
        } else if random.oneIn(3) {
            s.raw(random.bytes(random.smallLength(max: 64)))
        }
    }

    /// Apple DH parameters: small valid groups, the vectors' real groups now and then, and hostile
    /// values (even or tiny primes, out-of-range generator and public key, zero padding).
    static func dhParameters(_ s: inout FuzzSample, _ random: inout FuzzRandom) {
        var keyLength: Int
        var prime: [UInt8]
        var generator: UInt16
        var serverKey: [UInt8]
        if random.oneIn(80) {
            // The vectors' real groups (1024 to 4096 bits) cost milliseconds of modPow each, more in
            // debug builds: rarely, and the 4096-bit one rarer still.
            let vector = random.pick(AuthVectors.appleDH)
            let usable = vector.keyLength < 512 || random.oneIn(8) ? vector : AuthVectors.appleDH[0]
            prime = [UInt8](hex: usable.prime)
            generator = usable.generator
            serverKey = [UInt8](hex: usable.serverPublicKey)
            keyLength = prime.count
        } else {
            keyLength = random.pick([1, 1, 2, 3, 4, 7, 8, 16, 32, 64])
            prime = random.bytes(keyLength)
            prime[0] |= 0x80
            prime[keyLength - 1] |= 1
            generator = UInt16(random.int(2...5))
            serverKey = random.bytes(keyLength)
            serverKey[0] &= 0x3F
            switch random.below(14) {
            case 0: prime[keyLength - 1] &= 0xFE                                       // even
            case 1: prime = [UInt8](repeating: 0, count: keyLength)
            case 2: prime = [UInt8](repeating: 0, count: keyLength - 1) + [random.pick([1, 3, 5, 7])]   // tiny, padded
            case 3: prime = [UInt8](repeating: 0xFF, count: keyLength)
            case 4: generator = random.pick([0, 1, 0xFFFF])
            case 5: serverKey = [UInt8](repeating: 0, count: keyLength - 1) + [random.pick([0, 1])]
            case 6: serverKey = prime                                                 // = p
            case 7: serverKey = [UInt8](repeating: 0xFF, count: keyLength)            // > p
            case 8:                                                                   // p − 1
                serverKey = prime
                serverKey[keyLength - 1] &= 0xFE
            case 9 where keyLength <= 2:                                              // g = p − 1, g = p
                let p = Int(prime.reduce(0) { $0 << 8 | Int($1) })
                generator = UInt16(truncatingIfNeeded: p - random.below(2))
            default: break
            }
        }
        s.u16(generator, .value)
        let announced = random.oneIn(10) ? Int(random.pick([0, 513, 0xFFFF, UInt64(keyLength + 1)])) : keyLength
        s.u16(UInt16(truncatingIfNeeded: announced), .length)
        s.raw(prime)
        s.raw(serverKey)
    }
}
