import Foundation
import zlib

/// The Extended Clipboard pseudo-encoding (rfbproto, "Extended Clipboard Pseudo-Encoding",
/// 0xC0A1E5CE). A client that advertises it accepts ServerCutText / ClientCutText whose S32 length is
/// negative: `abs(length)` bytes follow, starting with U32 flags (formats in bits 0–15, actions in
/// bits 24–28). RFBKit uses the text format only: UTF-8 with CR LF line ends and a terminating NUL
/// counted in its size, carried zlib-compressed in a provide message.
public enum ExtendedClipboard {
    // Formats.
    public static let text: UInt32 = 1 << 0
    // Actions.
    public static let caps: UInt32 = 1 << 24
    public static let request: UInt32 = 1 << 25
    public static let peek: UInt32 = 1 << 26
    public static let notify: UInt32 = 1 << 27
    public static let provide: UInt32 = 1 << 28

    static let formatMask: UInt32 = 0xFFFF
    static let actionMask: UInt32 = 0x1F00_0000

    /// Extended messages longer than this (compressed) are skipped without being buffered.
    public static let maxMessageLength = 2 << 20
    /// Provide data inflated beyond this is dropped: one text of `ServerMessageDecoder.maxCutTextLength`
    /// bytes, its NUL and its U32 size, plus room for small empty entries of other formats.
    static let maxInflatedLength = ServerMessageDecoder.maxCutTextLength + 4096

    /// One extended message, parsed. Messages RFBKit cannot use (malformed, too large, other formats
    /// only) are dropped by the decoder; they never end the session.
    public enum Message: Equatable, Sendable {
        /// The sender's formats and actions, with its maximum unsolicited size per format
        /// (`[format bit: size]`).
        case caps(flags: UInt32, maxSizes: [UInt32: UInt32])
        case request(formats: UInt32)
        case peek
        case notify(formats: UInt32)
        /// `text` is `nil` when the provide carries no text format.
        case provide(text: String?)
    }

    // MARK: Parsing (server → client)

    /// Parses the payload of an extended ServerCutText (flags included). `nil` when it is malformed.
    static func parse(_ payload: UnsafeRawBufferPointer) -> Message? {
        guard payload.count >= 4 else { return nil }
        let flags = readU32(payload, 0)
        let formats = flags & formatMask
        if flags & caps != 0 {
            var sizes: [UInt32: UInt32] = [:]
            var offset = 4
            for bit in 0..<16 where formats & (1 << UInt32(bit)) != 0 {
                guard payload.count >= offset + 4 else { return nil }
                sizes[1 << UInt32(bit)] = readU32(payload, offset)
                offset += 4
            }
            return .caps(flags: flags, maxSizes: sizes)
        }
        // Without caps, exactly one action bit is set (rfbproto).
        // Reserved bits (16–23, 29–31) are ignored.
        switch flags & actionMask {
        case request: return .request(formats: formats)
        case peek: return .peek
        case notify: return .notify(formats: formats)
        case provide:
            let compressed = UnsafeRawBufferPointer(rebasing: payload[4...])
            return parseProvide(formats: formats, compressed: compressed)
        default: return nil
        }
    }

    /// Inflates a provide (a new zlib stream per message, ended or only sync-flushed) and reads the
    /// U32 size + data of each format bit set, in bit order; only the text is kept.
    private static func parseProvide(formats: UInt32, compressed: UnsafeRawBufferPointer) -> Message? {
        guard formats & text != 0 else { return .provide(text: nil) }
        guard !compressed.isEmpty else { return nil }
        let inflater = Inflater()
        guard let data = try? inflater.inflate(compressed, maxOutput: maxInflatedLength, "extended clipboard") else {
            return nil
        }
        // Text is bit 0, so it is the first entry.
        guard data.count >= 4 else { return nil }
        let size = Int(readU32(data, 0))
        guard size <= data.count - 4, size <= ServerMessageDecoder.maxCutTextLength + 1 else { return nil }
        var bytes = UnsafeRawBufferPointer(rebasing: data[4..<(4 + size)])
        // The terminating NUL (and anything a sloppy sender put after one) is not text.
        if let nul = bytes.firstIndex(of: 0) { bytes = UnsafeRawBufferPointer(rebasing: bytes[0..<nul]) }
        let decoded = String(decoding: bytes, as: UTF8.self)
        return .provide(text: ClipboardText.normalizedLF(decoded))
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }

    private static func readU32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    // MARK: Encoding (client → server)

    /// The client's caps: text only, every action but caps itself, text up to `maxCutTextLength`.
    static var clientCaps: ClientMessage {
        .extendedClientCutText(flags: caps | text | request | peek | notify | provide,
                               payload: u32(UInt32(ServerMessageDecoder.maxCutTextLength)))
    }

    static func provideMessage(text value: String?) -> ClientMessage {
        guard let value else { return .extendedClientCutText(flags: provide, payload: compress([])) }
        var data = Array(ClipboardText.toCRLF(value).utf8)
        data.append(0)
        return .extendedClientCutText(flags: provide | text, payload: compress(u32(UInt32(data.count)) + data))
    }

    /// One complete zlib stream (header and end): a receiver reading one stream per message accepts it.
    static func compress(_ bytes: [UInt8]) -> [UInt8] {
        var length = compressBound(uLong(bytes.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                compress2(out.baseAddress, &length, input.baseAddress, uLong(input.count), Z_DEFAULT_COMPRESSION)
            }
        }
        precondition(status == Z_OK, "compress2 failed with \(status)")   // only on a bad bound or level
        output.removeLast(output.count - Int(length))
        return output
    }
}

/// Text conversions shared by both clipboard paths.
public enum ClipboardText {
    /// Legacy cut text (RFC 6143 §7.5.6): Latin-1, LF line ends. Characters outside Latin-1 become
    /// `?`, as TigerVNC's viewer does: the remote gets the text with a visible gap rather than nothing.
    public static func latin1Bytes(_ text: String) -> [UInt8] {
        normalizedLF(text).unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : 0x3F }
    }

    /// The text as a server echoing `latin1Bytes(text)` sends it back, once decoded.
    static func latin1Echo(_ text: String) -> String {
        String(String.UnicodeScalarView(latin1Bytes(text).map { Unicode.Scalar($0) }))
    }

    /// Extended text on the wire: every line end as CR LF.
    static func toCRLF(_ text: String) -> String {
        normalizedLF(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Every line end (CR LF, lone CR, LF) as LF, both directions alike: "\r\r\n" is two line ends.
    public static func normalizedLF(_ text: String) -> String {
        // Swift treats "\r\n" as one Character: work on unicode scalars.
        guard text.unicodeScalars.contains("\r") else { return text }
        var scalars = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n", previousCR {
                previousCR = false
                continue   // the LF of a CR LF already written
            }
            previousCR = scalar == "\r"
            scalars.append(previousCR ? "\n" : scalar)
        }
        return String(scalars)
    }
}

/// What became of a `shareClipboard` call.
public enum ClipboardShare: Equatable, Sendable {
    /// Sent (or announced with a notify). `echo` is the text as the server holds it (Latin-1 `?`
    /// substitutions, LF line ends): a server sending it back is echoing, not a new copy.
    case sent(echo: String)
    /// Over 1 MiB of UTF-8, or over the server's unsolicited limit when it cannot be notified.
    case tooLarge
    case notSharing
}

/// What a session knows about the server's clipboard and what the user shares (pure, so the
/// negotiation is unit-tested without a socket). `RFBConnection` owns one per session.
public struct ClipboardNegotiation: Sendable {
    /// Off: nothing is sent, requests are answered with no text, received text is dropped.
    public var sharing: Bool {
        didSet { if !sharing { localText = nil } }
    }
    /// The server's caps, once received (only servers that support the pseudo-encoding send them).
    public private(set) var serverCaps: (flags: UInt32, textMaxSize: UInt32)?
    /// The last local text shared, to answer the server's request or peek. Only text the user
    /// already shared (never read from the pasteboard here).
    private var localText: String?

    public init(sharing: Bool) {
        self.sharing = sharing
    }

    /// Whether text goes out as an extended provide/notify (UTF-8) rather than Latin-1 cut text.
    public var usesExtended: Bool {
        guard let caps = serverCaps?.flags else { return false }
        return caps & ExtendedClipboard.text != 0
            && caps & (ExtendedClipboard.provide | ExtendedClipboard.notify) != 0
    }

    /// Shares `text` with the server: the messages to send and the text as the server will hold it
    /// (`ClipboardShare.sent`), or why nothing goes out.
    public mutating func share(_ text: String) -> (messages: [ClientMessage], outcome: ClipboardShare) {
        guard sharing else { return ([], .notSharing) }
        guard text.utf8.count <= ServerMessageDecoder.maxCutTextLength else { return ([], .tooLarge) }
        guard usesExtended, let caps = serverCaps else {
            return ([.clientCutText(ClipboardText.latin1Bytes(text))], .sent(echo: ClipboardText.latin1Echo(text)))
        }
        let echo = ClipboardText.normalizedLF(text)
        // Unsolicited provide only within the server's limit (+1: the NUL); otherwise a notify, and
        // the server asks for it. A server with neither room nor notify gets nothing.
        let size = UInt32(ClipboardText.toCRLF(text).utf8.count + 1)
        if caps.flags & ExtendedClipboard.provide != 0, size <= caps.textMaxSize {
            localText = text
            return ([ExtendedClipboard.provideMessage(text: text)], .sent(echo: echo))
        }
        if caps.flags & ExtendedClipboard.notify != 0 {
            localText = text
            return ([.extendedClientCutText(flags: ExtendedClipboard.notify | ExtendedClipboard.text, payload: [])],
                    .sent(echo: echo))
        }
        return ([], .tooLarge)
    }

    /// Handles a server event: the replies to send, and the text to hand to the app (`nil`: none).
    public mutating func handle(_ event: RFBEvent) -> (replies: [ClientMessage], text: String?) {
        switch event {
        case .serverCutText(let text):
            return ([], sharing ? ClipboardText.normalizedLF(text) : nil)
        case .extendedClipboard(let message):
            return handle(message)
        default:
            return ([], nil)
        }
    }

    private mutating func handle(_ message: ExtendedClipboard.Message) -> (replies: [ClientMessage], text: String?) {
        switch message {
        case .caps(let flags, let sizes):
            serverCaps = (flags, sizes[ExtendedClipboard.text] ?? 0)
            return ([ExtendedClipboard.clientCaps], nil)
        case .notify(let formats):
            guard sharing, formats & ExtendedClipboard.text != 0 else { return ([], nil) }
            return ([.extendedClientCutText(flags: ExtendedClipboard.request | ExtendedClipboard.text, payload: [])], nil)
        case .request(let formats):
            let text = sharing && formats & ExtendedClipboard.text != 0 ? localText : nil
            return ([ExtendedClipboard.provideMessage(text: text)], nil)
        case .peek:
            let formats = sharing && localText != nil ? ExtendedClipboard.text : 0
            return ([.extendedClientCutText(flags: ExtendedClipboard.notify | formats, payload: [])], nil)
        case .provide(let text):
            return ([], sharing ? text : nil)
        }
    }
}
