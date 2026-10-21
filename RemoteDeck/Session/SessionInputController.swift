import AppKit
import RFBKit

/// Turns a `FramebufferView`'s AppKit events into RFB messages (through `InputTranslator`) and owns
/// the keyboard capture state. The messages go to `onInput`, in event order; in a session that is
/// `InputSender.enqueue`, which sends them off the main actor.
///
/// Keyboard capture (AppFlow › Navigation rules): while the view is first responder of the key window
/// and the user has not released it, every key event, ⌘ shortcuts included, goes to the remote. The
/// view takes them in a local event monitor, before AppKit dispatches them, so menu shortcuts never
/// fire and key-ups that AppKit would drop while ⌘ is down still arrive. Exceptions:
/// - ⌃⌥⌘R (`ReleaseShortcut`) releases the capture and is never sent; a click in the view takes it again.
/// - ⌘1…⌘9 (`LocalShortcut`) stay local: the key and its key-up go back to AppKit (menus).
/// Losing focus or releasing the capture releases everything held on the remote.
///
/// System combos (`SystemShortcut`: ⌘Tab, ⌘Space, Mission Control, screenshots…) never reach the app;
/// with the Accessibility permission the view's `SystemShortcutTap` takes them first and hands them to
/// `handleSystemKey`, which sends them like any other key. Each event goes through exactly one of the
/// two paths: what the tap swallows never reaches the local monitor.
///
/// The pointer is forwarded whether or not the keyboard is captured.
@MainActor
final class SessionInputController {
    /// Messages to send, in order.
    var onInput: (([ClientMessage]) -> Void)?
    /// Called when `isCapturing` changes. Owned by `FramebufferView`, which starts and stops its
    /// system-shortcut tap from it: the toolbar uses `FramebufferView.onCaptureChange` instead.
    var onCaptureChange: ((Bool) -> Void)?

    /// Which keysyms ⌘ and ⌥ are sent as; set from the machine kind. Changing it releases what is
    /// held, then presses again, under the new keysyms, the modifiers still down locally.
    var profile: ModifierProfile {
        get { translator.profile }
        set {
            guard newValue != translator.profile else { return }
            emit(translator.releaseAll())
            translator = InputTranslator(profile: newValue)
            if isCapturing { emit(translator.syncModifiers(currentModifierFlags())) }
        }
    }

    /// The local modifier state right now (`NSEvent.modifierFlags`); replaceable in tests.
    var currentModifierFlags: () -> MacModifierFlags = { MacModifierFlags(rawValue: NSEvent.modifierFlags.rawValue) }

    private(set) var translator: InputTranslator
    /// The user wants the keyboard captured; ⌃⌥⌘R clears it, a click sets it again.
    private(set) var captureRequested = true
    /// The view is first responder of the key window.
    private(set) var hasFocus = false

    var isCapturing: Bool { captureRequested && hasFocus }

    /// Keys whose key-down was left to AppKit (local shortcuts): their key-up is too.
    private var localKeys: Set<UInt16> = []
    /// Keys whose key-down came from the system-shortcut tap: their key-up and repeats are taken there
    /// too, whatever the modifiers are by then (⌘ may be up before Tab).
    private var systemKeys: Set<UInt16> = []

    init(profile: ModifierProfile = .appleRemoteDesktop) {
        translator = InputTranslator(profile: profile)
    }

    func setFocus(_ focused: Bool) {
        updateCapture { hasFocus = focused }
    }

    func requestCapture() {
        updateCapture { captureRequested = true }
    }

    func releaseCapture() {
        updateCapture { captureRequested = false }
    }

    private func updateCapture(_ change: () -> Void) {
        let was = isCapturing
        change()
        guard isCapturing != was else { return }
        if !isCapturing {
            emit(translator.releaseAll())
            localKeys = []
            systemKeys = []
        }
        onCaptureChange?(isCapturing)
    }

    /// A key event while the view is focused. `true` if it was consumed (sent to the remote, or the
    /// release shortcut); `false` lets AppKit handle it locally.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isCapturing else { return false }
        let key = KeyInput(event: event)
        switch event.type {
        case .keyDown:
            if InputTranslator.isReleaseShortcut(key) {
                // Releases the modifiers already sent down (⌃, ⌥, ⌘): nothing stays held remotely.
                releaseCapture()
            } else if localKeys.contains(key.keyCode)
                        || LocalShortcut.matching(keyCode: key.keyCode, flags: key.modifierFlags) != nil {
                localKeys.insert(key.keyCode)
                return false
            } else {
                emit(translator.keyDown(key))
            }
        case .keyUp:
            if localKeys.remove(key.keyCode) != nil { return false }
            systemKeys.remove(key.keyCode)   // the tap was turned off while it was down
            emit(translator.keyUp(key))
        case .flagsChanged:
            emit(translator.flagsChanged(key))
        default:
            return false
        }
        return true
    }

    /// A key event from the system-shortcut tap, before macOS acts on it. `true` takes it (sent to the
    /// remote, swallowed locally): a `SystemShortcut` key-down, or the repeat or key-up of a key taken
    /// that way. Anything else returns `false` and goes on to the local monitor (`handleKey`).
    func handleSystemKey(_ key: KeyInput, down: Bool) -> Bool {
        guard isCapturing else { return false }
        if down {
            // A key already left to AppKit (⌘3 held, then ⇧ added: ⌘⇧3) stays local until its key-up.
            guard !localKeys.contains(key.keyCode),
                  systemKeys.contains(key.keyCode)
                    || SystemShortcut.matches(keyCode: key.keyCode, flags: key.modifierFlags) else { return false }
            systemKeys.insert(key.keyCode)
            emit(translator.keyDown(key))
        } else {
            guard systemKeys.remove(key.keyCode) != nil else { return false }
            localKeys.remove(key.keyCode)
            emit(translator.keyUp(key))
        }
        return true
    }

    /// A mouse or scroll event at `point` (view coordinates, flipped).
    func handlePointer(_ event: NSEvent, at point: CGPoint, geometry: FramebufferGeometry?) {
        guard let geometry else { return }
        // While a button is held, a drag past the content keeps moving along its edge.
        let location = geometry.pointerPixel(forViewPoint: point, clampingOutside: translator.buttonMask != 0)
            .map { PointerLocation(x: UInt16(clamping: $0.x), y: UInt16(clamping: $0.y)) }
        // Modifiers follow the event (Shift-click works with the keyboard released too).
        let flags = MacModifierFlags(rawValue: event.modifierFlags.rawValue)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            emit(translator.pointerMoved(to: location, modifierFlags: flags))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let button = PointerButton(event: event) else { return }
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            emit(translator.pointerButton(button, down: down, at: location, modifierFlags: flags))
        case .scrollWheel:
            emit(translator.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                   precise: event.hasPreciseScrollingDeltas, phaseBegan: event.phase.contains(.began),
                                   at: location, modifierFlags: flags))
        default:
            break
        }
    }

    private func emit(_ messages: [ClientMessage]) {
        guard !messages.isEmpty else { return }
        onInput?(messages)
    }
}

extension KeyInput {
    /// `characters` must not be read on a flagsChanged event (AppKit raises), so it stays empty there.
    init(event: NSEvent) {
        let isKey = event.type == .keyDown || event.type == .keyUp
        self.init(keyCode: event.keyCode,
                  characters: isKey ? event.characters ?? "" : "",
                  charactersIgnoringModifiers: isKey ? event.charactersIgnoringModifiers ?? "" : "",
                  modifierFlags: MacModifierFlags(rawValue: event.modifierFlags.rawValue),
                  isRepeat: isKey && event.isARepeat)
    }
}

extension PointerButton {
    /// Left and right from the event type; for other buttons AppKit's `buttonNumber` 2 is the middle
    /// one, the rest (back/forward) are not sent.
    init?(event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: self = .left
        case .rightMouseDown, .rightMouseUp: self = .right
        case .otherMouseDown where event.buttonNumber == 2, .otherMouseUp where event.buttonNumber == 2: self = .middle
        default: return nil
        }
    }
}
