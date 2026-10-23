import Foundation

/// RFB encoding numbers (RFC 6143 §7.7 and the IANA registry). Negative values are pseudo-encodings.
public enum Encoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let tight: Int32 = 7
    public static let zrle: Int32 = 16
    /// The server announces a framebuffer size change (RFC 6143 §7.8.2).
    public static let desktopSize: Int32 = -223
    /// The server sends the cursor shape and hotspot (RFC 6143 §7.8.1).
    public static let cursor: Int32 = -239
    /// Multi-screen variant of `desktopSize` (rfbproto, ExtendedDesktopSize).
    public static let extendedDesktopSize: Int32 = -308
    /// UTF-8 clipboard through extended cut text messages (rfbproto, Extended Clipboard, 0xC0A1E5CE).
    public static let extendedClipboard: Int32 = -1063131698

    /// Tight JPEG quality pseudo-encoding, level 0 (lowest) … 9 (highest): −32 … −23. Servers based
    /// on libvncserver use Tight's JPEG mode only when the client advertises one of these.
    public static func tightJPEGQuality(_ level: Int) -> Int32 {
        precondition((0...9).contains(level), "JPEG quality level must be 0…9")
        return -32 + Int32(level)
    }

    /// What `RFBConnection.startSession` advertises by default, by preference: Tight, ZRLE, CopyRect,
    /// Raw, then the pseudo-encodings. No JPEG quality level, so Tight stays lossless.
    public static let preferred: [Int32] = [tight, zrle, copyRect, raw, extendedDesktopSize, desktopSize, cursor,
                                            extendedClipboard]
}

extension PixelFormat {
    /// The format RFBKit requests with SetPixelFormat and that every decoder assumes: 32 bpp, depth 24,
    /// little-endian true colour with shifts 16/8/0, i.e. bytes B, G, R, X on the wire — what macOS 26
    /// announces in its ServerInit.
    public static let bgra32 = PixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
                                           redMax: 255, greenMax: 255, blueMax: 255,
                                           redShift: 16, greenShift: 8, blueShift: 0)
}

/// Client → server messages (RFC 6143 §7.5), encoded to their wire form.
public enum ClientMessage: Equatable, Sendable {
    case setPixelFormat(PixelFormat)
    case setEncodings([Int32])
    case framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16)
    /// `key` is an X11 keysym.
    case keyEvent(down: Bool, key: UInt32)
    /// `buttonMask` bit 0 = left, 1 = middle, 2 = right, 3/4 = wheel up/down.
    case pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16)
    /// ClientCutText (RFC 6143 §7.5.6): Latin-1 bytes, LF line ends (`ClipboardText.latin1Bytes`).
    case clientCutText([UInt8])
    /// Extended ClientCutText (Extended Clipboard): negative length, U32 flags, then `payload`.
    case extendedClientCutText(flags: UInt32, payload: [UInt8])

    public var wireBytes: [UInt8] {
        switch self {
        case .setPixelFormat(let format):
            return [0, 0, 0, 0] + format.wireBytes
        case .setEncodings(let encodings):
            precondition(encodings.count <= Int(UInt16.max), "too many encodings")
            var bytes: [UInt8] = [2, 0] + Self.u16(UInt16(encodings.count))
            for encoding in encodings { bytes += Self.u32(UInt32(bitPattern: encoding)) }
            return bytes
        case .framebufferUpdateRequest(let incremental, let x, let y, let width, let height):
            return [3, incremental ? 1 : 0] + Self.u16(x) + Self.u16(y) + Self.u16(width) + Self.u16(height)
        case .keyEvent(let down, let key):
            return [4, down ? 1 : 0, 0, 0] + Self.u32(key)
        case .pointerEvent(let buttonMask, let x, let y):
            return [5, buttonMask] + Self.u16(x) + Self.u16(y)
        case .clientCutText(let text):
            precondition(text.count <= Int(UInt32.max), "cut text too long")
            return [6, 0, 0, 0] + Self.u32(UInt32(text.count)) + text
        case .extendedClientCutText(let flags, let payload):
            precondition(payload.count <= Int(Int32.max) - 4, "extended cut text too long")
            return [6, 0, 0, 0] + Self.u32(UInt32(bitPattern: -Int32(4 + payload.count))) + Self.u32(flags) + payload
        }
    }

    private static func u16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)] }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }
}
