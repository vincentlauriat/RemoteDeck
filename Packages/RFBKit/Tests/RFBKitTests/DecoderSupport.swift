import Foundation
import Testing
import zlib
@testable import RFBKit

/// Vector shape filled in by the generated `DecoderVectors.swift`.
struct DecoderVector: Sendable, CustomTestStringConvertible {
    let name: String
    /// Framebuffer size before the stream (from ServerInit).
    let width: Int
    let height: Int
    let expectedWidth: Int
    let expectedHeight: Int
    /// Number of `.framebufferUpdate` events the stream produces.
    let updates: Int
    /// Largest per-component difference allowed (JPEG only; 0 = exact).
    let tolerance: Int
    /// Server → client bytes after ServerInit, base64.
    let stream: String
    /// Expected framebuffer as R, G, B bytes, zlib-compressed then base64.
    let expectedRGB: String

    init(name: String, width: Int, height: Int, expectedWidth: Int, expectedHeight: Int, updates: Int,
         tolerance: Int, stream: String, expectedRGB: String) {
        self.name = name
        self.width = width
        self.height = height
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
        self.updates = updates
        self.tolerance = tolerance
        self.stream = stream
        self.expectedRGB = expectedRGB
    }

    var testDescription: String { name }

    var streamBytes: [UInt8] { Self.base64(stream) }

    /// Expected pixels in `Framebuffer.pixels` form.
    var expectedPixels: [UInt32] {
        let rgb = Self.uncompress(Self.base64(expectedRGB), size: 3 * expectedWidth * expectedHeight)
        return stride(from: 0, to: rgb.count, by: 3).map {
            0xFF00_0000 | UInt32(rgb[$0]) << 16 | UInt32(rgb[$0 + 1]) << 8 | UInt32(rgb[$0 + 2])
        }
    }

    private static func base64(_ text: String) -> [UInt8] {
        [UInt8](Data(base64Encoded: text.filter { !$0.isWhitespace })!)
    }

    /// One-shot libz `uncompress`, independent of RFBKit's `Inflater`.
    private static func uncompress(_ data: [UInt8], size: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size)
        var length = uLongf(size)
        let status = zlib.uncompress(&output, &length, data, uLong(data.count))
        precondition(status == Z_OK && Int(length) == size, "bad expected image")
        return output
    }
}

/// Feeds `stream` to a decoder in `chunking` pieces and collects the events.
func decode(_ stream: [UInt8], width: Int, height: Int, chunking: Chunking) throws(RFBError)
    -> (ServerMessageDecoder, [RFBEvent]) {
    var decoder = try ServerMessageDecoder(width: width, height: height)
    var events: [RFBEvent] = []
    for chunk in chunking.split(stream) {
        events += try decoder.receive(chunk)
    }
    return (decoder, events)
}

/// The error a stream produces, or `nil` if it decodes cleanly.
func decodingError(_ stream: [UInt8], width: Int = 64, height: Int = 64, chunking: Chunking = .whole) -> RFBError? {
    do {
        _ = try decode(stream, width: width, height: height, chunking: chunking)
        return nil
    } catch {
        return error
    }
}

/// `true` when `error` is a protocol violation whose message contains `fragment`.
func isViolation(_ error: RFBError?, _ fragment: String) -> Bool {
    guard case .protocolViolation(let message) = error else { return false }
    return message.contains(fragment)
}

/// Largest per-component difference between two pixel arrays of the same size.
func maxComponentDifference(_ a: [UInt32], _ b: [UInt32]) -> Int {
    precondition(a.count == b.count)
    var worst = 0
    for (p, q) in zip(a, b) where p != q {
        for shift in [0, 8, 16, 24] as [UInt32] {
            worst = max(worst, abs(Int((p >> shift) & 0xFF) - Int((q >> shift) & 0xFF)))
        }
    }
    return worst
}

/// Hand-built server messages and rectangles for the framebuffer protocol.
enum FramebufferMessage {
    static func update(_ rectangles: [UInt8]..., count: Int? = nil) -> [UInt8] {
        [0, 0] + UInt16(count ?? rectangles.count).bigEndianBytes + rectangles.flatMap { $0 }
    }

    static func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, encoding: Int32) -> [UInt8] {
        UInt16(x).bigEndianBytes + UInt16(y).bigEndianBytes + UInt16(width).bigEndianBytes
            + UInt16(height).bigEndianBytes + UInt32(bitPattern: encoding).bigEndianBytes
    }

    /// Raw rectangle filled with one BGRX pixel.
    static func raw(_ x: Int, _ y: Int, _ width: Int, _ height: Int, b: UInt8, g: UInt8, r: UInt8) -> [UInt8] {
        rect(x, y, width, height, encoding: Encoding.raw)
            + Array([[UInt8]](repeating: [b, g, r, 0], count: width * height).joined())
    }

    static func cutText(_ bytes: [UInt8]) -> [UInt8] {
        [3, 0, 0, 0] + UInt32(bytes.count).bigEndianBytes + bytes
    }

    /// One-shot zlib stream (a new stream: header included), sync-flushed like a server's first rect.
    static func zlibStream(_ data: [UInt8]) -> [UInt8] {
        Deflater().compress(data)
    }

    static func zrle(_ x: Int, _ y: Int, _ width: Int, _ height: Int, compressed: [UInt8]) -> [UInt8] {
        rect(x, y, width, height, encoding: Encoding.zrle) + UInt32(compressed.count).bigEndianBytes + compressed
    }

    static func tightCompactLength(_ n: Int) -> [UInt8] {
        var out = [UInt8(n & 0x7F)]
        if n > 0x7F {
            out[0] |= 0x80
            out.append(UInt8((n >> 7) & 0x7F))
            if n > 0x3FFF {
                out[1] |= 0x80
                out.append(UInt8(n >> 14))
            }
        }
        return out
    }
}

/// Test-side zlib compressor (one persistent stream, sync flush per call), used for hand-built
/// error cases and the performance frames.
final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init(level: Int32 = 6) {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let status = deflateInit_(stream, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK)
    }

    deinit {
        deflateEnd(stream)
        stream.deallocate()
    }

    func compress(_ data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Int(deflateBound(stream, uLong(data.count))) + 64)
        var input = data
        let produced = input.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                stream.pointee.next_in = inBuffer.baseAddress
                stream.pointee.avail_in = uInt(inBuffer.count)
                stream.pointee.next_out = outBuffer.baseAddress
                stream.pointee.avail_out = uInt(outBuffer.count)
                let status = deflate(stream, Z_SYNC_FLUSH)
                // Z_BUF_ERROR: an empty input right after a flush has nothing to emit (fuzz generators do that).
                precondition((status == Z_OK || status == Z_BUF_ERROR && data.isEmpty) && stream.pointee.avail_in == 0)
                return outBuffer.count - Int(stream.pointee.avail_out)
            }
        }
        return Array(output.prefix(produced))
    }
}
