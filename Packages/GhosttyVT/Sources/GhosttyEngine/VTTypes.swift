import Foundation

/// An sRGB colour, 8 bits per channel.
public struct VTColor: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }
}

/// The text attributes of a cell (SGR), as the renderer needs them.
public struct VTCellStyle: Hashable, Sendable {
    public enum Underline: UInt8, Sendable {
        case none, single, double, curly, dotted, dashed
    }

    public var bold = false
    public var italic = false
    public var faint = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false
    public var overline = false
    public var underline = Underline.none

    public init() {}
}

/// One cell of a viewport row. A wide character is one cell with `width == 2`; the spacer that
/// follows it is not reported.
public struct VTCell: Equatable, Sendable {
    /// Column in the viewport.
    public var column: Int
    /// The grapheme cluster (base and extra code points); empty for a blank cell.
    public var text: String
    /// 1, or 2 for a wide character.
    public var width: Int
    /// The cell's own colours, `nil` for the terminal default.
    public var foreground: VTColor?
    public var background: VTColor?
    public var style: VTCellStyle

    public init(column: Int, text: String, width: Int, foreground: VTColor?, background: VTColor?,
                style: VTCellStyle) {
        self.column = column
        self.text = text
        self.width = width
        self.foreground = foreground
        self.background = background
        self.style = style
    }
}

/// One viewport row from the render state.
public struct VTRow: Sendable {
    public var y: Int
    public var cells: [VTCell]
    /// The selected columns of this row, inclusive, if the selection crosses it.
    public var selection: ClosedRange<Int>?
}

public struct VTCursor: Equatable, Sendable {
    public enum Shape: Sendable { case block, bar, underline, hollowBlock }
    public var x: Int
    public var y: Int
    public var shape: Shape
    /// On the right half of a wide character.
    public var wideTail: Bool
}

/// What a render-state update found.
public enum VTDirty: Sendable {
    case clean, partial, full
}

/// The terminal's colours after any OSC override, for one frame.
public struct VTFrameColors: Equatable, Sendable {
    public var foreground: VTColor
    public var background: VTColor
    /// `nil`: no explicit cursor colour (draw it with the foreground).
    public var cursor: VTColor?
}

/// A grid point: column and row in the viewport (row 0 is the top visible row).
public struct VTPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// The viewport's place in the scrollback, in rows.
public struct VTScrollbar: Equatable, Sendable {
    public var total: Int
    public var offset: Int
    public var length: Int
}

/// Modifier keys (`GhosttyMods`).
public struct VTMods: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = VTMods(rawValue: 1 << 0)
    public static let control = VTMods(rawValue: 1 << 1)
    public static let alt = VTMods(rawValue: 1 << 2)
    public static let command = VTMods(rawValue: 1 << 3)
    public static let capsLock = VTMods(rawValue: 1 << 4)
    public static let numLock = VTMods(rawValue: 1 << 5)
    /// The right-hand variant of the held ⇧ / ⌃ / ⌥ / ⌘ (only meaningful with that modifier).
    public static let shiftRight = VTMods(rawValue: 1 << 6)
    public static let controlRight = VTMods(rawValue: 1 << 7)
    public static let altRight = VTMods(rawValue: 1 << 8)
    public static let commandRight = VTMods(rawValue: 1 << 9)
}

/// A key event for the key encoder.
public struct VTKeyEvent: Sendable {
    public enum Action: Sendable { case press, release, `repeat` }

    /// The physical key (`GhosttyKey` raw value, from `VTKey.fromMacKeyCode`).
    public var key: VTKey
    public var action: Action
    public var mods: VTMods
    /// The modifiers the layout used to produce `text` (⇧, ⌥ when composing).
    public var consumedMods: VTMods
    /// The text the key produced on the user's layout, before any ⌃ / Meta change. Empty for keys
    /// that produce no text (arrows, F-keys, ⌃ chords); never C0 or the Mac's function-key range.
    public var text: String
    /// The character of the key on the layout with no modifier (AZERTY's "a" key is the physical Q).
    public var unshifted: Unicode.Scalar?
    /// Part of an input-method composition (dead key, marked text).
    public var composing: Bool

    public init(key: VTKey, action: Action = .press, mods: VTMods = [], consumedMods: VTMods = [],
                text: String = "", unshifted: Unicode.Scalar? = nil, composing: Bool = false) {
        self.key = key
        self.action = action
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshifted = unshifted
        self.composing = composing
    }
}

/// A mouse event for the mouse encoder. Positions are in the same unit as `VTMouseGeometry`.
public struct VTMouseEvent: Sendable {
    public enum Action: Sendable { case press, release, motion }
    public enum Button: Int, Sendable {
        case left = 1, right = 2, middle = 3, wheelUp = 4, wheelDown = 5, wheelLeft = 6, wheelRight = 7
    }

    public var action: Action
    public var button: Button?
    public var mods: VTMods
    public var x: Double
    public var y: Double

    public init(action: Action, button: Button?, mods: VTMods = [], x: Double, y: Double) {
        self.action = action
        self.button = button
        self.mods = mods
        self.x = x
        self.y = y
    }
}

/// The drawn grid, for the mouse encoder: everything in one unit (backing pixels).
public struct VTMouseGeometry: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var cellWidth: Double
    public var cellHeight: Double
    public var paddingX: Double
    public var paddingY: Double

    public init(width: Double, height: Double, cellWidth: Double, cellHeight: Double,
                paddingX: Double, paddingY: Double) {
        self.width = width
        self.height = height
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingX = paddingX
        self.paddingY = paddingY
    }
}
