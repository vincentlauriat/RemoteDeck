import CoreGraphics
import RemoteDeckCore

/// When `FramebufferView` draws. A frame is owed after anything that changes the picture (new pixels
/// or a framebuffer resize, a different scaling mode, scroll offset, backing scale or drawable size)
/// and stays owed until a draw succeeds; the display link runs only while a frame is owed, so a static
/// desktop costs no frame. Setting a property to its current value owes nothing. While the window is
/// not visible the link stays paused, frame owed or not.
struct FramebufferRedrawState {
    private(set) var needsRedraw = true
    private(set) var scalingMode: ScalingMode = .fit
    private(set) var scrollOffset: CGPoint = .zero
    private(set) var backingScale: CGFloat = 2
    /// Drawable size in pixels.
    private(set) var drawableSize: CGSize = .zero
    /// The view's window is on screen (`NSWindow.occlusionState`): a background session tab, a
    /// minimised or fully covered window draws nothing, however many updates arrive.
    private(set) var isVisible = true

    var isPaused: Bool { !needsRedraw || !isVisible }

    /// Hidden: no frame until shown again, the changes meanwhile stay owed. Shown again: one frame is
    /// owed in any case, so the picture is the current texture at once.
    mutating func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { needsRedraw = true }
    }

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
