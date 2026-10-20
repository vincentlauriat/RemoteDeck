import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RFBKit

/// Framebuffer protocol decoding. Golden streams come from `DecoderVectors` (Python zlib and
/// libjpeg-turbo, independent of RFBKit); malformed and hostile inputs are built by hand.
struct DecoderVectorTests {
    static let vectors = DecoderVectors.all

    @Test(arguments: DecoderVectors.all, Chunking.allCases)
    func goldenStream(vector: DecoderVector, chunking: Chunking) throws {
        let (decoder, events) = try decode(vector.streamBytes, width: vector.width, height: vector.height,
                                           chunking: chunking)
        let framebuffer = decoder.framebuffer
        #expect(framebuffer.width == vector.expectedWidth)
        #expect(framebuffer.height == vector.expectedHeight)
        let updates = events.compactMap { event -> FramebufferUpdate? in
            if case .framebufferUpdate(let update) = event { return update }
            return nil
        }
        #expect(updates.count == vector.updates)
        #expect(decoder.bufferedCount == 0)
        let difference = maxComponentDifference(framebuffer.pixels, vector.expectedPixels)
        #expect(difference <= vector.tolerance, "max component difference \(difference)")
        // Regions of the last update carry the framebuffer's final pixels.
        for region in updates.last?.regions ?? [] {
            #expect(region.pixels == framebuffer.copyPixels(in: region.rect))
        }
    }

    /// Without the last byte nothing fails and the final update is not reported yet.
    @Test(arguments: DecoderVectors.all)
    func truncatedStreamWaitsForMoreBytes(vector: DecoderVector) throws {
        let stream = vector.streamBytes
        for chunking in Chunking.allCases {
            let (decoder, events) = try decode(Array(stream.dropLast()), width: vector.width, height: vector.height,
                                               chunking: chunking)
            let updates = events.filter { if case .framebufferUpdate = $0 { true } else { false } }
            #expect(updates.count == vector.updates - 1)
            #expect(decoder.bufferedCount > 0)
        }
    }

    @Test func desktopSizeReportsResize() throws {
        let vector = try #require(DecoderVectors.all.first { $0.name == "desktop_size" })
        let (_, events) = try decode(vector.streamBytes, width: vector.width, height: vector.height, chunking: .whole)
        #expect(events.contains(.desktopResized(width: 24, height: 10)))
        guard case .framebufferUpdate(let last) = events.last else {
            Issue.record("expected an update last")
            return
        }
        #expect(last.width == 24 && last.height == 10)
    }

    @Test func extendedDesktopSizeIgnoresFailedRequests() throws {
        let vector = try #require(DecoderVectors.all.first { $0.name == "extended_desktop_size" })
        let (_, events) = try decode(vector.streamBytes, width: vector.width, height: vector.height, chunking: .whole)
        let resizes = events.filter { if case .desktopResized = $0 { true } else { false } }
        #expect(resizes == [.desktopResized(width: 20, height: 14)])
    }
}

struct ClientMessageTests {
    @Test func setPixelFormatRequestsBGRA32() {
        #expect(ClientMessage.setPixelFormat(.bgra32).wireBytes
            == [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        // What minim6 announces in its ServerInit, byte for byte.
        #expect(PixelFormat.bgra32 == ServerMessage.pixelFormat)
    }

    @Test func setEncodingsUsesTwosComplement() {
        #expect(ClientMessage.setEncodings([7, 16, -223, -308]).wireBytes
            == [2, 0, 0, 4, 0, 0, 0, 7, 0, 0, 0, 16, 0xFF, 0xFF, 0xFF, 0x21, 0xFF, 0xFF, 0xFE, 0xCC])
    }

    @Test func preferredEncodingOrder() {
        #expect(Encoding.preferred == [7, 16, 1, 0, -308, -223, -239])
        #expect(Encoding.tightJPEGQuality(0) == -32)
        #expect(Encoding.tightJPEGQuality(9) == -23)
    }

    @Test func framebufferUpdateRequest() {
        #expect(ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 1920, height: 1080).wireBytes
            == [3, 0, 0, 0, 0, 0, 0x07, 0x80, 0x04, 0x38])
        #expect(ClientMessage.framebufferUpdateRequest(incremental: true, x: 0x102, y: 3, width: 4, height: 5).wireBytes
            == [3, 1, 1, 2, 0, 3, 0, 4, 0, 5])
    }

    @Test func keyAndPointerEvents() {
        #expect(ClientMessage.keyEvent(down: true, key: 0xFF0D).wireBytes == [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        #expect(ClientMessage.keyEvent(down: false, key: 0x61).wireBytes == [4, 0, 0, 0, 0, 0, 0, 0x61])
        #expect(ClientMessage.pointerEvent(buttonMask: 0b101, x: 1919, y: 1079).wireBytes
            == [5, 5, 0x07, 0x7F, 0x04, 0x37])
    }
}

/// Hand-built server messages: non-update messages, caps, bounds and malformed data.
struct ServerMessageTests {
    typealias M = FramebufferMessage

    @Test(arguments: Chunking.allCases)
    func bellCutTextAndColourMap(chunking: Chunking) throws {
        let colourMap: [UInt8] = [1, 0, 0, 5, 0, 2] + [UInt8](repeating: 0xAB, count: 12)
        let stream: [UInt8] = [2] + M.cutText([0x63, 0x61, 0x66, 0xE9]) + colourMap + [2] + M.cutText([])
        let (_, events) = try decode(stream, width: 8, height: 8, chunking: chunking)
        #expect(events == [.bell, .serverCutText("café"), .bell, .serverCutText("")])
    }

    @Test(arguments: Chunking.allCases)
    func oversizedCutTextIsSkipped(chunking: Chunking) throws {
        let length = ServerMessageDecoder.maxCutTextLength + 1
        var stream = M.cutText([UInt8](repeating: 0x41, count: length))
        stream += [2]
        // Byte by byte over 1 MiB is slow in debug: one big chunk then small ones.
        var decoder = try ServerMessageDecoder(width: 8, height: 8)
        var events = try decoder.receive(stream.prefix(8))
        for chunk in (chunking == .byteByByte ? Chunking.sevenBytes : chunking).split(Array(stream.dropFirst(8))) {
            events += try decoder.receive(chunk)
            #expect(decoder.bufferedCount <= 64 * 1024)  // never buffered
        }
        #expect(events == [.bell])
    }

    @Test func cursorShapeWithMask() throws {
        // 3 x 2 cursor, hotspot (1, 1); mask rows 0b101_00000 and 0b010_00000.
        let pixels: [UInt8] = (0..<6).flatMap { [UInt8($0), 0x10, 0x20, 0] }
        let stream = M.update(M.rect(1, 1, 3, 2, encoding: Encoding.cursor) + pixels + [0b1010_0000, 0b0100_0000])
        let (_, events) = try decode(stream, width: 8, height: 8, chunking: .byteByByte)
        #expect(events.first == .cursor(CursorShape(width: 3, height: 2, hotspotX: 1, hotspotY: 1, pixels: [
            0xFF20_1000, 0, 0xFF20_1002,
            0, 0xFF20_1004, 0,
        ])))
        // A cursor update changes no framebuffer pixel.
        #expect(events.last == .framebufferUpdate(FramebufferUpdate(width: 8, height: 8, regions: [])))
    }

    @Test func emptyCursorAndClampedHotspot() throws {
        let empty = M.update(M.rect(0, 0, 0, 0, encoding: Encoding.cursor))
        let (_, events) = try decode(empty, width: 8, height: 8, chunking: .whole)
        #expect(events.first == .cursor(CursorShape(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: [])))
        let farHotspot = M.update(M.rect(40, 9, 1, 1, encoding: Encoding.cursor) + [1, 2, 3, 0, 0x80])
        let (_, more) = try decode(farHotspot, width: 8, height: 8, chunking: .whole)
        #expect(more.first == .cursor(CursorShape(width: 1, height: 1, hotspotX: 0, hotspotY: 0, pixels: [0xFF03_0201])))
    }

    @Test func regionsCopyThePixelsOfEachRect() throws {
        let stream = M.update(M.raw(0, 0, 2, 1, b: 1, g: 2, r: 3), M.raw(1, 1, 1, 2, b: 4, g: 5, r: 6))
        let (_, events) = try decode(stream, width: 4, height: 4, chunking: .whole)
        #expect(events == [.framebufferUpdate(FramebufferUpdate(width: 4, height: 4, regions: [
            .init(rect: RFBRect(x: 0, y: 0, width: 2, height: 1), pixels: [0xFF03_0201, 0xFF03_0201]),
            .init(rect: RFBRect(x: 1, y: 1, width: 1, height: 2), pixels: [0xFF06_0504, 0xFF06_0504]),
        ]))])
    }

    @Test func rawIgnoresThePaddingByteAndForcesOpaqueAlpha() throws {
        let stream = M.update(M.rect(0, 0, 1, 1, encoding: Encoding.raw) + [0x11, 0x22, 0x33, 0x00])
        let (decoder, _) = try decode(stream, width: 1, height: 1, chunking: .whole)
        #expect(decoder.framebuffer[0, 0] == 0xFF33_2211)
    }

    @Test func errorsAreSticky() throws {
        var decoder = try ServerMessageDecoder(width: 4, height: 4)
        #expect(throws: RFBError.protocolViolation("unknown server message type 9")) { try decoder.receive([9]) }
        #expect(throws: RFBError.protocolViolation("unknown server message type 9")) { try decoder.receive([2]) }
    }

    // MARK: Bounds and caps

    @Test(arguments: [Encoding.raw, Encoding.copyRect, Encoding.zrle, Encoding.tight])
    func rectOutsideTheFramebuffer(encoding: Int32) {
        for (x, y, w, h) in [(60, 0, 5, 1), (0, 64, 1, 1), (0, 0, 65, 1), (65535, 65535, 65535, 65535)] {
            let error = decodingError(M.update(M.rect(x, y, w, h, encoding: encoding)), width: 64, height: 64)
            #expect(isViolation(error, "outside the 64x64 framebuffer"), "\(x),\(y) \(w)x\(h): \(String(describing: error))")
        }
    }

    @Test func copyRectSourceOutsideTheFramebuffer() {
        let error = decodingError(M.update(M.rect(0, 0, 10, 10, encoding: Encoding.copyRect) + [0, 60, 0, 0]))
        #expect(isViolation(error, "CopyRect source"))
    }

    @Test func unknownEncodingsAreRejected() {
        for encoding: Int32 in [2, 5, 6, -224, -260, 99] {
            let error = decodingError(M.update(M.rect(0, 0, 1, 1, encoding: encoding)))
            #expect(error == .protocolViolation("unsupported encoding \(encoding)"))
        }
    }

    @Test func desktopSizeLimits() {
        for (w, h) in [(0, 10), (10, 0), (16385, 10), (16384, 16384)] {
            let error = decodingError(M.update(M.rect(0, 0, w, h, encoding: Encoding.desktopSize)))
            #expect(isViolation(error, "framebuffer size"), "\(w)x\(h)")
        }
        #expect(throws: RFBError.self) { try ServerMessageDecoder(width: 0, height: 1) }
        #expect(throws: RFBError.self) { try ServerMessageDecoder(width: 16385, height: 1) }
    }

    @Test func cursorSizeLimit() {
        let error = decodingError(M.update(M.rect(0, 0, 513, 1, encoding: Encoding.cursor)))
        #expect(isViolation(error, "cursor size"))
    }

    @Test func zrleLengthIsCappedBeforeThePayload() {
        let rect = RFBRect(x: 0, y: 0, width: 64, height: 64)
        let limit = ZRLEDecoder.maxCompressedLength(rect)
        // Only the length is sent: the cap must fire without waiting for the payload.
        let error = decodingError(M.update(M.rect(0, 0, 64, 64, encoding: Encoding.zrle)
            + UInt32(limit + 1).bigEndianBytes))
        #expect(isViolation(error, "ZRLE length"))
        let atLimit = decodingError(M.update(M.rect(0, 0, 64, 64, encoding: Encoding.zrle) + UInt32(limit).bigEndianBytes))
        #expect(atLimit == nil)  // waits for the payload
    }

    @Test func tightCompressedLengthIsCappedBeforeThePayload() {
        // Copy filter, 10 x 10: 300 bytes of filtered data; a bound a little over that.
        let header = M.rect(0, 0, 10, 10, encoding: Encoding.tight) + [0x40, 0]
        let error = decodingError(M.update(header + M.tightCompactLength(100_000)))
        #expect(isViolation(error, "Tight: compressed length"))
        #expect(decodingError(M.update(header + M.tightCompactLength(300))) == nil)
    }

    @Test func tightInvalidControlAndFilter() {
        for control: UInt8 in [0xA0, 0xB0, 0xF0] {
            let error = decodingError(M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [control]))
            #expect(isViolation(error, "invalid compression control"))
        }
        let error = decodingError(M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x40, 3]))
        #expect(isViolation(error, "unknown filter 3"))
        let jpeg = decodingError(M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x90, 0]))
        #expect(isViolation(jpeg, "empty JPEG"))
    }

    @Test func tightPaletteIndexBeyondPalette() {
        // 3-colour palette, 4 x 1 rect: 4 index bytes (< 12, sent raw); index 3 is invalid.
        let palette: [UInt8] = [1, 1, 1, 2, 2, 2, 3, 3, 3]
        let stream = M.update(M.rect(0, 0, 4, 1, encoding: Encoding.tight) + [0x40, 1, 2] + palette + [0, 1, 2, 3])
        #expect(isViolation(decodingError(stream), "palette index 3 beyond palette size 3"))
    }

    @Test func tightZlibOutputMustMatchTheExpectedSize() {
        let header = M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x40, 0]   // copy: 48 bytes expected
        let long = M.zlibStream([UInt8](repeating: 7, count: 49))
        #expect(isViolation(decodingError(M.update(header + M.tightCompactLength(long.count) + long)),
                            "exceeds the expected size"))
        let short = M.zlibStream([UInt8](repeating: 7, count: 47))
        #expect(isViolation(decodingError(M.update(header + M.tightCompactLength(short.count) + short)), "ends early"))
        let exact = M.zlibStream([UInt8](repeating: 7, count: 48))
        #expect(decodingError(M.update(header + M.tightCompactLength(exact.count) + exact)) == nil)
        let corrupt: [UInt8] = [0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(isViolation(decodingError(M.update(header + M.tightCompactLength(corrupt.count) + corrupt)),
                            "corrupt zlib data"))
    }

    @Test func tightJPEGMustMatchTheRect() throws {
        let garbage: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 4]
        let error = decodingError(M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x90, UInt8(garbage.count)]
            + garbage))
        #expect(isViolation(error, "JPEG"))
        // The 32 x 24 JPEG of the golden vector, announced as a 16 x 24 rectangle.
        let vector = try #require(DecoderVectors.all.first { $0.name == "tight_jpeg" })
        var stream = vector.streamBytes
        let jpegRect = M.rect(8, 4, 32, 24, encoding: Encoding.tight)
        let offset = try #require(stream.firstRange(of: jpegRect)).lowerBound
        stream.replaceSubrange(offset..<(offset + 12), with: M.rect(8, 4, 16, 24, encoding: Encoding.tight))
        #expect(isViolation(decodingError(stream, width: 48, height: 32), "32x24 JPEG for a 16x24 rectangle"))
    }

    @Test func zrleMalformedTiles() {
        func zrle(_ tile: [UInt8], width: Int = 2, height: Int = 2) -> RFBError? {
            decodingError(M.update(M.zrle(0, 0, width, height, compressed: M.zlibStream(tile))))
        }
        #expect(isViolation(zrle([17]), "invalid tile subencoding 17"))
        #expect(isViolation(zrle([127]), "invalid tile subencoding 127"))
        #expect(isViolation(zrle([129]), "invalid tile subencoding 129"))
        #expect(isViolation(zrle([0, 1, 2, 3]), "data ends inside a tile"))                       // raw, 1 of 4 pixels
        #expect(isViolation(zrle([1, 1, 2, 3, 0]), "bytes left after the last tile"))             // trailing byte
        #expect(isViolation(zrle([128, 1, 2, 3, 4]), "run of 5 pixels overflows the tile"))       // 5 > 4
        #expect(isViolation(zrle([128, 1, 2, 3, 255, 0]), "overflows the tile"))
        // Packed palette of 3 (2 bits per pixel): index 3 is invalid.
        #expect(isViolation(zrle([3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 0b0011_0000, 0]), "palette index 3 beyond palette size 3"))
        // Palette RLE of 2: index 2 is invalid.
        #expect(isViolation(zrle([130, 1, 1, 1, 2, 2, 2, 2]), "palette index 2 beyond palette size 2"))
        #expect(isViolation(zrle([130, 1, 1, 1, 2, 2, 2, 0x81, 1]), "data ends inside a tile"))  // 2 of 4 pixels
        #expect(zrle([130, 1, 1, 1, 2, 2, 2, 0x81, 1, 0, 1]) == nil)                             // + 2 single pixels
    }

    // MARK: Region copies are bounded

    static func copiedPixels(_ events: [RFBEvent]) -> Int {
        events.reduce(0) { total, event in
            guard case .framebufferUpdate(let update) = event else { return total }
            return total + update.regions.reduce(0) { $0 + $1.pixels.count }
        }
    }

    /// 200 full-screen Tight fills cost 16 bytes each on the wire; copying a region per rect would
    /// hand out 200 framebuffers (1.66 GB at 1080p).
    @Test func repeatedFullScreenFillsCopyAtMostOneFramebuffer() throws {
        let (width, height) = (1920, 1080)
        var rects: [UInt8] = []
        for index in 0..<200 {
            rects += M.rect(0, 0, width, height, encoding: Encoding.tight) + [0x80, UInt8(index), 2, 3]
        }
        let (decoder, events) = try decode(M.update(rects, count: 200), width: width, height: height, chunking: .whole)
        #expect(Self.copiedPixels(events) <= width * height)
        #expect(decoder.framebuffer.pixels.allSatisfy { $0 == 0xFFC7_0203 })
        guard case .framebufferUpdate(let update) = events.last else {
            Issue.record("expected an update")
            return
        }
        #expect(update.regions.map(\.pixels) == [decoder.framebuffer.pixels])
    }

    @Test func repeatedCopyRectsCopyAtMostOneFramebuffer() throws {
        let (width, height) = (64, 48)
        var rects = M.raw(0, 0, 1, 1, b: 9, g: 9, r: 9)
        for _ in 0..<300 {
            rects += M.rect(1, 0, width - 1, height, encoding: Encoding.copyRect) + [0, 0, 0, 0]  // shift right by 1
        }
        let (decoder, events) = try decode(M.update(rects, count: 301), width: width, height: height, chunking: .sevenBytes)
        #expect(Self.copiedPixels(events) <= width * height)
        // The marked pixel was smeared along the whole first row; nothing else changed.
        for x in 0..<width { #expect(decoder.framebuffer[x, 0] == 0xFF09_0909) }
        #expect(decoder.framebuffer[0, 1] == Framebuffer.black)
    }

    @Test func manySmallRectsMergeIntoTheirBoundingBox() throws {
        var rects: [UInt8] = []
        for index in 0..<100 { rects += M.raw(10 + index % 10, 5 + index / 10, 1, 1, b: UInt8(index), g: 0, r: 0) }
        let (decoder, events) = try decode(M.update(rects, count: 100), width: 64, height: 64, chunking: .whole)
        guard case .framebufferUpdate(let update) = events.last else {
            Issue.record("expected an update")
            return
        }
        #expect(update.regions.count <= ServerMessageDecoder.maxDirtyRects)
        #expect(Self.copiedPixels(events) <= 64 * 64)
        // Every changed pixel is inside a region that carries its final value.
        for index in 0..<100 {
            let (x, y) = (10 + index % 10, 5 + index / 10)
            let region = try #require(update.regions.last { $0.rect.x <= x && x < $0.rect.x + $0.rect.width
                && $0.rect.y <= y && y < $0.rect.y + $0.rect.height })
            #expect(region.pixels[(y - region.rect.y) * region.rect.width + x - region.rect.x] == decoder.framebuffer[x, y])
            #expect(decoder.framebuffer[x, y] == 0xFF00_0000 | UInt32(index))
        }
    }

    @Test func pngSentAsTightJPEGIsRejected() throws {
        let png = try pngData(width: 4, height: 4)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let stream = M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x90] + M.tightCompactLength(png.count) + png)
        #expect(isViolation(decodingError(stream), "does not start with a JPEG marker"))
        // A JPEG marker in front of PNG data does not get it past ImageIO's type detection either.
        let disguised = [0xFF, 0xD8] + png
        let stream2 = M.update(M.rect(0, 0, 4, 4, encoding: Encoding.tight) + [0x90]
            + M.tightCompactLength(disguised.count) + disguised)
        #expect(isViolation(decodingError(stream2), "JPEG"))
    }

    @Test func zrleOutputIsBounded() {
        // 2 x 2 rect: at most 1 + 381 + 16 bytes of tile data; send 2000 zero bytes.
        let error = decodingError(M.update(M.zrle(0, 0, 2, 2, compressed: M.zlibStream([UInt8](repeating: 0, count: 2000)))))
        #expect(isViolation(error, "exceeds the expected size"))
    }
}

/// A small PNG made with ImageIO.
func pngData(width: Int, height: Int) throws -> [UInt8] {
    let pixels = [UInt32](repeating: 0xFF33_6699, count: width * height)
    let provider = try #require(CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                         | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return [UInt8](output as Data)
}
