import CoreGraphics
import Foundation
import ImageIO
import RFBKit
import Testing
@testable import ClaudeKit

struct ScreenshotTests {
    @Test func referenceContainerIsSentUnscaled() {
        let size = ImageLimits.fittedSize(width: 1024, height: 768)
        #expect(size == (1024, 768))
        #expect(ImageLimits.visualTokens(width: 1024, height: 768) == 1036)
    }

    @Test func largeScreensFitTheTargetBox() {
        #expect(ImageLimits.fittedSize(width: 2560, height: 1440) == (1280, 720))
        #expect(ImageLimits.fittedSize(width: 5120, height: 2880) == (1280, 720))
        #expect(ImageLimits.fittedSize(width: 3024, height: 1964) == (1231, 800))
        #expect(ImageLimits.fittedSize(width: 800, height: 600) == (800, 600))   // never upscaled
    }

    @Test func apiLimitsHoldWithoutTheBox() {
        // 3024 × 1964 capped at 2576 wide would be 5,520 tokens: the token limit binds.
        #expect(ImageLimits.visualTokens(width: 2576, height: 1673) == 5520)
        let retina = ImageLimits.fittedSize(width: 3024, height: 1964, box: nil)
        #expect(ImageLimits.fitsAPI(width: retina.width, height: retina.height))
        #expect(ImageLimits.visualTokens(width: retina.width, height: retina.height) <= 4784)
        let fiveK = ImageLimits.fittedSize(width: 5120, height: 2880, box: nil)
        #expect(ImageLimits.fitsAPI(width: fiveK.width, height: fiveK.height))
        #expect(max(fiveK.width, fiveK.height) <= 2576)
        let wide = ImageLimits.fittedSize(width: 16000, height: 400, box: nil)
        #expect(wide.width <= 2576)
    }

    @Test func coordinatesMapBackPerAxisAndClampAtTheEdges() throws {
        let mapping = ScreenMapping(remoteWidth: 2560, remoteHeight: 1440)
        #expect(mapping.imageWidth == 1280 && mapping.imageHeight == 720)
        #expect(mapping.remotePoint(x: 0, y: 0) == PointerLocation(x: 1, y: 1))
        #expect(mapping.remotePoint(x: 640, y: 360) == PointerLocation(x: 1281, y: 721))
        #expect(mapping.remotePoint(x: 1279, y: 719) == PointerLocation(x: 2559, y: 1439))
        // Outside the screenshot: rejected, not clamped.
        #expect(mapping.remotePoint(x: 1280, y: 10) == nil)
        #expect(mapping.remotePoint(x: -1, y: 10) == nil)
        #expect(mapping.remotePoint(x: 10, y: 720) == nil)
        // Unequal axes (an image that is not the exact ratio).
        let odd = ScreenMapping(remoteWidth: 3024, remoteHeight: 1964, imageWidth: 1231, imageHeight: 800)
        let corner = try #require(odd.remotePoint(x: 1230, y: 799))
        #expect(corner.x == 3022 && corner.y == 1962)
        #expect(odd.remotePoint(x: 1230, y: 799).map { $0.x < 3024 && $0.y < 1964 } == true)
        // Round trip: remote → image → remote lands within one image pixel.
        let back = odd.imagePoint(PointerLocation(x: 1500, y: 1000))
        let again = try #require(odd.remotePoint(x: back.x, y: back.y))
        #expect(abs(Int(again.x) - 1500) <= 3 && abs(Int(again.y) - 1000) <= 3)
    }

    @Test func identityMappingKeepsPixels() {
        let mapping = ScreenMapping(remoteWidth: 1024, remoteHeight: 768)
        #expect(mapping.remotePoint(x: 512, y: 384) == PointerLocation(x: 512, y: 384))
        #expect(mapping.remotePoint(x: 1023, y: 767) == PointerLocation(x: 1023, y: 767))
        #expect(mapping.imagePoint(PointerLocation(x: 100, y: 200)) == (100, 200))
    }

    @Test func zoomRegionMapsToARemoteRect() {
        let mapping = ScreenMapping(remoteWidth: 2560, remoteHeight: 1440)
        #expect(mapping.remoteRect(x0: 100, y0: 200, x1: 400, y1: 350) == RFBRect(x: 200, y: 400, width: 600, height: 300))
        #expect(mapping.remoteRect(x0: 400, y0: 200, x1: 100, y1: 350) == nil)
        #expect(mapping.remoteRect(x0: 0, y0: 0, x1: 1281, y1: 10) == nil)
    }

    @Test func pngKeepsChannelsInOrder() throws {
        // Red, green, blue, white: RFBKit's 0xAARRGGBB.
        let framebuffer = try Framebuffer(width: 2, height: 2,
                                          pixels: [0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF, 0xFFFF_FFFF])
        let image = try ScreenshotEncoder.encode(framebuffer)
        #expect(image.mediaType == "image/png")
        #expect(image.width == 2 && image.height == 2)
        #expect(image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let rgba = try decodeRGBA(image.data)
        #expect(Array(rgba[0..<3]) == [255, 0, 0])
        #expect(Array(rgba[4..<7]) == [0, 255, 0])
        #expect(Array(rgba[8..<11]) == [0, 0, 255])
    }

    @Test func screenshotIsScaledIntoTheLimitsAndZoomCrops() throws {
        let framebuffer = try Framebuffer(width: 2560, height: 1440,
                                          pixels: [UInt32](repeating: 0xFF20_4060, count: 2560 * 1440))
        let full = try ScreenshotEncoder.encode(framebuffer)
        #expect(full.width == 1280 && full.height == 720)
        let zoom = try ScreenshotEncoder.encode(framebuffer, region: RFBRect(x: 200, y: 400, width: 600, height: 300))
        #expect(zoom.width == 600 && zoom.height == 300)   // full resolution: it fits the box
        #expect(throws: ScreenshotEncoder.Failure.emptyImage) {
            try ScreenshotEncoder.encode(framebuffer, region: RFBRect(x: 2500, y: 0, width: 100, height: 10))
        }
    }

    private func decodeRGBA(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
