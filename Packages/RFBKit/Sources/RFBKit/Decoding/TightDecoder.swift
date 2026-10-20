import CoreGraphics
import Foundation
import ImageIO

/// Tight (encoding 7, rfbproto "Tight Encoding"): fill, JPEG and basic compression with the copy,
/// palette and gradient filters over four persistent zlib streams.
///
/// For `PixelFormat.bgra32` a TPIXEL is 3 bytes in the order R, G, B (unlike ZRLE's CPIXEL, which
/// keeps the pixel's own byte order, B, G, R).
struct TightDecoder {
    /// Basic-compression data shorter than this is sent without zlib and without a length.
    static let minCompressedSize = 12
    /// Largest value a 1–3 byte compact length can hold (22 bits).
    static let maxCompactLength = (1 << 22) - 1

    private enum Filter: UInt8 { case copy = 0, palette = 1, gradient = 2 }

    /// Header fields of one Tight rectangle, parsed by `measure`.
    struct Layout {
        enum Kind {
            case fill
            case jpeg
            case basic(stream: Int, filter: UInt8, paletteSize: Int, compressed: Bool)
        }
        var control: UInt8
        var kind: Kind
        /// Offsets in the payload: palette (basic only) and the data that follows the header.
        var paletteOffset = 0
        var dataOffset: Int
        var dataLength: Int
        /// Uncompressed size of the filtered data (basic only).
        var rawLength = 0
        var totalLength: Int { dataOffset + dataLength }
    }

    private let streams = [Inflater(), Inflater(), Inflater(), Inflater()]

    /// Parses the rectangle header in `payload` (which may be incomplete). Returns `nil` while more
    /// bytes are needed; every length is checked as soon as it is readable.
    static func measure(_ payload: UnsafeRawBufferPointer, rect: RFBRect) throws(RFBError) -> Layout? {
        guard payload.count >= 1 else { return nil }
        let control = payload[0]
        switch control >> 4 {
        case 0x8:
            return Layout(control: control, kind: .fill, dataOffset: 1, dataLength: 3)
        case 0x9:
            guard let (length, size) = try compactLength(payload, at: 1) else { return nil }
            guard length > 0 else { throw .protocolViolation("Tight: empty JPEG data") }
            return Layout(control: control, kind: .jpeg, dataOffset: 1 + size, dataLength: length)
        case 0xA...:
            // 0xA is PNG, used only by the separate TightPNG encoding (-260), which RFBKit does not advertise.
            throw .protocolViolation("Tight: invalid compression control \(control)")
        default:
            break
        }
        var offset = 1
        var filter = Filter.copy.rawValue
        if control & 0x40 != 0 {
            guard payload.count > offset else { return nil }
            filter = payload[offset]
            offset += 1
            guard Filter(rawValue: filter) != nil else { throw .protocolViolation("Tight: unknown filter \(filter)") }
        }
        var paletteSize = 0
        let paletteOffset: Int
        let rawLength: Int
        if filter == Filter.palette.rawValue {
            guard payload.count > offset else { return nil }
            paletteSize = Int(payload[offset]) + 1
            offset += 1
            paletteOffset = offset
            offset += 3 * paletteSize
            let rowBytes = paletteSize == 2 ? (rect.width + 7) / 8 : rect.width
            rawLength = rowBytes * rect.height
        } else {
            paletteOffset = offset
            rawLength = 3 * rect.width * rect.height
        }
        let compressed = rawLength >= minCompressedSize
        let layoutKind = Layout.Kind.basic(stream: Int(control >> 4) & 3, filter: filter, paletteSize: paletteSize,
                                           compressed: compressed)
        guard compressed else {
            return Layout(control: control, kind: layoutKind, paletteOffset: paletteOffset, dataOffset: offset,
                          dataLength: rawLength, rawLength: rawLength)
        }
        guard let (length, size) = try compactLength(payload, at: offset) else { return nil }
        let bound = rawLength + (rawLength >> 12) + (rawLength >> 14) + (rawLength >> 25) + 13 + 64
        guard length <= bound else {
            throw .protocolViolation("Tight: compressed length \(length) exceeds the bound \(bound) for the rectangle")
        }
        return Layout(control: control, kind: layoutKind, paletteOffset: paletteOffset, dataOffset: offset + size,
                      dataLength: length, rawLength: rawLength)
    }

    /// A compact length (1–3 bytes, 7 + 7 + 8 bits) at `offset`: (value, byte count), or `nil` if incomplete.
    static func compactLength(_ payload: UnsafeRawBufferPointer, at offset: Int) throws(RFBError) -> (Int, Int)? {
        guard payload.count > offset else { return nil }
        let first = payload[offset]
        var value = Int(first & 0x7F)
        if first & 0x80 == 0 { return (value, 1) }
        guard payload.count > offset + 1 else { return nil }
        let second = payload[offset + 1]
        value |= Int(second & 0x7F) << 7
        if second & 0x80 == 0 { return (value, 2) }
        guard payload.count > offset + 2 else { return nil }
        value |= Int(payload[offset + 2]) << 14
        return (value, 3)
    }

    /// Decodes a complete rectangle whose header `measure` returned.
    func decode(_ rect: RFBRect, payload: UnsafeRawBufferPointer, layout: Layout,
                into framebuffer: inout Framebuffer) throws(RFBError) {
        for index in 0..<4 where layout.control & (1 << index) != 0 {
            streams[index].reset()
        }
        let data = UnsafeRawBufferPointer(rebasing: payload[layout.dataOffset..<layout.totalLength])
        switch layout.kind {
        case .fill:
            framebuffer.fill(rect, with: Pixel.fromRGB(data[0], data[1], data[2]))
        case .jpeg:
            try Self.decodeJPEG(data, rect: rect, into: &framebuffer)
        case .basic(let stream, let filter, let paletteSize, let compressed):
            guard !rect.isEmpty else { return }
            var filtered = data
            if compressed {
                filtered = try streams[stream].inflate(data, maxOutput: layout.rawLength, "Tight")
                guard filtered.count == layout.rawLength else {
                    throw .protocolViolation("Tight: zlib data ends early (\(filtered.count) of \(layout.rawLength) bytes)")
                }
            }
            let palette = UnsafeRawBufferPointer(rebasing: payload[layout.paletteOffset..<(layout.paletteOffset + 3 * paletteSize)])
            try Self.applyFilter(filter, filtered.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                 palette: palette, paletteSize: paletteSize, rect: rect, into: &framebuffer)
        }
    }

    /// Writes the filtered data of a basic-compression rectangle. Loops use `while` and raw pointers
    /// (`for … in` ranges stay generic, and slow, in debug builds).
    private static func applyFilter(_ filter: UInt8, _ data: UnsafePointer<UInt8>, palette paletteBytes: UnsafeRawBufferPointer,
                                    paletteSize: Int, rect: RFBRect, into framebuffer: inout Framebuffer) throws(RFBError) {
        let stride = framebuffer.width
        let width = rect.width
        let height = rect.height
        let result: Result<Void, RFBError> = framebuffer.pixels.withUnsafeMutableBufferPointer { pixels in
            let origin = pixels.baseAddress! + rect.y * stride + rect.x
            switch Filter(rawValue: filter)! {
            case .copy:
                var source = data
                var row = 0
                while row < height {
                    var line = origin + row * stride
                    let end = line + width
                    while line < end {
                        line.pointee = 0xFF00_0000 | UInt32(source[0]) << 16 | UInt32(source[1]) << 8 | UInt32(source[2])
                        line += 1
                        source += 3
                    }
                    row += 1
                }
            case .gradient:
                // Per component: prediction = left + above − above-left, clamped to 0…255; the data is
                // the difference modulo 256. Neighbours outside the rectangle count as 0.
                let rows = UnsafeMutablePointer<Int>.allocate(capacity: 6 * width)
                defer { rows.deallocate() }
                rows.initialize(repeating: 0, count: 6 * width)
                var previous = rows
                var current = rows + 3 * width
                var source = data
                var row = 0
                while row < height {
                    let line = origin + row * stride
                    var column = 0
                    while column < width {
                        let at = 3 * column
                        var component = 0
                        while component < 3 {
                            let above = previous[at + component]
                            let left = column > 0 ? current[at - 3 + component] : 0
                            let aboveLeft = column > 0 ? previous[at - 3 + component] : 0
                            var prediction = left + above - aboveLeft
                            prediction = prediction < 0 ? 0 : prediction > 255 ? 255 : prediction
                            current[at + component] = (prediction + Int(source.pointee)) & 0xFF
                            source += 1
                            component += 1
                        }
                        line[column] = 0xFF00_0000 | UInt32(current[at]) << 16 | UInt32(current[at + 1]) << 8
                            | UInt32(current[at + 2])
                        column += 1
                    }
                    swap(&previous, &current)
                    row += 1
                }
            case .palette:
                let colours = UnsafeMutablePointer<UInt32>.allocate(capacity: paletteSize)
                defer { colours.deallocate() }
                var entry = 0
                while entry < paletteSize {
                    colours[entry] = Pixel.fromRGB(paletteBytes[3 * entry], paletteBytes[3 * entry + 1],
                                                   paletteBytes[3 * entry + 2])
                    entry += 1
                }
                if paletteSize == 2 {
                    let rowBytes = (width + 7) / 8
                    var row = 0
                    while row < height {
                        let line = origin + row * stride
                        let source = data + row * rowBytes
                        var column = 0
                        while column < width {
                            line[column] = colours[Int(source[column >> 3] >> UInt8(7 - column & 7) & 1)]
                            column += 1
                        }
                        row += 1
                    }
                    return .success(())
                }
                var source = data
                var row = 0
                while row < height {
                    let line = origin + row * stride
                    var column = 0
                    while column < width {
                        let index = Int(source.pointee)
                        guard index < paletteSize else {
                            return .failure(.protocolViolation(
                                "Tight: palette index \(index) beyond palette size \(paletteSize)"))
                        }
                        line[column] = colours[index]
                        source += 1
                        column += 1
                    }
                    row += 1
                }
            }
            return .success(())
        }
        try result.get()
    }

    /// Decodes JPEG data with ImageIO straight into the framebuffer. The image must be exactly the
    /// rectangle's size; its header is checked before any pixel is decoded.
    private static func decodeJPEG(_ data: UnsafeRawBufferPointer, rect: RFBRect,
                                   into framebuffer: inout Framebuffer) throws(RFBError) {
        guard !rect.isEmpty else { return }
        // Only the JPEG parser may see server data: check the SOI marker, then ImageIO's own detection.
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else {
            throw .protocolViolation("Tight: JPEG data does not start with a JPEG marker")
        }
        let jpeg = Data(data) as CFData
        let options = [kCGImageSourceTypeIdentifierHint: "public.jpeg"] as CFDictionary
        guard let source = CGImageSourceCreateWithData(jpeg, options),
              CGImageSourceGetType(source) as String? == "public.jpeg" else {
            throw .protocolViolation("Tight: JPEG data is not a JPEG image")
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw .protocolViolation("Tight: invalid JPEG data")
        }
        guard pixelWidth == rect.width, pixelHeight == rect.height else {
            throw .protocolViolation("Tight: \(pixelWidth)x\(pixelHeight) JPEG for a \(rect.width)x\(rect.height) rectangle")
        }
        let decodeOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions),
              image.width == rect.width, image.height == rect.height else {
            throw .protocolViolation("Tight: invalid JPEG data")
        }
        // Draw in the image's own RGB space so no colour conversion alters the pixels.
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        let stride = framebuffer.width
        let drawn: Bool = framebuffer.pixels.withUnsafeMutableBufferPointer { pixels in
            let origin = pixels.baseAddress! + rect.y * stride + rect.x
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let context = CGContext(data: origin, width: rect.width, height: rect.height, bitsPerComponent: 8,
                                          bytesPerRow: stride * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return false
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            var row = 0
            while row < rect.height {
                var line = origin + row * stride
                let end = line + rect.width
                while line < end {
                    line.pointee |= 0xFF00_0000
                    line += 1
                }
                row += 1
            }
            return true
        }
        guard drawn else { throw .protocolViolation("Tight: cannot decode JPEG") }
    }
}
