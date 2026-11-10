import AppKit
import CoreText
import GhosttyEngine

/// The terminal's colours (DesignBrief › Colors › Terminal area). By default (`TerminalThemeChoice
/// .automatic`) Ghostty's defaults in dark mode and Ghostty's bundled "Tomorrow" theme (the light
/// sibling of the Tomorrow Night hues of Ghostty's default palette) in light mode, read from Ghostty
/// 1.4.0 (`ghostty +show-config --default` and `Ghostty.app/Contents/Resources/ghostty/themes/Tomorrow`).
/// Settings › Terminal picks another built-in theme or edits every colour (`custom`).
struct TerminalTheme: Equatable, Codable {
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

    /// Tomorrow Night (Chris Kempson's palette, the hues of Ghostty's built-in one).
    static let tomorrowNight = TerminalTheme(
        foreground: VTColor(hex: 0xC5C8C6), background: VTColor(hex: 0x1D1F21), cursor: VTColor(hex: 0xC5C8C6),
        ansi: [0x1D1F21, 0xCC6666, 0xB5BD68, 0xF0C674, 0x81A2BE, 0xB294BB, 0x8ABEB7, 0xC5C8C6,
               0x666666, 0xD54E53, 0xB9CA4A, 0xE7C547, 0x7AA6DA, 0xC397D8, 0x70C0B1, 0xEAEAEA].map(VTColor.init(hex:)),
        selectionBackground: VTColor(hex: 0x373B41), selectionForeground: VTColor(hex: 0xC5C8C6))

    /// Ethan Schoonover's Solarized ANSI mapping, shared by the dark and light variants.
    private static let solarizedANSI = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3].map(VTColor.init(hex:))

    static let solarizedDark = TerminalTheme(
        foreground: VTColor(hex: 0x839496), background: VTColor(hex: 0x002B36), cursor: VTColor(hex: 0x93A1A1),
        ansi: solarizedANSI, selectionBackground: VTColor(hex: 0x073642), selectionForeground: VTColor(hex: 0x93A1A1))

    static let solarizedLight = TerminalTheme(
        foreground: VTColor(hex: 0x657B83), background: VTColor(hex: 0xFDF6E3), cursor: VTColor(hex: 0x586E75),
        ansi: solarizedANSI, selectionBackground: VTColor(hex: 0xEEE8D5), selectionForeground: VTColor(hex: 0x586E75))

    /// Dracula (draculatheme.com, MIT).
    static let dracula = TerminalTheme(
        foreground: VTColor(hex: 0xF8F8F2), background: VTColor(hex: 0x282A36), cursor: VTColor(hex: 0xF8F8F2),
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF].map(VTColor.init(hex:)),
        selectionBackground: VTColor(hex: 0x44475A), selectionForeground: VTColor(hex: 0xF8F8F2))

    /// The automatic theme for the window's effective appearance.
    static func forAppearance(isDark: Bool) -> TerminalTheme { isDark ? .dark : .light }

    /// Every colour spelled out (the starting point of a custom theme): the built-in palette's first
    /// 16 colours, the foreground as cursor, a selection that swaps foreground and background.
    var filled: TerminalTheme {
        TerminalTheme(foreground: foreground, background: background, cursor: cursor ?? foreground,
                      ansi: Self.sixteen(ansi), selectionBackground: selectionBackground ?? foreground,
                      selectionForeground: selectionForeground ?? background)
    }

    private static func sixteen(_ colors: [VTColor]?) -> [VTColor] {
        let builtIn = Array(VTTerminal.builtInPalette.prefix(16))
        guard let colors else { return builtIn }
        return (0..<16).map { $0 < colors.count ? colors[$0] : builtIn[$0] }
    }

    /// One editable colour (Settings › Terminal › Colors).
    enum Slot: Hashable {
        case foreground, background, cursor, selectionBackground, selectionForeground
        case ansi(Int)
    }

    /// The colour of a slot, as shown (a `nil` colour resolved as `filled` does).
    func color(_ slot: Slot) -> VTColor {
        let theme = filled
        switch slot {
        case .foreground: return theme.foreground
        case .background: return theme.background
        case .cursor: return theme.cursor ?? theme.foreground
        case .selectionBackground: return theme.selectionBackground ?? theme.foreground
        case .selectionForeground: return theme.selectionForeground ?? theme.background
        case .ansi(let index): return (theme.ansi ?? [])[safe: index] ?? theme.foreground
        }
    }

    /// A filled copy with one colour changed.
    func setting(_ slot: Slot, to color: VTColor) -> TerminalTheme {
        var theme = filled
        switch slot {
        case .foreground: theme.foreground = color
        case .background: theme.background = color
        case .cursor: theme.cursor = color
        case .selectionBackground: theme.selectionBackground = color
        case .selectionForeground: theme.selectionForeground = color
        case .ansi(let index):
            guard (0..<16).contains(index) else { return theme }
            theme.ansi?[index] = color
        }
        return theme
    }

    // MARK: Codable: colours as "#RRGGBB" strings (readable in `defaults read`).

    private enum CodingKeys: String, CodingKey {
        case foreground, background, cursor, ansi, selectionBackground, selectionForeground
    }

    init(foreground: VTColor, background: VTColor, cursor: VTColor?, ansi: [VTColor]?,
         selectionBackground: VTColor?, selectionForeground: VTColor?) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func color(_ key: CodingKeys) throws -> VTColor? {
            guard let text = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = VTColor(hexString: text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not #RRGGBB")
            }
            return value
        }
        guard let foreground = try color(.foreground), let background = try color(.background) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "missing colours"))
        }
        self.foreground = foreground
        self.background = background
        cursor = try color(.cursor)
        selectionBackground = try color(.selectionBackground)
        selectionForeground = try color(.selectionForeground)
        if let texts = try c.decodeIfPresent([String].self, forKey: .ansi) {
            let colors = texts.compactMap(VTColor.init(hexString:))
            guard colors.count == 16, colors.count == texts.count else {
                throw DecodingError.dataCorruptedError(forKey: .ansi, in: c, debugDescription: "16 colours expected")
            }
            ansi = colors
        } else {
            ansi = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(foreground.hexString, forKey: .foreground)
        try c.encode(background.hexString, forKey: .background)
        try c.encodeIfPresent(cursor?.hexString, forKey: .cursor)
        try c.encodeIfPresent(ansi?.map(\.hexString), forKey: .ansi)
        try c.encodeIfPresent(selectionBackground?.hexString, forKey: .selectionBackground)
        try c.encodeIfPresent(selectionForeground?.hexString, forKey: .selectionForeground)
    }
}

/// Settings › Terminal › Theme: automatic (follows light/dark), a built-in theme, or the custom one.
enum TerminalThemeChoice: String, CaseIterable, Identifiable {
    case automatic, ghosttyDark, tomorrow, tomorrowNight, solarizedDark, solarizedLight, dracula, custom

    var id: String { rawValue }

    /// The built-in themes (custom excluded).
    static var builtIn: [TerminalThemeChoice] { allCases.filter { $0 != .custom } }

    var titleKey: String { "terminal_theme_\(rawValue)" }

    /// The theme of a built-in choice; `custom` gives `nil` (its colours are stored apart).
    func theme(isDark: Bool) -> TerminalTheme? {
        switch self {
        case .automatic: TerminalTheme.forAppearance(isDark: isDark)
        case .ghosttyDark: .dark
        case .tomorrow: .light
        case .tomorrowNight: .tomorrowNight
        case .solarizedDark: .solarizedDark
        case .solarizedLight: .solarizedLight
        case .dracula: .dracula
        case .custom: nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension VTColor {
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// An `NSColor` (a colour panel's) in sRGB, rounded to 8 bits per channel; `nil` if it has no RGB form.
    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(r: channel(rgb.redComponent), g: channel(rgb.greenComponent), b: channel(rgb.blueComponent))
    }

    /// "#RRGGBB".
    var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// "#RRGGBB" or "RRGGBB", case-insensitive.
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// The terminal font: JetBrains Mono (Ghostty's embedded default, bundled under SIL OFL 1.1, release
/// 2.304), 13 pt by default as Ghostty on macOS, or an installed monospaced family chosen in Settings ›
/// Terminal; the system monospaced font if neither can be loaded. The four static faces of the
/// bundled font are registered for this process once, on first use.
@MainActor
struct TerminalFonts {
    static let defaultSize: CGFloat = 13
    static let sizeRange: ClosedRange<CGFloat> = 8...36
    nonisolated static let familyName = "JetBrains Mono"

    let regular: CTFont
    let bold: CTFont
    let italic: CTFont
    let boldItalic: CTFont
    let size: CGFloat
    /// The family asked for (`nil`: the bundled font).
    let requestedFamily: String?
    /// Whether JetBrains Mono was used (false: another family, or the system monospaced fallback).
    let isBundledFont: Bool

    /// `family`: an installed family name; `nil`, empty or JetBrains Mono for the bundled font. A
    /// family that is not installed (removed since it was chosen) falls back to the bundled font.
    init(size: CGFloat, family: String? = nil) {
        let size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.size = size
        let family = Self.normalizedFamily(family)
        requestedFamily = family
        if let family, let faces = Self.installed(family: family, size: size) {
            (regular, bold, italic, boldItalic) = faces
            isBundledFont = false
            return
        }
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

    /// `nil` for the bundled font (`nil`, empty or JetBrains Mono), else the family name.
    nonisolated static func normalizedFamily(_ family: String?) -> String? {
        guard let family, !family.isEmpty, family != familyName else { return nil }
        return family
    }

    /// The four faces of an installed family (a missing bold or italic face reuses the closest one).
    private static func installed(family: String, size: CGFloat) -> (CTFont, CTFont, CTFont, CTFont)? {
        let manager = NSFontManager.shared
        guard let regular = manager.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? manager.font(withFamily: family, traits: [.unboldFontMask], weight: 5, size: size) else { return nil }
        let bold = manager.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size) ?? regular
        let italic = manager.font(withFamily: family, traits: .italicFontMask, weight: 5, size: size) ?? regular
        let boldItalic = manager.font(withFamily: family, traits: [.boldFontMask, .italicFontMask], weight: 9, size: size)
            ?? bold
        return (regular as CTFont, bold as CTFont, italic as CTFont, boldItalic as CTFont)
    }

    /// The installed fixed-pitch families, sorted, JetBrains Mono (bundled, listed apart) excluded.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            .filter { !$0.hasPrefix(".") && $0 != familyName }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
