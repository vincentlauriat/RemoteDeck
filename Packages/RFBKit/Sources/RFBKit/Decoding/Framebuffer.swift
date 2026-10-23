import Foundation

/// A rectangle in framebuffer coordinates (pixels, origin top-left).
public struct RFBRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width == 0 || height == 0 }
}

/// The client-side copy of the remote screen: 32-bit pixels, `0xAARRGGBB` as a `UInt32`, i.e. bytes
/// B, G, R, A in memory on the little-endian Macs RFBKit runs on (Metal `bgra8Unorm`). Alpha is always
/// 255. Row-major, no row padding: pixel (x, y) is `pixels[y * width + x]`.
public struct Framebuffer: Equatable, Sendable {
    /// Largest width or height accepted from a server.
    public static let maxDimension = 16384
    /// Largest pixel count accepted (8192 × 8192, 256 MiB of pixels).
    public static let maxPixelCount = 8192 * 8192
    /// Opaque black, the content of a new framebuffer.
    public static let black: UInt32 = 0xFF00_0000

    public private(set) var width: Int
    public private(set) var height: Int
    public internal(set) var pixels: [UInt32]

    /// Throws if the size is zero or beyond `maxDimension` / `maxPixelCount`.
    public init(width: Int, height: Int) throws(RFBError) {
        try Self.validate(width: width, height: height)
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: Self.black, count: width * height)
    }

    /// A framebuffer holding `pixels` (row-major, exactly `width × height` of them): test images and
    /// the Debug demo.
    public init(width: Int, height: Int, pixels: [UInt32]) throws(RFBError) {
        try Self.validate(width: width, height: height)
        guard pixels.count == width * height else {
            throw .protocolViolation("\(pixels.count) pixels for a \(width)x\(height) framebuffer")
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static func validate(width: Int, height: Int) throws(RFBError) {
        guard (1...maxDimension).contains(width), (1...maxDimension).contains(height),
              width * height <= maxPixelCount else {
            throw .protocolViolation("framebuffer size \(width)x\(height) out of range")
        }
    }

    /// Pixel at (x, y); traps when out of bounds.
    public subscript(x: Int, y: Int) -> UInt32 {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of bounds")
        return pixels[y * width + x]
    }

    /// Changes the size, keeping the overlapping top-left content; new areas are black.
    mutating func resize(width newWidth: Int, height newHeight: Int) throws(RFBError) {
        try Self.validate(width: newWidth, height: newHeight)
        guard newWidth != width || newHeight != height else { return }
        var resized = [UInt32](repeating: Self.black, count: newWidth * newHeight)
        let keptWidth = min(width, newWidth)
        for row in 0..<min(height, newHeight) {
            resized[(row * newWidth)..<(row * newWidth + keptWidth)] = pixels[(row * width)..<(row * width + keptWidth)]
        }
        width = newWidth
        height = newHeight
        pixels = resized
    }

    /// Throws unless `rect` lies inside the framebuffer.
    func check(_ rect: RFBRect, _ what: StaticString) throws(RFBError) {
        guard rect.x + rect.width <= width, rect.y + rect.height <= height else {
            throw .protocolViolation("\(what) rectangle \(rect.x),\(rect.y) \(rect.width)x\(rect.height) "
                                     + "outside the \(width)x\(height) framebuffer")
        }
    }

    /// Copies the pixels of `rect` (row-major), for an update event.
    func copyPixels(in rect: RFBRect) -> [UInt32] {
        var copy = [UInt32]()
        copy.reserveCapacity(rect.width * rect.height)
        for row in rect.y..<(rect.y + rect.height) {
            let start = row * width + rect.x
            copy += pixels[start..<(start + rect.width)]
        }
        return copy
    }

    /// CopyRect: copies `width × height` pixels from (`sourceX`, `sourceY`) to `destination`.
    /// Overlapping regions are handled like `memmove` (rows walked away from the overlap).
    mutating func copy(from sourceX: Int, _ sourceY: Int, to destination: RFBRect) {
        let stride = width
        let rows = destination.height
        let rowBytes = destination.width * MemoryLayout<UInt32>.size
        guard rows > 0, rowBytes > 0 else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            // Walk rows away from the overlap: bottom-up when moving down.
            let downward = destination.y > sourceY
            for step in 0..<rows {
                let row = downward ? rows - 1 - step : step
                memmove(base + (destination.y + row) * stride + destination.x,
                        base + (sourceY + row) * stride + sourceX, rowBytes)
            }
        }
    }

    /// Fills `rect` with one colour.
    mutating func fill(_ rect: RFBRect, with pixel: UInt32) {
        let stride = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            for row in rect.y..<(rect.y + rect.height) {
                let start = row * stride + rect.x
                buffer[start..<(start + rect.width)].update(repeating: pixel)
            }
        }
    }
}

/// Pixel helpers for the RFBKit pixel format (`PixelFormat.bgra32`).
enum Pixel {
    /// From the 4 wire bytes B, G, R, X (the padding byte is ignored).
    @inline(__always) static func fromBGRX(_ b: UInt8, _ g: UInt8, _ r: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    @inline(__always) static func fromRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}
