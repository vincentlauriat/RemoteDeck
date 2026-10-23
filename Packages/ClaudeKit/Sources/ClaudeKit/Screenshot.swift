import CoreGraphics
import Foundation
import ImageIO
import RFBKit
import UniformTypeIdentifiers

/// Image size rules for screenshot and zoom results. The API never downscales: an image over the
/// model's limits is rejected (computer use docs, "Size screenshots to fit image limits").
public enum ImageLimits {
    /// Opus 4.7 and later, every toolset model: 2,576 px on the long edge…
    public static let maxLongEdge = 2576
    /// …and 4,784 visual tokens, `⌈w/28⌉ × ⌈h/28⌉`.
    public static let maxVisualTokens = 4784
    public static let tokenTile = 28

    /// What the assistant sends: at most 1280 × 800, the docs' recommended desktop resolution range
    /// ("1024x768 or 1280x720 … 1280x800"), well inside the API limits, so a 5K Mac screen costs about
    /// 1,200 image tokens instead of 4,784. The reference container (1024 × 768) is sent as is.
    public static let targetBox = (width: 1280, height: 800)

    public static func visualTokens(width: Int, height: Int) -> Int {
        ((width + tokenTile - 1) / tokenTile) * ((height + tokenTile - 1) / tokenTile)
    }

    public static func fitsAPI(width: Int, height: Int) -> Bool {
        max(width, height) <= maxLongEdge && visualTokens(width: width, height: height) <= maxVisualTokens
    }

    /// The largest size with the aspect ratio of `width × height` (never upscaled) that fits
    /// `box` and the API limits. Floors each side, then shrinks one more pixel while the token
    /// ceilings push it over.
    public static func fittedSize(width: Int, height: Int,
                                  box: (width: Int, height: Int)? = targetBox) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        var scale = 1.0
        if let box { scale = min(scale, Double(box.width) / Double(width), Double(box.height) / Double(height)) }
        scale = min(scale, Double(maxLongEdge) / Double(max(width, height)),
                    (Double(maxVisualTokens * tokenTile * tokenTile) / Double(width * height)).squareRoot())
        var w = max(1, Int((Double(width) * scale).rounded(.down)))
        var h = max(1, Int((Double(height) * scale).rounded(.down)))
        while !fitsAPI(width: w, height: h) && w > 1 && h > 1 {
            if w >= h {
                w -= 1
                h = max(1, Int((Double(w) * Double(height) / Double(width)).rounded(.down)))
            } else {
                h -= 1
                w = max(1, Int((Double(h) * Double(width) / Double(height)).rounded(.down)))
            }
        }
        return (w, h)
    }
}

/// How one screenshot maps to the remote framebuffer: Claude's coordinates are in the pixel space of
/// the full screenshots (also after a zoom), and go back to remote pixels on each axis separately.
public struct ScreenMapping: Sendable, Equatable {
    public var remoteWidth: Int
    public var remoteHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int

    public init(remoteWidth: Int, remoteHeight: Int, imageWidth: Int, imageHeight: Int) {
        self.remoteWidth = remoteWidth
        self.remoteHeight = remoteHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// The mapping of a framebuffer sent at `ImageLimits.fittedSize`.
    public init(remoteWidth: Int, remoteHeight: Int) {
        let size = ImageLimits.fittedSize(width: remoteWidth, height: remoteHeight)
        self.init(remoteWidth: remoteWidth, remoteHeight: remoteHeight, imageWidth: size.width, imageHeight: size.height)
    }

    public func contains(x: Int, y: Int) -> Bool {
        (0..<imageWidth).contains(x) && (0..<imageHeight).contains(y)
    }

    /// The remote pixel under screenshot pixel (`x`, `y`): the centre of the remote area it covers,
    /// clamped to the framebuffer (rounding at the last column must not land past it). `nil` outside
    /// the screenshot: such an action is rejected (BackendSchema › AssistantAction coordinates).
    public func remotePoint(x: Int, y: Int) -> PointerLocation? {
        guard contains(x: x, y: y) else { return nil }
        func map(_ value: Int, image: Int, remote: Int) -> UInt16 {
            let scaled = ((Double(value) + 0.5) * Double(remote) / Double(image)).rounded(.down)
            return UInt16(clamping: min(max(Int(scaled), 0), remote - 1))
        }
        return PointerLocation(x: map(x, image: imageWidth, remote: remoteWidth),
                               y: map(y, image: imageHeight, remote: remoteHeight))
    }

    /// The screenshot pixel of a remote pixel (the cursor position Claude asks for).
    public func imagePoint(_ remote: PointerLocation) -> (x: Int, y: Int) {
        func map(_ value: UInt16, image: Int, remote: Int) -> Int {
            min(Int((Double(value) * Double(image) / Double(remote)).rounded(.down)), image - 1)
        }
        return (map(remote.x, image: imageWidth, remote: remoteWidth), map(remote.y, image: imageHeight, remote: remoteHeight))
    }

    /// A screenshot region (`zoom`'s `[x0, y0, x1, y1]`) as a remote rectangle; `nil` when it is
    /// empty or not inside the screenshot.
    public func remoteRect(x0: Int, y0: Int, x1: Int, y1: Int) -> RFBRect? {
        guard x1 > x0, y1 > y0, x0 >= 0, y0 >= 0, x1 <= imageWidth, y1 <= imageHeight else { return nil }
        let left = x0 * remoteWidth / imageWidth
        let top = y0 * remoteHeight / imageHeight
        let right = max(left + 1, min(remoteWidth, (x1 * remoteWidth + imageWidth - 1) / imageWidth))
        let bottom = max(top + 1, min(remoteHeight, (y1 * remoteHeight + imageHeight - 1) / imageHeight))
        return RFBRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// An encoded screenshot.
public struct EncodedImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    public var width: Int
    public var height: Int
}

public enum ScreenshotEncoder {
    /// A PNG larger than this goes as JPEG instead: every screenshot stays in the conversation and is
    /// sent again with each request (32 MB request limit).
    public static let maxPNGBytes = 1_500_000
    public static let jpegQuality = 0.8

    public enum Failure: Error, Sendable { case emptyImage, encodingFailed }

    /// `region` (remote pixels, default the whole framebuffer) scaled to fit `ImageLimits` and
    /// encoded. The pixels are RFBKit's (`0xAARRGGBB` little-endian: B, G, R, A in memory).
    public static func encode(_ framebuffer: Framebuffer, region: RFBRect? = nil) throws(Failure) -> EncodedImage {
        let rect = region ?? RFBRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
        guard rect.width > 0, rect.height > 0, rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= framebuffer.width, rect.y + rect.height <= framebuffer.height,
              let source = makeImage(framebuffer, rect: rect) else { throw .emptyImage }
        let size = ImageLimits.fittedSize(width: rect.width, height: rect.height)
        let image = size.width == rect.width && size.height == rect.height ? source : scale(source, to: size)
        guard let image else { throw .encodingFailed }
        if let png = data(image, type: .png), png.count <= maxPNGBytes {
            return EncodedImage(data: png, mediaType: "image/png", width: image.width, height: image.height)
        }
        guard let jpeg = data(image, type: .jpeg, quality: jpegQuality) else { throw .encodingFailed }
        return EncodedImage(data: jpeg, mediaType: "image/jpeg", width: image.width, height: image.height)
    }

    private static func makeImage(_ framebuffer: Framebuffer, rect: RFBRect) -> CGImage? {
        var pixels = [UInt32]()
        pixels.reserveCapacity(rect.width * rect.height)
        for row in rect.y..<(rect.y + rect.height) {
            let start = row * framebuffer.width + rect.x
            pixels += framebuffer.pixels[start..<(start + rect.width)]
        }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: rect.width, height: rect.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rect.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func scale(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    private static func data(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
