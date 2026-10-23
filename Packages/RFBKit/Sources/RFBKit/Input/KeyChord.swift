import Foundation

/// A key or `+`-joined key combination by name, as the computer use toolset's `key` and `hold_key`
/// members (and the modifier `text` of clicks and scrolls) give it: `"Return"`, `"ctrl+s"`,
/// `"alt+Tab"`, `"ctrl+shift"`. Names are X11 keysym names (xdotool style, as Anthropic's reference
/// implementation passes them to `xdotool key`), matched without case, plus a few common aliases
/// (`Enter`, `Esc`, `cmd`…); any other single character is the key that types it.
///
/// `super` is the Mac's ⌘ and `alt` its ⌥, sent as the machine's `ModifierProfile` sends them, so
/// `super+c` copies on a Mac (⌘C) and is Super+C on X11.
public struct KeyChord: Sendable, Equatable {
    public enum ParseError: Error, Sendable, Equatable {
        case empty
        /// A name that is no key, quoted as given.
        case unknownKey(String)
        /// A key where only modifiers are allowed (the modifier `text` of a click).
        case notAModifier(String)
    }

    /// Keysyms in press order; released in reverse.
    public let keysyms: [UInt32]

    public init(keysyms: [UInt32]) {
        self.keysyms = keysyms
    }

    public static func parse(_ text: String, profile: ModifierProfile) throws(ParseError) -> KeyChord {
        let names = try split(text)
        let hasModifier = names.contains { modifier($0, profile: profile) != nil }
        var keysyms: [UInt32] = []
        for name in names {
            // With a modifier a letter is the key, not the character: `ctrl+C` is ⌃C, as `ctrl+c`
            // (an uppercase keysym would also need Shift on the remote).
            let keyName = hasModifier && name.count == 1 && name.first?.isLetter == true ? name.lowercased() : name
            guard let keysym = modifier(name, profile: profile) ?? key(keyName) else { throw .unknownKey(name) }
            keysyms.append(keysym)
        }
        return KeyChord(keysyms: keysyms)
    }

    /// Modifiers only (`shift`, `ctrl+shift`…); an empty text is no modifier.
    public static func parseModifiers(_ text: String, profile: ModifierProfile) throws(ParseError) -> KeyChord {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return KeyChord(keysyms: []) }
        var keysyms: [UInt32] = []
        for name in try split(text) {
            guard let keysym = modifier(name, profile: profile) else {
                throw key(name) == nil ? .unknownKey(name) : .notAModifier(name)
            }
            keysyms.append(keysym)
        }
        return KeyChord(keysyms: keysyms)
    }

    /// Every key down in order, then up in reverse: nothing stays held.
    public var pressAndRelease: [ClientMessage] {
        press + release
    }

    public var press: [ClientMessage] { keysyms.map { .keyEvent(down: true, key: $0) } }
    public var release: [ClientMessage] { keysyms.reversed().map { .keyEvent(down: false, key: $0) } }

    private static func split(_ text: String) throws(ParseError) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .empty }
        if trimmed == "+" { return ["+"] }
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++": the key is the plus sign.
        if trimmed.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard !parts.contains(where: \.isEmpty) else { throw .unknownKey(text) }
        return parts
    }

    private static func modifier(_ name: String, profile: ModifierProfile) -> UInt32? {
        switch name.lowercased() {
        case "shift", "shift_l": Keysym.shiftL
        case "shift_r": Keysym.shiftR
        case "ctrl", "control", "control_l", "ctrl_l": Keysym.controlL
        case "control_r", "ctrl_r": Keysym.controlR
        case "alt", "alt_l", "option", "opt": profile.option(right: false)
        case "alt_r": profile.option(right: true)
        case "super", "super_l", "cmd", "command", "win", "windows": profile.command(right: false)
        case "super_r": profile.command(right: true)
        default: nil
        }
    }

    /// A non-modifier key: a name, else the one character it is.
    public static func key(_ name: String) -> UInt32? {
        if let keysym = named[name.lowercased()] { return keysym }
        if name.count > 1, name.first == "F" || name.first == "f", let number = Int(name.dropFirst()),
           (1...35).contains(number) {
            return Keysym.f(number)
        }
        let scalars = name.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        return Keysym.forCharacter(scalar)
    }

    /// Lowercased X11 keysym names and aliases.
    private static let named: [String: UInt32] = [
        "return": Keysym.return, "enter": Keysym.return, "kp_enter": Keysym.kpEnter,
        "tab": Keysym.tab, "escape": Keysym.escape, "esc": Keysym.escape,
        "backspace": Keysym.backSpace, "delete": Keysym.delete, "del": Keysym.delete,
        "insert": 0xFF63, "home": Keysym.home, "end": Keysym.end,
        "page_up": Keysym.pageUp, "pageup": Keysym.pageUp, "prior": Keysym.pageUp,
        "page_down": Keysym.pageDown, "pagedown": Keysym.pageDown, "next": Keysym.pageDown,
        "up": Keysym.up, "down": Keysym.down, "left": Keysym.left, "right": Keysym.right,
        "space": Keysym.space, "menu": Keysym.menu, "help": Keysym.help,
        "caps_lock": Keysym.capsLock, "num_lock": Keysym.numLock, "print": 0xFF61, "pause": 0xFF13,
        "scroll_lock": 0xFF14,
        "meta_l": Keysym.metaL, "meta_r": Keysym.metaR,
        "minus": 0x2D, "plus": 0x2B, "equal": 0x3D, "period": 0x2E, "comma": 0x2C, "slash": 0x2F,
        "backslash": 0x5C, "semicolon": 0x3B, "colon": 0x3A, "apostrophe": 0x27, "quotedbl": 0x22,
        "grave": 0x60, "asciitilde": 0x7E, "asciicircum": 0x5E, "bracketleft": 0x5B, "bracketright": 0x5D,
        "braceleft": 0x7B, "braceright": 0x7D, "parenleft": 0x28, "parenright": 0x29, "less": 0x3C,
        "greater": 0x3E, "bar": 0x7C, "underscore": 0x5F, "asterisk": 0x2A, "ampersand": 0x26, "at": 0x40,
        "numbersign": 0x23, "dollar": 0x24, "percent": 0x25, "exclam": 0x21, "question": 0x3F,
    ]
}

extension KeyChord {
    /// The keysym sequence that types `text`, one press + release per character: newline is Return,
    /// tab is Tab, every other character its own keysym (`Keysym.forCharacter`). `nil` when a
    /// character has no keysym (a control character).
    public static func typing(_ text: String) -> [ClientMessage]? {
        var messages: [ClientMessage] = []
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            let keysym: UInt32?
            switch scalar {
            case "\n", "\r": keysym = Keysym.return
            case "\t": keysym = Keysym.tab
            default: keysym = Keysym.forCharacter(scalar)
            }
            guard let keysym else { return nil }
            messages += [.keyEvent(down: true, key: keysym), .keyEvent(down: false, key: keysym)]
        }
        return messages
    }
}
