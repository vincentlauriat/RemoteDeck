import CoreGraphics
import RemoteDeckCore

/// Where the remote framebuffer sits in a `FramebufferView`, and the mapping between view points
/// and remote pixels. View coordinates are flipped (origin top-left, y down), like the framebuffer.
///
/// - `fit`: the whole framebuffer, aspect ratio kept, centered, scaled up or down to the view; the
///   rest is letterbox (black, DesignBrief › Layout rules).
/// - `actual`: one remote pixel per device pixel of the local display, i.e. `1 / backingScale`
///   points, so the image is pixel-exact. On an axis where the framebuffer is smaller than the view
///   it is centered; where it is larger it is clipped, and `scrollOffset` (points, the top-left of
///   the visible part) picks what is shown. The offset is clamped here; moving it is up to the
///   Session Window (T3.5).
///
/// The content origin is snapped to the device-pixel grid so 1:1 drawing samples whole texels.
struct FramebufferGeometry: Equatable {
    let remoteWidth: Int
    let remoteHeight: Int
    let viewSize: CGSize
    let backingScale: CGFloat
    let mode: ScalingMode
    /// Points per remote pixel.
    let scale: CGFloat
    /// The framebuffer in view points; in `actual` mode it may extend past the view.
    let contentRect: CGRect

    init(remoteWidth: Int, remoteHeight: Int, viewSize: CGSize, backingScale: CGFloat,
         mode: ScalingMode, scrollOffset: CGPoint = .zero) {
        self.remoteWidth = remoteWidth
        self.remoteHeight = remoteHeight
        self.viewSize = viewSize
        self.backingScale = backingScale
        self.mode = mode
        let remote = CGSize(width: remoteWidth, height: remoteHeight)
        switch mode {
        case .fit:
            scale = remoteWidth > 0 && remoteHeight > 0
                ? max(0, min(viewSize.width / remote.width, viewSize.height / remote.height)) : 0
        case .actual:
            scale = 1 / backingScale
        }
        let content = CGSize(width: remote.width * scale, height: remote.height * scale)
        let snap = { (value: CGFloat) in (value * backingScale).rounded(.down) / backingScale }
        // Centered when it fits on that axis, otherwise shifted left/up by the clamped offset.
        func origin(view: CGFloat, content: CGFloat, offset: CGFloat) -> CGFloat {
            content <= view ? snap((view - content) / 2) : -snap(min(max(offset, 0), content - view))
        }
        contentRect = CGRect(x: origin(view: viewSize.width, content: content.width, offset: scrollOffset.x),
                             y: origin(view: viewSize.height, content: content.height, offset: scrollOffset.y),
                             width: content.width, height: content.height)
    }

    /// `true` when one remote pixel covers exactly one device pixel: sample with nearest filtering.
    var isPixelExact: Bool { abs(scale * backingScale - 1) < 1e-9 }

    /// Remote pixel coordinates (fractional, may lie outside the framebuffer) under a view point.
    func remotePoint(forViewPoint point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: (point.x - contentRect.minX) / scale, y: (point.y - contentRect.minY) / scale)
    }

    /// The remote pixel under a view point, or `nil` over the letterbox.
    func remotePixel(forViewPoint point: CGPoint) -> (x: Int, y: Int)? {
        guard scale > 0 else { return nil }
        let remote = remotePoint(forViewPoint: point)
        let x = Int(remote.x.rounded(.down))
        let y = Int(remote.y.rounded(.down))
        guard (0..<remoteWidth).contains(x), (0..<remoteHeight).contains(y) else { return nil }
        return (x, y)
    }

    /// The view point of a remote position (integer coordinates are a pixel's top-left corner).
    func viewPoint(forRemotePoint remote: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + remote.x * scale, y: contentRect.minY + remote.y * scale)
    }
}
