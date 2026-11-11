import Foundation
import GhosttyVt

/// One libghostty-vt terminal fed with bytes (an SSH channel's output), with the encoders that turn
/// keys, mouse events and pastes into the bytes to send back. No pty, no I/O, no UI: the caller draws
/// the cells it reads after each `update()`.
///
/// Not thread-safe (libghostty-vt is not reentrant): use one instance from one isolation domain, the
/// main actor in the app. Callbacks (`onReply`, `onClipboardWrite`) run synchronously inside `write`.
public final class VTTerminal {
    /// Ghostty 1.4.0's `scrollback-limit-bytes` (`ghostty +show-config --default`).
    public static let defaultScrollbackBytes = 50_000_000

    /// Bytes the terminal answers with (device attributes, status reports, mode 2048 size
    /// reports…), to write to the channel like typed input.
    public var onReply: ([UInt8]) -> Void = { _ in }

    /// Largest OSC 52 payload (decoded bytes) handed to `onClipboardWrite`; the same bound as the
    /// screen clipboard (TRD › Clipboard › Bounds).
    public static let maxClipboardWriteBytes = 1 << 20

    /// A program wrote the clipboard with OSC 52: the decoded plain text, for the standard clipboard
    /// only. Return true when it was written, false to refuse. Never called for reads (`ESC ] 52 ; c ; ?`
    /// is not answered: no read callback is installed), for other destinations, non-text content, empty
    /// or invalid UTF-8 text, or text over `maxClipboardWriteBytes`. Without a handler every write is
    /// refused.
    public var onClipboardWrite: ((String) -> Bool)?

    public private(set) var columns: Int
    public private(set) var rows: Int

    private let handles: Handles

    /// The C handles, freed together. A separate object so `deinit` needs no isolation and the
    /// callback's userdata (this object) lives exactly as long as the terminal.
    private final class Handles {
        var terminal: GhosttyTerminal?
        var renderState: GhosttyRenderState?
        var rowIterator: GhosttyRenderStateRowIterator?
        var rowCells: GhosttyRenderStateRowCells?
        var keyEncoder: GhosttyKeyEncoder?
        var keyEvent: GhosttyKeyEvent?
        var mouseEncoder: GhosttyMouseEncoder?
        var mouseEvent: GhosttyMouseEvent?
        var formatter: GhosttyFormatter?
        var onReply: ([UInt8]) -> Void = { _ in }
        var onClipboardWrite: (String) -> Bool = { _ in false }

        deinit {
            ghostty_formatter_free(formatter)
            ghostty_mouse_event_free(mouseEvent)
            ghostty_mouse_encoder_free(mouseEncoder)
            ghostty_key_event_free(keyEvent)
            ghostty_key_encoder_free(keyEncoder)
            ghostty_render_state_row_cells_free(rowCells)
            ghostty_render_state_row_iterator_free(rowIterator)
            ghostty_render_state_free(renderState)
            ghostty_terminal_free(terminal)
        }
    }

    /// - Parameters:
    ///   - terminfoName: reported to XTGETTCAP "TN" queries; the shell is opened with this `TERM`.
    public init(columns: Int, rows: Int, scrollbackBytes: Int = VTTerminal.defaultScrollbackBytes,
                terminfoName: String = "xterm-256color") {
        let columns = max(1, min(columns, Int(UInt16.max)))
        let rows = max(1, min(rows, Int(UInt16.max)))
        self.columns = columns
        self.rows = rows
        let h = Handles()
        handles = h
        // Allocation failures here are out-of-memory at launch: nothing sensible to continue with.
        precondition(ghostty_terminal_new(nil, &h.terminal, UInt16(columns), UInt16(rows)) == GHOSTTY_SUCCESS)
        precondition(ghostty_render_state_new(nil, &h.renderState) == GHOSTTY_SUCCESS)
        precondition(ghostty_render_state_row_iterator_new(nil, &h.rowIterator) == GHOSTTY_SUCCESS)
        precondition(ghostty_render_state_row_cells_new(nil, &h.rowCells) == GHOSTTY_SUCCESS)
        precondition(ghostty_key_encoder_new(nil, &h.keyEncoder) == GHOSTTY_SUCCESS)
        precondition(ghostty_key_event_new(nil, &h.keyEvent) == GHOSTTY_SUCCESS)
        precondition(ghostty_mouse_encoder_new(nil, &h.mouseEncoder) == GHOSTTY_SUCCESS)
        precondition(ghostty_mouse_event_new(nil, &h.mouseEvent) == GHOSTTY_SUCCESS)
        precondition(ghostty_formatter_terminal_new(nil, &h.formatter, h.terminal) == GHOSTTY_SUCCESS)
        let term = h.terminal

        // Ghostty's defaults: grapheme-width-method = unicode (DEC mode 2027 on, also after RIS).
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes)
        var scrollback = scrollbackBytes
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback)
        // No image drawing in this renderer: do not advertise or store Kitty graphics.
        var noImages: UInt64 = 0
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &noImages)
        let name = Array(terminfoName.utf8)
        name.withUnsafeBufferPointer { buffer in
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &string)
        }
        // OSC 52 writes only (Vincent, 2026-11-11, as Ghostty does); no read callback is installed, so
        // reads (`?`) are never answered and the remote cannot read the Mac pasteboard.

        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(h).toOpaque())
        let reply: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            let handles = Unmanaged<Handles>.fromOpaque(userdata).takeUnretainedValue()
            handles.onReply(Array(UnsafeBufferPointer(start: data, count: length)))
        }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(reply, to: UnsafeRawPointer.self))
        h.onReply = { [weak self] bytes in self?.onReply(bytes) }
        let clipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
            guard let userdata, let request else { return }
            let handles = Unmanaged<Handles>.fromOpaque(userdata).takeUnretainedValue()
            var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
            if let text = VTTerminal.clipboardText(of: request.pointee) {
                result = handles.onClipboardWrite(text) ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
                                                        : GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
            }
            var reply = GhosttyClipboardWriteReply(size: MemoryLayout<GhosttyClipboardWriteReply>.size,
                                                   result: result, remember: false)
            request.pointee.reply?(request, &reply)
        }
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self))
        h.onClipboardWrite = { [weak self] text in self?.onClipboardWrite?(text) ?? false }

        // Copy text the way Ghostty copies it: wrapped lines joined, trailing blanks trimmed.
        var yes = true
        ghostty_formatter_set(h.formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
        ghostty_formatter_set(h.formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
    }

    private var term: GhosttyTerminal? { handles.terminal }

    /// The text of a clipboard write the app may honour: standard clipboard (macOS has no selection or
    /// primary pasteboard; Ghostty's macOS app keeps those apart from the general one, so they are
    /// refused here), one `text/plain` representation of valid, non-empty UTF-8 within the bound.
    /// Never logged.
    private static func clipboardText(of write: GhosttyClipboardWrite) -> String? {
        guard write.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD, let contents = write.contents else { return nil }
        for content in UnsafeBufferPointer(start: contents, count: write.contents_len) {
            guard let mime = content.mime.ptr, let data = content.data.ptr else { continue }
            let type = String(decoding: UnsafeBufferPointer(start: mime, count: content.mime.len), as: UTF8.self)
            guard type == "text/plain" || type.hasPrefix("text/plain;") else { continue }
            guard content.data.len > 0, content.data.len <= maxClipboardWriteBytes else { return nil }
            return String(bytes: UnsafeBufferPointer(start: data, count: content.data.len), encoding: .utf8)
        }
        return nil
    }

    // MARK: Bytes in

    /// Parses `bytes`. Any split is fine: the parser keeps its state between calls.
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(term, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    public func write(_ text: String) {
        write(Data(text.utf8))
    }

    // MARK: Size and colours

    /// New grid size; `cellWidth`/`cellHeight` in pixels (size reports, the mouse encoder's pixel mode).
    public func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let columns = max(1, min(columns, Int(UInt16.max)))
        let rows = max(1, min(rows, Int(UInt16.max)))
        self.columns = columns
        self.rows = rows
        ghostty_terminal_resize(term, UInt16(columns), UInt16(rows), UInt32(max(1, cellWidth)), UInt32(max(1, cellHeight)))
    }

    /// The default colours (a program may still override them with OSC 10/11/12).
    public func setDefaultColors(foreground: VTColor, background: VTColor, cursor: VTColor?) {
        var fg = foreground.c
        var bg = background.c
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if var cursor = cursor?.c {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
        } else {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
    }

    /// The built-in 256-colour palette (Ghostty's: Tomorrow Night hues, the 6×6×6 cube, the grey ramp).
    public static let builtInPalette: [VTColor] = {
        let probe = VTTerminal(columns: 1, rows: 1)
        var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        colors.withUnsafeMutableBufferPointer { buffer in
            _ = ghostty_terminal_get(probe.term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, buffer.baseAddress)
        }
        return colors.map(VTColor.init)
    }()

    /// Replaces the first entries of the built-in palette (the 16 ANSI colours of a theme); `nil`
    /// restores the built-in palette.
    public func setPalette(overriding first: [VTColor]?) {
        guard let first else {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
            return
        }
        var palette = Self.builtInPalette.map(\.c)
        for (index, color) in first.prefix(256).enumerated() { palette[index] = color.c }
        palette.withUnsafeBufferPointer { buffer in
            _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress)
        }
    }

    // MARK: Modes

    /// A mode's current value: DEC private (`?2004`) unless `ansi`.
    public func mode(_ number: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    /// Bracketed paste (DEC mode 2004).
    public var bracketedPaste: Bool { mode(2004) }

    /// Any mouse tracking mode (X10, normal, button or any-event) is on.
    public var mouseTracking: Bool {
        var on = false
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on)
        return on
    }

    public var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    /// The title set with OSC 0/2, empty when none.
    public var title: String {
        var string = GhosttyString()
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TITLE, &string) == GHOSTTY_SUCCESS,
              let pointer = string.ptr, string.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
    }

    // MARK: Scrollback

    public func scroll(by rows: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = rows
        ghostty_terminal_scroll_viewport(term, behavior)
    }

    public func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(term, behavior)
    }

    /// The viewport follows the active area (not scrolled back).
    public var isViewportAtBottom: Bool {
        var active = true
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active)
        return active
    }

    public var scrollbar: VTScrollbar {
        var bar = GhosttyTerminalScrollbar()
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar)
        return VTScrollbar(total: Int(bar.total), offset: Int(bar.offset), length: Int(bar.len))
    }

    // MARK: Selection

    private func gridRef(_ point: VTPoint) -> GhosttyGridRef? {
        let x = max(0, min(point.x, columns - 1))
        let y = max(0, min(point.y, rows - 1))
        var p = GhosttyPoint()
        p.tag = GHOSTTY_POINT_TAG_VIEWPORT
        p.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(term, p, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// Selects from `start` to `end` (viewport points, both included), the way text flows.
    public func select(from start: VTPoint, to end: VTPoint) {
        guard let a = gridRef(start), let b = gridRef(end) else { return }
        var selection = GhosttySelection(start: a, end: b, rectangle: false)
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// Selects the word under `point` (double click).
    public func selectWord(at point: VTPoint) {
        guard let ref = gridRef(point) else { return }
        var options = GhosttyTerminalSelectWordOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        if ghostty_terminal_select_word(term, &options, &selection) == GHOSTTY_SUCCESS {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        }
    }

    /// Selects the line under `point` (triple click).
    public func selectLine(at point: VTPoint) {
        guard let ref = gridRef(point) else { return }
        var options = GhosttyTerminalSelectLineOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
        options.ref = ref
        var selection = GhosttySelection()
        if ghostty_terminal_select_line(term, &options, &selection) == GHOSTTY_SUCCESS {
            ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        }
    }

    public func clearSelection() {
        ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    public var hasSelection: Bool {
        var selection = GhosttySelection()
        return ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// The selected text as Ghostty copies it (plain, wrapped lines joined, trailing blanks
    /// trimmed), `nil` without a selection.
    public func selectionText() -> String? {
        var selection = GhosttySelection()
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else {
            return nil
        }
        ghostty_formatter_set(handles.formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection)
        defer { ghostty_formatter_set(handles.formatter, GHOSTTY_FORMATTER_OPT_SELECTION, nil) }
        return format()
    }

    /// The whole screen as plain text (scrollback included), for tests and accessibility.
    public func screenText() -> String {
        format() ?? ""
    }

    private func format() -> String? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(handles.formatter, nil, &pointer, &length) == GHOSTTY_SUCCESS else {
            return nil
        }
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    // MARK: Keys, mouse, paste

    /// The bytes a key event sends, for the terminal's current modes (cursor-key mode, Kitty flags,
    /// modifyOtherKeys…). `optionAsAlt`: ⌥ is Meta (Settings › "Use ⌥ as Meta"); off, ⌥ only
    /// composes characters, as in Ghostty.
    public func encodeKey(_ key: VTKeyEvent, optionAsAlt: Bool) -> [UInt8] {
        let encoder = handles.keyEncoder
        let event = handles.keyEvent
        ghostty_key_encoder_set_from_terminal(encoder, term)
        // set_from_terminal resets it to false: set it after every call.
        var option = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option)

        let action: GhosttyKeyAction = switch key.action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        }
        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, key.key.raw)
        ghostty_key_event_set_mods(event, key.mods.rawValue)
        ghostty_key_event_set_consumed_mods(event, key.consumedMods.rawValue)
        ghostty_key_event_set_composing(event, key.composing)
        ghostty_key_event_set_unshifted_codepoint(event, key.unshifted?.value ?? 0)

        let text = Array(key.text.utf8)
        return text.withUnsafeBufferPointer { buffer -> [UInt8] in
            // The event borrows the text: encode while the buffer is alive, then clear it.
            ghostty_key_event_set_utf8(event, GhosttyString(ptr: buffer.baseAddress, len: buffer.count))
            defer { ghostty_key_event_set_utf8(event, GhosttyString(ptr: nil, len: 0)) }
            return Self.encode { buf, cap, written in ghostty_key_encoder_encode(encoder, event, buf, cap, written) }
        }
    }

    /// The bytes a mouse event sends while the program tracks the mouse (`mouseTracking`), in its
    /// format (X10, SGR…). Empty when the event is not reported (a motion in normal mode).
    public func encodeMouse(_ mouse: VTMouseEvent, geometry: VTMouseGeometry, anyButtonPressed: Bool) -> [UInt8] {
        let encoder = handles.mouseEncoder
        let event = handles.mouseEvent
        ghostty_mouse_encoder_set_from_terminal(encoder, term)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(max(1, geometry.width.rounded()))
        size.screen_height = UInt32(max(1, geometry.height.rounded()))
        size.cell_width = UInt32(max(1, geometry.cellWidth.rounded()))
        size.cell_height = UInt32(max(1, geometry.cellHeight.rounded()))
        size.padding_left = UInt32(max(0, geometry.paddingX.rounded()))
        size.padding_right = size.padding_left
        size.padding_top = UInt32(max(0, geometry.paddingY.rounded()))
        size.padding_bottom = size.padding_top
        ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        let action: GhosttyMouseAction = switch mouse.action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(event, action)
        if let button = mouse.button {
            ghostty_mouse_event_set_button(event, GhosttyMouseButton(rawValue: numericCast(button.rawValue)))
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, mouse.mods.rawValue)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(mouse.x), y: Float(mouse.y)))
        return Self.encode { buf, cap, written in ghostty_mouse_encoder_encode(encoder, event, buf, cap, written) }
    }

    /// The bytes a paste sends: wrapped in bracketed-paste markers when the program asked for them
    /// (mode 2004), otherwise with newlines as carriage returns; unsafe control bytes removed.
    public func encodePaste(_ text: String) -> [UInt8] {
        var data = Array(text.utf8CString.dropLast())   // a mutable copy: the encoder rewrites it
        guard !data.isEmpty else { return [] }
        let bracketed = bracketedPaste
        return data.withUnsafeMutableBufferPointer { input in
            Self.encode { buf, cap, written in
                ghostty_paste_encode(input.baseAddress, input.count, bracketed, buf, cap, written)
            }
        }
    }

    /// Runs an encoder that reports the size it needs (GHOSTTY_OUT_OF_SPACE) into a growing buffer.
    private static func encode(_ run: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 128)
        var written = 0
        var result = buffer.withUnsafeMutableBufferPointer { run($0.baseAddress, $0.count, &written) }
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [UInt8](repeating: 0, count: written)
            result = buffer.withUnsafeMutableBufferPointer { run($0.baseAddress, $0.count, &written) }
        }
        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(buffer.prefix(written))
    }

    // MARK: Render state

    /// Takes the terminal's changes since the last update. Then read `colors`, `cursor` and
    /// `rows(onlyDirty:)`, and call `markClean()` once they are drawn.
    @discardableResult
    public func update() -> VTDirty {
        ghostty_render_state_update(handles.renderState, term)
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(handles.renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        switch dirty {
        case GHOSTTY_RENDER_STATE_DIRTY_FULL: return .full
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: return .partial
        default: return .clean
        }
    }

    /// Marks every row drawn (`ghostty_render_state_clean`).
    public func markClean() {
        ghostty_render_state_clean(handles.renderState)
    }

    public var colors: VTFrameColors {
        var c = GhosttyRenderStateColors()
        c.size = MemoryLayout<GhosttyRenderStateColors>.size
        ghostty_render_state_get(handles.renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &c)
        return VTFrameColors(foreground: VTColor(c.foreground), background: VTColor(c.background),
                             cursor: c.cursor_has_value ? VTColor(c.cursor) : nil)
    }

    /// The cursor if it is visible (modes) and inside the viewport.
    public var cursor: VTCursor? {
        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(handles.renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c)
        guard c.visible, c.viewport_has_value else { return nil }
        let shape: VTCursor.Shape = switch c.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
        return VTCursor(x: Int(c.viewport_x), y: Int(c.viewport_y), shape: shape, wideTail: c.wide_tail)
    }

    /// The viewport rows of the last `update()`: every row, or only those that changed (all of
    /// them after a full change). Valid until the next `update()`.
    public func rows(onlyDirty: Bool) -> [VTRow] {
        rows(onlyDirty: onlyDirty, including: nil)
    }

    /// Only the viewport rows whose y is in `ys` (the cells of the others are not read).
    public func rows(at ys: Set<Int>) -> [VTRow] {
        ys.isEmpty ? [] : rows(onlyDirty: false, including: ys)
    }

    private func rows(onlyDirty: Bool, including ys: Set<Int>?) -> [VTRow] {
        let state = handles.renderState
        let iterator = handles.rowIterator
        let cells = handles.rowCells
        var rowIterator = iterator
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator) == GHOSTTY_SUCCESS else {
            return []
        }
        var result: [VTRow] = []
        var y: UInt16 = 0
        var index = 0
        var codepoints = [UInt32](repeating: 0, count: 16)
        while true {
            let advanced: Bool
            if onlyDirty {
                advanced = ghostty_render_state_row_iterator_next_dirty(iterator, &y)
            } else {
                advanced = ghostty_render_state_row_iterator_next(iterator)
                y = UInt16(clamping: index)
                index += 1
            }
            guard advanced else { break }
            if let ys, !ys.contains(Int(y)) { continue }
            var rowCells = cells
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)
            var range = GhosttyRenderStateRowSelection()
            range.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let selected: ClosedRange<Int>? =
                ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &range) == GHOSTTY_SUCCESS
                    && range.end_x >= range.start_x
                ? Int(range.start_x)...Int(range.end_x) : nil

            var line: [VTCell] = []
            line.reserveCapacity(columns)
            var column = 0
            while ghostty_render_state_row_cells_next(cells) {
                defer { column += 1 }
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }

                var count: UInt32 = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &count)
                var text = ""
                if count > 0 {
                    if Int(count) > codepoints.count { codepoints = [UInt32](repeating: 0, count: Int(count)) }
                    codepoints.withUnsafeMutableBufferPointer { buffer in
                        var graphemes = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes)
                        for i in 0..<min(Int(graphemes.len), buffer.count) {
                            if let scalar = Unicode.Scalar(buffer[i]) { text.unicodeScalars.append(scalar) }
                        }
                    }
                }
                var styled = false
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
                var style = VTCellStyle()
                if styled {
                    var s = GhosttyStyle()
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &s)
                    style = VTCellStyle(flags: s.flags)
                }
                var fg = GhosttyColorRgb()
                var bg = GhosttyColorRgb()
                let hasFg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS
                let hasBg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
                guard !text.isEmpty || hasBg || style != VTCellStyle() else { continue }
                line.append(VTCell(column: column, text: text, width: wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1,
                                   foreground: hasFg ? VTColor(fg) : nil, background: hasBg ? VTColor(bg) : nil,
                                   style: style))
            }
            result.append(VTRow(y: Int(y), cells: line, selection: selected))
        }
        return result
    }

    /// The library's version (`ghostty_version()`), e.g. "1.0.0".
    public static var version: String {
        guard let pointer = ghostty_version() else { return "" }
        return String(cString: pointer)
    }
}

extension VTColor {
    init(_ c: GhosttyColorRgb) { self.init(r: c.r, g: c.g, b: c.b) }
    var c: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

extension VTCellStyle {
    init(flags: GhosttyStyleFlags) {
        self.init()
        bold = flags & (1 << 0) != 0
        italic = flags & (1 << 1) != 0
        faint = flags & (1 << 2) != 0
        inverse = flags & (1 << 4) != 0
        invisible = flags & (1 << 5) != 0
        strikethrough = flags & (1 << 6) != 0
        overline = flags & (1 << 7) != 0
        underline = Underline(rawValue: UInt8((flags >> 8) & 0x7)) ?? .single
    }
}
