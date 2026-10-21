import CoreGraphics
import Metal
import RemoteDeckCore
import RFBKit
import Testing
@testable import RemoteDeck

/// Uploads and draws through the real Metal pipeline, offscreen, and reads the pixels back.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct FramebufferRendererTests {
    let renderer: FramebufferRenderer

    init() throws {
        renderer = try FramebufferRenderer(device: #require(MTLCreateSystemDefaultDevice()))
    }

    /// Distinct red, green and blue per pixel, so a swapped channel order or a shifted copy shows.
    static func pattern(width: Int, height: Int, seed: UInt32) -> [UInt32] {
        (0..<(width * height)).map { index in
            let x = UInt32(index % width), y = UInt32(index / width)
            return 0xFF00_0000 | ((x &* 7 &+ seed) & 0xFF) << 16 | ((y &* 13 &+ seed) & 0xFF) << 8
                | ((x &+ y &* 3 &+ seed &* 5) & 0xFF)
        }
    }

    /// Reference model: what the framebuffer holds after copying `pixels` into `rect`.
    static func paste(_ pixels: [UInt32], at rect: RFBRect, into frame: inout [UInt32], width: Int) {
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                frame[(rect.y + row) * width + rect.x + column] = pixels[row * rect.width + column]
            }
        }
    }

    static func update(width: Int, height: Int, _ regions: [(RFBRect, [UInt32])]) -> RFBEvent {
        .framebufferUpdate(FramebufferUpdate(width: width, height: height,
                                             regions: regions.map { .init(rect: $0.0, pixels: $0.1) }))
    }

    func textureContents() throws -> [UInt32] {
        renderer.readPixels(of: try #require(renderer.texture))
    }

    func makeTarget(width: Int, height: Int) throws -> any MTLTexture {
        // A literal format, like the CAMetalLayer's: drawn colors must match RFBKit's 0xAARRGGBB pixels.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    @Test func uploadsOnlyTheRegionsAndKeepsTheRest() throws {
        let model = SessionDisplayModel(renderer: renderer)
        let width = 37, height = 23
        var expected = Self.pattern(width: width, height: height, seed: 1)
        model.handle(Self.update(width: width, height: height,
                                 [(RFBRect(x: 0, y: 0, width: width, height: height), expected)]))
        #expect(try textureContents() == expected)

        // Two regions in one update, overlapping: applied in order.
        let first = RFBRect(x: 5, y: 3, width: 10, height: 7)
        let second = RFBRect(x: 12, y: 8, width: 25, height: 15)
        let firstPixels = Self.pattern(width: first.width, height: first.height, seed: 90)
        let secondPixels = Self.pattern(width: second.width, height: second.height, seed: 170)
        model.handle(Self.update(width: width, height: height, [(first, firstPixels), (second, secondPixels)]))
        Self.paste(firstPixels, at: first, into: &expected, width: width)
        Self.paste(secondPixels, at: second, into: &expected, width: width)
        #expect(try textureContents() == expected)
        #expect(renderer.uploadCount == 2)
    }

    @Test func skipsInvalidRegions() throws {
        let model = SessionDisplayModel(renderer: renderer)
        let frame = Self.pattern(width: 8, height: 8, seed: 3)
        model.handle(Self.update(width: 8, height: 8, [(RFBRect(x: 0, y: 0, width: 8, height: 8), frame)]))
        model.handle(Self.update(width: 8, height: 8, [
            (RFBRect(x: 6, y: 6, width: 4, height: 4), [UInt32](repeating: 0xFFFF_FFFF, count: 16)),  // outside
            (RFBRect(x: 0, y: 0, width: 2, height: 2), [0xFFFF_FFFF]),                                // short
        ]))
        #expect(try textureContents() == frame)
    }

    @Test func resizeKeepsTheTopLeftOverlapAndBlacksTheRest() throws {
        let model = SessionDisplayModel(renderer: renderer)
        let frame = Self.pattern(width: 40, height: 30, seed: 7)
        model.handle(Self.update(width: 40, height: 30, [(RFBRect(x: 0, y: 0, width: 40, height: 30), frame)]))

        model.handle(.desktopResized(width: 50, height: 20))
        var expected = [UInt32](repeating: Framebuffer.black, count: 50 * 20)
        for y in 0..<20 {
            for x in 0..<40 { expected[y * 50 + x] = frame[y * 40 + x] }
        }
        #expect(renderer.framebufferSize.map { [$0.width, $0.height] } == [50, 20])
        #expect(try textureContents() == expected)

        // Then an update at the new size lands in the new texture.
        let patch = RFBRect(x: 42, y: 15, width: 8, height: 5)
        let patchPixels = Self.pattern(width: 8, height: 5, seed: 200)
        model.handle(Self.update(width: 50, height: 20, [(patch, patchPixels)]))
        Self.paste(patchPixels, at: patch, into: &expected, width: 50)
        #expect(try textureContents() == expected)
    }

    @Test func ignoresSizesBeyondFramebufferLimits() {
        renderer.resize(width: 64, height: 48)
        renderer.resize(width: Framebuffer.maxDimension, height: Framebuffer.maxDimension)   // > maxPixelCount
        renderer.resize(width: Framebuffer.maxDimension + 1, height: 1)
        renderer.resize(width: 0, height: 10)
        #expect(renderer.framebufferSize.map { [$0.width, $0.height] } == [64, 48])
    }

    @Test func drawsOneToOneTopLeftFirstWithBlackLetterbox() throws {
        let model = SessionDisplayModel(renderer: renderer)
        let width = 37, height = 23
        let frame = Self.pattern(width: width, height: height, seed: 11)
        model.handle(Self.update(width: width, height: height, [(RFBRect(x: 0, y: 0, width: width, height: height), frame)]))

        // A 60 × 40 px Retina target (30 × 20 pt): content at (11, 8) px, see FramebufferGeometryTests.
        let target = try makeTarget(width: 60, height: 40)
        let geometry = FramebufferGeometry(remoteWidth: width, remoteHeight: height,
                                           viewSize: CGSize(width: 30, height: 20), backingScale: 2, mode: .actual)
        let commandBuffer = try #require(renderer.render(to: target, geometry: geometry))
        commandBuffer.commit()
        let drawn = renderer.readPixels(of: target)

        var expected = [UInt32](repeating: Framebuffer.black, count: 60 * 40)
        Self.paste(frame, at: RFBRect(x: 11, y: 8, width: width, height: height), into: &expected, width: 60)
        #expect(drawn == expected)
    }

    @Test func fitDrawsAUniformFrameWithLetterbox() throws {
        let model = SessionDisplayModel(renderer: renderer)
        let color: UInt32 = 0xFF20_40C0
        model.handle(Self.update(width: 64, height: 32, [(RFBRect(x: 0, y: 0, width: 64, height: 32),
                                                          [UInt32](repeating: color, count: 64 * 32))]))
        // 100 × 100 pt at 1×: scaled to 100 × 50, bars of 25 px above and below.
        let target = try makeTarget(width: 100, height: 100)
        let geometry = FramebufferGeometry(remoteWidth: 64, remoteHeight: 32, viewSize: CGSize(width: 100, height: 100),
                                           backingScale: 1, mode: .fit)
        #expect(!geometry.isPixelExact)
        let commandBuffer = try #require(renderer.render(to: target, geometry: geometry))
        commandBuffer.commit()
        let drawn = renderer.readPixels(of: target)
        for y in 0..<100 {
            #expect(drawn[y * 100 + 50] == ((25..<75).contains(y) ? color : Framebuffer.black), "row \(y)")
        }
    }

    @Test func consumesAnEventStreamInOrder() async throws {
        let model = SessionDisplayModel(renderer: renderer)
        let (events, continuation) = AsyncThrowingStream.makeStream(of: RFBEvent.self)
        let frame = Self.pattern(width: 16, height: 16, seed: 5)
        continuation.yield(Self.update(width: 16, height: 16, [(RFBRect(x: 0, y: 0, width: 16, height: 16), frame)]))
        continuation.yield(.bell)
        continuation.yield(.desktopResized(width: 8, height: 8))
        continuation.finish()
        try await model.consume(events)
        var expected = [UInt32]()
        for y in 0..<8 { expected += frame[(y * 16)..<(y * 16 + 8)] }
        #expect(try textureContents() == expected)
    }
}
