import Metal
import RFBKit

/// The GPU copy of a remote framebuffer, and the pass that draws it scaled into a target texture.
///
/// The texture is `bgra8Unorm`, RFBKit's pixel layout in memory (`0xAARRGGBB` as a little-endian
/// `UInt32`), so region pixels are copied as-is. Each update copies its regions into one shared
/// `MTLBuffer` (the only CPU work) and blits them into the private texture in a command buffer of its
/// own. The GPU runs that blit after any draw already sampling the texture and before the next one, so
/// an upload never tears a frame in flight and never waits for the GPU.
@MainActor
final class FramebufferRenderer {
    enum SetupError: Error {
        case metalUnavailable
    }

    /// RFBKit's pixel layout in memory: region pixels are copied into the texture byte for byte.
    static let textureFormat = MTLPixelFormat.bgra8Unorm
    /// What the pass renders into: the `CAMetalLayer` drawables (and offscreen targets in tests).
    static let drawableFormat = MTLPixelFormat.bgra8Unorm

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let linearSampler: any MTLSamplerState
    private let nearestSampler: any MTLSamplerState
    /// The remote screen; `nil` until the first update or resize gives its size.
    private(set) var texture: (any MTLTexture)?
    /// Called after the texture contents or size changed (the view schedules a redraw).
    var onChange: (() -> Void)?
    /// Number of updates uploaded, for the debug counters.
    private(set) var uploadCount = 0

    var framebufferSize: (width: Int, height: Int)? {
        texture.map { ($0.width, $0.height) }
    }

    /// Compiles the shader from source at run time: no `.metal` file, so the build never depends on
    /// the Metal toolchain (a separate Xcode component, not guaranteed on CI runners).
    init(device: any MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw SetupError.metalUnavailable }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "framebufferVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "framebufferFragment")
        descriptor.colorAttachments[0].pixelFormat = Self.drawableFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let linear = Self.makeSampler(device, filter: .linear),
              let nearest = Self.makeSampler(device, filter: .nearest) else { throw SetupError.metalUnavailable }
        self.device = device
        self.queue = queue
        linearSampler = linear
        nearestSampler = nearest
    }

    private static func makeSampler(_ device: any MTLDevice, filter: MTLSamplerMinMagFilter) -> (any MTLSamplerState)? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }

    // MARK: Uploads

    /// Uploads the regions of `update`. A size different from the texture's (first update) re-creates
    /// it first. Regions outside the texture or with a wrong pixel count are skipped.
    func apply(_ update: FramebufferUpdate) {
        if texture?.width != update.width || texture?.height != update.height {
            resize(width: update.width, height: update.height)
        }
        guard let texture else { return }
        let regions = update.regions.filter { region in
            let rect = region.rect
            return !rect.isEmpty && rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= texture.width
                && rect.y + rect.height <= texture.height && region.pixels.count == rect.width * rect.height
        }
        let pixelSize = MemoryLayout<UInt32>.size
        let byteCount = regions.reduce(0) { $0 + $1.pixels.count * pixelSize }
        guard byteCount > 0,
              let staging = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        var offset = 0
        for region in regions {
            let rect = region.rect
            region.pixels.withUnsafeBytes { bytes in
                (staging.contents() + offset).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: rect.width * pixelSize,
                      sourceBytesPerImage: 0, sourceSize: MTLSize(width: rect.width, height: rect.height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: rect.x, y: rect.y, z: 0))
            offset += region.pixels.count * pixelSize
        }
        blit.endEncoding()
        commandBuffer.commit()
        uploadCount += 1
        onChange?()
    }

    /// Re-creates the texture at the new size, keeping the overlapping top-left content and filling the
    /// rest with black, as `Framebuffer` does on a DesktopSize change. Sizes beyond `Framebuffer`'s
    /// limits are ignored (RFBKit never reports them).
    func resize(width: Int, height: Int) {
        guard (1...Framebuffer.maxDimension).contains(width), (1...Framebuffer.maxDimension).contains(height),
              width * height <= Framebuffer.maxPixelCount,
              texture?.width != width || texture?.height != height else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.textureFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let resized = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = resized
        clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        clear.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        if let old = texture, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: old, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: min(old.width, width), height: min(old.height, height), depth: 1),
                      to: resized, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        commandBuffer.commit()
        texture = resized
        onChange?()
    }

    // MARK: Drawing

    /// Encodes a frame into `target` (a drawable's texture, or an offscreen texture in tests): opaque
    /// black everywhere, the framebuffer at `geometry.contentRect` (nearest filtering when pixel-exact,
    /// linear otherwise). The caller presents and commits the returned command buffer.
    func render(to target: any MTLTexture, geometry: FramebufferGeometry?) -> (any MTLCommandBuffer)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if let texture, let geometry, geometry.viewSize.width > 0, geometry.viewSize.height > 0 {
            // Content rectangle in normalized device coordinates (y up): left, top, right, bottom.
            let rect = geometry.contentRect
            let size = geometry.viewSize
            var quad = SIMD4<Float>(Float(rect.minX / size.width * 2 - 1), Float(1 - rect.minY / size.height * 2),
                                    Float(rect.maxX / size.width * 2 - 1), Float(1 - rect.maxY / size.height * 2))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(geometry.isPixelExact ? nearestSampler : linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    /// Reads a texture back as RFBKit pixels after all committed work. Blocks until the GPU is done:
    /// for tests only.
    func readPixels(of texture: any MTLTexture) -> [UInt32] {
        let pixelSize = MemoryLayout<UInt32>.size
        let rowBytes = texture.width * pixelSize
        guard let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: 0)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let pointer = buffer.contents().bindMemory(to: UInt32.self, capacity: texture.width * texture.height)
        return Array(UnsafeBufferPointer(start: pointer, count: texture.width * texture.height))
    }

    /// A quad covering the content rectangle (`rect`: left, top, right, bottom in NDC); texture
    /// coordinates run from the top-left corner, matching the framebuffer's row order.
    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct QuadVertex {
            float4 position [[position]];
            float2 uv;
        };

        vertex QuadVertex framebufferVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
            float2 corner = float2(float(id & 1), float(id >> 1));
            QuadVertex out;
            out.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.y, rect.w, corner.y), 0.0, 1.0);
            out.uv = corner;
            return out;
        }

        fragment float4 framebufferFragment(QuadVertex in [[stage_in]], texture2d<float> screen [[texture(0)]],
                                            sampler filter [[sampler(0)]]) {
            return float4(screen.sample(filter, in.uv).rgb, 1.0);
        }
        """
}
