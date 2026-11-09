import AppKit

/// How the terminal looks: light or dark (the window's effective appearance), the font size
/// (`AppSettings.terminalFontSize`, ⌘+ / ⌘−) and ⌥ as Meta (Settings › Terminal).
struct TerminalAppearance: Equatable {
    var isDark: Bool
    var fontSize: CGFloat
    var optionAsMeta: Bool
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
