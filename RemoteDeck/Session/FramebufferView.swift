import AppKit
import QuartzCore
import RemoteDeckCore
import SwiftUI

/// The remote screen: an NSView backed by a `CAMetalLayer`, drawn by the view's display link.
///
/// The display link runs only while there is something to draw (new pixels, a resize, a scaling,
/// scroll or backing-scale change) and pauses itself after the frame, so a static desktop costs no
/// frame and no wake-up at all. The coordinate system is flipped (origin top-left) to match the
/// framebuffer and `FramebufferGeometry`.
final class FramebufferView: NSView {
    var renderer: FramebufferRenderer? {
        didSet {
            guard renderer !== oldValue else { return }
            oldValue?.onChange = nil
            renderer?.onChange = { [weak self] in self?.redraw.contentChanged() }
            metalLayer.device = renderer?.device
            redraw.contentChanged()
        }
    }

    var scalingMode: ScalingMode {
        get { redraw.scalingMode }
        set { redraw.setScalingMode(newValue) }
    }

    /// Top-left of the visible part in `actual` mode when the framebuffer is larger than the view
    /// (points, clamped by `FramebufferGeometry`).
    var scrollOffset: CGPoint {
        get { redraw.scrollOffset }
        set { redraw.setScrollOffset(newValue) }
    }

    /// Frames drawn, for the debug counters.
    private(set) var drawCount = 0

    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?
    private var redraw = FramebufferRedrawState() {
        didSet { displayLink?.isPaused = redraw.isPaused }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        metalLayer.pixelFormat = FramebufferRenderer.drawableFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = CGColor.black
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // During a live resize, keep the last frame unscaled (black around it) until the next draw.
        metalLayer.contentsGravity = .topLeft
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }

    /// AppKit asks for a redisplay (e.g. during a live resize): draw on the next display refresh.
    override func updateLayer() {
        redraw.contentChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        redraw.setBackingScale(scale)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Invalidated when leaving the window: the link retains the view.
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        // Up to ProMotion's 120 Hz; the system clamps it to the display the window is on.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = redraw.isPaused
        link.add(to: .main, forMode: .common)
        displayLink = link
        viewDidChangeBackingProperties()
    }

    /// The current placement of the framebuffer, `nil` before its size is known. The view size is the
    /// drawable's (whole pixels) in points, so content edges land exactly on drawable pixels even when
    /// the bounds are fractional.
    var geometry: FramebufferGeometry? {
        guard let size = renderer?.framebufferSize else { return nil }
        let scale = redraw.backingScale
        let viewSize = CGSize(width: redraw.drawableSize.width / scale, height: redraw.drawableSize.height / scale)
        return FramebufferGeometry(remoteWidth: size.width, remoteHeight: size.height, viewSize: viewSize,
                                   backingScale: scale, mode: scalingMode, scrollOffset: scrollOffset)
    }

    private func updateDrawableSize() {
        let scale = redraw.backingScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size != metalLayer.drawableSize { metalLayer.drawableSize = size }
        redraw.setDrawableSize(size)
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // Setting `redraw` pauses the link once no frame is owed.
        if redraw.needsRedraw {
            let drawn = draw()   // reads `redraw` (geometry): not inside the mutating call
            redraw.tick(drawSucceeded: drawn)
        } else {
            link.isPaused = true
        }
    }

    /// `false` only when a frame could not be produced (no drawable): the next tick retries. Nothing to
    /// draw yet (no renderer, empty view) counts as done; whatever changes that owes a new frame.
    private func draw() -> Bool {
        guard let renderer, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0 else { return true }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = renderer.render(to: drawable.texture, geometry: geometry) else { return false }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        drawCount += 1
        return true
    }
}

/// SwiftUI wrapper for `FramebufferView`.
struct FramebufferViewRepresentable: NSViewRepresentable {
    let renderer: FramebufferRenderer?
    var scalingMode: ScalingMode
    /// Called once with the created view (e.g. to read its counters).
    var onCreate: ((FramebufferView) -> Void)?

    func makeNSView(context: Context) -> FramebufferView {
        let view = FramebufferView(frame: .zero)
        view.renderer = renderer
        view.scalingMode = scalingMode
        onCreate?(view)
        return view
    }

    func updateNSView(_ view: FramebufferView, context: Context) {
        view.renderer = renderer
        view.scalingMode = scalingMode
    }
}
