import Foundation

/// Transport-agnostic decoder for the server → client messages that follow ServerInit
/// (RFC 6143 §7.6): FramebufferUpdate, SetColourMapEntries (parsed and ignored), Bell and
/// ServerCutText. It owns the framebuffer and the zlib streams of ZRLE and Tight.
///
/// Feed it every byte received with `receive(_:)` in chunks of any size; it returns the events that
/// completed. Each rectangle is decoded as soon as its bytes have arrived. Every length is checked
/// against a limit as soon as it is parsed, before its payload is awaited, so the buffer never grows
/// beyond the largest valid rectangle (bounded by the framebuffer size) plus one chunk.
///
/// The decoder assumes the server sends `PixelFormat.bgra32`, which `RFBConnection.startSession`
/// requests before any update. It is not `Sendable` (it holds zlib state): keep it on one thread.
public struct ServerMessageDecoder {
    /// ServerCutText longer than this is skipped without being buffered (no event).
    public static let maxCutTextLength = 1 << 20

    private enum State {
        case messageType
        /// Inside a FramebufferUpdate, before the header of the next rectangle.
        case rectangleHeader(remaining: Int)
        case rectanglePayload(RFBRect, encoding: Int32, remaining: Int)
        /// Discarding an oversized ServerCutText.
        case skipping(Int)
        case failed(RFBError)
    }

    public private(set) var framebuffer: Framebuffer
    private var state = State.messageType
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var dirty: [RFBRect] = []
    /// Summed area of `dirty`; with the count, keeps the region copies of one update within one framebuffer.
    private var dirtyArea = 0
    /// Beyond this many dirty rectangles in one update, they are merged into their bounding box.
    static let maxDirtyRects = 64
    private let zrle = ZRLEDecoder()
    private let tight = TightDecoder()

    public init(width: Int, height: Int) throws(RFBError) {
        framebuffer = try Framebuffer(width: width, height: height)
    }

    /// Bytes received but not yet parsed.
    var bufferedCount: Int { buffer.count - readIndex }

    /// Processes bytes from the server. After an error, every later call throws it again.
    public mutating func receive(_ bytes: some Sequence<UInt8>) throws(RFBError) -> [RFBEvent] {
        if case .failed(let error) = state { throw error }
        if readIndex > 0, readIndex >= buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer.append(contentsOf: bytes)
        var events: [RFBEvent] = []
        do throws(RFBError) {
            while try advance(&events) {}
        } catch {
            state = .failed(error)
            buffer = []
            readIndex = 0
            throw error
        }
        return events
    }

    // MARK: State machine

    /// Parses one message or rectangle if it is complete. Returns `true` when it moved on.
    private mutating func advance(_ events: inout [RFBEvent]) throws(RFBError) -> Bool {
        switch state {
        case .messageType:
            guard let type = byte(at: 0) else { return false }
            switch type {
            case 0:  // FramebufferUpdate: type, padding, U16 number of rectangles
                guard let count = u16(at: 2) else { return false }
                consume(4)
                state = .rectangleHeader(remaining: Int(count))
            case 1:  // SetColourMapEntries: type, padding, U16 first colour, U16 count, count × 6 bytes
                guard let count = u16(at: 4) else { return false }
                guard available >= 6 + 6 * Int(count) else { return false }
                consume(6 + 6 * Int(count))
            case 2:
                consume(1)
                events.append(.bell)
            case 3:  // ServerCutText: type, 3 padding bytes, U32 length, Latin-1 text
                guard let length = u32(at: 4).map(Int.init) else { return false }
                if length > Self.maxCutTextLength {
                    consume(8)
                    state = .skipping(length)
                    return true
                }
                guard available >= 8 + length else { return false }
                let text = withBytes(8, length) { String(bytes: $0, encoding: .isoLatin1) ?? "" }
                consume(8 + length)
                events.append(.serverCutText(text))
            default:
                throw .protocolViolation("unknown server message type \(type)")
            }

        case .skipping(let left):
            let skipped = min(left, available)
            guard skipped > 0 else { return false }
            consume(skipped)
            state = left == skipped ? .messageType : .skipping(left - skipped)

        case .rectangleHeader(let remaining):
            guard remaining > 0 else {
                events.append(.framebufferUpdate(takeUpdate()))
                state = .messageType
                return true
            }
            guard available >= 12, let x = u16(at: 0), let y = u16(at: 2), let width = u16(at: 4),
                  let height = u16(at: 6), let encoding = u32(at: 8).map({ Int32(bitPattern: $0) }) else {
                return false
            }
            consume(12)
            let rect = RFBRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
            try begin(rect, encoding: encoding, remaining: remaining - 1, &events)

        case .rectanglePayload(let rect, let encoding, let remaining):
            guard try decodePayload(rect, encoding: encoding, &events) else { return false }
            state = .rectangleHeader(remaining: remaining)

        case .failed:
            return false
        }
        return true
    }

    /// Validates a rectangle header; pseudo-encodings without payload take effect here.
    private mutating func begin(_ rect: RFBRect, encoding: Int32, remaining: Int,
                                _ events: inout [RFBEvent]) throws(RFBError) {
        switch encoding {
        case Encoding.raw, Encoding.copyRect, Encoding.zrle, Encoding.tight:
            try framebuffer.check(rect, "update")
        case Encoding.desktopSize:
            try resize(width: rect.width, height: rect.height, &events)
            state = .rectangleHeader(remaining: remaining)
            return
        case Encoding.extendedDesktopSize:
            break
        case Encoding.cursor:
            guard rect.width <= CursorShape.maxDimension, rect.height <= CursorShape.maxDimension else {
                throw .protocolViolation("cursor size \(rect.width)x\(rect.height) exceeds the limit")
            }
        default:
            throw .protocolViolation("unsupported encoding \(encoding)")
        }
        state = .rectanglePayload(rect, encoding: encoding, remaining: remaining)
    }

    /// Decodes the payload of `rect` if it is complete; `false` while more bytes are needed.
    private mutating func decodePayload(_ rect: RFBRect, encoding: Int32,
                                         _ events: inout [RFBEvent]) throws(RFBError) -> Bool {
        let pixelCount = rect.width * rect.height
        switch encoding {
        case Encoding.raw:
            let length = 4 * pixelCount
            guard available >= length else { return false }
            decodeRaw(rect)
            consume(length)

        case Encoding.copyRect:
            guard let sourceX = u16(at: 0).map(Int.init), let sourceY = u16(at: 2).map(Int.init) else { return false }
            try framebuffer.check(RFBRect(x: sourceX, y: sourceY, width: rect.width, height: rect.height), "CopyRect source")
            framebuffer.copy(from: sourceX, sourceY, to: rect)
            consume(4)

        case Encoding.zrle:
            guard let length = u32(at: 0).map(Int.init) else { return false }
            let limit = ZRLEDecoder.maxCompressedLength(rect)
            guard length <= limit else {
                throw .protocolViolation("ZRLE length \(length) exceeds the bound \(limit) for the rectangle")
            }
            guard available >= 4 + length else { return false }
            try withPayload { (decoder, payload) throws(RFBError) in
                try decoder.zrle.decode(rect, compressed: UnsafeRawBufferPointer(rebasing: payload[4..<(4 + length)]),
                                        into: &decoder.framebuffer)
            }
            consume(4 + length)

        case Encoding.tight:
            let decoded: Int? = try withPayload { (decoder, payload) throws(RFBError) -> Int? in
                guard let layout = try TightDecoder.measure(payload, rect: rect),
                      payload.count >= layout.totalLength else { return nil }
                try decoder.tight.decode(rect, payload: payload, layout: layout, into: &decoder.framebuffer)
                return layout.totalLength
            }
            guard let decoded else { return false }
            consume(decoded)

        case Encoding.cursor:
            let maskLength = (rect.width + 7) / 8 * rect.height
            guard available >= 4 * pixelCount + maskLength else { return false }
            let shape = withBytes(0, 4 * pixelCount + maskLength) { Self.cursorShape(rect, $0) }
            consume(4 * pixelCount + maskLength)
            events.append(.cursor(shape))
            return true

        case Encoding.extendedDesktopSize:
            // U8 number of screens, 3 padding bytes, then 16 bytes per screen (id, x, y, w, h, flags).
            guard let screens = byte(at: 0) else { return false }
            guard available >= 4 + 16 * Int(screens) else { return false }
            consume(4 + 16 * Int(screens))
            // y is the status of a client-requested change; non-zero means it failed and nothing changed.
            if rect.y == 0 { try resize(width: rect.width, height: rect.height, &events) }
            return true

        default:
            preconditionFailure("encoding \(encoding) passed begin()")
        }
        if !rect.isEmpty { markDirty(rect) }
        return true
    }

    private mutating func decodeRaw(_ rect: RFBRect) {
        let stride = framebuffer.width
        withPayload { decoder, payload in
            var source = payload.baseAddress!
            decoder.framebuffer.pixels.withUnsafeMutableBufferPointer { pixels in
                var row = 0
                while row < rect.height {
                    var line = pixels.baseAddress! + (rect.y + row) * stride + rect.x
                    let end = line + rect.width
                    while line < end {
                        line.pointee = UInt32(littleEndian: source.loadUnaligned(as: UInt32.self)) | 0xFF00_0000
                        line += 1
                        source += 4
                    }
                    row += 1
                }
            }
        }
    }

    private static func cursorShape(_ rect: RFBRect, _ bytes: UnsafeRawBufferPointer) -> CursorShape {
        let width = rect.width
        let height = rect.height
        let maskRow = (width + 7) / 8
        let maskStart = 4 * width * height
        var pixels = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let maskByte = bytes[maskStart + row * maskRow + column >> 3]
                guard maskByte >> UInt8(7 - column & 7) & 1 == 1 else { continue }
                let offset = 4 * (row * width + column)
                pixels[row * width + column] = Pixel.fromBGRX(bytes[offset], bytes[offset + 1], bytes[offset + 2])
            }
        }
        // The hotspot is clamped rather than rejected: a bad hotspot is cosmetic.
        return CursorShape(width: width, height: height,
                           hotspotX: min(rect.x, max(0, width - 1)), hotspotY: min(rect.y, max(0, height - 1)),
                           pixels: pixels)
    }

    private mutating func resize(width: Int, height: Int, _ events: inout [RFBEvent]) throws(RFBError) {
        guard width != framebuffer.width || height != framebuffer.height else { return }
        // Regions decoded so far refer to the old size: hand them out first.
        if !dirty.isEmpty { events.append(.framebufferUpdate(takeUpdate(completesMessage: false))) }
        try framebuffer.resize(width: width, height: height)
        events.append(.desktopResized(width: width, height: height))
    }

    /// Records a changed rectangle. A hostile server can repaint the whole screen many times in one
    /// update for a few bytes (Tight fills), so once the rectangles would cover more than the
    /// framebuffer or exceed `maxDirtyRects`, they collapse into their bounding box: the pixels copied
    /// for one update never exceed one framebuffer.
    private mutating func markDirty(_ rect: RFBRect) {
        let area = rect.width * rect.height
        guard dirty.count >= Self.maxDirtyRects || dirtyArea + area > framebuffer.width * framebuffer.height else {
            dirty.append(rect)
            dirtyArea += area
            return
        }
        var minX = rect.x, minY = rect.y, maxX = rect.x + rect.width, maxY = rect.y + rect.height
        for other in dirty {
            minX = min(minX, other.x)
            minY = min(minY, other.y)
            maxX = max(maxX, other.x + other.width)
            maxY = max(maxY, other.y + other.height)
        }
        let box = RFBRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        dirty.removeAll(keepingCapacity: true)
        dirty.append(box)
        dirtyArea = box.width * box.height
    }

    private mutating func takeUpdate(completesMessage: Bool = true) -> FramebufferUpdate {
        let regions = dirty.map { FramebufferUpdate.Region(rect: $0, pixels: framebuffer.copyPixels(in: $0)) }
        dirty.removeAll(keepingCapacity: true)
        dirtyArea = 0
        return FramebufferUpdate(width: framebuffer.width, height: framebuffer.height, regions: regions,
                                 completesMessage: completesMessage)
    }

    // MARK: Buffer access (big-endian, RFC 6143 §7), relative to `readIndex`

    private var available: Int { buffer.count - readIndex }

    private mutating func consume(_ count: Int) {
        readIndex += count
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
            readIndex = 0
        }
    }

    private func byte(at offset: Int) -> UInt8? {
        available > offset ? buffer[readIndex + offset] : nil
    }

    private func u16(at offset: Int) -> UInt16? {
        guard available >= offset + 2 else { return nil }
        return UInt16(buffer[readIndex + offset]) << 8 | UInt16(buffer[readIndex + offset + 1])
    }

    private func u32(at offset: Int) -> UInt32? {
        guard available >= offset + 4 else { return nil }
        let start = readIndex + offset
        return buffer[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Runs `body` with the unparsed bytes while it mutates the decoder (framebuffer, zlib state). The
    /// local copy only shares the buffer's storage; `body` must not touch `buffer` itself.
    private mutating func withPayload<T, E: Error>(_ body: (inout Self, UnsafeRawBufferPointer) throws(E) -> T)
        throws(E) -> T {
        let data = buffer
        let start = readIndex
        let result: Result<T, E> = data.withUnsafeBytes { raw in
            Result { () throws(E) -> T in try body(&self, UnsafeRawBufferPointer(rebasing: raw[start...])) }
        }
        return try result.get()
    }

    private func withBytes<T>(_ offset: Int, _ count: Int, _ body: (UnsafeRawBufferPointer) -> T) -> T {
        buffer.withUnsafeBytes { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[(readIndex + offset)..<(readIndex + offset + count)]))
        }
    }
}
