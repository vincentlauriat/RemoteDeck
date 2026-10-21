import Testing
@testable import RFBKit

private func down(_ key: UInt32) -> ClientMessage { .keyEvent(down: true, key: key) }
private func up(_ key: UInt32) -> ClientMessage { .keyEvent(down: false, key: key) }
private func tap(_ key: UInt32) -> [ClientMessage] { [down(key), up(key)] }
private func pointer(_ mask: UInt8, _ x: UInt16, _ y: UInt16) -> ClientMessage {
    .pointerEvent(buttonMask: mask, x: x, y: y)
}

/// Virtual key codes used below (Carbon `kVK_*`).
private enum VK {
    static let ansiA: UInt16 = 0x00, ansiC: UInt16 = 0x08, isoSection: UInt16 = 0x0A, ansiQ: UInt16 = 0x0C
    static let ansiE: UInt16 = 0x0E, ansi2: UInt16 = 0x13, ansiLeftBracket: UInt16 = 0x21, ansiN: UInt16 = 0x2D
    static let returnKey: UInt16 = 0x24, tab: UInt16 = 0x30, space: UInt16 = 0x31, delete: UInt16 = 0x33
    static let escape: UInt16 = 0x35, forwardDelete: UInt16 = 0x75, home: UInt16 = 0x73, end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74, pageDown: UInt16 = 0x79, left: UInt16 = 0x7B, up: UInt16 = 0x7E
    static let f1: UInt16 = 0x7A, f12: UInt16 = 0x6F, f20: UInt16 = 0x5A, keypadEnter: UInt16 = 0x4C
    static let keypad7: UInt16 = 0x59, keypadPlus: UInt16 = 0x45
    static let command: UInt16 = 0x37, rightCommand: UInt16 = 0x36, shift: UInt16 = 0x38, rightShift: UInt16 = 0x3C
    static let option: UInt16 = 0x3A, rightOption: UInt16 = 0x3D, control: UInt16 = 0x3B, rightControl: UInt16 = 0x3E
    static let capsLock: UInt16 = 0x39
}

struct InputTranslatorKeyTests {
    @Test(arguments: [
        (VK.returnKey, Keysym.return), (VK.tab, Keysym.tab), (VK.space, Keysym.space), (VK.escape, Keysym.escape),
        (VK.delete, Keysym.backSpace), (VK.forwardDelete, Keysym.delete), (VK.home, Keysym.home),
        (VK.end, Keysym.end), (VK.pageUp, Keysym.pageUp), (VK.pageDown, Keysym.pageDown), (VK.left, Keysym.left),
        (VK.up, Keysym.up), (VK.f1, 0xFFBE), (VK.f12, 0xFFC9), (VK.f20, 0xFFD1), (VK.keypadEnter, 0xFF8D),
        (VK.keypad7, 0xFFB7), (VK.keypadPlus, 0xFFAB), (0x66, 0xFF30), (0x68, 0xFF27),   // JIS Eisu, Kana
    ] as [(UInt16, UInt32)])
    func nonPrintableKeysComeFromTheKeyCode(keyCode: UInt16, keysym: UInt32) {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        // AppKit's characters for these are control or private-use characters: never used.
        let key = KeyInput(keyCode: keyCode, characters: "\u{F704}")
        #expect(translator.keyDown(key) == [down(keysym)])
        #expect(translator.keyUp(key) == [up(keysym)])
    }

    @Test(arguments: [("a", 0x61), ("Z", 0x5A), ("7", 0x37), (";", 0x3B), ("~", 0x7E), ("ß", 0xDF),
                      ("€", 0x0100_20AC), ("œ", 0x0100_0153)] as [(String, UInt32)])
    func printableKeysSendTheirCharacter(text: String, keysym: UInt32) {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiA, characters: text)) == [down(keysym)])
    }

    /// French AZERTY (layout `com.apple.keylayout.French`, read with UCKeyTranslate): the physical key
    /// is not the character, so a key-code lookup would type the wrong thing.
    @Test(arguments: [
        (VK.ansiQ, "a", UInt32(0x61)),          // kVK_ANSI_Q types "a"
        (VK.ansiA, "q", UInt32(0x71)),          // kVK_ANSI_A types "q"
        (VK.ansi2, "é", UInt32(0xE9)),          // XK_eacute
        (VK.isoSection, "@", UInt32(0x40)),     // XK_at, unshifted
    ])
    func azertyTypesTheLocalCharacter(keyCode: UInt16, text: String, keysym: UInt32) {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        #expect(translator.keyDown(KeyInput(keyCode: keyCode, characters: text)) == [down(keysym)])
        #expect(translator.keyUp(KeyInput(keyCode: keyCode)) == [up(keysym)])
    }

    /// Pins the current policy for characters ⌥ picks (AZERTY ⌥( → "{", key 23): the character is
    /// sent while the Option keysym flagsChanged sent is still held. Whether hosts type "{" or see
    /// Alt+"{" is unverified (TRD › Input).
    @Test func azertyOptionCharacterIsSentWithOptionHeld() {
        var translator = InputTranslator(profile: .x11)
        var messages = translator.flagsChanged(KeyInput(keyCode: VK.option, modifierFlags: [.option, .leftOption]))
        messages += translator.keyDown(KeyInput(keyCode: 0x17, characters: "{", charactersIgnoringModifiers: "(",
                                                modifierFlags: [.option, .leftOption]))
        #expect(messages == [down(Keysym.altL), down(0x7B)])
    }

    @Test func deadKeyComposesLocally() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        // AZERTY: the ^ key (kVK_ANSI_LeftBracket) arms a dead key, then "e" types "ê".
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiLeftBracket, characters: "", charactersIgnoringModifiers: "^")) == [])
        #expect(translator.keyUp(KeyInput(keyCode: VK.ansiLeftBracket)) == [])
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiE, characters: "ê", charactersIgnoringModifiers: "e"))
                == [down(0xEA)])
        #expect(translator.keyUp(KeyInput(keyCode: VK.ansiE)) == [up(0xEA)])
        // ^ then a key it does not combine with: both characters, each pressed and released.
        _ = translator.keyDown(KeyInput(keyCode: VK.ansiLeftBracket, characters: ""))
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiN, characters: "^n")) == tap(0x5E) + tap(0x6E))
        #expect(translator.keyUp(KeyInput(keyCode: VK.ansiN)) == [])
    }

    @Test func commandCSendsTheProfileCommandKeysymThenC() {
        for (profile, command) in [(ModifierProfile.appleRemoteDesktop, Keysym.altL), (.x11, Keysym.superL)] {
            var translator = InputTranslator(profile: profile)
            var messages = translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: [.command, .leftCommand]))
            // ⌘ with ⌥ held types "ç" in `characters` on a US layout; the shortcut must stay "c".
            messages += translator.keyDown(KeyInput(keyCode: VK.ansiC, characters: "c", charactersIgnoringModifiers: "c",
                                                    modifierFlags: [.command, .leftCommand]))
            messages += translator.keyUp(KeyInput(keyCode: VK.ansiC, modifierFlags: [.command, .leftCommand]))
            messages += translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: []))
            #expect(messages == [down(command), down(0x63), up(0x63), up(command)], "\(profile)")
        }
    }

    @Test func commandOrControlUseTheCharacterWithShiftOnly() {
        // The modifiers are pressed by the flags sync (no flagsChanged here).
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        // ⌃C: `characters` is ETX (0x03).
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiC, characters: "\u{03}", charactersIgnoringModifiers: "c",
                                            modifierFlags: [.control])) == [down(Keysym.controlL), down(0x63)])
        _ = translator.keyUp(KeyInput(keyCode: VK.ansiC, modifierFlags: [.control]))
        // ⌘⌥C: `characters` would be "ç"; ⌃ is gone, ⌥ and ⌘ are pressed (in shift/control/option/command order).
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiC, characters: "ç", charactersIgnoringModifiers: "c",
                                            modifierFlags: [.command, .option]))
                == [up(Keysym.controlL), down(Keysym.metaL), down(Keysym.altL), down(0x63)])
        // ⌥ alone: the character ⌥ typed, with the Option keysym held.
        var plain = InputTranslator(profile: .appleRemoteDesktop)
        #expect(plain.keyDown(KeyInput(keyCode: VK.ansiC, characters: "ç", charactersIgnoringModifiers: "c",
                                       modifierFlags: [.option])) == [down(Keysym.metaL), down(0xE7)])
    }

    @Test(arguments: [
        (VK.shift, MacModifierFlags.leftShift, MacModifierFlags.shift, Keysym.shiftL, Keysym.shiftL),
        (VK.rightShift, .rightShift, .shift, Keysym.shiftR, Keysym.shiftR),
        (VK.control, .leftControl, .control, Keysym.controlL, Keysym.controlL),
        (VK.rightControl, .rightControl, .control, Keysym.controlR, Keysym.controlR),
        (VK.option, .leftOption, .option, Keysym.metaL, Keysym.altL),
        (VK.rightOption, .rightOption, .option, Keysym.metaR, Keysym.altR),
        (VK.command, .leftCommand, .command, Keysym.altL, Keysym.superL),
        (VK.rightCommand, .rightCommand, .command, Keysym.altR, Keysym.superR),
    ])
    func modifiersLeftAndRight(keyCode: UInt16, device: MacModifierFlags, generic: MacModifierFlags,
                               apple: UInt32, x11: UInt32) {
        for (profile, keysym) in [(ModifierProfile.appleRemoteDesktop, apple), (.x11, x11)] {
            var translator = InputTranslator(profile: profile)
            #expect(translator.flagsChanged(KeyInput(keyCode: keyCode, modifierFlags: [generic, device])) == [down(keysym)])
            #expect(translator.flagsChanged(KeyInput(keyCode: keyCode, modifierFlags: [])) == [up(keysym)])
        }
    }

    @Test func bothShiftsReleasedIndependently() {
        var translator = InputTranslator(profile: .x11)
        var messages = translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: [.shift, .leftShift]))
        messages += translator.flagsChanged(KeyInput(keyCode: VK.rightShift, modifierFlags: [.shift, .leftShift, .rightShift]))
        // Left released, right still down: the generic flag is still set.
        messages += translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: [.shift, .rightShift]))
        #expect(messages == [down(Keysym.shiftL), down(Keysym.shiftR), up(Keysym.shiftL)])
        #expect(translator.heldKeysyms == [Keysym.shiftR])
    }

    @Test func capsLockTogglesWithAPressAndRelease() {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.flagsChanged(KeyInput(keyCode: VK.capsLock, modifierFlags: [.capsLock])) == tap(Keysym.capsLock))
        #expect(translator.flagsChanged(KeyInput(keyCode: VK.capsLock, modifierFlags: [])) == tap(Keysym.capsLock))
        #expect(translator.heldKeysyms.isEmpty)
    }

    @Test func autoRepeatSendsTheKeyDownAgain() {
        var translator = InputTranslator(profile: .x11)
        let key = KeyInput(keyCode: VK.ansiA, characters: "a")
        var repeated = key
        repeated.isRepeat = true
        #expect(translator.keyDown(key) + translator.keyDown(repeated) == [down(0x61), down(0x61)])
        #expect(translator.keyUp(key) == [up(0x61)])
    }

    @Test func keyUpReleasesWhatWasPressedEvenIfShiftChanged() {
        var translator = InputTranslator(profile: .x11)
        _ = translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: [.shift, .leftShift]))
        _ = translator.keyDown(KeyInput(keyCode: VK.ansiA, characters: "A", modifierFlags: [.shift, .leftShift]))
        let release = translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: []))
            + translator.keyUp(KeyInput(keyCode: VK.ansiA, characters: "a"))
        #expect(release == [up(Keysym.shiftL), up(0x41)])
    }

    @Test func releaseShortcutIsCommandOptionEscapeOnly() {
        #expect(InputTranslator.isReleaseShortcut(KeyInput(keyCode: VK.escape, modifierFlags: [.command, .option])))
        #expect(!InputTranslator.isReleaseShortcut(KeyInput(keyCode: VK.escape, modifierFlags: [.command])))
        #expect(!InputTranslator.isReleaseShortcut(KeyInput(keyCode: VK.escape, modifierFlags: [.command, .option, .shift])))
        #expect(!InputTranslator.isReleaseShortcut(KeyInput(keyCode: VK.ansiA, modifierFlags: [.command, .option])))
    }
}

struct InputTranslatorStuckKeyTests {
    @Test func losingFocusReleasesKeysThenModifiersThenButtons() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        _ = translator.flagsChanged(KeyInput(keyCode: VK.control, modifierFlags: [.control, .leftControl]))
        _ = translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: [.control, .shift, .leftControl, .leftShift]))
        _ = translator.keyDown(KeyInput(keyCode: VK.ansiA, characters: "A", charactersIgnoringModifiers: "A",
                                        modifierFlags: [.control, .shift]))
        _ = translator.keyDown(KeyInput(keyCode: VK.left, modifierFlags: [.control, .shift]))
        _ = translator.pointerButton(.left, down: true, at: PointerLocation(x: 10, y: 20))
        _ = translator.pointerMoved(to: PointerLocation(x: 11, y: 21))
        #expect(translator.releaseAll() == [up(0x41), up(Keysym.left), up(Keysym.shiftL), up(Keysym.controlL),
                                            pointer(0, 11, 21)])
        #expect(translator.heldKeysyms.isEmpty)
        #expect(translator.buttonMask == 0)
        #expect(translator.releaseAll() == [])
        // Late key-ups after the release send nothing.
        #expect(translator.keyUp(KeyInput(keyCode: VK.ansiA)) == [])
        #expect(translator.flagsChanged(KeyInput(keyCode: VK.shift, modifierFlags: [])) == [])
    }

    /// ⌘Tab away: ⌘ went down through flagsChanged, the Tab and the ⌘ release go to the app switcher.
    @Test func commandTabAwayReleasesCommand() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        #expect(translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: [.command, .leftCommand]))
                == [down(Keysym.altL)])
        #expect(translator.releaseAll() == [up(Keysym.altL)])
    }

    @Test func keysPressedWithCommandAreReleasedWithCommand() {
        // AppKit may not deliver the key-up of a key pressed while ⌘ is down.
        var translator = InputTranslator(profile: .x11)
        var messages = translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: [.command, .leftCommand]))
        messages += translator.keyDown(KeyInput(keyCode: VK.ansiC, characters: "c", modifierFlags: [.command]))
        messages += translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: []))
        #expect(messages == [down(Keysym.superL), down(0x63), up(0x63), up(Keysym.superL)])
        #expect(translator.keyUp(KeyInput(keyCode: VK.ansiC)) == [])
    }

    /// ⌘ was already down when the capture started (⌘-click into the view, a sheet closing with ⌘
    /// held): its flagsChanged never reached the translator, so ⌘V must press ⌘ first.
    @Test func aModifierAlreadyDownIsPressedBeforeTheKey() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        #expect(translator.keyDown(KeyInput(keyCode: 0x09, characters: "v", modifierFlags: [.command, .leftCommand]))
                == [down(Keysym.altL), down(0x76)])
        #expect(translator.flagsChanged(KeyInput(keyCode: VK.command, modifierFlags: [])) == [up(0x76), up(Keysym.altL)])
    }

    @Test func syncPressesTheRightSideFromDeviceBitsAndLeftByDefault() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        // Shift+Right with Shift held before the capture, no device bits (synthetic event): Shift_L.
        #expect(translator.keyDown(KeyInput(keyCode: VK.left + 1, modifierFlags: [.shift])) == [down(Keysym.shiftL), down(Keysym.right)])
        var right = InputTranslator(profile: .appleRemoteDesktop)
        #expect(right.keyDown(KeyInput(keyCode: VK.ansiA, characters: "a", modifierFlags: [.command, .rightCommand]))
                == [down(Keysym.altR), down(0x61)])
        // Already held: nothing extra.
        #expect(right.keyDown(KeyInput(keyCode: VK.ansiC, characters: "c", modifierFlags: [.command, .rightCommand]))
                == [down(0x63)])
    }

    @Test func aMissedModifierReleaseIsCaughtUpOnTheNextKey() {
        var translator = InputTranslator(profile: .x11)
        _ = translator.flagsChanged(KeyInput(keyCode: VK.option, modifierFlags: [.option, .leftOption]))
        // The ⌥ release happened while another app had focus; the next key says ⌥ is up.
        #expect(translator.keyDown(KeyInput(keyCode: VK.ansiA, characters: "a")) == [up(Keysym.altL), down(0x61)])
    }
}

struct InputTranslatorPointerTests {
    @Test func buttonMaskTransitions() {
        var translator = InputTranslator(profile: .x11)
        let at = PointerLocation(x: 5, y: 6)
        var messages = translator.pointerButton(.left, down: true, at: at)
        messages += translator.pointerButton(.right, down: true, at: at)
        messages += translator.pointerButton(.middle, down: true, at: at)
        messages += translator.pointerButton(.left, down: false, at: at)
        messages += translator.pointerButton(.middle, down: false, at: at)
        messages += translator.pointerButton(.right, down: false, at: at)
        #expect(messages == [pointer(1, 5, 6), pointer(5, 5, 6), pointer(7, 5, 6), pointer(6, 5, 6),
                             pointer(4, 5, 6), pointer(0, 5, 6)])
        // A second release, or a press already held, sends nothing.
        #expect(translator.pointerButton(.left, down: false, at: at) == [])
    }

    @Test func dragCarriesTheMask() {
        var translator = InputTranslator(profile: .x11)
        var messages = translator.pointerButton(.left, down: true, at: PointerLocation(x: 1, y: 1))
        messages += translator.pointerMoved(to: PointerLocation(x: 2, y: 3))
        messages += translator.pointerMoved(to: PointerLocation(x: 2, y: 3))   // no motion: nothing
        messages += translator.pointerButton(.left, down: false, at: PointerLocation(x: 4, y: 4))
        #expect(messages == [pointer(1, 1, 1), pointer(1, 2, 3), pointer(0, 4, 4)])
    }

    @Test func letterboxIgnoresEverythingButReleases() {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.pointerMoved(to: nil) == [])
        #expect(translator.pointerButton(.left, down: true, at: nil) == [])
        #expect(translator.scroll(deltaX: 0, deltaY: 3, precise: false, at: nil) == [])
        _ = translator.pointerButton(.right, down: true, at: PointerLocation(x: 9, y: 9))
        // Released over the letterbox: sent at the last remote position.
        #expect(translator.pointerButton(.right, down: false, at: nil) == [pointer(0, 9, 9)])
    }

    /// The keyboard is released (no flagsChanged forwarded), yet a Shift-click must reach the remote
    /// as one: pointer events carry their modifier flags.
    @Test func shiftClickWithoutKeyboardCaptureSyncsShift() {
        var translator = InputTranslator(profile: .x11)
        let at = PointerLocation(x: 3, y: 4)
        #expect(translator.pointerButton(.left, down: true, at: at, modifierFlags: [.shift, .leftShift])
                == [down(Keysym.shiftL), pointer(1, 3, 4)])
        #expect(translator.pointerButton(.left, down: false, at: at, modifierFlags: [.shift, .leftShift]) == [pointer(0, 3, 4)])
        #expect(translator.pointerMoved(to: PointerLocation(x: 5, y: 4), modifierFlags: []) == [up(Keysym.shiftL), pointer(0, 5, 4)])
        #expect(translator.scroll(deltaX: 0, deltaY: 1, precise: false, at: at, modifierFlags: [.control])
                == [down(Keysym.controlL), pointer(8, 3, 4), pointer(0, 3, 4)])
    }

    @Test func controlClickStaysALeftClickWithControl() {
        var translator = InputTranslator(profile: .appleRemoteDesktop)
        var messages = translator.flagsChanged(KeyInput(keyCode: VK.control, modifierFlags: [.control, .leftControl]))
        messages += translator.pointerButton(.left, down: true, at: PointerLocation(x: 3, y: 3))
        #expect(messages == [down(Keysym.controlL), pointer(1, 3, 3)])
    }
}

struct InputTranslatorScrollTests {
    let at = PointerLocation(x: 100, y: 50)

    @Test func wheelLinesAreSteps() {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.scroll(deltaX: 0, deltaY: 1, precise: false, at: at) == [pointer(8, 100, 50), pointer(0, 100, 50)])
        #expect(translator.scroll(deltaX: 0, deltaY: -2, precise: false, at: at)
                == [pointer(16, 100, 50), pointer(0, 100, 50), pointer(16, 100, 50), pointer(0, 100, 50)])
        #expect(translator.scroll(deltaX: 1, deltaY: 0, precise: false, at: at) == [pointer(32, 100, 50), pointer(0, 100, 50)])
        #expect(translator.scroll(deltaX: -1, deltaY: 0, precise: false, at: at) == [pointer(64, 100, 50), pointer(0, 100, 50)])
    }

    /// Accelerated wheels report fractions of a line: ten 0.1-line events are one step, not ten.
    @Test func fractionalWheelDeltasAccumulate() {
        var translator = InputTranslator(profile: .x11)
        var messages: [ClientMessage] = []
        for _ in 0..<10 { messages += translator.scroll(deltaX: 0, deltaY: 0.1, precise: false, at: at) }
        #expect(messages == [pointer(8, 100, 50), pointer(0, 100, 50)])
        #expect(translator.scroll(deltaX: 0, deltaY: 1.5, precise: false, at: at).count == 2)
        #expect(translator.scroll(deltaX: 0, deltaY: 0.5, precise: false, at: at).count == 2)
    }

    @Test func aNewGestureDropsTheLeftover() {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.scroll(deltaX: 0, deltaY: 30, precise: true, at: at) == [])
        #expect(translator.scroll(deltaX: 0, deltaY: 30, precise: true, phaseBegan: true, at: at) == [])
        #expect(translator.scroll(deltaX: 0, deltaY: 20, precise: true, at: at).count == 2)
    }

    @Test func preciseDeltasAccumulateIntoSteps() {
        var translator = InputTranslator(profile: .x11)
        var messages: [ClientMessage] = []
        for _ in 0..<12 { messages += translator.scroll(deltaX: 0, deltaY: 10, precise: true, at: at) }
        // 120 points = 2 steps of 50, 20 points left over.
        #expect(messages == [pointer(8, 100, 50), pointer(0, 100, 50), pointer(8, 100, 50), pointer(0, 100, 50)])
        #expect(translator.scroll(deltaX: 0, deltaY: 30, precise: true, at: at).count == 2)
        // Changing direction drops the remainder: −49 is not a step yet, −1 more is.
        #expect(translator.scroll(deltaX: 0, deltaY: -49, precise: true, at: at) == [])
        #expect(translator.scroll(deltaX: 0, deltaY: -1, precise: true, at: at) == [pointer(16, 100, 50), pointer(0, 100, 50)])
    }

    /// AppKit's scrolling deltas already include the natural-scrolling inversion
    /// (`NSEvent.isDirectionInvertedFromDevice` documentation), so the button follows the delta's
    /// sign, i.e. the direction the local content would move. Swiping up with natural scrolling gives
    /// a negative delta → button 5, like the local scroll view.
    @Test func directionFollowsTheContentDelta() {
        var translator = InputTranslator(profile: .x11)
        #expect(translator.scroll(deltaX: 0, deltaY: -60, precise: true, at: at).first == pointer(16, 100, 50))
        #expect(translator.scroll(deltaX: 0, deltaY: 60, precise: true, at: at).first == pointer(8, 100, 50))
    }

    @Test func scrollKeepsHeldButtonsAndIsCapped() {
        var translator = InputTranslator(profile: .x11)
        _ = translator.pointerButton(.left, down: true, at: at)
        #expect(translator.scroll(deltaX: 0, deltaY: 1, precise: false, at: at) == [pointer(9, 100, 50), pointer(1, 100, 50)])
        #expect(translator.scroll(deltaX: 0, deltaY: 5000, precise: true, at: at).count == 2 * InputTranslator.maxScrollSteps)
    }
}

struct ClientMessageInputBytesTests {
    @Test func keyEventIsEightBytes() {
        // RFC 6143 §7.5.4: type 4, down-flag, 2 padding bytes, keysym (big-endian U32).
        #expect(ClientMessage.keyEvent(down: true, key: Keysym.altL).wireBytes == [4, 1, 0, 0, 0x00, 0x00, 0xFF, 0xE9])
        #expect(ClientMessage.keyEvent(down: false, key: 0x0100_20AC).wireBytes == [4, 0, 0, 0, 0x01, 0x00, 0x20, 0xAC])
    }

    @Test func pointerEventIsSixBytes() {
        // RFC 6143 §7.5.5: type 5, button-mask, x, y (big-endian U16).
        #expect(ClientMessage.pointerEvent(buttonMask: 0b101, x: 1919, y: 1079).wireBytes == [5, 5, 0x07, 0x7F, 0x04, 0x37])
    }
}
