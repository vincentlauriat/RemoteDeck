import Foundation

/// What the terminal assistant reads of a terminal tab, as text (TRD › Claude Assistant › Terminal):
/// the active screen's rows, a bounded scrollback (Claude only), the cursor, the title. Terminal
/// content is written by remote programs: data for the model, never instructions.
struct TerminalSnapshot: Equatable, Sendable {
    /// Scrollback rows kept for Claude (newest).
    static let maxScrollbackLines = 200
    /// Scrollback characters kept for Claude (newest whole rows).
    static let maxScrollbackCharacters = 16_000

    /// The active screen's rows, top to bottom, trailing spaces trimmed (always `rows` of them for a
    /// snapshot read from a surface).
    var screen: [String]
    /// Rows above the screen, oldest first.
    var scrollback: [String]
    /// The cursor in the screen (0-based), `nil` when unknown.
    var cursorRow: Int?
    var cursorColumn: Int?
    /// A full-screen program (vim, less, top) has the alternate screen.
    var isAlternateScreen: Bool
    /// OSC 0/2, empty when none.
    var title: String
    var columns: Int
    var rows: Int

    init(screen: [String], scrollback: [String] = [], cursorRow: Int? = nil, cursorColumn: Int? = nil,
         isAlternateScreen: Bool = false, title: String = "", columns: Int = 80, rows: Int? = nil) {
        self.screen = screen
        self.scrollback = scrollback
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.isAlternateScreen = isAlternateScreen
        self.title = title
        self.columns = columns
        self.rows = rows ?? screen.count
    }

    /// The row the cursor is on: where typed text lands.
    var promptLine: String? {
        guard let cursorRow, screen.indices.contains(cursorRow) else { return nil }
        return screen[cursorRow]
    }

    /// The cursor is at (or past) the end of its row's text.
    var cursorIsAtLineEnd: Bool {
        guard let line = promptLine, let cursorColumn else { return false }
        return cursorColumn >= line.count
    }

    /// The newest scrollback rows within both bounds (whole rows only).
    func bounded(maxLines: Int = TerminalSnapshot.maxScrollbackLines,
                 maxCharacters: Int = TerminalSnapshot.maxScrollbackCharacters) -> TerminalSnapshot {
        var kept: [String] = []
        var characters = 0
        for line in scrollback.reversed() {
            guard kept.count < maxLines else { break }
            let cost = line.count + 1
            guard characters + cost <= maxCharacters else { break }
            characters += cost
            kept.append(line)
        }
        var copy = self
        copy.scrollback = kept.reversed()
        return copy
    }

    /// The fixed text the models read. Blank rows below the cursor are left out; `includeScrollback`
    /// false (Apple: an 8,192-token context) gives the screen only.
    func rendered(includeScrollback: Bool) -> String {
        let cursor = cursorRow.map { row in "\(row),\(cursorColumn ?? 0)" } ?? "none"
        var lines = ["<terminal cols=\(columns) rows=\(rows) alternate=\(isAlternateScreen ? "yes" : "no") title=\"\(Self.attribute(title))\" cursor=\(cursor)>"]
        if includeScrollback, !scrollback.isEmpty {
            lines.append("--- scrollback ---")
            lines += scrollback.map(Self.visible)
        }
        lines.append("--- screen ---")
        var shown = screen
        let keep = (cursorRow ?? -1) + 1
        while shown.count > keep, shown.last?.isEmpty == true { shown.removeLast() }
        lines += shown.map(Self.visible)
        lines.append("</terminal>")
        return lines.joined(separator: "\n")
    }

    /// Control characters never reach the request as such.
    private static func visible(_ line: String) -> String {
        String(String.UnicodeScalarView(line.unicodeScalars.map { TerminalCommandValidator.isControl($0) ? " " : $0 }))
    }

    private static func attribute(_ text: String) -> String {
        visible(text).replacingOccurrences(of: "\"", with: "'")
    }
}
