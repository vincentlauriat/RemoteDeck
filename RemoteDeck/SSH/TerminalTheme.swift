import AppKit
import CoreText
import GhosttyEngine

/// The terminal's colours (DesignBrief › Colors › Terminal area): Ghostty's defaults in dark mode,
/// Ghostty's bundled "Tomorrow" theme (the light sibling of the Tomorrow Night hues of Ghostty's
/// default palette) in light mode. Read from Ghostty 1.4.0 (`ghostty +show-config --default` and
/// `Ghostty.app/Contents/Resources/ghostty/themes/Tomorrow`).
struct TerminalTheme: Equatable {
    var foreground: VTColor
    var background: VTColor
    /// `nil`: the cursor takes the foreground colour, and the text under it the background.
    var cursor: VTColor?
    /// The 16 ANSI colours, or `nil` for the engine's built-in palette (Ghostty's default).
    var ansi: [VTColor]?
    /// `nil`: a selected cell swaps its foreground and background (Ghostty's default).
    var selectionBackground: VTColor?
    var selectionForeground: VTColor?

    /// Ghostty 1.4.0 with no config: background #282C34, foreground #FFFFFF, the built-in palette.
    static let dark = TerminalTheme(foreground: VTColor(hex: 0xFFFFFF), background: VTColor(hex: 0x282C34),
                                    cursor: nil, ansi: nil, selectionBackground: nil, selectionForeground: nil)

    /// Ghostty's "Tomorrow" theme.
    static let light = TerminalTheme(
        foreground: VTColor(hex: 0x4D4D4C), background: VTColor(hex: 0xFFFFFF), cursor: VTColor(hex: 0x4D4D4C),
        ansi: [0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xBFBFBF,
               0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF].map(VTColor.init(hex:)),
        selectionBackground: VTColor(hex: 0xD6D6D6), selectionForeground: VTColor(hex: 0x4D4D4C))

    /// The theme for the window's effective appearance.
    static func forAppearance(isDark: Bool) -> TerminalTheme { isDark ? .dark : .light }
}

extension VTColor {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// The terminal font: JetBrains Mono (Ghostty's embedded default, bundled under SIL OFL 1.1, release
/// 2.304), 13 pt by default as Ghostty on macOS; the system monospaced font if it cannot be loaded.
/// The four static faces are registered for this process once, on first use.
@MainActor
struct TerminalFonts {
    static let defaultSize: CGFloat = 13
    static let sizeRange: ClosedRange<CGFloat> = 8...36
    static let familyName = "JetBrains Mono"

    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let size: CGFloat
    /// Whether JetBrains Mono was found (false: the system monospaced fallback).
    let isBundledFont: Bool

    init(size: CGFloat) {
        let size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.size = size
        Self.registerBundledFonts()
        if let regular = Self.face("JetBrainsMono-Regular", size: size) {
            self.regular = regular
            bold = Self.face("JetBrainsMono-Bold", size: size) ?? regular
            italic = Self.face("JetBrainsMono-Italic", size: size) ?? regular
            boldItalic = Self.face("JetBrainsMono-BoldItalic", size: size) ?? bold
            isBundledFont = true
        } else {
            let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
            regular = system
            bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold) as CTFont
            italic = CTFontCreateCopyWithSymbolicTraits(system, size, nil, .traitItalic, .traitItalic) ?? system
            boldItalic = CTFontCreateCopyWithSymbolicTraits(bold, size, nil, .traitItalic, .traitItalic) ?? bold
            isBundledFont = false
        }
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    /// A face by PostScript name, only if that face itself was found (CoreText otherwise substitutes).
    private static func face(_ postScriptName: String, size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(postScriptName as CFString, size, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName ? font : nil
    }

    private static var registered = false

    private static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        let urls = ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]
            .compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
        guard !urls.isEmpty else { return }
        // Already registered (another process scope) or a damaged file: the lookup above falls back.
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, false, nil)
    }
}

/// The cell grid of a terminal view: cell size from the font, columns and rows from the view size
/// (Ghostty's 2 pt window padding on each side).
struct TerminalGrid: Equatable {
    static let padding: CGFloat = 2

    var cellWidth: CGFloat
    var cellHeight: CGFloat
    /// Distance from a cell's top to the baseline.
    var ascent: CGFloat

    /// Cell metrics of a monospaced font: the advance of "M" rounded up (so every glyph is placed at
    /// a whole cell, as Ghostty does), and the line height rounded up.
    init(font: CTFont) {
        var glyph = CGGlyph(0)
        var character = UniChar(77)   // "M"
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        self.init(cellWidth: ceil(max(advance.width, 1)), cellHeight: ceil(ascent + descent + leading),
                  ascent: ceil(ascent + leading / 2))
    }

    init(cellWidth: CGFloat, cellHeight: CGFloat, ascent: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.ascent = ascent
    }

    /// Columns and rows that fit in `size` (at least 1 × 1).
    func size(fitting size: CGSize) -> (columns: Int, rows: Int) {
        let width = size.width - 2 * Self.padding
        let height = size.height - 2 * Self.padding
        return (max(1, Int((width / cellWidth).rounded(.down))), max(1, Int((height / cellHeight).rounded(.down))))
    }

    /// The cell under a point of the view (flipped: y down), clamped to the grid.
    func cell(at point: CGPoint, columns: Int, rows: Int) -> VTPoint {
        let x = Int(((point.x - Self.padding) / cellWidth).rounded(.down))
        let y = Int(((point.y - Self.padding) / cellHeight).rounded(.down))
        return VTPoint(x: max(0, min(x, columns - 1)), y: max(0, min(y, rows - 1)))
    }

    func rowRect(_ y: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: Self.padding + CGFloat(y) * cellHeight, width: width, height: cellHeight)
    }
}
