import CoreGraphics
import RemoteDeckCore

/// When `FramebufferView` draws. A frame is owed after anything that changes the picture (new pixels
/// or a framebuffer resize, a different scaling mode, scroll offset, backing scale or drawable size)
/// and stays owed until a draw succeeds; the display link runs only while a frame is owed, so a static
/// desktop costs no frame. Setting a property to its current value owes nothing.
struct FramebufferRedrawState {
    private(set) var needsRedraw = true
    private(set) var scalingMode: ScalingMode = .fit
    private(set) var scrollOffset: CGPoint = .zero
    private(set) var backingScale: CGFloat = 2
    /// Drawable size in pixels.
    private(set) var drawableSize: CGSize = .zero

    var isPaused: Bool { !needsRedraw }

    /// New pixels, a framebuffer resize, a new renderer or an AppKit redisplay.
    mutating func contentChanged() {
        needsRedraw = true
    }

    mutating func setScalingMode(_ mode: ScalingMode) {
        guard mode != scalingMode else { return }
        scalingMode = mode
        needsRedraw = true
    }

    mutating func setScrollOffset(_ offset: CGPoint) {
        guard offset != scrollOffset else { return }
        scrollOffset = offset
        needsRedraw = true
    }

    mutating func setBackingScale(_ scale: CGFloat) {
        guard scale != backingScale else { return }
        backingScale = scale
        needsRedraw = true
    }

    mutating func setDrawableSize(_ size: CGSize) {
        guard size != drawableSize else { return }
        drawableSize = size
        needsRedraw = true
    }

    /// After a display-link tick that tried to draw. A failed draw (no drawable available) keeps the
    /// frame owed, so the next tick retries instead of leaving a stale picture.
    mutating func tick(drawSucceeded: Bool) {
        if drawSucceeded { needsRedraw = false }
    }
}
