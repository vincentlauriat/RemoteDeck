/// Which keysyms the Mac's ⌘ and ⌥ keys are sent as. Servers disagree, so the app picks the profile
/// from the machine kind.
///
/// - `appleRemoteDesktop`: ⌘ → `Alt_L`/`Alt_R`, ⌥ → `Meta_L`/`Meta_R`. Sources: OSXvnc's server key
///   table maps `XK_Alt_L/R` to the Command key and `XK_Meta_L/R` and `XK_Super_L/R` to Option
///   (stweil/OSXvnc, `OSXvnc-server/kbdptr.h`), and its author states that Apple's Remote Desktop
///   server chose the same mapping; noVNC remaps a Mac client's ⌘ to `Alt_L` "to make things more sane
///   for the remote server", citing RealVNC and TigerVNC (`core/input/keyboard.js`). Not yet checked
///   against the macOS 26 server: see TRD › Input.
/// - `x11`: ⌘ → `Super_L`/`Super_R`, ⌥ → `Alt_L`/`Alt_R`, the key at the same place on a PC keyboard;
///   what TigerVNC's macOS viewer sends today (`vncviewer/KeyboardMacOS.mm`).
public enum ModifierProfile: Sendable, Equatable {
    case appleRemoteDesktop
    case x11

    /// The keysym the Mac's ⌘ is sent as.
    public func command(right: Bool) -> UInt32 {
        switch self {
        case .appleRemoteDesktop: right ? Keysym.altR : Keysym.altL
        case .x11: right ? Keysym.superR : Keysym.superL
        }
    }

    /// The keysym the Mac's ⌥ is sent as.
    public func option(right: Bool) -> UInt32 {
        switch self {
        case .appleRemoteDesktop: right ? Keysym.metaR : Keysym.metaL
        case .x11: right ? Keysym.altR : Keysym.altL
        }
    }
}

/// `NSEvent.ModifierFlags` raw values, including the device-dependent bits that tell left from right
/// (IOKit `NX_DEVICE*KEYMASK`; also what TigerVNC reads in `KeyboardMacOS.mm`).
public struct MacModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let capsLock = MacModifierFlags(rawValue: 1 << 16)
    public static let shift = MacModifierFlags(rawValue: 1 << 17)
    public static let control = MacModifierFlags(rawValue: 1 << 18)
    public static let option = MacModifierFlags(rawValue: 1 << 19)
    public static let command = MacModifierFlags(rawValue: 1 << 20)

    public static let leftControl = MacModifierFlags(rawValue: 0x0001)
    public static let leftShift = MacModifierFlags(rawValue: 0x0002)
    public static let rightShift = MacModifierFlags(rawValue: 0x0004)
    public static let leftCommand = MacModifierFlags(rawValue: 0x0008)
    public static let rightCommand = MacModifierFlags(rawValue: 0x0010)
    public static let leftOption = MacModifierFlags(rawValue: 0x0020)
    public static let rightOption = MacModifierFlags(rawValue: 0x0040)
    public static let rightControl = MacModifierFlags(rawValue: 0x2000)

    static let deviceDependent: MacModifierFlags = [.leftControl, .leftShift, .rightShift, .leftCommand,
                                                     .rightCommand, .leftOption, .rightOption, .rightControl]
}

/// One key event as AppKit reports it, without AppKit (see `KeyInput(event:)` in the app).
public struct KeyInput: Sendable, Equatable {
    /// Virtual key code (`kVK_*`, Carbon `Events.h`): the physical key, independent of the layout.
    public var keyCode: UInt16
    /// What the key typed with every modifier and pending dead key applied (`NSEvent.characters`).
    /// Empty when the key only armed a dead key.
    public var characters: String
    /// What the key types with Shift only (`NSEvent.charactersIgnoringModifiers`).
    public var charactersIgnoringModifiers: String
    public var modifierFlags: MacModifierFlags
    public var isRepeat: Bool

    public init(keyCode: UInt16, characters: String = "", charactersIgnoringModifiers: String? = nil,
                modifierFlags: MacModifierFlags = [], isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.modifierFlags = modifierFlags
        self.isRepeat = isRepeat
    }
}

/// A mouse button, with its RFB PointerEvent mask bit (RFC 6143 §7.5.5).
public enum PointerButton: Sendable, CaseIterable {
    case left, middle, right

    var mask: UInt8 {
        switch self {
        case .left: 1
        case .middle: 2
        case .right: 4
        }
    }
}

/// A remote framebuffer pixel.
public struct PointerLocation: Sendable, Equatable {
    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}

/// Turns local key, pointer and scroll input into RFB KeyEvents and PointerEvents, and tracks what is
/// held down so nothing stays stuck on the remote. Pure state machine: no AppKit, no I/O.
///
/// **Keys.** Keys that type no character (arrows, F1–F20, Return, keypad…) and the modifiers come from
/// a key-code table, independent of the layout. Other keys send the keysym of the *character* the
/// local layout produced, so an AZERTY keyboard types `a`, `é`, `@` remotely as it does locally:
/// - without ⌘ or ⌃: `characters` (layout, Shift, ⌥, Caps Lock and dead keys applied). A dead key
///   alone sends nothing; the composed character (`ê`) is sent with the next key, so composition
///   does not depend on the remote layout. Several characters (dead key + a key it does not combine
///   with) are each pressed and released at once.
/// - with ⌘ or ⌃: `charactersIgnoringModifiers` (layout and Shift only), so ⌘C is the profile's
///   Command keysym + `c`, not ⌘ + whatever ⌥ or ⌃ would type.
/// - A key pressed while ⌘ is down is released, at the latest, when ⌘ is released: AppKit may drop
///   its key-up.
/// - Caps Lock: each toggle sends `Caps_Lock` press + release (AppKit reports no key-up), and the
///   characters are sent with the case already applied, like TigerVNC.
/// - Modifier sync both ways: every key and pointer event carries the local modifier flags; a held
///   modifier whose flag is gone is released, and a flag set without its modifier held (⌘ already
///   down when the capture started, a Shift-click while the keyboard is released) presses it first
///   (left key unless the device bits say right).
///
/// **Pointer.** Positions are remote pixels; `nil` means "over the letterbox": moves, presses and
/// scrolls there are ignored, a release is sent at the last position. ⌃-click is a left click with
/// Control held, not a right click: the remote decides what it means.
///
/// **Scroll.** Buttons 4/5 (up/down) and 6/7 (left/right), each step a press + release. Deltas are
/// AppKit's `scrollingDeltaX/Y`, which already follow the user's natural-scrolling setting, so a
/// positive Y delta (content moves down, i.e. scroll toward the top) is button 4 whatever
/// `isDirectionInvertedFromDevice` says, and the remote moves the way the local content would.
/// Deltas accumulate: precise (trackpad) ones at `preciseScrollStep` points per step, wheel (line)
/// ones at one line per step, so ten 0.1-line events make one step. A new trackpad gesture
/// (`phaseBegan`) drops the leftover.
public struct InputTranslator: Sendable {
    public let profile: ModifierProfile
    /// Points of precise (trackpad) scrolling per wheel step: noVNC's `WHEEL_STEP`, about three
    /// lines of text, what one wheel notch scrolls on X11.
    public static let preciseScrollStep = 50.0
    /// At most this many steps per event, so a fast fling cannot flood the connection.
    public static let maxScrollSteps = 10

    private struct HeldKey: Sendable {
        let keyCode: UInt16
        let keysym: UInt32
        let withCommand: Bool
    }

    /// Non-modifier keys sent down and not yet up, in press order.
    private var heldKeys: [HeldKey] = []
    /// Modifier keys sent down and not yet up, in press order.
    private var heldModifiers: [HeldKey] = []
    public private(set) var buttonMask: UInt8 = 0
    public private(set) var lastLocation: PointerLocation?
    private var scrollRemainder = (x: 0.0, y: 0.0)

    public init(profile: ModifierProfile) {
        self.profile = profile
    }

    /// Keysyms currently held on the remote, keys then modifiers (for tests and debugging).
    public var heldKeysyms: [UInt32] { (heldKeys + heldModifiers).map(\.keysym) }

    // MARK: Keys

    /// ⌃⌥⌘R (`ReleaseShortcut`): release the keyboard capture (AppFlow › Navigation rules). Never sent
    /// to the remote.
    public static func isReleaseShortcut(_ key: KeyInput) -> Bool {
        ReleaseShortcut.matches(keyCode: key.keyCode, flags: key.modifierFlags)
    }

    public mutating func keyDown(_ key: KeyInput) -> [ClientMessage] {
        var messages = syncModifiers(key.modifierFlags)
        guard KeyCode.modifiers[key.keyCode] == nil, key.keyCode != KeyCode.capsLock else { return messages }
        let keysyms = Self.keysyms(for: key)
        let withCommand = key.modifierFlags.contains(.command)
        if keysyms.count == 1, let keysym = keysyms.first {
            if let index = heldKeys.firstIndex(where: { $0.keyCode == key.keyCode }) {
                // Auto-repeat sends the same keysym down again (X11 style); a different one releases the old.
                if heldKeys[index].keysym != keysym {
                    messages.append(.keyEvent(down: false, key: heldKeys[index].keysym))
                    heldKeys[index] = HeldKey(keyCode: key.keyCode, keysym: keysym, withCommand: withCommand)
                }
            } else {
                heldKeys.append(HeldKey(keyCode: key.keyCode, keysym: keysym, withCommand: withCommand))
            }
            messages.append(.keyEvent(down: true, key: keysym))
        } else {
            for keysym in keysyms {
                messages += [.keyEvent(down: true, key: keysym), .keyEvent(down: false, key: keysym)]
            }
        }
        return messages
    }

    public mutating func keyUp(_ key: KeyInput) -> [ClientMessage] {
        var messages: [ClientMessage] = []
        if let index = heldKeys.firstIndex(where: { $0.keyCode == key.keyCode }) {
            messages.append(.keyEvent(down: false, key: heldKeys.remove(at: index).keysym))
        }
        return messages + syncModifiers(key.modifierFlags)
    }

    /// A modifier key changed (`NSEvent.flagsChanged`): `key.keyCode` is the modifier, the flags the
    /// state after the change.
    public mutating func flagsChanged(_ key: KeyInput) -> [ClientMessage] {
        let flags = key.modifierFlags
        if key.keyCode == KeyCode.capsLock {
            return syncModifiers(flags) + [.keyEvent(down: true, key: Keysym.capsLock),
                                           .keyEvent(down: false, key: Keysym.capsLock)]
        }
        guard let modifier = KeyCode.modifiers[key.keyCode] else { return syncModifiers(flags) }
        let isDown = flags.contains(modifier.device)
            || (flags.isDisjoint(with: .deviceDependent) && flags.contains(modifier.generic))
        let keysym = modifier.keysym(profile)
        let index = heldModifiers.firstIndex { $0.keyCode == key.keyCode }
        var messages: [ClientMessage] = []
        if isDown, index == nil {
            heldModifiers.append(HeldKey(keyCode: key.keyCode, keysym: keysym, withCommand: false))
            messages.append(.keyEvent(down: true, key: keysym))
        } else if !isDown, let index {
            if modifier.kind == .command && !flags.contains(.command) {
                messages += releaseKeys { $0.withCommand }
            }
            heldModifiers.remove(at: index)
            messages.append(.keyEvent(down: false, key: keysym))
        }
        return messages + syncModifiers(flags)
    }

    /// Releases every held key (in press order), then every held modifier (last pressed first), then
    /// the mouse buttons at the last position. Call when the view loses focus or capture is released.
    public mutating func releaseAll() -> [ClientMessage] {
        var messages = releaseKeys { _ in true }
        for modifier in heldModifiers.reversed() {
            messages.append(.keyEvent(down: false, key: modifier.keysym))
        }
        heldModifiers = []
        if buttonMask != 0, let lastLocation {
            messages.append(.pointerEvent(buttonMask: 0, x: lastLocation.x, y: lastLocation.y))
        }
        buttonMask = 0
        scrollRemainder = (0, 0)
        return messages
    }

    private mutating func releaseKeys(where predicate: (HeldKey) -> Bool) -> [ClientMessage] {
        let released = heldKeys.filter(predicate)
        heldKeys.removeAll(where: predicate)
        return released.map { .keyEvent(down: false, key: $0.keysym) }
    }

    /// Makes the held modifiers match `flags` (the local state): releases those whose flag is gone (a
    /// release lost while unfocused), then presses those whose flag is set but which are not held (a
    /// modifier already down when the capture started, or a click while the keyboard is released).
    /// The device bits pick left or right; without them, the left key.
    public mutating func syncModifiers(_ flags: MacModifierFlags) -> [ClientMessage] {
        var messages: [ClientMessage] = []
        heldModifiers.removeAll { held in
            guard let modifier = KeyCode.modifiers[held.keyCode], !flags.contains(modifier.generic) else { return false }
            messages.append(.keyEvent(down: false, key: held.keysym))
            return true
        }
        for kind in KeyCode.Modifier.Kind.allCases {
            let sides = KeyCode.modifiers.filter { $0.value.kind == kind }
            guard let generic = sides.first?.value.generic, flags.contains(generic),
                  !heldModifiers.contains(where: { sides[$0.keyCode] != nil }) else { continue }
            var pressed = sides.filter { flags.contains($0.value.device) }.sorted { !$0.value.right && $1.value.right }
            if pressed.isEmpty { pressed = sides.filter { !$0.value.right } }
            for (keyCode, modifier) in pressed {
                let keysym = modifier.keysym(profile)
                heldModifiers.append(HeldKey(keyCode: keyCode, keysym: keysym, withCommand: false))
                messages.append(.keyEvent(down: true, key: keysym))
            }
        }
        return messages
    }

    static func keysyms(for key: KeyInput) -> [UInt32] {
        if let keysym = KeyCode.special[key.keyCode] { return [keysym] }
        let text = key.modifierFlags.isDisjoint(with: [.command, .control])
            ? key.characters : key.charactersIgnoringModifiers
        return text.unicodeScalars.compactMap(Keysym.forCharacter)
    }

    // MARK: Pointer
    //
    // `modifierFlags`: the event's local modifier state, synced first (`syncModifiers`); `nil` leaves
    // the held modifiers alone.

    public mutating func pointerMoved(to location: PointerLocation?,
                                      modifierFlags: MacModifierFlags? = nil) -> [ClientMessage] {
        let messages = modifierFlags.map { syncModifiers($0) } ?? []
        guard let location, location != lastLocation else { return messages }
        lastLocation = location
        return messages + [.pointerEvent(buttonMask: buttonMask, x: location.x, y: location.y)]
    }

    public mutating func pointerButton(_ button: PointerButton, down: Bool, at location: PointerLocation?,
                                       modifierFlags: MacModifierFlags? = nil) -> [ClientMessage] {
        let position: PointerLocation
        if down {
            guard let location, buttonMask & button.mask == 0 else { return [] }
            buttonMask |= button.mask
            position = location
        } else {
            guard buttonMask & button.mask != 0, let released = location ?? lastLocation else { return [] }
            buttonMask &= ~button.mask
            position = released
        }
        lastLocation = position
        let messages = modifierFlags.map { syncModifiers($0) } ?? []
        return messages + [.pointerEvent(buttonMask: buttonMask, x: position.x, y: position.y)]
    }

    /// `precise`: `NSEvent.hasPreciseScrollingDeltas` (trackpad, Magic Mouse) — deltas in points;
    /// otherwise a wheel, with deltas in lines. `phaseBegan`: a new trackpad gesture starts
    /// (`NSEvent.phase` contains `.began`), so the previous gesture's leftover is dropped.
    public mutating func scroll(deltaX: Double, deltaY: Double, precise: Bool, phaseBegan: Bool = false,
                                at location: PointerLocation?,
                                modifierFlags: MacModifierFlags? = nil) -> [ClientMessage] {
        guard let location else { return [] }
        lastLocation = location
        if phaseBegan { scrollRemainder = (0, 0) }
        let unit = precise ? Self.preciseScrollStep : 1
        let vertical = steps(&scrollRemainder.y, delta: deltaY, unit: unit)
        let horizontal = steps(&scrollRemainder.x, delta: deltaX, unit: unit)
        var messages = modifierFlags.map { syncModifiers($0) } ?? []
        // Positive = toward the top / the left: buttons 4 and 6 (masks 8 and 32).
        let buttons: [(mask: UInt8, count: Int)] = [(vertical > 0 ? 8 : 16, abs(vertical)),
                                                    (horizontal > 0 ? 32 : 64, abs(horizontal))]
        for (mask, count) in buttons {
            for _ in 0..<count {
                messages.append(.pointerEvent(buttonMask: buttonMask | mask, x: location.x, y: location.y))
                messages.append(.pointerEvent(buttonMask: buttonMask, x: location.x, y: location.y))
            }
        }
        return messages
    }

    /// Signed number of whole `unit`s in `remainder + delta`; the rest stays for the next event.
    private func steps(_ remainder: inout Double, delta: Double, unit: Double) -> Int {
        guard delta != 0 else { return 0 }
        // A change of direction starts afresh rather than first cancelling the old remainder.
        if remainder != 0 && (remainder > 0) != (delta > 0) { remainder = 0 }
        remainder += delta
        // Toward zero, with a tolerance so ten 0.1-line deltas (0.999…) make one step.
        let count = Int(remainder / unit + (remainder > 0 ? 1e-9 : -1e-9))
        remainder -= Double(count) * unit
        return max(-Self.maxScrollSteps, min(Self.maxScrollSteps, count))
    }
}

/// macOS virtual key codes (`kVK_*`, Carbon `HIToolbox/Events.h`) with a fixed keysym.
enum KeyCode {
    static let capsLock: UInt16 = 0x39

    struct Modifier: Sendable {
        enum Kind: Sendable, CaseIterable { case shift, control, option, command }
        let kind: Kind
        let right: Bool

        var generic: MacModifierFlags {
            switch kind {
            case .shift: .shift
            case .control: .control
            case .option: .option
            case .command: .command
            }
        }

        var device: MacModifierFlags {
            switch kind {
            case .shift: right ? .rightShift : .leftShift
            case .control: right ? .rightControl : .leftControl
            case .option: right ? .rightOption : .leftOption
            case .command: right ? .rightCommand : .leftCommand
            }
        }

        func keysym(_ profile: ModifierProfile) -> UInt32 {
            switch kind {
            case .shift: right ? Keysym.shiftR : Keysym.shiftL
            case .control: right ? Keysym.controlR : Keysym.controlL
            case .option: profile.option(right: right)
            case .command: profile.command(right: right)
            }
        }
    }

    static let modifiers: [UInt16: Modifier] = [
        0x38: Modifier(kind: .shift, right: false), 0x3C: Modifier(kind: .shift, right: true),
        0x3B: Modifier(kind: .control, right: false), 0x3E: Modifier(kind: .control, right: true),
        0x3A: Modifier(kind: .option, right: false), 0x3D: Modifier(kind: .option, right: true),
        0x37: Modifier(kind: .command, right: false), 0x36: Modifier(kind: .command, right: true),
    ]

    /// Keys that type no character, or one that depends on nothing but the key. Based on TigerVNC's
    /// `kvk_map`; the keypad decimal key is left to its character (`.` or `,` with the layout).
    static let special: [UInt16: UInt32] = [
        0x24: Keysym.return, 0x30: Keysym.tab, 0x31: Keysym.space, 0x33: Keysym.backSpace,
        0x35: Keysym.escape, 0x75: Keysym.delete, 0x72: Keysym.help, 0x6E: Keysym.menu,
        0x73: Keysym.home, 0x77: Keysym.end, 0x74: Keysym.pageUp, 0x79: Keysym.pageDown,
        0x7B: Keysym.left, 0x7C: Keysym.right, 0x7D: Keysym.down, 0x7E: Keysym.up,
        0x7A: Keysym.f(1), 0x78: Keysym.f(2), 0x63: Keysym.f(3), 0x76: Keysym.f(4), 0x60: Keysym.f(5),
        0x61: Keysym.f(6), 0x62: Keysym.f(7), 0x64: Keysym.f(8), 0x65: Keysym.f(9), 0x6D: Keysym.f(10),
        0x67: Keysym.f(11), 0x6F: Keysym.f(12), 0x69: Keysym.f(13), 0x6B: Keysym.f(14), 0x71: Keysym.f(15),
        0x6A: Keysym.f(16), 0x40: Keysym.f(17), 0x4F: Keysym.f(18), 0x50: Keysym.f(19), 0x5A: Keysym.f(20),
        0x4C: Keysym.kpEnter, 0x43: Keysym.kpMultiply, 0x45: Keysym.kpAdd, 0x4E: Keysym.kpSubtract,
        0x4B: Keysym.kpDivide, 0x51: Keysym.kpEqual, 0x47: Keysym.numLock,
        0x66: Keysym.eisuToggle, 0x68: Keysym.hiraganaKatakana,   // kVK_JIS_Eisu, kVK_JIS_Kana
        0x52: Keysym.kp(0), 0x53: Keysym.kp(1), 0x54: Keysym.kp(2), 0x55: Keysym.kp(3), 0x56: Keysym.kp(4),
        0x57: Keysym.kp(5), 0x58: Keysym.kp(6), 0x59: Keysym.kp(7), 0x5B: Keysym.kp(8), 0x5C: Keysym.kp(9),
    ]
}
