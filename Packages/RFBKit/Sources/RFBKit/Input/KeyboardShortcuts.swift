/// The key combos the Session Window treats specially while the keyboard is captured (AppFlow ›
/// Navigation rules). All of them match on the virtual key code (`kVK_*`, the physical key) and on the
/// exact set of ⇧⌃⌥⌘, so they work with any layout (AZERTY included) and ignore Caps Lock and the
/// numeric-pad, function and left/right device bits that AppKit adds to some keys.
public struct KeyCombo: Sendable, Hashable {
    public var keyCode: UInt16
    /// Exactly these of ⇧⌃⌥⌘ must be held.
    public var modifiers: MacModifierFlags

    public init(keyCode: UInt16, modifiers: MacModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.shortcutModifiers)
    }

    public func matches(keyCode: UInt16, flags: MacModifierFlags) -> Bool {
        keyCode == self.keyCode && flags.intersection(.shortcutModifiers) == modifiers
    }
}

extension MacModifierFlags {
    /// The modifiers a shortcut is defined by; Caps Lock, numeric pad, function and device bits are not.
    public static let shortcutModifiers: MacModifierFlags = [.shift, .control, .option, .command]
}

/// ⌃⌥⌘R: releases the keyboard capture. Never sent to the remote. (Not the Force Quit combo, which
/// macOS keeps for itself and never delivers to the app.)
public enum ReleaseShortcut {
    public static let combo = KeyCombo(keyCode: 0x0F, modifiers: [.control, .option, .command])   // kVK_ANSI_R

    public static func matches(keyCode: UInt16, flags: MacModifierFlags) -> Bool {
        combo.matches(keyCode: keyCode, flags: flags)
    }
}

/// Shortcuts that stay local while the keyboard is captured: AppKit handles them (menus,
/// `performKeyEquivalent`) and the remote never sees the key. Everything else, ⌘W, ⌘Q, ⌘K, ⌘V
/// included, goes to the remote. Extend the allow-list here.
public enum LocalShortcut: Sendable, Equatable {
    /// ⌘1…⌘9: show session tab 1…9. The top-row digit keys, so AZERTY's ⌘& ⌘é ⌘" … match too.
    case switchTab(Int)

    /// kVK_ANSI_1 … kVK_ANSI_9 (not in key-code order on the keyboard).
    static let digitKeyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    public static func matching(keyCode: UInt16, flags: MacModifierFlags) -> LocalShortcut? {
        guard flags.intersection(.shortcutModifiers) == .command,
              let index = digitKeyCodes.firstIndex(of: keyCode) else { return nil }
        return .switchTab(index + 1)
    }
}

/// Combos macOS takes before the frontmost app sees them (Dock, Spotlight, WindowServer symbolic
/// hotkeys). While the keyboard is captured and the system-shortcut event tap is on, they are taken
/// from the tap and sent to the remote instead. Sources: Apple's "Mac keyboard shortcuts" support
/// article (support.apple.com/102650: ⌘Tab, ⌘Space, ⌥⌘Space, ⌃Space, ⌘⇧3/4/5, ⌃↑, ⌃↓, ⌥⌘D) and the
/// `com.apple.symbolichotkeys` entries read on the dev Mac (ids in comments; ⌃←/⌃→ and the ⇧ and ⌃
/// variants come from there only). ⌃Space/⌃⌥Space (60/61) were disabled on that Mac: taking them
/// is harmless where macOS would not, and needed where several input sources are on. Left out on
/// purpose: Force Quit (stays local as the way out of a hung app), F-key hotkeys (F11 Show Desktop,
/// ⌃F1…⌃F8 keyboard focus, brightness: the top row sends media keys by default), and ⌘`, ⌘⇧/, ⌃⌘Q,
/// ⌃⌘Space, which reach the app and so the local monitor already sends them.
public enum SystemShortcut {
    public static let combos: [KeyCombo] = [
        KeyCombo(keyCode: 0x30, modifiers: .command),                      // ⌘Tab app switcher (Dock)
        KeyCombo(keyCode: 0x30, modifiers: [.command, .shift]),            // ⌘⇧Tab
        KeyCombo(keyCode: 0x31, modifiers: .command),                      // ⌘Space Spotlight (64)
        KeyCombo(keyCode: 0x31, modifiers: [.command, .option]),           // ⌥⌘Space Finder search (65)
        KeyCombo(keyCode: 0x31, modifiers: .control),                      // ⌃Space previous input source (60)
        KeyCombo(keyCode: 0x31, modifiers: [.control, .option]),           // ⌃⌥Space next input source (61)
        KeyCombo(keyCode: 0x7E, modifiers: .control),                      // ⌃↑ Mission Control (32)
        KeyCombo(keyCode: 0x7E, modifiers: [.control, .shift]),            // ⌃⇧↑ (34)
        KeyCombo(keyCode: 0x7D, modifiers: .control),                      // ⌃↓ App Exposé (33)
        KeyCombo(keyCode: 0x7D, modifiers: [.control, .shift]),            // ⌃⇧↓ (35)
        KeyCombo(keyCode: 0x7B, modifiers: .control),                      // ⌃← space left (79)
        KeyCombo(keyCode: 0x7B, modifiers: [.control, .shift]),            // ⌃⇧← (80)
        KeyCombo(keyCode: 0x7C, modifiers: .control),                      // ⌃→ space right (81)
        KeyCombo(keyCode: 0x7C, modifiers: [.control, .shift]),            // ⌃⇧→ (82)
        KeyCombo(keyCode: 0x14, modifiers: [.command, .shift]),            // ⌘⇧3 screenshot (28)
        KeyCombo(keyCode: 0x14, modifiers: [.command, .shift, .control]),  // ⌃⌘⇧3 to clipboard (29)
        KeyCombo(keyCode: 0x15, modifiers: [.command, .shift]),            // ⌘⇧4 selection (30)
        KeyCombo(keyCode: 0x15, modifiers: [.command, .shift, .control]),  // ⌃⌘⇧4 to clipboard (31)
        KeyCombo(keyCode: 0x17, modifiers: [.command, .shift]),            // ⌘⇧5 Screenshot app (article)
        KeyCombo(keyCode: 0x02, modifiers: [.command, .option]),           // ⌥⌘D Dock hiding (52)
    ]

    public static func matches(keyCode: UInt16, flags: MacModifierFlags) -> Bool {
        combos.contains { $0.matches(keyCode: keyCode, flags: flags) }
    }
}
