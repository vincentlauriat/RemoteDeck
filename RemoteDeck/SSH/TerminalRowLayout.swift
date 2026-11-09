import AppKit
import CoreText
import GhosttyEngine

/// One viewport row ready to draw: rebuilt only when the engine reports the row dirty (or the
/// cursor, focus, theme or font changed), then replayed by `draw(_:)` as often as AppKit asks.
/// Coordinates are row-local: x from the view's left edge, y from the row's top, baseline at
/// `TerminalGrid.ascent`.
struct TerminalRowLayout {
    struct Fill {
        var rect: CGRect
        var color: CGColor
    }

    /// Glyphs of one font and colour at explicit cell positions. The positions are in text space,
    /// which the flipped view's text matrix (y × −1) maps to the row: y is minus the baseline.
    struct GlyphRun {
        var font: CTFont
        var color: CGColor
        var glyphs: [CGGlyph]
        var positions: [CGPoint]
    }

    /// A cluster the primary font cannot draw alone (CJK, emoji, combining marks): a cached `CTLine`
    /// (font fallback), drawn at its cell.
    struct Cluster {
        var line: CTLine
        var origin: CGPoint
        var color: CGColor
    }

    var fills: [Fill] = []
    var runs: [GlyphRun] = []
    var clusters: [Cluster] = []
    /// Underline, strikethrough, overline and the hollow cursor, drawn over the text.
    var decorations: [Fill] = []
    /// The row's text (accessibility).
    var text = ""

    static var empty: TerminalRowLayout { TerminalRowLayout() }

    func draw(in context: CGContext, at y: CGFloat) {
        context.saveGState()
        context.translateBy(x: 0, y: y)
        for fill in fills {
            context.setFillColor(fill.color)
            context.fill(fill.rect)
        }
        // Glyph positions are relative to the text position, which `CTLineDraw` moves and the
        // graphics state does not restore.
        context.textPosition = .zero
        for run in runs {
            context.setFillColor(run.color)
            run.glyphs.withUnsafeBufferPointer { glyphs in
                run.positions.withUnsafeBufferPointer { positions in
                    CTFontDrawGlyphs(run.font, glyphs.baseAddress!, positions.baseAddress!, glyphs.count, context)
                }
            }
        }
        for cluster in clusters {
            context.setFillColor(cluster.color)
            context.textPosition = cluster.origin
            CTLineDraw(cluster.line, context)
        }
        for fill in decorations {
            context.setFillColor(fill.color)
            context.fill(fill.rect)
        }
        context.restoreGState()
    }
}

/// What a row build needs besides the cells.
struct TerminalFrameStyle {
    var theme: TerminalTheme
    var colors: VTFrameColors
    var cursor: VTCursor?
    /// The view is first responder in the key window: a filled block; otherwise a hollow one.
    var focused: Bool
}

/// Builds row layouts from the engine's cells, with a glyph cache keyed by cluster and face: a cell's
/// glyphs are shaped once per font size, whatever row or colour it appears in later.
@MainActor
final class TerminalRowBuilder {
    private(set) var fonts: TerminalFonts
    private(set) var grid: TerminalGrid

    private enum Shaped {
        /// One glyph per scalar, all in the primary face.
        case glyphs(CTFont, [CGGlyph], advance: CGFloat)
        case line(CTLine, advance: CGFloat)
    }

    private struct CacheKey: Hashable {
        var text: String
        var bold: Bool
        var italic: Bool
    }

    private var cache: [CacheKey: Shaped] = [:]
    static let cacheLimit = 8192

    init(fonts: TerminalFonts) {
        self.fonts = fonts
        grid = TerminalGrid(font: fonts.regular)
    }

    func setFonts(_ fonts: TerminalFonts) {
        self.fonts = fonts
        grid = TerminalGrid(font: fonts.regular)
        cache.removeAll()
    }

    var cachedClusters: Int { cache.count }

    private func shape(_ text: String, bold: Bool, italic: Bool) -> Shaped {
        let key = CacheKey(text: text, bold: bold, italic: italic)
        if let hit = cache[key] { return hit }
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        let font = fonts.font(bold: bold, italic: italic)
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let shaped: Shaped
        if utf16.count == 1, CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), glyphs[0] != 0 {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
            shaped = .glyphs(font, glyphs, advance: advance.width)
        } else {
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                               kCTForegroundColorFromContextAttributeName: true]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString,
                                                                                 attributes as CFDictionary))
            shaped = .line(line, advance: CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        cache[key] = shaped
        return shaped
    }

    /// The layout of one viewport row.
    func layout(_ row: VTRow, columns: Int, style frame: TerminalFrameStyle) -> TerminalRowLayout {
        var layout = TerminalRowLayout()
        let theme = frame.theme
        let defaultFg = frame.colors.foreground
        let defaultBg = frame.colors.background
        let cw = grid.cellWidth
        let ch = grid.cellHeight
        let pad = TerminalGrid.padding
        func cellRect(_ column: Int, width: Int) -> CGRect {
            CGRect(x: pad + CGFloat(column) * cw, y: 0, width: CGFloat(width) * cw, height: ch)
        }
        let cursor = frame.cursor.flatMap { $0.y == row.y ? $0 : nil }
        let cursorColor = frame.colors.cursor ?? theme.cursor ?? defaultFg
        let selectionBg = theme.selectionBackground ?? defaultFg

        if let selection = row.selection {
            let upper = min(selection.upperBound, columns - 1)
            if selection.lowerBound <= upper {
                layout.fills.append(.init(rect: cellRect(selection.lowerBound, width: upper - selection.lowerBound + 1),
                                          color: selectionBg.cgColor))
            }
        }
        let cursorCell = cursor.flatMap { c in row.cells.first { $0.column <= c.x && c.x < $0.column + $0.width } }
        if let cursor, cursorCell == nil {
            appendCursor(cursor, rect: cellRect(cursor.x, width: 1), color: cursorColor, focused: frame.focused, to: &layout)
        }

        var text = ""
        var nextColumn = 0
        var run: TerminalRowLayout.GlyphRun?
        func flush() {
            if let current = run, !current.glyphs.isEmpty { layout.runs.append(current) }
            run = nil
        }

        for cell in row.cells {
            if cell.column > nextColumn { text += String(repeating: " ", count: cell.column - nextColumn) }
            nextColumn = cell.column + cell.width
            text += cell.text.isEmpty ? " " : cell.text

            var fg = cell.foreground ?? defaultFg
            var bg = cell.background
            if cell.style.inverse { (fg, bg) = (bg ?? defaultBg, fg) }
            if let selection = row.selection, selection.contains(cell.column) {
                if let selected = theme.selectionBackground {
                    bg = selected
                    fg = theme.selectionForeground ?? fg
                } else {
                    (fg, bg) = (bg ?? defaultBg, fg)
                }
            }
            let rect = cellRect(cell.column, width: cell.width)
            var textColor = fg.cgColor
            if let cursor, cell == cursorCell {
                appendCursor(cursor, rect: rect, color: cursorColor, focused: frame.focused, to: &layout,
                             under: bg?.cgColor)
                if frame.focused, cursor.shape == .block { textColor = defaultBg.cgColor }
            } else if let bg {
                layout.fills.append(.init(rect: rect, color: bg.cgColor))
            }
            if cell.style.faint { textColor = textColor.copy(alpha: 0.5) ?? textColor }

            if !cell.text.isEmpty, !cell.style.invisible {
                let shaped = shape(cell.text, bold: cell.style.bold, italic: cell.style.italic)
                switch shaped {
                case .glyphs(let font, let glyphs, let advance):
                    let x = rect.minX + max(0, (rect.width - advance) / 2)
                    if let current = run, current.font == font, current.color == textColor {
                        run?.glyphs.append(contentsOf: glyphs)
                        run?.positions.append(CGPoint(x: x, y: -grid.ascent))
                    } else {
                        flush()
                        run = .init(font: font, color: textColor, glyphs: glyphs, positions: [CGPoint(x: x, y: -grid.ascent)])
                    }
                case .line(let line, let advance):
                    flush()
                    let x = rect.minX + max(0, (rect.width - advance) / 2)
                    layout.clusters.append(.init(line: line, origin: CGPoint(x: x, y: grid.ascent), color: textColor))
                }
            }
            appendDecorations(cell.style, rect: rect, color: textColor, to: &layout)
        }
        flush()
        layout.text = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return layout
    }

    private func appendCursor(_ cursor: VTCursor, rect: CGRect, color: VTColor, focused: Bool,
                              to layout: inout TerminalRowLayout, under background: CGColor? = nil) {
        let thickness: CGFloat = 1.5
        switch (cursor.shape, focused) {
        case (.block, true):
            layout.fills.append(.init(rect: rect, color: color.cgColor))
        case (.bar, _):
            if let background { layout.fills.append(.init(rect: rect, color: background)) }
            layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: 0, width: 2, height: rect.height),
                                            color: color.cgColor))
        case (.underline, _):
            if let background { layout.fills.append(.init(rect: rect, color: background)) }
            layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2),
                                            color: color.cgColor))
        case (.block, false), (.hollowBlock, _):
            if let background { layout.fills.append(.init(rect: rect, color: background)) }
            let c = color.cgColor
            layout.decorations += [
                .init(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness), color: c),
                .init(rect: CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness), color: c),
                .init(rect: CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height), color: c),
                .init(rect: CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height), color: c),
            ]
        }
    }

    private func appendDecorations(_ style: VTCellStyle, rect: CGRect, color: CGColor, to layout: inout TerminalRowLayout) {
        let font = fonts.regular
        let thickness = max(1, CTFontGetUnderlineThickness(font).rounded())
        let baseline = grid.ascent
        if style.underline != .none {
            let y = min(rect.maxY - thickness, baseline - CTFontGetUnderlinePosition(font))
            layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: thickness), color: color))
            if style.underline == .double {
                layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: y - 2 * thickness, width: rect.width,
                                                             height: thickness), color: color))
            }
        }
        if style.strikethrough {
            let y = baseline - CTFontGetXHeight(font) / 2
            layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: thickness), color: color))
        }
        if style.overline {
            layout.decorations.append(.init(rect: CGRect(x: rect.minX, y: 0, width: rect.width, height: thickness), color: color))
        }
    }
}
