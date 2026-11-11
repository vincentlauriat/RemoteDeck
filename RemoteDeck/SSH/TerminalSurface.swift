import AppKit
import GhosttyEngine

/// How the terminal looks: the colours (`AppSettings.terminalTheme(isDark:)`: the theme chosen in
/// Settings › Terminal, the automatic one following the window's light or dark appearance), the font
/// family and size (`AppSettings.terminalFontSize`, ⌘+ / ⌘−) and ⌥ as Meta (Settings › Terminal).
struct TerminalAppearance: Equatable {
    var theme: TerminalTheme
    /// `nil`: the bundled JetBrains Mono.
    var fontFamily: String?
    var fontSize: CGFloat
    var optionAsMeta: Bool

    init(theme: TerminalTheme, fontFamily: String? = nil, fontSize: CGFloat, optionAsMeta: Bool) {
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.optionAsMeta = optionAsMeta
    }

    /// The automatic theme for a light or dark window, with the bundled font.
    init(isDark: Bool, fontSize: CGFloat, optionAsMeta: Bool) {
        self.init(theme: .forAppearance(isDark: isDark), fontSize: fontSize, optionAsMeta: optionAsMeta)
    }
}

/// The terminal engine behind a terminal tab, as `TerminalSessionModel` sees it (TRD › Architecture ›
/// SSH › Terminal engine). It hides the engine, so the model is tested on `FakeTerminalSurface`; the
/// engine adapter comes with the terminal view (plan Task 9b).
///
/// Contract for an adapter:
/// - `onInput` gets the bytes to send for each key, paste or mouse report, in order.
/// - `onResize` gets the grid size whenever it changes, and once as soon as it is set (attach): the
///   model opens the shell with the last size reported (80 x 24 until then) and sends every later
///   change to the server.
/// - `feed` is called on the main actor at most once per display frame, with every byte received
///   since (`TerminalOutputCoalescer`).
/// - `showSeparator` draws a full-width line with the text, where the previous shell ended, after a
///   reconnect.
@MainActor
protocol TerminalSurface: AnyObject {
    var view: NSView { get }
    var onInput: (Data) -> Void { get set }
    var onResize: (_ columns: Int, _ rows: Int) -> Void { get set }
    func feed(_ data: Data)
    func showSeparator(_ text: String)
    func apply(_ appearance: TerminalAppearance)
}

/// The engine adapter (TRD › Architecture › SSH › Terminal engine): libghostty-vt (`VTTerminal`)
/// fed with the shell's output, drawn by `TerminalView` from a row cache.
///
/// - Output: `feed` only queues the bytes; each frame parses at most `maxBytesPerFrame` of them, in
///   `sliceSize` slices, and stops early when `frameBudget` is spent, then refreshes the dirty rows.
///   What is left waits for the next frame: a flood (`yes`, the `cat` of a large log) never holds the
///   main actor for more than about one budget, and no byte is ever dropped. The first bytes after a
///   quiet spell are parsed at once (a typed key echoes without a frame of delay).
/// - Frame: parse, `update()` the render state, rebuild only the dirty rows' layouts, invalidate their
///   rects. `draw(_:)` reads the cache only, so drawing (and an offscreen `cacheDisplay`) never calls
///   the engine.
/// - Input: keys through libghostty-vt's key encoder (cursor-key mode, Kitty flags…), mouse through
///   its mouse encoder while the program tracks the mouse, pastes bracketed when the program asked
///   (mode 2004); the terminal's own replies (device attributes, status reports) go to `onInput` too.
///   OSC 52 writes (a program that tracks the mouse copies this way) go to the view's pasteboard only
///   while its window is key, else they are refused; reads are never answered.
@MainActor
final class GhosttyTerminalSurface: TerminalSurface {
    static let sliceSize = 64 * 1024

    let terminal: VTTerminal
    private let terminalView: TerminalView
    var view: NSView { terminalView }

    var onInput: (Data) -> Void = { _ in }
    /// Called with the current grid as soon as it is set, then on every change.
    var onResize: (_ columns: Int, _ rows: Int) -> Void = { _, _ in } {
        didSet { onResize(terminal.columns, terminal.rows) }
    }
    /// ⌘+ / ⌘− in the terminal (+1 / −1): the view stores the size (`AppSettings.terminalFontSize`)
    /// and applies it back.
    var onFontSizeStep: (Int) -> Void = { _ in }
    /// The view's accessibility label (localized by the SwiftUI view).
    var accessibilityLabel: String = "Terminal" {
        didSet { terminalView.setAccessibilityLabel(accessibilityLabel) }
    }
    /// ⌘1…⌘9 in the terminal (tab index from 0).
    var onSelectTab: (Int) -> Void = { _ in }
    /// Files dragged onto the terminal (Task 12): whether a drop is taken now (the shell is up and
    /// no transfer sheet shows), the highlight while one hovers, then the files dropped.
    var acceptsFileDrop: () -> Bool = { false }
    var onDropTargeted: (Bool) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }

    /// One display frame.
    static let frameInterval = 1.0 / 60
    /// Most bytes parsed in one frame.
    var maxBytesPerFrame = 2 << 20
    /// Parsing stops once a frame has spent this long (checked between slices): half a frame, so
    /// the rest of the main actor's work (drawing, input, the coalescer's delivery) keeps its share.
    var frameBudget: Duration = .milliseconds(8)
    /// Runs the next frame's work after the delay (what is left of the frame that just ran).
    var scheduleFrame: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    private(set) var appearance = TerminalAppearance(isDark: true, fontSize: TerminalFonts.defaultSize, optionAsMeta: false)
    private(set) var theme = TerminalTheme.dark
    let builder: TerminalRowBuilder
    private(set) var rowLayouts: [TerminalRowLayout]

    private var pending: [Data] = []
    private var pendingOffset = 0
    /// Bytes queued and not parsed yet.
    private(set) var pendingBytes = 0
    /// The most bytes ever queued at once (flood measurement).
    private(set) var peakPendingBytes = 0
    /// Bytes parsed since creation.
    private(set) var parsedBytes = 0
    private(set) var framesRun = 0
    /// Row layouts rebuilt since creation (tests: a cursor move rebuilds two rows, not the screen).
    private(set) var rowsBuilt = 0
    private var frameScheduled = false
    private var needsFullRefresh = true
    private var lastCursor: VTCursor?
    private var lastFocused = false
    /// The last size given to the engine (columns, rows, cell pixels): an unchanged size is not
    /// resized again, since a resize also ends synchronized output (mode 2026) and sends an in-band
    /// size report (mode 2048) even when nothing changed.
    private var lastEngineSize: [Int] = []

    init(columns: Int = 80, rows: Int = 24) {
        terminal = VTTerminal(columns: columns, rows: rows)
        builder = TerminalRowBuilder(fonts: TerminalFonts(size: TerminalFonts.defaultSize))
        rowLayouts = Array(repeating: .empty, count: rows)
        terminalView = TerminalView(frame: .zero)
        terminalView.surface = self
        terminal.onReply = { [weak self] bytes in self?.onInput(Data(bytes)) }
        terminal.onClipboardWrite = { [weak self] text in self?.terminalView.remoteCopy(text) ?? false }
        applyTheme()
        refresh()
    }

    var grid: TerminalGrid { builder.grid }

    // MARK: TerminalSurface

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        enqueue(data)
    }

    /// A dim full-width line where the previous shell ended. It goes through the same queue as the
    /// output, after the old shell's last bytes; first it leaves whatever state that shell left
    /// (a sequence cut mid-way, the alternate screen, mouse tracking, bracketed paste).
    func showSeparator(_ text: String) {
        let label = " \(text) "
        let dashes = max(2, terminal.columns - label.count - 2)
        let line = "──" + label + String(repeating: "─", count: dashes)
        // Also the Kitty keyboard flags (pop the whole stack, then set 0: a new shell must get ^C and
        // Esc as legacy bytes) and focus reports (?1004).
        let reset = "\u{18}\u{1B}[0m\u{1B}[!p\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l"
            + "\u{1B}[?1004l\u{1B}[<99u\u{1B}[=0;1u"
        enqueue(Data((reset + "\r\n\u{1B}[2m" + line + "\u{1B}[0m\r\n").utf8))
    }

    func apply(_ appearance: TerminalAppearance) {
        let previous = self.appearance
        self.appearance = appearance
        let family = TerminalFonts.normalizedFamily(appearance.fontFamily)
        if appearance.fontSize != previous.fontSize || appearance.fontSize != builder.fonts.size
            || family != builder.fonts.requestedFamily {
            builder.setFonts(TerminalFonts(size: appearance.fontSize, family: family))
            layoutGrid()
        }
        if theme != appearance.theme {
            applyTheme()
        }
        needsFullRefresh = true
        refresh()
    }

    private func applyTheme() {
        theme = appearance.theme
        terminal.setDefaultColors(foreground: theme.foreground, background: theme.background, cursor: theme.cursor)
        terminal.setPalette(overriding: theme.ansi)
        terminalView.themeChanged()
        needsFullRefresh = true
    }

    // MARK: Output queue

    private func enqueue(_ data: Data) {
        pending.append(data)
        pendingBytes += data.count
        peakPendingBytes = max(peakPendingBytes, pendingBytes)
        if !frameScheduled { runFrame() }
    }

    /// One frame: parse what the budget allows, refresh, and schedule the next frame if bytes are left.
    func runFrame() {
        frameScheduled = false
        framesRun += 1
        let clock = ContinuousClock()
        let start = clock.now
        var parsed = 0
        while pendingBytes > 0, parsed < maxBytesPerFrame {
            let chunk = pending[0]
            let count = min(Self.sliceSize, chunk.count - pendingOffset, maxBytesPerFrame - parsed)
            chunk.withUnsafeBytes { raw in
                terminal.write(UnsafeRawBufferPointer(rebasing: raw[pendingOffset..<(pendingOffset + count)]))
            }
            pendingOffset += count
            if pendingOffset == chunk.count {
                pending.removeFirst()
                pendingOffset = 0
            }
            parsed += count
            pendingBytes -= count
            if clock.now - start >= frameBudget { break }
        }
        parsedBytes += parsed
        refresh()
        if pendingBytes > 0 {
            frameScheduled = true
            let spent = clock.now - start
            let left = max(0, Self.frameInterval - Double(spent.components.attoseconds) / 1e18 - Double(spent.components.seconds))
            scheduleFrame(left) { [weak self] in self?.runFrame() }
        }
    }

    // MARK: Grid

    /// Columns and rows from the view's size; the engine and the server follow every change, and only
    /// a change. Until the view has a size the grid stays as created (80 × 24).
    func layoutGrid() {
        let bounds = terminalView.bounds.size
        let grid = builder.grid
        guard bounds.width >= grid.cellWidth + 2 * TerminalGrid.padding,
              bounds.height >= grid.cellHeight + 2 * TerminalGrid.padding else { return }
        let size = grid.size(fitting: bounds)
        let scale = terminalView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cellWidth = Int((grid.cellWidth * scale).rounded())
        let cellHeight = Int((grid.cellHeight * scale).rounded())
        let engineSize = [size.columns, size.rows, cellWidth, cellHeight]
        guard engineSize != lastEngineSize else { return }
        lastEngineSize = engineSize
        let changed = size.columns != terminal.columns || size.rows != terminal.rows
        terminal.resize(columns: size.columns, rows: size.rows, cellWidth: cellWidth, cellHeight: cellHeight)
        if rowLayouts.count != terminal.rows { rowLayouts = Array(repeating: .empty, count: terminal.rows) }
        needsFullRefresh = true
        refresh()
        if changed { onResize(terminal.columns, terminal.rows) }
    }

    // MARK: Render

    /// Takes the engine's changes into the row cache and invalidates the rows that changed.
    func refresh() {
        let dirty = terminal.update()
        let cursor = terminal.cursor
        let focused = terminalView.isFocused
        let cursorMoved = cursor != lastCursor || focused != lastFocused
        guard needsFullRefresh || dirty != .clean || cursorMoved else { return }
        let full = needsFullRefresh || dirty == .full
        let style = TerminalFrameStyle(theme: theme, colors: terminal.colors, cursor: cursor, focused: focused)
        if rowLayouts.count != terminal.rows { rowLayouts = Array(repeating: .empty, count: terminal.rows) }
        var rows = full ? terminal.rows(onlyDirty: false) : (dirty == .clean ? [] : terminal.rows(onlyDirty: true))
        if !full, cursorMoved {
            // A cursor move or focus change alone: its old and new rows, unless already dirty.
            let cursorRows = Set([lastCursor?.y, cursor?.y].compactMap { $0 }).subtracting(rows.map(\.y))
            rows += terminal.rows(at: cursorRows)
        }
        var changed: [Int] = []
        rowsBuilt += rows.count
        for row in rows where row.y < rowLayouts.count {
            rowLayouts[row.y] = builder.layout(row, columns: terminal.columns, style: style)
            changed.append(row.y)
        }
        terminal.markClean()
        lastCursor = cursor
        lastFocused = focused
        if needsFullRefresh || dirty == .full {
            terminalView.needsDisplay = true
        } else {
            for y in changed { terminalView.setNeedsDisplay(grid.rowRect(y, width: terminalView.bounds.width)) }
        }
        needsFullRefresh = false
        terminalView.contentChanged()
    }

    /// The visible text, one line per row (accessibility).
    var visibleText: String { rowLayouts.map(\.text).joined(separator: "\n") }

    // MARK: Input

    /// Encodes key events and sends their bytes. Typing scrolls back to the bottom and clears the
    /// selection, as Ghostty does.
    func send(_ events: [VTKeyEvent]) {
        var sent = false
        for event in events {
            let bytes = terminal.encodeKey(event, optionAsAlt: appearance.optionAsMeta)
            guard !bytes.isEmpty else { continue }
            onInput(Data(bytes))
            sent = true
        }
        if sent { inputSent() }
    }

    /// Text typed without a key event of its own (the character palette, an input method's commit).
    func sendText(_ text: String) {
        let sanitized = TerminalKeyTranslator.sanitized(text)
        guard !sanitized.isEmpty else { return }
        send([VTKeyEvent(key: .unidentified, text: sanitized)])
    }

    func paste(_ text: String) {
        let bytes = terminal.encodePaste(text)
        guard !bytes.isEmpty else { return }
        onInput(Data(bytes))
        inputSent()
    }

    private func inputSent() {
        if terminal.hasSelection { terminal.clearSelection() }
        if !terminal.isViewportAtBottom { terminal.scrollToBottom() }
        refresh()
    }

    /// The selected text, as Ghostty copies it.
    var selectionText: String? { terminal.selectionText() }

    func select(from start: VTPoint, to end: VTPoint) {
        terminal.select(from: start, to: end)
        refresh()
    }

    func selectWord(at point: VTPoint) {
        terminal.selectWord(at: point)
        refresh()
    }

    func selectLine(at point: VTPoint) {
        terminal.selectLine(at: point)
        refresh()
    }

    func clearSelection() {
        guard terminal.hasSelection else { return }
        terminal.clearSelection()
        refresh()
    }

    /// Reports a mouse event while the program tracks the mouse; `false` when it does not (the view
    /// selects instead).
    func reportMouse(_ event: VTMouseEvent, geometry: VTMouseGeometry, anyButtonPressed: Bool) -> Bool {
        guard terminal.mouseTracking else { return false }
        let bytes = terminal.encodeMouse(event, geometry: geometry, anyButtonPressed: anyButtonPressed)
        if !bytes.isEmpty { onInput(Data(bytes)) }
        return true
    }

    /// Scroll wheel by whole rows (negative: up). Reported as wheel buttons while the program tracks
    /// the mouse; as arrow keys on the alternate screen with alternate scroll (mode 1007, a pager);
    /// otherwise the viewport moves through the scrollback.
    func scroll(rows: Int, at position: CGPoint, geometry: VTMouseGeometry, mods: VTMods) {
        guard rows != 0 else { return }
        if terminal.mouseTracking {
            let button: VTMouseEvent.Button = rows < 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(rows) {
                let event = VTMouseEvent(action: .press, button: button, mods: mods, x: position.x, y: position.y)
                let bytes = terminal.encodeMouse(event, geometry: geometry, anyButtonPressed: false)
                if !bytes.isEmpty { onInput(Data(bytes)) }
            }
            return
        }
        if terminal.isAlternateScreen, terminal.mode(1007) {
            let key: VTKey = rows < 0 ? .arrowUp : .arrowDown
            for _ in 0..<abs(rows) {
                let bytes = terminal.encodeKey(VTKeyEvent(key: key), optionAsAlt: false)
                if !bytes.isEmpty { onInput(Data(bytes)) }
            }
            return
        }
        terminal.scroll(by: rows)
        refresh()
    }

    func focusChanged() {
        refresh()
    }
}
