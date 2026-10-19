import Foundation

/// Pixel layout of framebuffer data (RFC 6143 §7.4), 16 bytes on the wire.
public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public static let byteCount = 16

    public init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColor: Bool,
                redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
                redShift: UInt8, greenShift: UInt8, blueShift: UInt8) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// Parses the 16-byte wire form; the 3 trailing padding bytes are ignored.
    init(wire bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == Self.byteCount)
        let b = Array(bytes)
        self.init(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColor: b[3] != 0,
                  redMax: UInt16(b[4]) << 8 | UInt16(b[5]),
                  greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
                  blueMax: UInt16(b[8]) << 8 | UInt16(b[9]),
                  redShift: b[10], greenShift: b[11], blueShift: b[12])
    }

    /// 16-byte wire form (used by SetPixelFormat, RFC 6143 §7.5.1).
    public var wireBytes: [UInt8] {
        [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0,
         UInt8(redMax >> 8), UInt8(truncatingIfNeeded: redMax),
         UInt8(greenMax >> 8), UInt8(truncatingIfNeeded: greenMax),
         UInt8(blueMax >> 8), UInt8(truncatingIfNeeded: blueMax),
         redShift, greenShift, blueShift, 0, 0, 0]
    }
}

/// The server's description of the session, sent after ClientInit (RFC 6143 §7.3.2).
public struct ServerInit: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var pixelFormat: PixelFormat
    /// Desktop name, decoded as UTF-8 (invalid sequences are replaced).
    public var name: String

    public init(width: UInt16, height: UInt16, pixelFormat: PixelFormat, name: String) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
    }
}
