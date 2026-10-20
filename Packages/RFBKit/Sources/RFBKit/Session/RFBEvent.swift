import Foundation

/// What the server sent, decoded. Delivered by `RFBConnection.startSession` in arrival order.
public enum RFBEvent: Equatable, Sendable {
    /// One FramebufferUpdate message has been applied.
    case framebufferUpdate(FramebufferUpdate)
    /// The framebuffer changed size (DesktopSize or ExtendedDesktopSize). Updates that follow use the
    /// new size; the overlapping top-left content is kept until the server repaints it.
    case desktopResized(width: Int, height: Int)
    case bell
    /// ServerCutText, decoded as Latin-1 (RFC 6143 §7.6.4).
    case serverCutText(String)
    /// The cursor shape changed (Cursor pseudo-encoding).
    case cursor(CursorShape)
}

/// The regions a FramebufferUpdate changed, each with a copy of its new pixels, so the consumer can
/// upload only what changed (e.g. into a Metal texture) without sharing the decoder's buffer.
public struct FramebufferUpdate: Equatable, Sendable {
    public struct Region: Equatable, Sendable {
        public var rect: RFBRect
        /// `rect.width × rect.height` pixels, row-major, in the `Framebuffer.pixels` format.
        public var pixels: [UInt32]
    }

    /// Framebuffer size the regions refer to.
    public var width: Int
    public var height: Int
    /// In the order the server sent them; regions may overlap. Their pixels never add up to more
    /// than one framebuffer: many rectangles are merged into their bounding box.
    public var regions: [Region]
    /// `false` for the regions handed out just before a resize in the middle of a FramebufferUpdate
    /// (they refer to the old size); the rest of that message follows in another update.
    public var completesMessage: Bool = true
}

/// A cursor image from the Cursor pseudo-encoding. Pixels use the `Framebuffer.pixels` format with
/// premultiplied alpha: 255 where the server's bitmask is set, fully transparent (0) elsewhere.
public struct CursorShape: Equatable, Sendable {
    /// Largest cursor width or height accepted.
    public static let maxDimension = 512

    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    public var pixels: [UInt32]
}
