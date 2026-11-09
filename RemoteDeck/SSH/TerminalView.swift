import AppKit
import GhosttyEngine
import RFBKit

/// The terminal tab's view (AppFlow › Terminal tab): draws `GhosttyTerminalSurface`'s row cache and
/// turns AppKit events into terminal input. App shortcuts keep priority: ⌘1…⌘9 (key codes, so
/// AZERTY's ⌘& ⌘é… too), ⌘+ / ⌘− (font size), ⌘C / ⌘V (Edit menu actions), and every other ⌘ chord
/// goes to the menus (⌘W, ⌘Y, ⌘?, ⌘0, ⌘,). Everything else goes to the terminal. Text input goes
/// through `NSTextInputClient`, so ⌥ compositions and dead keys type their characters.
@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    weak var surface: GhosttyTerminalSurface?

    /// The pasteboard: the general one in the app, replaced in tests.
    var readPasteboard: () -> String? = { NSPasteboard.general.string(forType: .string) }
    var writePasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var markedText = NSMutableAttributedString()
    /// The selection inside the marked text, as the input method set it.
    private var markedSelection = NSRange(location: 0, length: 0)
    /// Keys whose press reached the terminal: only their releases are sent (a key taken by an app
    /// shortcut, ⌘1 or ⌘+, has no press there, so its release is dropped).
    private var keysDown: Set<UInt16> = []
    /// Text `insertText` received during the current `keyDown` (nil outside one).
    private var keyTextAccumulator: [String]?
    private var selectionAnchor: VTPoint?
    private var scrollRemainder: CGFloat = 0
    private var buttonsDown = 0
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    /// First responder in the key window: a filled cursor. (Tests that draw offscreen set
    /// `focusOverride`.)
    var isFocused: Bool { focusOverride ?? (window?.isKeyWindow == true && window?.firstResponder === self) }
    var focusOverride: Bool?

    func themeChanged() {
        layer?.backgroundColor = surface?.theme.background.cgColor
        needsDisplay = true
    }

    func contentChanged() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Layout and drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        surface?.layoutGrid()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surface?.layoutGrid()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
        surface?.layoutGrid()
    }

    @objc private func windowKeyChanged() { surface?.focusChanged() }

    override func becomeFirstResponder() -> Bool {
        defer { surface?.focusChanged() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { surface?.focusChanged() }
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let surface, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(surface.theme.background.cgColor)
        context.fill(dirtyRect)
        let grid = surface.grid
        // Flipped view: text drawn with y going down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (y, row) in surface.rowLayouts.enumerated() {
            let rect = grid.rowRect(y, width: bounds.width)
            guard rect.intersects(dirtyRect) else { continue }
            row.draw(in: context, at: rect.minY)
        }
        drawMarkedText()
    }

    /// The input method's composing text (a dead key's accent, kana before conversion), underlined
    /// at the cursor until it is committed.
    private func drawMarkedText() {
        guard markedText.length > 0, let surface else { return }
        let grid = surface.grid
        let cursor = surface.terminal.cursor
        let origin = CGPoint(x: TerminalGrid.padding + CGFloat(cursor?.x ?? 0) * grid.cellWidth,
                             y: TerminalGrid.padding + CGFloat(cursor?.y ?? 0) * grid.cellHeight)
        let font = surface.builder.fonts.regular as NSFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: surface.theme.foreground.nsColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        let text = NSAttributedString(string: markedText.string, attributes: attributes)
        let width = max(grid.cellWidth, ceil(text.size().width))
        surface.theme.background.nsColor.setFill()
        NSRect(x: origin.x, y: origin.y, width: width, height: grid.cellHeight).fill()
        text.draw(at: NSPoint(x: origin.x, y: origin.y + grid.ascent - font.ascender))
    }

    private func markedTextChanged() {
        guard let surface else { return }
        let y = surface.terminal.cursor?.y ?? 0
        setNeedsDisplay(surface.grid.rowRect(y, width: bounds.width))
    }

    // MARK: File drop (Task 12)

    /// The file URLs on a drag's pasteboard (the sandbox lets the app read the dropped files).
    private func droppedFileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let surface, surface.acceptsFileDrop(), !droppedFileURLs(sender).isEmpty else { return [] }
        surface.onDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        surface?.onDropTargeted(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        surface?.onDropTargeted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        surface.onDropTargeted(false)
        let urls = droppedFileURLs(sender)
        guard surface.acceptsFileDrop(), !urls.isEmpty else { return false }
        surface.onDropFiles(urls)
        return true
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? { surface?.visibleText }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if let shortcut = LocalShortcut.matching(keyCode: event.keyCode, flags: MacModifierFlags(rawValue: event.modifierFlags.rawValue)),
           case .switchTab(let number) = shortcut {
            surface.onSelectTab(number - 1)
            return true
        }
        if flags == .command || flags == [.command, .shift] {
            switch Self.fontSizeStep(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "") {
            case let step?:
                surface.onFontSizeStep(step)
                return true
            case nil:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘+ / ⌘= (AZERTY: ⇧ on the "=" key), ⌘− (AZERTY: the "-" on the 6 key), and the keypad's.
    static func fontSizeStep(keyCode: UInt16, characters: String) -> Int? {
        switch characters {
        case "+", "=": return 1
        case "-": return -1
        default: break
        }
        switch keyCode {
        case 0x45: return 1    // kVK_ANSI_KeypadPlus
        case 0x4E: return -1   // kVK_ANSI_KeypadMinus
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        keysDown.insert(event.keyCode)
        let optionAsMeta = surface.appearance.optionAsMeta
        let hadMarked = hasMarkedText()
        var composed: [String] = []
        if TerminalKeyTranslator.usesComposition(modifiers: event.modifierFlags, optionAsMeta: optionAsMeta,
                                                 hasMarkedText: hadMarked, isRelease: false) {
            keyTextAccumulator = []
            interpretKeyEvents([event])
            composed = keyTextAccumulator ?? []
            keyTextAccumulator = nil
        }
        surface.send(TerminalKeyTranslator.events(for: keyInput(event, composed: composed, hadMarked: hadMarked,
                                                                 optionAsMeta: optionAsMeta)))
    }

    override func keyUp(with event: NSEvent) {
        guard keysDown.remove(event.keyCode) != nil, let surface, !hasMarkedText() else { return }
        var input = keyInput(event, composed: [], hadMarked: false, optionAsMeta: surface.appearance.optionAsMeta)
        input.isRelease = true
        surface.send(TerminalKeyTranslator.events(for: input))
    }

    private func keyInput(_ event: NSEvent, composed: [String], hadMarked: Bool, optionAsMeta: Bool) -> TerminalKeyInput {
        TerminalKeyInput(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                         shiftedCharacters: event.characters(byApplyingModifiers: event.modifierFlags.intersection(.shift)) ?? "",
                         unshiftedCharacters: event.characters(byApplyingModifiers: []) ?? "",
                         composed: composed, hadMarkedText: hadMarked, hasMarkedText: hasMarkedText(),
                         optionAsMeta: optionAsMeta)
    }

    /// Keys AppKit maps to commands (Return, arrows, ⌫…) are encoded from the key itself.
    override func doCommand(by selector: Selector) {}

    // MARK: Copy and paste (Edit menu)

    @objc func copy(_ sender: Any?) {
        guard let text = surface?.selectionText, !text.isEmpty else { return }
        writePasteboard(text)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = readPasteboard(), !text.isEmpty else { return }
        surface?.paste(text)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if markedText.length > 0 {
            markedText = NSMutableAttributedString()
            markedSelection = NSRange(location: 0, length: 0)
            markedTextChanged()
        }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            surface?.sendText(text)   // the character palette, an input method's commit
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        markedSelection = selectedRange
        markedTextChanged()
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
        markedTextChanged()
    }

    /// Inside the marked text, where the input method put it; an empty insertion point otherwise.
    func selectedRange() -> NSRange { markedText.length > 0 ? markedSelection : NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where an input method puts its candidate window: under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        let grid = surface.grid
        let cursor = surface.terminal.cursor
        let x = TerminalGrid.padding + CGFloat(cursor?.x ?? 0) * grid.cellWidth
        let y = TerminalGrid.padding + CGFloat(cursor?.y ?? 0) * grid.cellHeight
        let local = NSRect(x: x, y: y, width: grid.cellWidth, height: grid.cellHeight)
        return window.convertToScreen(convert(local, to: nil))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private var mouseGeometry: VTMouseGeometry {
        let scale = window?.backingScaleFactor ?? 2
        let grid = surface?.grid ?? TerminalGrid(cellWidth: 8, cellHeight: 16, ascent: 12)
        return VTMouseGeometry(width: bounds.width * scale, height: bounds.height * scale,
                               cellWidth: grid.cellWidth * scale, cellHeight: grid.cellHeight * scale,
                               paddingX: TerminalGrid.padding * scale, paddingY: TerminalGrid.padding * scale)
    }

    private func mouseEvent(_ event: NSEvent, action: VTMouseEvent.Action, button: VTMouseEvent.Button?) -> VTMouseEvent {
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        return VTMouseEvent(action: action, button: button, mods: TerminalKeyTranslator.vtMods(event.modifierFlags),
                            x: point.x * scale, y: point.y * scale)
    }

    /// Shift forces a selection even while the program tracks the mouse.
    private func reports(_ event: NSEvent, _ action: VTMouseEvent.Action, _ button: VTMouseEvent.Button?) -> Bool {
        guard let surface, !event.modifierFlags.contains(.shift) else { return false }
        return surface.reportMouse(mouseEvent(event, action: action, button: button), geometry: mouseGeometry,
                                   anyButtonPressed: buttonsDown > 0)
    }

    private func cell(at event: NSEvent) -> VTPoint? {
        guard let surface else { return nil }
        return surface.grid.cell(at: convert(event.locationInWindow, from: nil),
                                 columns: surface.terminal.columns, rows: surface.terminal.rows)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonsDown += 1
        if reports(event, .press, .left) { return }
        guard let point = cell(at: event) else { return }
        switch event.clickCount {
        case 2: surface?.selectWord(at: point)
        case 3...: surface?.selectLine(at: point)
        default:
            selectionAnchor = point
            surface?.clearSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if reports(event, .motion, .left) { return }
        guard let anchor = selectionAnchor, let point = cell(at: event) else { return }
        surface?.select(from: anchor, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        buttonsDown = max(0, buttonsDown - 1)
        if reports(event, .release, .left) { return }
        selectionAnchor = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        buttonsDown += 1
        if !reports(event, .press, .right) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonsDown = max(0, buttonsDown - 1)
        if !reports(event, .release, .right) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        buttonsDown += 1
        _ = reports(event, .press, .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonsDown = max(0, buttonsDown - 1)
        _ = reports(event, .release, .middle)
    }

    override func mouseMoved(with event: NSEvent) {
        _ = reports(event, .motion, nil)
    }

    override func rightMouseDragged(with event: NSEvent) { _ = reports(event, .motion, .right) }
    override func otherMouseDragged(with event: NSEvent) { _ = reports(event, .motion, .middle) }

    /// Trackpad: whole rows of the precise delta; a wheel: 3 rows per notch (Ghostty's
    /// `mouse-scroll-multiplier = precision:1,discrete:3`).
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let rows: Int
        if event.hasPreciseScrollingDeltas {
            scrollRemainder += event.scrollingDeltaY
            let whole = (scrollRemainder / surface.grid.cellHeight).rounded(.towardZero)
            scrollRemainder -= whole * surface.grid.cellHeight
            rows = Int(-whole)
        } else {
            rows = Int((-event.scrollingDeltaY * 3).rounded())
        }
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2
        surface.scroll(rows: rows, at: CGPoint(x: point.x * scale, y: point.y * scale), geometry: mouseGeometry,
                       mods: TerminalKeyTranslator.vtMods(event.modifierFlags))
    }
}
