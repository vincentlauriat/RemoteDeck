import AppKit
import Foundation
import GhosttyEngine
import Testing
@testable import RemoteDeck

// Plan Task 9 Step 7 (build and look): the terminal view drawn offscreen (`cacheDisplay`, the same
// `draw(_:)` path as a window) in light and dark with sample output. The PNGs land in
// `$TMPDIR/RemoteDeckTerminalSnapshots/` to be read by eye; the test itself checks a few pixels.
@MainActor
struct TerminalRenderingTests {
    static let sample: String = {
        var s = "\u{1B}[1;32mvincent@raspberry\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m$ ls --color\r\n"
        s += "\u{1B}[1;34mDocuments\u{1B}[0m  \u{1B}[1;32mbuild.sh\u{1B}[0m  notes.txt  \u{1B}[1;36mlink\u{1B}[0m\r\n"
        s += "16:  "
        for i in 30...37 { s += "\u{1B}[\(i)m■\u{1B}[0m" }
        s += " "
        for i in 90...97 { s += "\u{1B}[\(i)m■\u{1B}[0m" }
        s += "   bg: "
        for i in 40...47 { s += "\u{1B}[\(i)m  \u{1B}[0m" }
        s += "\r\n256: "
        for i in stride(from: 16, to: 232, by: 3) { s += "\u{1B}[48;5;\(i)m \u{1B}[0m" }
        s += "\r\nrgb: "
        for i in stride(from: 0, to: 256, by: 4) { s += "\u{1B}[48;2;\(i);\(255 - i);\(i / 2)m \u{1B}[0m" }
        s += "\r\n\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[1;3mbold-italic\u{1B}[0m \u{1B}[4munderline\u{1B}[0m "
        s += "\u{1B}[7minverse\u{1B}[0m \u{1B}[9mstrike\u{1B}[0m \u{1B}[2mfaint\u{1B}[0m \u{1B}[38;2;255;100;0morange\u{1B}[0m\r\n"
        s += "wide: |你好世界| emoji: |🎉👍🏽🇫🇷| combining: |e\u{301}| box: ┌─┬─┐ │ ├─┤ λ → ≠ ≥\r\n"
        s += "cols: 0123456789012345678901234567890123456789\r\n"
        s += "$ "
        return s
    }()

    /// A vim-like full screen: alternate screen, line numbers, syntax colours, `~` rows, status line.
    static func vim(rows: Int, columns: Int) -> String {
        var s = "\u{1B}[?1049h\u{1B}[H\u{1B}[2J"
        let code = [
            "\u{1B}[35mimport\u{1B}[0m Foundation",
            "",
            "\u{1B}[33mstruct\u{1B}[0m \u{1B}[36mGreeter\u{1B}[0m {",
            "    \u{1B}[33mlet\u{1B}[0m name: \u{1B}[36mString\u{1B}[0m",
            "    \u{1B}[33mfunc\u{1B}[0m greet() -> \u{1B}[36mString\u{1B}[0m { \u{1B}[32m\"Bonjour, \\(name) ✓\"\u{1B}[0m }",
            "}",
        ]
        for row in 0..<(rows - 2) {
            s += "\u{1B}[\(row + 1);1H"
            if row < code.count {
                s += "\u{1B}[33m\(String(format: "%3d", row + 1)) \u{1B}[0m" + code[row]
            } else {
                s += "\u{1B}[34m~\u{1B}[0m"
            }
        }
        let status = " greeter.swift [+]".padding(toLength: columns - 12, withPad: " ", startingAt: 0) + "3,9     All "
        s += "\u{1B}[\(rows - 1);1H\u{1B}[7m\(status)\u{1B}[0m"
        s += "\u{1B}[\(rows);1H\u{1B}[1m-- INSERT --\u{1B}[0m"
        s += "\u{1B}[3;9H"
        return s
    }

    private func render(_ text: String, dark: Bool, select: (VTPoint, VTPoint)? = nil, focused: Bool = false,
                        name: String) throws -> NSBitmapImageRep {
        let surface = GhosttyTerminalSurface()
        let view = surface.view
        (view as? TerminalView)?.focusOverride = focused
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        surface.apply(TerminalAppearance(isDark: dark, fontSize: 13, optionAsMeta: false))
        view.setFrameSize(NSSize(width: 820, height: 300))
        surface.feed(Data(text.utf8))
        if let select { surface.select(from: select.0, to: select.1) }
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDeckTerminalSnapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        return rep
    }

    private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> VTColor? {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return VTColor(r: UInt8((color.redComponent * 255).rounded()), g: UInt8((color.greenComponent * 255).rounded()),
                       b: UInt8((color.blueComponent * 255).rounded()))
    }

    /// Within 2 per channel: the bitmap's colour space conversion may round differently.
    private func near(_ a: VTColor?, _ b: VTColor) -> Bool {
        guard let a else { return false }
        return abs(Int(a.r) - Int(b.r)) <= 2 && abs(Int(a.g) - Int(b.g)) <= 2 && abs(Int(a.b) - Int(b.b)) <= 2
    }

    @Test func darkAndLightRenderTheirPalettes() throws {
        for dark in [true, false] {
            let theme = TerminalTheme.forAppearance(isDark: dark)
            let main = try render(Self.sample, dark: dark, select: (VTPoint(x: 0, y: 8), VTPoint(x: 3, y: 8)),
                                  name: dark ? "terminal-dark" : "terminal-light")
            // The bottom-right corner is background; so is the right part of the prompt row.
            #expect(near(pixel(main, x: main.pixelsWide - 3, y: main.pixelsHigh - 3), theme.background))
            // Row 3 (16 colours) has the SGR 41 background block: red of the theme, somewhere on the row.
            let grid = GhosttyTerminalSurface().grid
            let scale = CGFloat(main.pixelsWide) / 820
            let rowY = Int((TerminalGrid.padding + grid.cellHeight * 2.5) * scale)
            let red = dark ? VTTerminal.builtInPalette[1] : VTColor(hex: 0xC82829)
            let rowColors = Set((0..<main.pixelsWide).compactMap { pixel(main, x: $0, y: rowY) })
            #expect(rowColors.contains { near($0, red) })

            let surface = GhosttyTerminalSurface()
            surface.view.setFrameSize(NSSize(width: 820, height: 300))
            let vim = try render(Self.vim(rows: surface.terminal.rows, columns: surface.terminal.columns), dark: dark,
                                 focused: true,
                                 name: dark ? "terminal-vim-dark" : "terminal-vim-light")
            #expect(near(pixel(vim, x: vim.pixelsWide - 3, y: 3), theme.background))
        }
    }
}
