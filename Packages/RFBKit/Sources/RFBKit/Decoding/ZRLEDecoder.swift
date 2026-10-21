import Foundation

/// ZRLE (encoding 16, RFC 6143 §7.7.6): a U32 length, then zlib data on one stream that persists for
/// the whole connection. The data is a sequence of 64 × 64 tiles, left to right then top to bottom.
///
/// For `PixelFormat.bgra32` a CPIXEL is 3 bytes: the least significant 3 bytes of the little-endian
/// pixel, i.e. B, G, R.
///
/// Hot loops use `while` and raw pointers: `for … in` ranges stay generic, and slow, in debug builds.
struct ZRLEDecoder {
    static let tileSize = 64
    private let inflater = Inflater()

    /// Largest valid uncompressed size for `rect`: per tile a subencoding byte and a 127-entry palette,
    /// plus at most 4 bytes per pixel (a plain RLE run of one: CPIXEL + a length byte).
    static func maxUncompressedLength(_ rect: RFBRect) -> Int {
        let tiles = (rect.width + tileSize - 1) / tileSize * ((rect.height + tileSize - 1) / tileSize)
        return tiles * (1 + 3 * 127) + 4 * rect.width * rect.height
    }

    /// Largest compressed length accepted for `rect`: zlib's `compressBound` of the largest valid
    /// uncompressed size, plus room for sync-flush markers.
    static func maxCompressedLength(_ rect: RFBRect) -> Int {
        let n = maxUncompressedLength(rect)
        return n + (n >> 12) + (n >> 14) + (n >> 25) + 13 + 64
    }

    func decode(_ rect: RFBRect, compressed: UnsafeRawBufferPointer,
                into framebuffer: inout Framebuffer) throws(RFBError) {
        let data = try inflater.inflate(compressed, maxOutput: Self.maxUncompressedLength(rect), "ZRLE")
        let stride = framebuffer.width
        let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: 128)
        defer { palette.deallocate() }
        let result: Result<Void, RFBError> = framebuffer.pixels.withUnsafeMutableBufferPointer { pixels in
            var reader = ByteReader(data, "ZRLE")
            do throws(RFBError) {
                var tileY = rect.y
                while tileY < rect.y + rect.height {
                    let tileHeight = min(Self.tileSize, rect.y + rect.height - tileY)
                    var tileX = rect.x
                    while tileX < rect.x + rect.width {
                        let tileWidth = min(Self.tileSize, rect.x + rect.width - tileX)
                        try Self.decodeTile(&reader, origin: pixels.baseAddress! + tileY * stride + tileX,
                                            width: tileWidth, height: tileHeight, stride: stride, palette: palette)
                        tileX += Self.tileSize
                    }
                    tileY += Self.tileSize
                }
                guard reader.remaining == 0 else {
                    throw .protocolViolation("ZRLE: \(reader.remaining) bytes left after the last tile")
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// `palette` is scratch space for at least 127 entries.
    private static func decodeTile(_ reader: inout ByteReader, origin: UnsafeMutablePointer<UInt32>,
                                   width: Int, height: Int, stride: Int,
                                   palette: UnsafeMutablePointer<UInt32>) throws(RFBError) {
        let subencoding = try reader.u8()
        let count = width * height
        switch subencoding {
        case 0:  // raw CPIXELs
            var bytes = try reader.take(3 * count)
            var row = 0
            while row < height {
                var line = origin + row * stride
                let end = line + width
                while line < end {
                    line.pointee = 0xFF00_0000 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
                    line += 1
                    bytes += 3
                }
                row += 1
            }
        case 1:  // solid
            let pixel = try reader.cpixel()
            var row = 0
            while row < height {
                (origin + row * stride).update(repeating: pixel, count: width)
                row += 1
            }
        case 2...16:  // packed palette, rows padded to a byte, most significant bits first
            let size = Int(subencoding)
            let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
            let rowBytes = (width * bits + 7) / 8
            var index = 0
            while index < size {
                palette[index] = try reader.cpixel()
                index += 1
            }
            let packed = try reader.take(rowBytes * height)
            let mask = UInt8((1 << bits) - 1)
            var row = 0
            while row < height {
                let line = origin + row * stride
                let source = packed + row * rowBytes
                var column = 0
                while column < width {
                    let bitOffset = column * bits
                    let value = Int(source[bitOffset >> 3] >> UInt8(8 - bits - bitOffset & 7) & mask)
                    guard value < size else {
                        throw .protocolViolation("ZRLE: palette index \(value) beyond palette size \(size)")
                    }
                    line[column] = palette[value]
                    column += 1
                }
                row += 1
            }
        case 128:  // plain RLE
            var filled = 0
            while filled < count {
                let pixel = try reader.cpixel()
                let run = try reader.runLength(limit: count - filled)
                fillRun(origin, from: filled, count: run, width: width, stride: stride, pixel: pixel)
                filled += run
            }
        case 130...255:  // palette RLE
            let size = Int(subencoding) - 128
            var index = 0
            while index < size {
                palette[index] = try reader.cpixel()
                index += 1
            }
            var filled = 0
            while filled < count {
                let code = try reader.u8()
                let entry = Int(code & 0x7F)
                guard entry < size else {
                    throw .protocolViolation("ZRLE: palette index \(entry) beyond palette size \(size)")
                }
                let run = code & 0x80 == 0 ? 1 : try reader.runLength(limit: count - filled)
                fillRun(origin, from: filled, count: run, width: width, stride: stride, pixel: palette[entry])
                filled += run
            }
        default:  // 17…127 and 129 are unused
            throw .protocolViolation("ZRLE: invalid tile subencoding \(subencoding)")
        }
    }

    /// Writes `count` pixels starting at tile-linear position `start`, wrapping across tile rows.
    @inline(__always)
    private static func fillRun(_ origin: UnsafeMutablePointer<UInt32>, from start: Int, count: Int,
                                width: Int, stride: Int, pixel: UInt32) {
        var position = start
        var left = count
        while left > 0 {
            let row = position / width
            let column = position - row * width
            let span = min(left, width - column)
            (origin + row * stride + column).update(repeating: pixel, count: span)
            position += span
            left -= span
        }
    }
}

/// Bounds-checked reader over decompressed data; every short read throws `protocolViolation`.
struct ByteReader {
    private let base: UnsafePointer<UInt8>?
    private let count: Int
    private var offset = 0
    private let what: StaticString

    init(_ data: UnsafeRawBufferPointer, _ what: StaticString) {
        base = data.baseAddress?.assumingMemoryBound(to: UInt8.self)
        count = data.count
        self.what = what
    }

    var remaining: Int { count - offset }

    @inline(__always) mutating func u8() throws(RFBError) -> UInt8 {
        guard offset < count, let base else { throw truncated() }
        defer { offset += 1 }
        return base[offset]
    }

    /// The next `length` bytes.
    @inline(__always) mutating func take(_ length: Int) throws(RFBError) -> UnsafePointer<UInt8> {
        guard length <= count - offset, let base else { throw truncated() }
        defer { offset += length }
        return base + offset
    }

    /// A ZRLE 3-byte CPIXEL: B, G, R.
    @inline(__always) mutating func cpixel() throws(RFBError) -> UInt32 {
        let bytes = try take(3)
        return 0xFF00_0000 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
    }

    /// A ZRLE run length: bytes summed while they are 255, plus one. Throws if it exceeds `limit`.
    @inline(__always) mutating func runLength(limit: Int) throws(RFBError) -> Int {
        var length = 1
        while true {
            let byte = try u8()
            length += Int(byte)
            guard length <= limit else {
                throw .protocolViolation("\(what): run of \(length) pixels overflows the tile")
            }
            if byte != 255 { return length }
        }
    }

    private func truncated() -> RFBError { .protocolViolation("\(what): data ends inside a tile") }
}
