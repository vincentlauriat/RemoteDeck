import AppKit
import Foundation
import GhosttyEngine
import Testing
@testable import RemoteDeck

// Plan Task 9 Step 6: the terminal engine adapter on the real libghostty-vt engine, headless (no
// window, no network, no pasteboard: the view's pasteboard closures are replaced).

/// Frames that run only when the test says so.
@MainActor
final class ManualFrames {
    private(set) var queued: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) { queued.append(work) }

    /// Runs the queued frames, and the ones they queue, until none is left; returns how many ran.
    @discardableResult
    func runAll(limit: Int = 100_000) -> Int {
        var count = 0
        while !queued.isEmpty, count < limit {
            let next = queued.removeFirst()
            next()
            count += 1
        }
        return count
    }
}

@MainActor
private func makeSurface(frames: ManualFrames? = nil) -> (GhosttyTerminalSurface, [Data]) {
    let surface = GhosttyTerminalSurface()
    if let frames { surface.scheduleFrame = { frames.schedule($0, $1) } }
    return (surface, [])
}

@MainActor
private final class InputLog {
    var chunks: [Data] = []
    var bytes: Data { chunks.reduce(Data(), +) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

@MainActor
private func recording(_ surface: GhosttyTerminalSurface) -> InputLog {
    let log = InputLog()
    surface.onInput = { log.chunks.append($0) }
    return log
}

@MainActor
struct TerminalSurfaceTests {
    // MARK: Feed slicing

    @Test func floodIsParsedInCappedSlicesAcrossFramesWithoutLosingBytes() {
        let frames = ManualFrames()
        let (surface, _) = makeSurface(frames: frames)
        surface.maxBytesPerFrame = 100_000
        surface.frameBudget = .seconds(10)   // the byte cap alone decides here
        var text = ""
        for i in 0..<20_000 { text += "line \(i)\r\n" }   // about 228 kB
        let data = Data(text.utf8)

        surface.feed(data)
        #expect(surface.parsedBytes == 100_000)   // the first frame runs at once, capped
        #expect(surface.pendingBytes == data.count - 100_000)
        #expect(frames.queued.count == 1)

        let ran = frames.runAll()
        #expect(ran == (data.count - 1) / 100_000)   // the remaining frames, one cap each
        #expect(surface.parsedBytes == data.count)
        #expect(surface.pendingBytes == 0)
        #expect(surface.peakPendingBytes == data.count)
        // The last rows on screen are the last lines fed: nothing dropped, nothing reordered.
        let lines = surface.visibleText.split(separator: "\n").map(String.init)
        #expect(lines.suffix(2) == ["line 19998", "line 19999"])
    }

    @Test func aFrameStopsWhenItsTimeBudgetIsSpent() {
        let frames = ManualFrames()
        let (surface, _) = makeSurface(frames: frames)
        surface.frameBudget = .zero   // spent after the first slice
        surface.feed(Data(repeating: 0x61, count: 3 * GhosttyTerminalSurface.sliceSize))
        #expect(surface.parsedBytes == GhosttyTerminalSurface.sliceSize)
        #expect(frames.runAll() == 2)
        #expect(surface.parsedBytes == 3 * GhosttyTerminalSurface.sliceSize)
    }

    @Test func separatorComesAfterTheQueuedOutputOfTheOldShell() {
        let frames = ManualFrames()
        let (surface, _) = makeSurface(frames: frames)
        surface.maxBytesPerFrame = 10
        surface.feed(Data("\u{1B}[?1049hold shell in vim".utf8))
        surface.showSeparator("Reconnected")
        surface.feed(Data("$ ".utf8))
        frames.runAll()
        #expect(!surface.terminal.isAlternateScreen)   // the old shell's alternate screen is left
        let lines = surface.visibleText.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains("Reconnected") })
        #expect(lines.last == "$")
        #expect(lines.first { $0.contains("Reconnected") }?.hasPrefix("── Reconnected ──") == true)
    }

    // MARK: Resize

    @Test func gridMathFromViewSize() {
        let grid = TerminalGrid(cellWidth: 8, cellHeight: 17, ascent: 13)
        #expect(grid.size(fitting: CGSize(width: 800, height: 400)) == (99, 23))   // (800 − 4) / 8, (400 − 4) / 17
        #expect(grid.size(fitting: CGSize(width: 3, height: 3)) == (1, 1))
        #expect(grid.cell(at: CGPoint(x: 2 + 8 * 5 + 1, y: 2 + 17 * 2 + 1), columns: 99, rows: 23) == VTPoint(x: 5, y: 2))
        #expect(grid.cell(at: CGPoint(x: 5000, y: -10), columns: 99, rows: 23) == VTPoint(x: 98, y: 0))
    }

    @Test func resizeReportsTheGridAtOnceAndOnEveryChange() throws {
        let (surface, _) = makeSurface()
        var sizes: [String] = []
        surface.onResize = { sizes.append("\($0)x\($1)") }
        #expect(sizes == ["80x24"])   // as soon as it is set: the model opens the shell with it

        let grid = surface.grid
        let width = 2 * TerminalGrid.padding + 100 * grid.cellWidth + 3
        let height = 2 * TerminalGrid.padding + 30 * grid.cellHeight + 1
        surface.view.setFrameSize(NSSize(width: width, height: height))
        #expect(sizes.last == "100x30")
        #expect(surface.terminal.columns == 100 && surface.terminal.rows == 30)
        surface.view.setFrameSize(NSSize(width: width, height: height))   // the same size
        #expect(sizes.count == 2)
    }

    /// A frame set again at the same size does not resize the engine: a resize would end
    /// synchronized output and send an in-band size report (mode 2048) to the shell.
    @Test func anUnchangedSizeIsNotResizedAgain() {
        let (surface, _) = makeSurface()
        surface.view.setFrameSize(NSSize(width: 800, height: 500))
        surface.feed(Data("\u{1B}[?2048h".utf8))   // in-band size reports on
        let log = recording(surface)
        surface.view.setFrameSize(NSSize(width: 800, height: 500))
        surface.view.setFrameSize(NSSize(width: 801, height: 500))   // the same grid
        #expect(log.chunks.isEmpty)
        surface.view.setFrameSize(NSSize(width: 900, height: 500))
        #expect(log.text.hasPrefix("\u{1B}[48;"))   // a real change is reported
    }

    @Test func fontSizeChangeKeepsTheViewAndChangesTheGrid() {
        let (surface, _) = makeSurface()
        surface.view.setFrameSize(NSSize(width: 800, height: 500))
        let small = surface.terminal.columns
        surface.apply(TerminalAppearance(isDark: true, fontSize: 20, optionAsMeta: false))
        #expect(surface.terminal.columns < small)
        #expect(surface.builder.fonts.size == 20)
    }

    // MARK: Keys

    @Test func arrowControlAndOptionKeysAreEncoded() {
        let (surface, _) = makeSurface()
        let log = recording(surface)

        let up = TerminalKeyInput(keyCode: 0x7E, modifiers: [.function, .numericPad],
                                  shiftedCharacters: "\u{F700}", unshiftedCharacters: "\u{F700}")
        surface.send(TerminalKeyTranslator.events(for: up))
        #expect(log.chunks.last == Data([0x1B, 0x5B, 0x41]))

        let ctrlC = TerminalKeyInput(keyCode: 0x08, modifiers: .control, shiftedCharacters: "c", unshiftedCharacters: "c")
        surface.send(TerminalKeyTranslator.events(for: ctrlC))
        #expect(log.chunks.last == Data([0x03]))

        // AZERTY ⌃A: the layout's "a" is the physical Q key.
        let ctrlA = TerminalKeyInput(keyCode: 0x0C, modifiers: .control, shiftedCharacters: "a", unshiftedCharacters: "a")
        surface.send(TerminalKeyTranslator.events(for: ctrlA))
        #expect(log.chunks.last == Data([0x01]))
    }

    /// ⌥ composes by default: AZERTY ⌥⇧L is "|" (interpretKeyEvents → insertText), ⌥( is "{".
    @Test func optionComposesWhenNotMeta() {
        let (surface, _) = makeSurface()
        let log = recording(surface)
        #expect(TerminalKeyTranslator.usesComposition(modifiers: [.option, .shift], optionAsMeta: false,
                                                      hasMarkedText: false, isRelease: false))
        let pipe = TerminalKeyInput(keyCode: 0x25, modifiers: [.option, .shift], shiftedCharacters: "L",
                                    unshiftedCharacters: "l", composed: ["|"])
        surface.send(TerminalKeyTranslator.events(for: pipe))
        #expect(log.text == "|")
        let brace = TerminalKeyInput(keyCode: 0x17, modifiers: .option, shiftedCharacters: "(",
                                     unshiftedCharacters: "(", composed: ["{"])
        surface.send(TerminalKeyTranslator.events(for: brace))
        #expect(log.text == "|{")
    }

    @Test func optionIsMetaWhenTheSettingIsOn() {
        let (surface, _) = makeSurface()
        surface.apply(TerminalAppearance(isDark: true, fontSize: 13, optionAsMeta: true))
        let log = recording(surface)
        #expect(!TerminalKeyTranslator.usesComposition(modifiers: .option, optionAsMeta: true,
                                                       hasMarkedText: false, isRelease: false))
        let altB = TerminalKeyInput(keyCode: 0x0B, modifiers: .option, shiftedCharacters: "b",
                                    unshiftedCharacters: "b", optionAsMeta: true)
        surface.send(TerminalKeyTranslator.events(for: altB))
        #expect(log.bytes == Data([0x1B, 0x62]))
    }

    @Test func deadKeyWaitsForItsLetter() {
        // ⌥N then N: the first key leaves marked text and sends nothing; the second brings "ñ".
        let pending = TerminalKeyInput(keyCode: 0x2D, modifiers: .option, shiftedCharacters: "n",
                                       unshiftedCharacters: "n", hasMarkedText: true)
        #expect(TerminalKeyTranslator.events(for: pending).isEmpty)
        let done = TerminalKeyInput(keyCode: 0x2D, modifiers: [], shiftedCharacters: "n", unshiftedCharacters: "n",
                                    composed: ["ñ"], hadMarkedText: true)
        #expect(TerminalKeyTranslator.events(for: done).map(\.text) == ["ñ"])
    }

    @Test func typingClearsTheSelectionAndScrollsToTheBottom() {
        let (surface, _) = makeSurface()
        _ = recording(surface)
        for i in 0..<100 { surface.feed(Data("row \(i)\r\n".utf8)) }
        surface.scroll(rows: -10, at: .zero, geometry: geometry(), mods: [])
        #expect(!surface.terminal.isViewportAtBottom)
        surface.select(from: VTPoint(x: 0, y: 0), to: VTPoint(x: 2, y: 0))
        surface.send([VTKeyEvent(key: .q, text: "a", unshifted: "a")])
        #expect(surface.terminal.isViewportAtBottom)
        #expect(!surface.terminal.hasSelection)
    }

    // MARK: Copy, paste, replies, mouse

    @Test func selectionIsCopiedAsText() throws {
        let (surface, _) = makeSurface()
        let view = try #require(surface.view as? TerminalView)
        var copied: [String] = []
        view.writePasteboard = { copied.append($0) }
        surface.feed(Data("hello world\r\n".utf8))
        view.copy(nil)
        #expect(copied.isEmpty)   // nothing selected
        surface.select(from: VTPoint(x: 0, y: 0), to: VTPoint(x: 4, y: 0))
        view.copy(nil)
        #expect(copied == ["hello"])
    }

    @Test func pasteIsBracketedWhenTheProgramAskedForIt() throws {
        let (surface, _) = makeSurface()
        let view = try #require(surface.view as? TerminalView)
        view.readPasteboard = { "ls\nrm -rf x" }
        let log = recording(surface)
        view.paste(nil)
        #expect(log.text == "ls\rrm -rf x")   // not bracketed: newlines as Return
        surface.feed(Data("\u{1B}[?2004h".utf8))
        log.chunks = []
        view.paste(nil)
        #expect(log.text == "\u{1B}[200~ls\nrm -rf x\u{1B}[201~")
    }

    @Test func terminalRepliesGoToTheShell() {
        let (surface, _) = makeSurface()
        let log = recording(surface)
        surface.feed(Data("\u{1B}[6n".utf8))   // cursor position report
        #expect(log.text == "\u{1B}[1;1R")
    }

    @Test func mouseIsReportedOnlyWhileTracked() {
        let (surface, _) = makeSurface()
        let log = recording(surface)
        let press = VTMouseEvent(action: .press, button: .left, x: 25, y: 65)
        #expect(!surface.reportMouse(press, geometry: geometry(), anyButtonPressed: true))
        surface.feed(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        #expect(surface.reportMouse(press, geometry: geometry(), anyButtonPressed: true))
        #expect(log.text == "\u{1B}[<0;3;4M")
        log.chunks = []
        surface.scroll(rows: -2, at: CGPoint(x: 25, y: 65), geometry: geometry(), mods: [])
        #expect(log.text == "\u{1B}[<64;3;4M\u{1B}[<64;3;4M")   // two wheel-up reports, no scrollback move
    }

    private func geometry() -> VTMouseGeometry {
        VTMouseGeometry(width: 200, height: 100, cellWidth: 10, cellHeight: 20, paddingX: 0, paddingY: 0)
    }

    // MARK: Appearance

    @Test func themeFollowsTheAppearance() {
        let (surface, _) = makeSurface()
        surface.apply(TerminalAppearance(isDark: true, fontSize: 13, optionAsMeta: false))
        #expect(surface.theme == .dark)
        #expect(surface.terminal.colors.background == VTColor(hex: 0x282C34))
        #expect(surface.terminal.colors.foreground == VTColor(hex: 0xFFFFFF))
        surface.apply(TerminalAppearance(isDark: false, fontSize: 13, optionAsMeta: false))
        #expect(surface.theme == .light)
        #expect(surface.terminal.colors.background == VTColor(hex: 0xFFFFFF))
        #expect(surface.terminal.colors.foreground == VTColor(hex: 0x4D4D4C))
        // Light: Tomorrow's red for SGR 31; the 256-colour cube stays the built-in one.
        surface.feed(Data("\u{1B}[31mR\u{1B}[38;5;196mC".utf8))
        surface.terminal.update()
        let cells = surface.terminal.rows(onlyDirty: false)[0].cells
        #expect(cells[0].foreground == VTColor(hex: 0xC82829))
        #expect(cells[1].foreground == VTTerminal.builtInPalette[196])
    }

    @Test func bundledFontIsJetBrainsMono() {
        let fonts = TerminalFonts(size: 13)
        #expect(fonts.isBundledFont)
        #expect(CTFontCopyFamilyName(fonts.regular) as String == "JetBrains Mono")
        #expect(CTFontCopyPostScriptName(fonts.bold) as String == "JetBrainsMono-Bold")
        #expect(TerminalFonts(size: 200).size == TerminalFonts.sizeRange.upperBound)
    }

    @Test func fontSizeShortcutsMatchByCharacterOrKeypad() {
        #expect(TerminalView.fontSizeStep(keyCode: 0x18, characters: "=") == 1)
        #expect(TerminalView.fontSizeStep(keyCode: 0x18, characters: "+") == 1)    // AZERTY ⌘⇧=
        #expect(TerminalView.fontSizeStep(keyCode: 0x16, characters: "-") == -1)   // AZERTY: "-" on the 6 key
        #expect(TerminalView.fontSizeStep(keyCode: 0x4E, characters: "-") == -1)
        #expect(TerminalView.fontSizeStep(keyCode: 0x1D, characters: "0") == nil)   // ⌘0 stays the Library's
    }
}

@MainActor
struct TerminalSettingsTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    @Test func fontSizeAndOptionAsMetaPersist() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        #expect(settings.terminalFontSize == 13)   // Ghostty's default on macOS
        #expect(settings.terminalOptionAsMeta == false)
        settings.stepTerminalFontSize(1)
        settings.stepTerminalFontSize(1)
        settings.terminalOptionAsMeta = true
        let reopened = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        #expect(reopened.terminalFontSize == 15)
        #expect(reopened.terminalOptionAsMeta)
        for _ in 0..<40 { reopened.stepTerminalFontSize(1) }
        #expect(reopened.terminalFontSize == AppSettings.terminalFontSizeRange.upperBound)
        for _ in 0..<60 { reopened.stepTerminalFontSize(-1) }
        #expect(reopened.terminalFontSize == AppSettings.terminalFontSizeRange.lowerBound)
    }
}
