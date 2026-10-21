import AppKit
import RFBKit

/// Turns a `FramebufferView`'s AppKit events into RFB messages (through `InputTranslator`) and owns
/// the keyboard capture state. The messages go to `onInput`, in event order; in a session that is
/// `InputSender.enqueue`, which sends them off the main actor.
///
/// Keyboard capture (AppFlow › Navigation rules): while the view is first responder of the key window
/// and the user has not released it, every key event, ⌘ shortcuts included, goes to the remote. The
/// view takes them in a local event monitor, before AppKit dispatches them, so menu shortcuts never
/// fire and key-ups that AppKit would drop while ⌘ is down still arrive. ⌘⌥Esc releases the capture; a
/// click in the view takes it again. Losing focus or releasing the capture releases everything held
/// on the remote. System shortcuts (⌘Tab, ⌘Space, Mission Control, and ⌘⌥Esc itself, which opens
/// Force Quit) never reach the app without a `CGEventTap` and the Accessibility permission: open
/// item, see TRD › Input.
///
/// The pointer is forwarded whether or not the keyboard is captured.
@MainActor
final class SessionInputController {
    /// Messages to send, in order.
    var onInput: (([ClientMessage]) -> Void)?
    /// Called when `isCapturing` changes (for the toolbar's "Keyboard captured" pill).
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
    /// The user wants the keyboard captured; ⌘⌥Esc clears it, a click sets it again.
    private(set) var captureRequested = true
    /// The view is first responder of the key window.
    private(set) var hasFocus = false

    var isCapturing: Bool { captureRequested && hasFocus }

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
        if !isCapturing { emit(translator.releaseAll()) }
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
                releaseCapture()
            } else {
                emit(translator.keyDown(key))
            }
        case .keyUp:
            emit(translator.keyUp(key))
        case .flagsChanged:
            emit(translator.flagsChanged(key))
        default:
            return false
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
