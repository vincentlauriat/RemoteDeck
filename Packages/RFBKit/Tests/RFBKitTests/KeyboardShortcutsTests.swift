import Testing
@testable import RFBKit

private func down(_ key: UInt32) -> ClientMessage { .keyEvent(down: true, key: key) }
private func up(_ key: UInt32) -> ClientMessage { .keyEvent(down: false, key: key) }

/// `NSEvent.ModifierFlags` bits AppKit adds that a shortcut must ignore.
private let numericPad = MacModifierFlags(rawValue: 1 << 21)
private let function = MacModifierFlags(rawValue: 1 << 23)

struct ReleaseShortcutTests {
    static let r: UInt16 = 0x0F

    @Test func controlOptionCommandRMatches() {
        #expect(ReleaseShortcut.matches(keyCode: Self.r, flags: [.control, .option, .command]))
        // Caps Lock and the left/right device bits do not matter.
        #expect(ReleaseShortcut.matches(keyCode: Self.r, flags: [.control, .option, .command, .capsLock, .leftControl,
                                                                  .leftOption, .rightCommand]))
    }

    @Test func extraOrMissingModifiersAreRejected() {
        #expect(!ReleaseShortcut.matches(keyCode: Self.r, flags: [.control, .option, .command, .shift]))
        #expect(!ReleaseShortcut.matches(keyCode: Self.r, flags: [.option, .command]))
        #expect(!ReleaseShortcut.matches(keyCode: Self.r, flags: [.control, .command]))
        #expect(!ReleaseShortcut.matches(keyCode: Self.r, flags: [.control, .option]))
        #expect(!ReleaseShortcut.matches(keyCode: Self.r, flags: []))
    }

    /// Key code, not character: AZERTY's R key (same place, types `r` or `®`) matches; Dvorak's `r`,
    /// typed by the key at QWERTY's O (kVK_ANSI_O), does not.
    @Test func matchesThePhysicalKeyWhateverTheLayout() {
        let flags: MacModifierFlags = [.control, .option, .command]
        #expect(InputTranslator.isReleaseShortcut(KeyInput(keyCode: Self.r, characters: "®", charactersIgnoringModifiers: "r",
                                                           modifierFlags: flags)))
        #expect(!InputTranslator.isReleaseShortcut(KeyInput(keyCode: 0x1F, characters: "r", modifierFlags: flags)))
    }
}

struct LocalShortcutTests {
    @Test func commandDigitsSwitchTabs() {
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (index, keyCode) in digits.enumerated() {
            #expect(LocalShortcut.matching(keyCode: keyCode, flags: [.command, .leftCommand]) == .switchTab(index + 1))
        }
        // With Caps Lock on, and on AZERTY where the same keys type & é " ' ( without Shift.
        #expect(LocalShortcut.matching(keyCode: 0x12, flags: [.command, .capsLock]) == .switchTab(1))
    }

    @Test func everythingElseGoesToTheRemote() {
        #expect(LocalShortcut.matching(keyCode: 0x12, flags: []) == nil)                       // 1
        #expect(LocalShortcut.matching(keyCode: 0x12, flags: [.command, .shift]) == nil)       // ⌘⇧1
        #expect(LocalShortcut.matching(keyCode: 0x12, flags: [.command, .option]) == nil)
        #expect(LocalShortcut.matching(keyCode: 0x1D, flags: .command) == nil)                 // ⌘0
        #expect(LocalShortcut.matching(keyCode: 0x53, flags: [.command, numericPad]) == nil)  // ⌘ keypad 1
        for keyCode: UInt16 in [0x0D, 0x0C, 0x28, 0x09] {                                      // ⌘W ⌘Q ⌘K ⌘V
            #expect(LocalShortcut.matching(keyCode: keyCode, flags: .command) == nil)
        }
    }
}

struct SystemShortcutTests {
    @Test(arguments: [
        (UInt16(0x30), MacModifierFlags.command), (0x30, [.command, .shift]), (0x31, .command), (0x31, [.command, .option]),
        (0x31, .control), (0x31, [.control, .option]),
        (0x7E, .control), (0x7D, .control), (0x7B, .control), (0x7C, .control), (0x7E, [.control, .shift]),
        (0x14, [.command, .shift]), (0x15, [.command, .shift]), (0x17, [.command, .shift]),
        (0x14, [.command, .shift, .control]), (0x15, [.command, .shift, .control]), (0x02, [.command, .option]),
    ] as [(UInt16, MacModifierFlags)])
    func systemCombosAreTaken(keyCode: UInt16, flags: MacModifierFlags) {
        #expect(SystemShortcut.matches(keyCode: keyCode, flags: flags))
    }

    /// Arrow keys carry the numeric-pad and function bits; Caps Lock may be on.
    @Test func ignoresNumericPadFunctionAndCapsLock() {
        #expect(SystemShortcut.matches(keyCode: 0x7E, flags: [.control, .leftControl, numericPad, function]))
        #expect(SystemShortcut.matches(keyCode: 0x30, flags: [.command, .capsLock]))
    }

    @Test func otherCombosAreNotTaken() {
        #expect(!SystemShortcut.matches(keyCode: 0x30, flags: []))                                // Tab
        #expect(!SystemShortcut.matches(keyCode: 0x30, flags: [.command, .option]))               // ⌘⌥Tab
        #expect(!SystemShortcut.matches(keyCode: 0x35, flags: [.command, .option]))               // Force Quit stays local
        #expect(!SystemShortcut.matches(keyCode: 0x0D, flags: .command))                          // ⌘W
        #expect(!SystemShortcut.matches(keyCode: 0x7E, flags: [.command, numericPad, function]))  // ⌘↑
        #expect(!SystemShortcut.matches(keyCode: 0x14, flags: .command))                          // ⌘3
        #expect(!ReleaseShortcut.matches(keyCode: 0x30, flags: .command))
        #expect(!SystemShortcut.matches(keyCode: ReleaseShortcut.combo.keyCode, flags: ReleaseShortcut.combo.modifiers))
    }

    /// The tap delivers ⌘Tab before the app has dequeued ⌘'s flagsChanged: ⌘ is pressed from the
    /// flags first, the late flagsChanged is a no-op, and the remote ends with nothing held.
    @Test func comboKeyBeforeItsModifierFlagsChanged() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        let cmd: MacModifierFlags = [.command, .leftCommand]
        #expect(translator.keyDown(KeyInput(keyCode: 0x30, modifierFlags: cmd)) == [down(Keysym.altL), down(Keysym.tab)])
        #expect(translator.flagsChanged(KeyInput(keyCode: 0x37, modifierFlags: cmd)) == [])
        #expect(translator.keyUp(KeyInput(keyCode: 0x30, modifierFlags: cmd)) == [up(Keysym.tab)])
        #expect(translator.flagsChanged(KeyInput(keyCode: 0x37, modifierFlags: [])) == [up(Keysym.altL)])
        #expect(translator.heldKeysyms.isEmpty)
    }
}
