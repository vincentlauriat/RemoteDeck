import Foundation

/// Why a proposed `run_command` is answered with a refusal at once, never proposed (spec › Command
/// validation). Confirm is the security boundary; this only keeps out what can never be one line
/// typed at a visible prompt.
enum CommandRefusal: Equatable, Sendable {
    case empty
    case tooLong
    /// A line end, ESC, DEL or another C0/C1 control character.
    case controlCharacter
    /// The alternate screen is active: `send_keys` must leave the program first.
    case fullScreenProgram
    case passwordPrompt
    case notConnected

    /// The tool result text (English, part of the conversation).
    var resultText: String {
        switch self {
        case .empty: "Refused: the command is empty."
        case .tooLong: "Refused: the command is longer than \(TerminalCommandValidator.maxLength) characters."
        case .controlCharacter: "Refused: the command must be one line without control characters (no line breaks, tabs or escape sequences)."
        case .fullScreenProgram: "Refused: a full-screen program is running; use send_keys to leave it first."
        case .passwordPrompt: "Refused: a password prompt is showing; the user must type it."
        case .notConnected: "Refused: the shell is not connected."
        }
    }
}

enum TerminalCommandValidator {
    static let maxLength = 4000

    /// C0 (U+0000–U+001F), DEL (U+007F) and C1 (U+0080–U+009F).
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// A reading aid only (the panel's "Destructive" badge), never a security check: Confirm is the
    /// boundary. Patterns that delete, format, overwrite a disk or stop the machine.
    static func looksDestructive(_ command: String) -> Bool {
        let text = " " + command.lowercased() + " "
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
        func program(_ name: String) -> Bool {
            // A program in command position, also after sudo.
            for (index, word) in words.enumerated() where word == name || word.hasPrefix(name + ".") {
                if index == 0 || ["sudo", "doas", "exec", "nohup"].contains(words[index - 1]) { return true }
            }
            return false
        }
        if program("rm"), words.contains(where: { $0.hasPrefix("-") && $0.contains("r") && $0.contains("f") }) { return true }
        if program("mkfs") || program("shutdown") || program("reboot") || program("halt") || program("poweroff")
            || program("wipefs") { return true }
        if program("dd"), words.contains(where: { $0.hasPrefix("of=") }) { return true }
        return text.contains("> /dev/sd") || text.contains(">/dev/sd") || text.contains("> /dev/nvme")
    }

    static func validate(_ command: String, snapshot: TerminalSnapshot?, connected: Bool) -> CommandRefusal? {
        guard connected else { return .notConnected }
        guard !command.isEmpty else { return .empty }
        guard command.count <= maxLength else { return .tooLong }
        guard !command.unicodeScalars.contains(where: isControl) else { return .controlCharacter }
        if let snapshot {
            if snapshot.isAlternateScreen { return .fullScreenProgram }
            if PasswordPromptDetector.isShowing(in: snapshot) { return .passwordPrompt }
        }
        return nil
    }
}

/// A password, passphrase or PIN prompt on the cursor's row (spec › Password prompts): the assistant
/// never types there; the user does.
enum PasswordPromptDetector {
    static func isShowing(in snapshot: TerminalSnapshot) -> Bool {
        guard let line = snapshot.promptLine, snapshot.cursorIsAtLineEnd else { return false }
        return isPrompt(line)
    }

    static func isPrompt(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasSuffix(":") else { return false }
        return text.hasSuffix("password:") || text.contains("password for ") || text.contains("passphrase")
            || text.contains("enter pin") || text.hasSuffix("pin:")
    }
}

/// The keys `send_keys` may press (the tool's enum).
enum TerminalNamedKey: String, CaseIterable, Codable, Sendable {
    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case escape
    case q
    case `return`
    case tab
    case up, down, left, right
    case pageUp = "page_up"
    case pageDown = "page_down"

    /// The row's label ("Ctrl-C", "q").
    var displayName: String {
        switch self {
        case .ctrlC: "Ctrl-C"
        case .ctrlD: "Ctrl-D"
        case .escape: "Esc"
        case .q: "q"
        case .return: "Return"
        case .tab: "Tab"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        }
    }

    /// The legacy encoding; arrows follow cursor-key mode (DECCKM, `ESC O A` in vim or less).
    func bytes(cursorKeysApplication: Bool = false) -> Data {
        let arrow = cursorKeysApplication ? "\u{1B}O" : "\u{1B}["
        let text = switch self {
        case .ctrlC: "\u{03}"
        case .ctrlD: "\u{04}"
        case .escape: "\u{1B}"
        case .q: "q"
        case .return: "\r"
        case .tab: "\t"
        case .up: arrow + "A"
        case .down: arrow + "B"
        case .right: arrow + "C"
        case .left: arrow + "D"
        case .pageUp: "\u{1B}[5~"
        case .pageDown: "\u{1B}[6~"
        }
        return Data(text.utf8)
    }
}
