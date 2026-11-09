import GhosttyVt

/// A physical key, as the key encoder names it (`GhosttyKey`, the W3C `KeyboardEvent.code` set):
/// layout-independent, so AZERTY's "A" key is `.q`. The text the layout produces travels separately
/// (`VTKeyEvent.text`, `unshifted`).
public struct VTKey: Hashable, Sendable {
    let raw: GhosttyKey

    init(_ raw: GhosttyKey) { self.raw = raw }

    public static let unidentified = VTKey(GHOSTTY_KEY_UNIDENTIFIED)
    public static let a = VTKey(GHOSTTY_KEY_A)
    public static let b = VTKey(GHOSTTY_KEY_B)
    public static let c = VTKey(GHOSTTY_KEY_C)
    public static let l = VTKey(GHOSTTY_KEY_L)
    public static let q = VTKey(GHOSTTY_KEY_Q)
    public static let digit5 = VTKey(GHOSTTY_KEY_DIGIT_5)
    public static let enter = VTKey(GHOSTTY_KEY_ENTER)
    public static let escape = VTKey(GHOSTTY_KEY_ESCAPE)
    public static let backspace = VTKey(GHOSTTY_KEY_BACKSPACE)
    public static let tab = VTKey(GHOSTTY_KEY_TAB)
    public static let arrowUp = VTKey(GHOSTTY_KEY_ARROW_UP)
    public static let arrowDown = VTKey(GHOSTTY_KEY_ARROW_DOWN)
    public static let arrowLeft = VTKey(GHOSTTY_KEY_ARROW_LEFT)
    public static let arrowRight = VTKey(GHOSTTY_KEY_ARROW_RIGHT)

    /// The physical key for a Mac virtual key code (`kVK_*`, `NSEvent.keyCode`). Modifier keys and
    /// unknown codes give `.unidentified`.
    public static func fromMacKeyCode(_ code: UInt16) -> VTKey {
        VTKey(macKeyCodes[code] ?? GHOSTTY_KEY_UNIDENTIFIED)
    }

    /// The key the encoder should see: the layout's key when its unshifted character is an ASCII
    /// letter, digit or punctuation key (so ⌃ follows the layout, as in Ghostty: AZERTY's physical Q
    /// types "a" and ⌃ on it is ⌃A), the physical key otherwise (arrows, F-keys, keys whose character
    /// is not ASCII).
    public static func logical(physical: VTKey, unshifted: Unicode.Scalar?) -> VTKey {
        guard let unshifted, let key = asciiKeys[Character(unshifted).lowercased().first ?? " "] else { return physical }
        return VTKey(key)
    }

    private static let asciiKeys: [Character: GhosttyKey] = {
        var keys: [Character: GhosttyKey] = [:]
        let letters: [GhosttyKey] = [GHOSTTY_KEY_A, GHOSTTY_KEY_B, GHOSTTY_KEY_C, GHOSTTY_KEY_D, GHOSTTY_KEY_E,
            GHOSTTY_KEY_F, GHOSTTY_KEY_G, GHOSTTY_KEY_H, GHOSTTY_KEY_I, GHOSTTY_KEY_J, GHOSTTY_KEY_K, GHOSTTY_KEY_L,
            GHOSTTY_KEY_M, GHOSTTY_KEY_N, GHOSTTY_KEY_O, GHOSTTY_KEY_P, GHOSTTY_KEY_Q, GHOSTTY_KEY_R, GHOSTTY_KEY_S,
            GHOSTTY_KEY_T, GHOSTTY_KEY_U, GHOSTTY_KEY_V, GHOSTTY_KEY_W, GHOSTTY_KEY_X, GHOSTTY_KEY_Y, GHOSTTY_KEY_Z]
        for (offset, key) in letters.enumerated() { keys[Character(Unicode.Scalar(UInt8(97 + offset)))] = key }
        let digits: [GhosttyKey] = [GHOSTTY_KEY_DIGIT_0, GHOSTTY_KEY_DIGIT_1, GHOSTTY_KEY_DIGIT_2, GHOSTTY_KEY_DIGIT_3,
            GHOSTTY_KEY_DIGIT_4, GHOSTTY_KEY_DIGIT_5, GHOSTTY_KEY_DIGIT_6, GHOSTTY_KEY_DIGIT_7, GHOSTTY_KEY_DIGIT_8,
            GHOSTTY_KEY_DIGIT_9]
        for (offset, key) in digits.enumerated() { keys[Character(Unicode.Scalar(UInt8(48 + offset)))] = key }
        let punctuation: [Character: GhosttyKey] = ["`": GHOSTTY_KEY_BACKQUOTE, "-": GHOSTTY_KEY_MINUS,
            "=": GHOSTTY_KEY_EQUAL, "[": GHOSTTY_KEY_BRACKET_LEFT, "]": GHOSTTY_KEY_BRACKET_RIGHT,
            "\\": GHOSTTY_KEY_BACKSLASH, ";": GHOSTTY_KEY_SEMICOLON, "'": GHOSTTY_KEY_QUOTE, ",": GHOSTTY_KEY_COMMA,
            ".": GHOSTTY_KEY_PERIOD, "/": GHOSTTY_KEY_SLASH, " ": GHOSTTY_KEY_SPACE]
        keys.merge(punctuation) { a, _ in a }
        return keys
    }()

    /// `kVK_*` (Carbon Events.h) → W3C code, as Ghostty's own macOS table (`keycodes.zig`).
    private static let macKeyCodes: [UInt16: GhosttyKey] = [
        0x00: GHOSTTY_KEY_A, 0x01: GHOSTTY_KEY_S, 0x02: GHOSTTY_KEY_D, 0x03: GHOSTTY_KEY_F,
        0x04: GHOSTTY_KEY_H, 0x05: GHOSTTY_KEY_G, 0x06: GHOSTTY_KEY_Z, 0x07: GHOSTTY_KEY_X,
        0x08: GHOSTTY_KEY_C, 0x09: GHOSTTY_KEY_V, 0x0A: GHOSTTY_KEY_INTL_BACKSLASH, 0x0B: GHOSTTY_KEY_B,
        0x0C: GHOSTTY_KEY_Q, 0x0D: GHOSTTY_KEY_W, 0x0E: GHOSTTY_KEY_E, 0x0F: GHOSTTY_KEY_R,
        0x10: GHOSTTY_KEY_Y, 0x11: GHOSTTY_KEY_T, 0x12: GHOSTTY_KEY_DIGIT_1, 0x13: GHOSTTY_KEY_DIGIT_2,
        0x14: GHOSTTY_KEY_DIGIT_3, 0x15: GHOSTTY_KEY_DIGIT_4, 0x16: GHOSTTY_KEY_DIGIT_6, 0x17: GHOSTTY_KEY_DIGIT_5,
        0x18: GHOSTTY_KEY_EQUAL, 0x19: GHOSTTY_KEY_DIGIT_9, 0x1A: GHOSTTY_KEY_DIGIT_7, 0x1B: GHOSTTY_KEY_MINUS,
        0x1C: GHOSTTY_KEY_DIGIT_8, 0x1D: GHOSTTY_KEY_DIGIT_0, 0x1E: GHOSTTY_KEY_BRACKET_RIGHT, 0x1F: GHOSTTY_KEY_O,
        0x20: GHOSTTY_KEY_U, 0x21: GHOSTTY_KEY_BRACKET_LEFT, 0x22: GHOSTTY_KEY_I, 0x23: GHOSTTY_KEY_P,
        0x24: GHOSTTY_KEY_ENTER, 0x25: GHOSTTY_KEY_L, 0x26: GHOSTTY_KEY_J, 0x27: GHOSTTY_KEY_QUOTE,
        0x28: GHOSTTY_KEY_K, 0x29: GHOSTTY_KEY_SEMICOLON, 0x2A: GHOSTTY_KEY_BACKSLASH, 0x2B: GHOSTTY_KEY_COMMA,
        0x2C: GHOSTTY_KEY_SLASH, 0x2D: GHOSTTY_KEY_N, 0x2E: GHOSTTY_KEY_M, 0x2F: GHOSTTY_KEY_PERIOD,
        0x30: GHOSTTY_KEY_TAB, 0x31: GHOSTTY_KEY_SPACE, 0x32: GHOSTTY_KEY_BACKQUOTE, 0x33: GHOSTTY_KEY_BACKSPACE,
        0x35: GHOSTTY_KEY_ESCAPE,
        0x40: GHOSTTY_KEY_F17, 0x41: GHOSTTY_KEY_NUMPAD_DECIMAL, 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x45: GHOSTTY_KEY_NUMPAD_ADD, 0x47: GHOSTTY_KEY_NUM_LOCK, 0x4B: GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x4C: GHOSTTY_KEY_NUMPAD_ENTER, 0x4E: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x4F: GHOSTTY_KEY_F18,
        0x50: GHOSTTY_KEY_F19, 0x51: GHOSTTY_KEY_NUMPAD_EQUAL,
        0x52: GHOSTTY_KEY_NUMPAD_0, 0x53: GHOSTTY_KEY_NUMPAD_1, 0x54: GHOSTTY_KEY_NUMPAD_2, 0x55: GHOSTTY_KEY_NUMPAD_3,
        0x56: GHOSTTY_KEY_NUMPAD_4, 0x57: GHOSTTY_KEY_NUMPAD_5, 0x58: GHOSTTY_KEY_NUMPAD_6, 0x59: GHOSTTY_KEY_NUMPAD_7,
        0x5A: GHOSTTY_KEY_F20, 0x5B: GHOSTTY_KEY_NUMPAD_8, 0x5C: GHOSTTY_KEY_NUMPAD_9,
        0x5D: GHOSTTY_KEY_INTL_YEN, 0x5E: GHOSTTY_KEY_INTL_RO, 0x5F: GHOSTTY_KEY_NUMPAD_COMMA,
        0x60: GHOSTTY_KEY_F5, 0x61: GHOSTTY_KEY_F6, 0x62: GHOSTTY_KEY_F7, 0x63: GHOSTTY_KEY_F3,
        0x64: GHOSTTY_KEY_F8, 0x65: GHOSTTY_KEY_F9, 0x67: GHOSTTY_KEY_F11, 0x69: GHOSTTY_KEY_F13,
        0x6A: GHOSTTY_KEY_F16, 0x6B: GHOSTTY_KEY_F14, 0x6D: GHOSTTY_KEY_F10, 0x6E: GHOSTTY_KEY_CONTEXT_MENU,
        0x6F: GHOSTTY_KEY_F12, 0x71: GHOSTTY_KEY_F15, 0x72: GHOSTTY_KEY_INSERT, 0x73: GHOSTTY_KEY_HOME,
        0x74: GHOSTTY_KEY_PAGE_UP, 0x75: GHOSTTY_KEY_DELETE, 0x76: GHOSTTY_KEY_F4, 0x77: GHOSTTY_KEY_END,
        0x78: GHOSTTY_KEY_F2, 0x79: GHOSTTY_KEY_PAGE_DOWN, 0x7A: GHOSTTY_KEY_F1,
        0x7B: GHOSTTY_KEY_ARROW_LEFT, 0x7C: GHOSTTY_KEY_ARROW_RIGHT, 0x7D: GHOSTTY_KEY_ARROW_DOWN,
        0x7E: GHOSTTY_KEY_ARROW_UP,
    ]
}
