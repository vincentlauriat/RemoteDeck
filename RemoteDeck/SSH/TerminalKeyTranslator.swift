import AppKit
import GhosttyEngine

/// What one key event gave, read from the `NSEvent` and from the input context (`interpretKeyEvents`).
/// A plain value so the translation is tested without a window or a keyboard layout.
struct TerminalKeyInput: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var isRepeat = false
    var isRelease = false
    /// The layout's character for this key with ⇧ only (`characters(byApplyingModifiers:)`), for
    /// chords that bypass composition (⌃, ⌥ as Meta).
    var shiftedCharacters: String
    /// The layout's character with no modifier (AZERTY's physical Q: "a").
    var unshiftedCharacters: String
    /// Text `insertText` received while the event was interpreted (⌥ compositions, dead keys).
    var composed: [String] = []
    var hadMarkedText = false
    var hasMarkedText = false
    /// Settings › "Use ⌥ as Meta".
    var optionAsMeta = false
}

/// Turns a Mac key event into the key events libghostty-vt's encoder takes (AppFlow › Terminal tab ›
/// Type). ⌥ composes the layout's characters (AZERTY ⌥⇧L = |, ⌥( = {) unless "Use ⌥ as Meta" is on;
/// dead keys and input methods go through `interpretKeyEvents` and arrive in `composed`; keys that
/// produce no text (arrows, Return, ⌃ chords) are encoded from the key itself.
enum TerminalKeyTranslator {
    /// Whether the event should be passed through `interpretKeyEvents` first (composition): not for
    /// ⌃ chords (no marked text pending) nor for ⌥ chords when ⌥ is Meta, nor for releases.
    static func usesComposition(modifiers: NSEvent.ModifierFlags, optionAsMeta: Bool, hasMarkedText: Bool,
                                isRelease: Bool) -> Bool {
        if isRelease { return false }
        if hasMarkedText { return true }
        if modifiers.contains(.control) || modifiers.contains(.command) { return false }
        if optionAsMeta, modifiers.contains(.option) { return false }
        return true
    }

    static func events(for input: TerminalKeyInput) -> [VTKeyEvent] {
        let mods = vtMods(input.modifiers)
        let physical = VTKey.fromMacKeyCode(input.keyCode)
        let unshifted = input.unshiftedCharacters.unicodeScalars.first.flatMap { isText($0) ? $0 : nil }
        let key = VTKey.logical(physical: physical, unshifted: unshifted)
        let action: VTKeyEvent.Action = input.isRelease ? .release : (input.isRepeat ? .repeat : .press)

        if !input.composed.isEmpty {
            // The layout produced text (with ⇧ / ⌥ as part of it): send that text.
            let consumed = mods.intersection([.shift, .alt, .shiftRight, .altRight])
            return input.composed.filter { !$0.isEmpty }.map { text in
                VTKeyEvent(key: key, action: action, mods: mods, consumedMods: consumed,
                           text: sanitized(text), unshifted: unshifted)
            }
        }
        // Mid-composition (a dead key waiting for its letter), or a composition just cancelled: nothing.
        if input.hasMarkedText || input.hadMarkedText { return [] }
        let text = input.isRelease ? "" : sanitized(input.shiftedCharacters)
        return [VTKeyEvent(key: key, action: action, mods: mods,
                           consumedMods: text.isEmpty ? [] : mods.intersection([.shift, .shiftRight]),
                           text: text, unshifted: unshifted)]
    }

    /// Text that is not a control character nor in the Mac's function-key range (U+F700…U+F8FF), which
    /// the encoder must not receive.
    static func sanitized(_ text: String) -> String {
        text.unicodeScalars.allSatisfy(isText) ? text : ""
    }

    private static func isText(_ scalar: Unicode.Scalar) -> Bool {
        !(scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value))
    }

    /// `NSEvent.ModifierFlags` → the encoder's modifiers, with the right-hand side bits
    /// (`NX_DEVICER*KEYMASK`) when only the right key is held.
    static func vtMods(_ flags: NSEvent.ModifierFlags) -> VTMods {
        var mods: VTMods = []
        let raw = flags.rawValue
        if flags.contains(.shift) {
            mods.insert(.shift)
            if raw & 0x04 != 0, raw & 0x02 == 0 { mods.insert(.shiftRight) }
        }
        if flags.contains(.control) {
            mods.insert(.control)
            if raw & 0x2000 != 0, raw & 0x01 == 0 { mods.insert(.controlRight) }
        }
        if flags.contains(.option) {
            mods.insert(.alt)
            if raw & 0x40 != 0, raw & 0x20 == 0 { mods.insert(.altRight) }
        }
        if flags.contains(.command) {
            mods.insert(.command)
            if raw & 0x10 != 0, raw & 0x08 == 0 { mods.insert(.commandRight) }
        }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        return mods
    }
}
