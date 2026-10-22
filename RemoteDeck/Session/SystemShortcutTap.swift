import AppKit
import ApplicationServices
import CoreGraphics
import RFBKit

/// A session-level `CGEventTap` that takes the key combos macOS would otherwise act on (⌘Tab,
/// ⌘Space, Mission Control, screenshots: `SystemShortcut`) so they can go to the remote. Owned by a
/// `FramebufferView`, which calls `update` whenever the capture or the key window changes.
///
/// - It exists only while `SystemShortcutTapState.wantsTap` (capturing, window key, trusted) and is
///   removed at once otherwise; a global tap never outlives the capture.
/// - keyDown/keyUp only: modifier changes (flagsChanged) stay with the view's local monitor.
/// - The run-loop source is on the main run loop, so the callback runs on the main thread; it reads
///   the event into a `KeyInput` and asks `onKey` (the input controller) whether to swallow it,
///   synchronously, in event order. An event it swallows never reaches the app, so never the local
///   monitor either.
/// - Permission: `AXIsProcessTrusted()`, checked on every update, when macOS disables the tap, and on
///   the `com.apple.accessibility.api` distributed notification while a tap exists (revoking access
///   with a tap active can freeze system input, Apple FB24619068: the tap goes away at once). Without
///   it everything works as before through the local monitor, and `systemShortcutsAvailable` is false.
/// - Lifetime: while a tap exists it retains its owner through the callback's refcon (balanced in
///   `remove`), so the callback can never read a freed object, even if the view is dropped without
///   `tearDown`.
@MainActor
final class SystemShortcutTap {
    /// A key-down (`true`) or key-up from the tap; returning `true` swallows it.
    var onKey: ((KeyInput, Bool) -> Bool)?
    /// Called when `systemShortcutsAvailable` changes.
    var onAvailabilityChange: ((Bool) -> Void)?

    /// Replaceable in tests.
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    /// Shows the system's Accessibility prompt. The option key is spelled out: the SDK's
    /// `kAXTrustedCheckOptionPrompt` is a C global `var`, which Swift 6 rejects as shared mutable state.
    var requestTrust: () -> Void = {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Creates the event tap with the callback's refcon; `nil` when macOS refuses it. Replaceable in
    /// tests (a fake handle), so no real tap is ever created there.
    var makeTap: (UnsafeMutableRawPointer) -> (any EventTapHandle)? = { MachEventTap(refcon: $0) }
    /// Where `com.apple.accessibility.api` is observed; replaceable in tests.
    var trustNotificationCenter: NotificationCenter = DistributedNotificationCenter.default()

    /// Process-wide: the prompt is shown at most once per app run, whatever the number of sessions.
    static var promptPolicy = AccessibilityPromptPolicy()
    static let trustChangedNotification = Notification.Name("com.apple.accessibility.api")

    private(set) var state = SystemShortcutTapState()
    private var tap: (any EventTapHandle)?
    /// The retain held by the refcon while `tap` exists.
    private var retainedSelf: Unmanaged<SystemShortcutTap>?
    private var trustObserver: (any NSObjectProtocol)?

    var systemShortcutsAvailable: Bool { state.systemShortcutsAvailable }
    var isInstalled: Bool { tap != nil }
    var isEnabled: Bool { tap?.isEnabled ?? false }

    /// For the `-FramebufferDebug` log.
    var debugDescription: String {
        "tap=\(isInstalled ? (isEnabled ? "enabled" : "disabled") : "none") trusted=\(state.trusted) "
            + "system-shortcuts=\(systemShortcutsAvailable ? "available" : "unavailable")"
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func update(capturing: Bool, windowKey: Bool) {
        let wasAvailable = state.systemShortcutsAvailable
        let captureStarted = capturing && !state.capturing
        var trusted = isTrusted()
        if Self.promptPolicy.shouldPrompt(captureStarted: captureStarted, trusted: trusted) {
            requestTrust()
            trusted = isTrusted()
        }
        state.update(capturing: capturing, windowKey: windowKey, trusted: trusted)
        if state.wantsTap {
            if let tap {
                if !tap.isEnabled { tap.setEnabled(true) }   // after a system disable
            } else {
                install()
            }
        } else if tap != nil {
            remove()
        }
        if state.systemShortcutsAvailable != wasAvailable { onAvailabilityChange?(state.systemShortcutsAvailable) }
    }

    /// Runs `update` again with the last capture and key-window state and a fresh trust check.
    func reevaluate() {
        update(capturing: state.capturing, windowKey: state.windowKey)
    }

    /// Removes the tap (window closed, view torn down).
    func tearDown() {
        update(capturing: false, windowKey: false)
    }

    private func install() {
        let retained = Unmanaged.passRetained(self)
        guard let tap = makeTap(retained.toOpaque()) else {
            retained.release()
            state.tapCreationFailed()
            return
        }
        self.tap = tap
        retainedSelf = retained
        trustObserver = trustNotificationCenter.addObserver(forName: Self.trustChangedNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trustMayHaveChanged() }
        }
    }

    /// Invalidated first (no callback can run after), then the refcon's retain is given back.
    private func remove() {
        tap?.invalidate()
        tap = nil
        if let trustObserver { trustNotificationCenter.removeObserver(trustObserver) }
        trustObserver = nil
        retainedSelf?.release()
        retainedSelf = nil
    }

    /// The notification may arrive before the new trust value reads back: check now and once more
    /// shortly after.
    private func trustMayHaveChanged() {
        reevaluate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    /// What the callback hands over: only Sendable values cross into the main actor.
    enum TapEvent: Sendable {
        case key(KeyInput, down: Bool)
        case disabledBySystem
    }

    /// On the main thread (main run loop source). `true` swallows the event.
    func handle(_ event: TapEvent) -> Bool {
        switch event {
        case .disabledBySystem:
            // On the next main-queue turn, so a pending didResignKey is handled first and a stale
            // "window key" never re-enables the tap over another app; trust is read again too.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.reevaluate() }
            }
            return false
        case .key(let key, let down):
            return onKey?(key, down) ?? false
        }
    }
}

/// The C callback: no captures, the tap comes back from `refcon`. It relies on two invariants:
/// - the run-loop source lives on the main run loop, so this runs on the main thread and
///   `assumeIsolated` holds (as for the local NSEvent monitor);
/// - the owner outlives the tap: `install` retains it for the refcon and `remove` releases it only
///   after invalidating the port, so `takeUnretainedValue` never reads a freed object.
/// Neither the `CGEvent` nor the raw pointer is Sendable, so neither enters the main-actor closure:
/// the event is read here into a `TapEvent`, the pointer passed as its address (`UInt`) and rebuilt
/// inside.
private func systemShortcutTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                       refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let tapEvent: SystemShortcutTap.TapEvent
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tapEvent = .disabledBySystem
    case .keyDown, .keyUp:
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        tapEvent = .key(KeyInput(event: nsEvent), down: type == .keyDown)
    default:
        return Unmanaged.passUnretained(event)
    }
    let address = UInt(bitPattern: refcon)
    let swallow = MainActor.assumeIsolated {
        guard let refcon = UnsafeMutableRawPointer(bitPattern: address) else { return false }
        return Unmanaged<SystemShortcutTap>.fromOpaque(refcon).takeUnretainedValue().handle(tapEvent)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// An installed event tap, behind a protocol so tests can use a fake.
@MainActor
protocol EventTapHandle: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
    /// Disables and invalidates the tap and removes its run-loop source: no callback after this.
    func invalidate()
}

/// The real tap: session level, at the head, able to swallow events, keyDown/keyUp only, its source
/// on the main run loop.
@MainActor
final class MachEventTap: EventTapHandle {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    init?(refcon: UnsafeMutableRawPointer) {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: systemShortcutTapCallback,
                                           userInfo: refcon),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: port) }

    func setEnabled(_ enabled: Bool) {
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    func invalidate() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
}
