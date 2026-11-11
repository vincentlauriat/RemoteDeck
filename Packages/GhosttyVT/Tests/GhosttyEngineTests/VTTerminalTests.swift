import Foundation
import Testing
@testable import GhosttyEngine

/// The real libghostty-vt engine, headless: bytes in, cells, replies and encoded input out.
struct VTTerminalTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    @Test func linksTheReleasedLibrary() {
        #expect(VTTerminal.version == "1.0.0")
    }

    @Test func textReachesTheScreen() {
        let vt = VTTerminal(columns: 40, rows: 5)
        vt.write("hello world\r\nsecond line")
        #expect(vt.screenText() == "hello world\nsecond line")
    }

    @Test func aSequenceSplitAcrossWritesStillApplies() {
        let vt = VTTerminal(columns: 20, rows: 3)
        vt.write("\u{1B}[3")
        vt.write("8;2;255;100;0mX")
        vt.update()
        let cell = vt.rows(onlyDirty: false)[0].cells.first
        #expect(cell?.text == "X")
        #expect(cell?.foreground == VTColor(r: 255, g: 100, b: 0))
    }

    // MARK: Keys

    @Test func arrowUpFollowsCursorKeyMode() {
        let vt = VTTerminal(columns: 20, rows: 3)
        #expect(vt.encodeKey(VTKeyEvent(key: .arrowUp), optionAsAlt: false) == [0x1B, 0x5B, 0x41])
        vt.write("\u{1B}[?1h")   // DECCKM: application cursor keys (vim, less)
        #expect(vt.encodeKey(VTKeyEvent(key: .arrowUp), optionAsAlt: false) == [0x1B, 0x4F, 0x41])
    }

    @Test func controlCIsETX() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let bytes = vt.encodeKey(VTKeyEvent(key: .c, mods: .control, unshifted: "c"), optionAsAlt: false)
        #expect(hex(bytes) == "03")
    }

    /// AZERTY: the layout's "a" is the physical Q key. ⌃ follows the layout's character.
    @Test func controlFollowsTheLayoutCharacter() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let key = VTKey.logical(physical: .q, unshifted: "a")
        #expect(key == .a)
        let bytes = vt.encodeKey(VTKeyEvent(key: key, mods: .control, unshifted: "a"), optionAsAlt: false)
        #expect(hex(bytes) == "01", "got \(hex(bytes))")
    }

    /// AZERTY ⌥⇧L types "|": with ⌥ not Meta, the composed character is sent as is.
    @Test func optionComposedCharacterIsSentWhenOptionIsNotMeta() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let event = VTKeyEvent(key: .l, mods: [.alt, .shift], consumedMods: [.alt, .shift], text: "|", unshifted: "l")
        #expect(vt.encodeKey(event, optionAsAlt: false) == Array("|".utf8))
        let brace = VTKeyEvent(key: .digit5, mods: .alt, consumedMods: .alt, text: "{", unshifted: "(")
        #expect(vt.encodeKey(brace, optionAsAlt: false) == Array("{".utf8))
    }

    /// "Use ⌥ as Meta": ⌥B is ESC b (readline's backward-word), not the layout's ⌥ character.
    @Test func optionIsMetaWhenAsked() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let event = VTKeyEvent(key: .b, mods: .alt, text: "b", unshifted: "b")
        #expect(hex(vt.encodeKey(event, optionAsAlt: true)) == "1b 62")
    }

    @Test func enterEscapeAndBackspace() {
        let vt = VTTerminal(columns: 20, rows: 3)
        #expect(vt.encodeKey(VTKeyEvent(key: .enter), optionAsAlt: false) == [0x0D])
        #expect(vt.encodeKey(VTKeyEvent(key: .escape), optionAsAlt: false) == [0x1B])
        #expect(vt.encodeKey(VTKeyEvent(key: .backspace), optionAsAlt: false) == [0x7F])
    }

    @Test func plainTextKey() {
        let vt = VTTerminal(columns: 20, rows: 3)
        #expect(vt.encodeKey(VTKeyEvent(key: .q, text: "a", unshifted: "a"), optionAsAlt: false) == [0x61])
        #expect(vt.encodeKey(VTKeyEvent(key: .unidentified, text: "é"), optionAsAlt: false) == Array("é".utf8))
    }

    /// A ⌘ chord no menu took sends nothing in the legacy encoding (it is not typed text).
    @Test func commandChordsSendNothing() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let event = VTKeyEvent(key: .q, mods: .command, text: "a", unshifted: "a")
        #expect(vt.encodeKey(event, optionAsAlt: false).isEmpty)
    }

    /// Holding a key repeats it: a repeat sends what the press sends (⌫, arrows, letters).
    @Test func repeatsSendLikePresses() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let press = vt.encodeKey(VTKeyEvent(key: .arrowUp), optionAsAlt: false)
        #expect(vt.encodeKey(VTKeyEvent(key: .arrowUp, action: .repeat), optionAsAlt: false) == press)
        #expect(vt.encodeKey(VTKeyEvent(key: .backspace, action: .repeat), optionAsAlt: false) == [0x7F])
        #expect(vt.encodeKey(VTKeyEvent(key: .a, action: .repeat, text: "a", unshifted: "a"), optionAsAlt: false) == [0x61])
    }

    /// The adapter redraws only what the engine marks dirty: moving the viewport must mark it.
    @Test func scrollingTheViewportIsDirty() {
        let vt = VTTerminal(columns: 20, rows: 3)
        for i in 0..<20 { vt.write("line \(i)\r\n") }
        vt.update()
        vt.markClean()
        #expect(vt.update() == .clean)
        vt.markClean()
        vt.scroll(by: -5)
        #expect(vt.update() != .clean)
        vt.markClean()
        vt.scrollToBottom()
        #expect(vt.update() != .clean)
    }

    @Test func releasesSendNothingInLegacyMode() {
        let vt = VTTerminal(columns: 20, rows: 3)
        #expect(vt.encodeKey(VTKeyEvent(key: .arrowUp, action: .release), optionAsAlt: false).isEmpty)
    }

    @Test func macKeyCodesMapToPhysicalKeys() {
        #expect(VTKey.fromMacKeyCode(0x7E) == .arrowUp)
        #expect(VTKey.fromMacKeyCode(0x08) == .c)
        #expect(VTKey.fromMacKeyCode(0x0C) == .q)
        #expect(VTKey.fromMacKeyCode(0x24) == .enter)
        #expect(VTKey.fromMacKeyCode(0x38) == .unidentified)   // Shift alone
        #expect(VTKey.logical(physical: .arrowUp, unshifted: "\u{F700}") == .arrowUp)
        #expect(VTKey.logical(physical: .digit5, unshifted: "(") == .digit5)   // AZERTY: not ASCII-keyed
    }

    // MARK: Selection and paste

    @Test func selectionCopiesItsText() {
        let vt = VTTerminal(columns: 40, rows: 5)
        vt.write("hello world\r\nnext")
        #expect(vt.selectionText() == nil)
        vt.select(from: VTPoint(x: 0, y: 0), to: VTPoint(x: 4, y: 0))
        #expect(vt.selectionText() == "hello")
        vt.selectWord(at: VTPoint(x: 8, y: 0))
        #expect(vt.selectionText() == "world")
        vt.select(from: VTPoint(x: 6, y: 0), to: VTPoint(x: 1, y: 1))   // across the line end
        #expect(vt.selectionText() == "world\nne")
        vt.clearSelection()
        #expect(!vt.hasSelection)
    }

    @Test func selectionIsReportedPerRow() {
        let vt = VTTerminal(columns: 40, rows: 5)
        vt.write("hello world")
        vt.select(from: VTPoint(x: 2, y: 0), to: VTPoint(x: 6, y: 0))
        vt.update()
        let rows = vt.rows(onlyDirty: false)
        #expect(rows[0].selection == 2...6)
        #expect(rows[1].selection == nil)
    }

    @Test func pasteIsBracketedOnlyWhenAsked() {
        let vt = VTTerminal(columns: 20, rows: 3)
        #expect(vt.encodePaste("a\nb") == Array("a\rb".utf8))
        vt.write("\u{1B}[?2004h")
        #expect(vt.bracketedPaste)
        #expect(vt.encodePaste("a\nb") == Array("\u{1B}[200~a\nb\u{1B}[201~".utf8))
    }

    // MARK: Replies and mouse

    @Test func deviceAttributesAreAnswered() {
        let vt = VTTerminal(columns: 20, rows: 3)
        var replies: [[UInt8]] = []
        vt.onReply = { replies.append($0) }
        vt.write("\u{1B}[c")
        #expect(String(decoding: replies.joined(), as: UTF8.self).hasPrefix("\u{1B}[?"))
    }

    // MARK: OSC 52

    private func osc52(_ target: String, _ payload: String) -> String { "\u{1B}]52;\(target);\(payload)\u{07}" }

    @Test func osc52WriteGivesTheDecodedText() {
        let vt = VTTerminal(columns: 20, rows: 3)
        var written: [String] = []
        var replies: [[UInt8]] = []
        vt.onReply = { replies.append($0) }
        vt.onClipboardWrite = { written.append($0); return true }
        vt.write(osc52("c", Data("héllo\nworld".utf8).base64EncodedString()))
        #expect(written == ["héllo\nworld"])
        #expect(replies.isEmpty)
    }

    @Test func osc52IsRefusedWithoutAHandlerOrWhenTheHandlerRefuses() {
        let vt = VTTerminal(columns: 20, rows: 3)
        vt.write(osc52("c", "aGk="))   // no handler: must not crash
        var asked = 0
        vt.onClipboardWrite = { _ in asked += 1; return false }
        vt.write(osc52("c", "aGk="))
        #expect(asked == 1)
    }

    @Test func osc52QueryIsNeverAnswered() {
        let vt = VTTerminal(columns: 20, rows: 3)
        var written: [String] = []
        var replies: [[UInt8]] = []
        vt.onReply = { replies.append($0) }
        vt.onClipboardWrite = { written.append($0); return true }
        vt.write(osc52("c", "?"))
        #expect(written.isEmpty)
        #expect(replies.isEmpty)   // no OSC 52 reply carrying the pasteboard
    }

    @Test func osc52OversizedOrInvalidTextIsDropped() {
        let vt = VTTerminal(columns: 20, rows: 3)
        var written: [String] = []
        vt.onClipboardWrite = { written.append($0); return true }
        vt.write(osc52("c", Data([0xFF, 0xFE, 0x41]).base64EncodedString()))   // not UTF-8
        vt.write(osc52("c", ""))   // empty
        let big = Data(repeating: 0x61, count: VTTerminal.maxClipboardWriteBytes + 1).base64EncodedString()
        vt.write(osc52("c", big))
        #expect(written.isEmpty)
        let ok = Data(repeating: 0x61, count: 1000).base64EncodedString()
        vt.write(osc52("c", ok))
        #expect(written.count == 1 && written[0].utf8.count == 1000)
    }

    @Test func mouseIsReportedInSGRWhenTracked() {
        let vt = VTTerminal(columns: 20, rows: 5)
        let geometry = VTMouseGeometry(width: 200, height: 100, cellWidth: 10, cellHeight: 20, paddingX: 0, paddingY: 0)
        let press = VTMouseEvent(action: .press, button: .left, x: 25, y: 65)   // cell (2, 3)
        #expect(!vt.mouseTracking)
        vt.write("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(vt.mouseTracking)
        #expect(String(decoding: vt.encodeMouse(press, geometry: geometry, anyButtonPressed: true), as: UTF8.self)
                == "\u{1B}[<0;3;4M")
    }

    // MARK: Cells

    @Test func wideCharactersAndGraphemeClustersTakeTwoCells() {
        let vt = VTTerminal(columns: 20, rows: 3)
        vt.write("你a👍🏽b")
        vt.update()
        let cells = vt.rows(onlyDirty: false)[0].cells
        #expect(cells.map(\.text) == ["你", "a", "👍🏽", "b"])
        #expect(cells.map(\.width) == [2, 1, 2, 1])
        #expect(cells.map(\.column) == [0, 2, 3, 5])
    }

    @Test func stylesAreRead() {
        let vt = VTTerminal(columns: 30, rows: 3)
        vt.write("\u{1B}[1mB\u{1B}[0m\u{1B}[3mI\u{1B}[0m\u{1B}[4mU\u{1B}[0m\u{1B}[7mR\u{1B}[0m\u{1B}[38;5;196mP")
        vt.update()
        let cells = vt.rows(onlyDirty: false)[0].cells
        #expect(cells[0].style.bold)
        #expect(cells[1].style.italic)
        #expect(cells[2].style.underline == .single)
        #expect(cells[3].style.inverse)
        #expect(cells[4].foreground == VTTerminal.builtInPalette[196])
    }

    @Test func onlyChangedRowsAreDirty() {
        let vt = VTTerminal(columns: 20, rows: 6)
        vt.write("one\r\ntwo\r\nthree")
        vt.update()
        vt.markClean()
        vt.write("\u{1B}[5;1Hfive")   // row 4
        #expect(vt.update() == .partial)
        let dirty = vt.rows(onlyDirty: true).map(\.y)
        #expect(dirty.contains(4))
        #expect(!dirty.contains(0))
        #expect(!dirty.contains(1))
    }

    @Test func resizeChangesTheGrid() {
        let vt = VTTerminal(columns: 80, rows: 24)
        vt.resize(columns: 120, rows: 36, cellWidth: 16, cellHeight: 34)
        #expect(vt.columns == 120)
        #expect(vt.rows == 36)
        vt.update()
        #expect(vt.rows(onlyDirty: false).count == 36)
    }

    @Test func scrollbackKeepsLinesAboveTheViewport() {
        let vt = VTTerminal(columns: 20, rows: 3)
        for i in 0..<20 { vt.write("line \(i)\r\n") }
        #expect(vt.isViewportAtBottom)
        vt.scroll(by: -5)
        #expect(!vt.isViewportAtBottom)
        vt.update()
        let top = vt.rows(onlyDirty: false).first?.cells.map(\.text).joined(); #expect(top == "line 13", "got \(top ?? "nil")")
        vt.scrollToBottom()
        #expect(vt.isViewportAtBottom)
    }

    @Test func alternateScreen() {
        let vt = VTTerminal(columns: 20, rows: 3)
        vt.write("\u{1B}[?1049h")
        #expect(vt.isAlternateScreen)
        vt.write("\u{1B}[?1049l")
        #expect(!vt.isAlternateScreen)
    }

    @Test func paletteOverrideKeepsTheCube() {
        let vt = VTTerminal(columns: 20, rows: 3)
        let red = VTColor(hex: 0xC82829)
        vt.setPalette(overriding: [VTColor(hex: 0), red])
        vt.write("\u{1B}[31mR\u{1B}[38;5;196mC")
        vt.update()
        let cells = vt.rows(onlyDirty: false)[0].cells
        #expect(cells[0].foreground == red)
        #expect(cells[1].foreground == VTTerminal.builtInPalette[196])
    }
}
