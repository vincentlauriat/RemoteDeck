import AppKit
@testable import RemoteDeck

/// Records what the terminal session asks of its engine; the test types and resizes through the
/// closures the model set (`attach`).
@MainActor
final class FakeTerminalSurface: TerminalSurface {
    let view = NSView()
    var onInput: (Data) -> Void = { _ in }
    var onResize: (_ columns: Int, _ rows: Int) -> Void = { _, _ in }
    /// Off for floods: only the counts are kept.
    var keepsBytes = true
    private(set) var feeds = 0
    private(set) var fedBytes = 0
    private(set) var fed = Data()
    private(set) var separators: [String] = []
    private(set) var appearances: [TerminalAppearance] = []

    var fedText: String { String(decoding: fed, as: UTF8.self) }

    func feed(_ data: Data) {
        feeds += 1
        fedBytes += data.count
        if keepsBytes { fed.append(data) }
    }

    func showSeparator(_ text: String) { separators.append(text) }
    func apply(_ appearance: TerminalAppearance) { appearances.append(appearance) }

    func type(_ text: String) { onInput(Data(text.utf8)) }
}
