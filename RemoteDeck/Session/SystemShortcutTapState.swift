/// When `SystemShortcutTap` has an event tap. The tap exists only while the keyboard is captured, the
/// session window is key and the process is trusted for Accessibility; any of those going false
/// removes it at once. If creating it failed although trusted, it is not retried until the capture
/// starts again or the trust changes. When macOS disables the tap (callback too slow, or user input
/// such as secure event input), it is re-enabled only if it is still wanted.
///
/// Pure (no CoreGraphics): `SystemShortcutTap` creates or removes the tap to match `wantsTap`.
struct SystemShortcutTapState: Equatable {
    private(set) var capturing = false
    private(set) var windowKey = false
    private(set) var trusted = false
    /// `CGEvent.tapCreate` returned nil while trusted.
    private(set) var creationFailed = false

    var wantsTap: Bool { capturing && windowKey && trusted && !creationFailed }

    /// What T3.5's toolbar shows: `false` → "System shortcuts need Accessibility access — Open Settings".
    var systemShortcutsAvailable: Bool { trusted && !creationFailed }

    mutating func update(capturing: Bool, windowKey: Bool, trusted: Bool) {
        let captureStarted = capturing && !self.capturing
        if captureStarted || trusted != self.trusted { creationFailed = false }
        self.capturing = capturing
        self.windowKey = windowKey
        self.trusted = trusted
    }

    mutating func tapCreationFailed() {
        creationFailed = true
    }

    /// The system turned the tap off (`tapDisabledByTimeout` / `tapDisabledByUserInput`).
    var shouldReenableAfterSystemDisable: Bool { wantsTap }
}

/// The Accessibility prompt: never at launch; the first time the capture starts without trust, once
/// per app run (`SystemShortcutTap.promptPolicy` is process-wide).
struct AccessibilityPromptPolicy: Equatable {
    private(set) var hasPrompted = false

    /// `true` when the system prompt should be shown now.
    mutating func shouldPrompt(captureStarted: Bool, trusted: Bool) -> Bool {
        guard captureStarted, !trusted, !hasPrompted else { return false }
        hasPrompted = true
        return true
    }
}
