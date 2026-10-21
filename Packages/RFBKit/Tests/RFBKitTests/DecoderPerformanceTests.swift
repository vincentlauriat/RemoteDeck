import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RFBKit

/// Decode time of a full 1920 × 1080 update. The frames are encoded here by a small test-side
/// encoder (libz `deflate`, ImageIO JPEG); correctness is covered by the Python vectors, this only
/// drives the timing. Gated behind `RFBKIT_PERF=1`:
/// `RFBKIT_PERF=1 swift test -c release -Xswiftc -enable-testing --filter fullHDUpdateTiming`.
///
/// The frame is desktop-like: a gradient wallpaper band (many colours per tile), a 640 × 400 noisy
/// "photo", a text window (2–3 colours) and flat window background.
struct DecoderPerformanceTests {
    enum Variant: String, CaseIterable, Sendable {
        case zrle, tight, tightJPEG
    }

    static let width = 1920
    static let height = 1080

    @Test(.enabled(if: perfTestsEnabled, "set RFBKIT_PERF=1 to run timing tests"), arguments: Variant.allCases)
    func fullHDUpdateTiming(variant: Variant) async throws {
        let image = Self.desktopImage()
        let stream = switch variant {
        case .zrle: Self.zrleUpdate(image)
        case .tight: Self.tightUpdate(image, jpeg: false)
        case .tightJPEG: Self.tightUpdate(image, jpeg: true)
        }
        let chunks = stride(from: 0, to: stream.count, by: 64 * 1024).map {
            Array(stream[$0..<min($0 + 64 * 1024, stream.count)])
        }
        let clock = ContinuousClock()
        var best = Duration.seconds(600)
        var decoded: Framebuffer?
        for _ in 0..<7 {
            var decoder = try ServerMessageDecoder(width: Self.width, height: Self.height)
            var events: [RFBEvent] = []
            let elapsed = try clock.measure {
                for chunk in chunks { events += try decoder.receive(chunk) }
            }
            #expect(events.count == 1)
            best = min(best, elapsed)
            decoded = decoder.framebuffer
        }
        print("1080p \(variant.rawValue): \(stream.count) bytes on the wire, best decode = \(best)")
        if variant != .tightJPEG {
            #expect(decoded?.pixels == image)
        }
        #if DEBUG
        #expect(best < .milliseconds(300))
        #else
        #expect(best < .milliseconds(30))
        #endif
    }

    // MARK: Test frame

    static func desktopImage() -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: width * height)
        var seed: UInt32 = 12345
        func random() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed >> 8
        }
        for y in 0..<height {
            for x in 0..<width {
                let pixel: UInt32
                if y < 180 {
                    pixel = rgb(UInt32(x * 255 / width), UInt32(y), UInt32(128 + (x + y) % 64))
                } else if (100..<740).contains(x), (250..<650).contains(y) {
                    let r = random()
                    pixel = rgb(UInt32(x / 4 % 256) ^ (r & 0x1F), UInt32(y / 3 % 256) ^ (r >> 5 & 0x1F),
                                (r >> 10) & 0xFF)
                } else if (900..<1800).contains(x), (250..<1000).contains(y) {
                    let line = (y - 250) % 16
                    let ink = line < 12 && (x * 7 + y * 13 + (x / 6) * 31) % 5 < 2
                    pixel = ink ? rgb(40, 40, 40) : (line < 12 && x % 6 == 0 ? rgb(150, 150, 150) : rgb(255, 255, 255))
                } else {
                    pixel = rgb(230, 230, 235)
                }
                pixels[y * width + x] = pixel
            }
        }
        return pixels
    }

    private static func rgb(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 { 0xFF00_0000 | r << 16 | g << 8 | b }

    private static func colours(_ image: [UInt32], x: Int, y: Int, w: Int, h: Int, limit: Int) -> [UInt32] {
        var found: [UInt32] = []
        for row in y..<(y + h) {
            for column in x..<(x + w) {
                let pixel = image[row * width + column]
                if !found.contains(pixel) {
                    found.append(pixel)
                    if found.count > limit { return found }
                }
            }
        }
        return found
    }

    // MARK: Test-side encoders

    static func zrleUpdate(_ image: [UInt32]) -> [UInt8] {
        var data: [UInt8] = []
        data.reserveCapacity(width * height * 3)
        func cpixel(_ p: UInt32) { data += [UInt8(p & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p >> 16 & 0xFF)] }
        for ty in stride(from: 0, to: height, by: 64) {
            for tx in stride(from: 0, to: width, by: 64) {
                let w = min(64, width - tx), h = min(64, height - ty)
                let palette = colours(image, x: tx, y: ty, w: w, h: h, limit: 16)
                if palette.count == 1 {
                    data.append(1)
                    cpixel(palette[0])
                } else if palette.count <= 16 {
                    data.append(UInt8(palette.count))
                    palette.forEach(cpixel)
                    let bits = palette.count == 2 ? 1 : palette.count <= 4 ? 2 : 4
                    for row in ty..<(ty + h) {
                        var acc = 0, filled = 0
                        for column in tx..<(tx + w) {
                            acc = acc << bits | palette.firstIndex(of: image[row * width + column])!
                            filled += bits
                            if filled == 8 { data.append(UInt8(acc)); acc = 0; filled = 0 }
                        }
                        if filled > 0 { data.append(UInt8(acc << (8 - filled))) }
                    }
                } else {
                    data.append(0)
                    for row in ty..<(ty + h) {
                        for column in tx..<(tx + w) { cpixel(image[row * width + column]) }
                    }
                }
            }
        }
        let compressed = Deflater().compress(data)
        return FramebufferMessage.update(FramebufferMessage.zrle(0, 0, width, height, compressed: compressed))
    }

    /// Tight in 256 × 64 rects (16 Ki pixels, under the 64 Ki-pixel limit of common encoders):
    /// fill, 2-colour palette (stream 1), ≤ 256-colour palette (stream 2), otherwise gradient
    /// (stream 3), or JPEG for the photo with `jpeg`.
    static func tightUpdate(_ image: [UInt32], jpeg: Bool) -> [UInt8] {
        let deflaters = [Deflater(), Deflater(), Deflater(), Deflater()]
        func tpixel(_ p: UInt32) -> [UInt8] { [UInt8(p >> 16 & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p & 0xFF)] }
        func compressed(_ stream: Int, _ raw: [UInt8]) -> [UInt8] {
            guard raw.count >= 12 else { return raw }
            let data = deflaters[stream].compress(raw)
            return FramebufferMessage.tightCompactLength(data.count) + data
        }
        var rects: [UInt8] = []
        var count = 0
        for y in stride(from: 0, to: height, by: 64) {
            for x in stride(from: 0, to: width, by: 256) {
                let w = min(256, width - x), h = min(64, height - y)
                count += 1
                rects += FramebufferMessage.rect(x, y, w, h, encoding: Encoding.tight)
                let palette = colours(image, x: x, y: y, w: w, h: h, limit: 256)
                let photo = (100..<740).contains(x + w / 2) && (250..<650).contains(y + h / 2)
                if palette.count == 1 {
                    rects += [0x80] + tpixel(palette[0])
                } else if jpeg && photo {
                    let data = jpegData(image, x: x, y: y, w: w, h: h)
                    rects += [0x90] + FramebufferMessage.tightCompactLength(data.count) + data
                } else if palette.count <= 256 {
                    let stream = palette.count == 2 ? 1 : 2
                    var raw: [UInt8] = []
                    for row in y..<(y + h) {
                        if palette.count == 2 {
                            var acc = 0, filled = 0
                            for column in x..<(x + w) {
                                acc = acc << 1 | palette.firstIndex(of: image[row * width + column])!
                                filled += 1
                                if filled == 8 { raw.append(UInt8(acc)); acc = 0; filled = 0 }
                            }
                            if filled > 0 { raw.append(UInt8(acc << (8 - filled))) }
                        } else {
                            for column in x..<(x + w) { raw.append(UInt8(palette.firstIndex(of: image[row * width + column])!)) }
                        }
                    }
                    rects += [UInt8(stream << 4) | 0x40, 1, UInt8(palette.count - 1)] + palette.flatMap(tpixel)
                        + compressed(stream, raw)
                } else {
                    var raw: [UInt8] = []
                    raw.reserveCapacity(3 * w * h)
                    for row in y..<(y + h) {
                        for column in x..<(x + w) {
                            let here = tpixel(image[row * width + column])
                            let left = column > x ? tpixel(image[row * width + column - 1]) : [0, 0, 0]
                            let up = row > y ? tpixel(image[(row - 1) * width + column]) : [0, 0, 0]
                            let upLeft = column > x && row > y ? tpixel(image[(row - 1) * width + column - 1]) : [0, 0, 0]
                            for c in 0..<3 {
                                let prediction = min(255, max(0, Int(left[c]) + Int(up[c]) - Int(upLeft[c])))
                                raw.append(UInt8((Int(here[c]) - prediction) & 0xFF))
                            }
                        }
                    }
                    rects += [0x70, 2] + compressed(3, raw)
                }
            }
        }
        return FramebufferMessage.update(rects, count: count)
    }

    private static func jpegData(_ image: [UInt32], x: Int, y: Int, w: Int, h: Int) -> [UInt8] {
        var crop = [UInt32](repeating: 0, count: w * h)
        for row in 0..<h {
            for column in 0..<w { crop[row * w + column] = image[(y + row) * width + x + column] }
        }
        let provider = CGDataProvider(data: Data(bytes: crop, count: crop.count * 4) as CFData)!
        let cgImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                  | CGImageAlphaInfo.noneSkipFirst.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return [UInt8](output as Data)
    }
}
