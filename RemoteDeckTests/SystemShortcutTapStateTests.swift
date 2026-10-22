import AppKit
import Testing
@testable import RemoteDeck

struct SystemShortcutTapStateTests {
    static func state(capturing: Bool = true, windowKey: Bool = true, trusted: Bool = true) -> SystemShortcutTapState {
        var state = SystemShortcutTapState()
        state.update(capturing: capturing, windowKey: windowKey, trusted: trusted)
        return state
    }

    @Test func tapOnlyWhileCapturingInTheKeyWindowWithTrust() {
        #expect(Self.state().wantsTap)
        #expect(!Self.state(capturing: false).wantsTap)
        #expect(!Self.state(windowKey: false).wantsTap)
        #expect(!Self.state(trusted: false).wantsTap)
        #expect(!SystemShortcutTapState().wantsTap)
    }

    /// Release, focus loss and teardown (all false) remove it at once; capturing again brings it back.
    @Test func goesAwayAtOnceAndComesBack() {
        var state = Self.state()
        state.update(capturing: false, windowKey: true, trusted: true)     // ⌃⌥⌘R
        #expect(!state.wantsTap)
        state.update(capturing: true, windowKey: true, trusted: true)      // click
        #expect(state.wantsTap)
        state.update(capturing: false, windowKey: false, trusted: true)    // another app, window closed
        #expect(!state.wantsTap)
    }

    @Test func reenablesAfterASystemDisableOnlyIfStillWanted() {
        var state = Self.state()
        #expect(state.shouldReenableAfterSystemDisable)
        state.update(capturing: false, windowKey: true, trusted: true)
        #expect(!state.shouldReenableAfterSystemDisable)
        state.update(capturing: true, windowKey: true, trusted: false)     // trust revoked
        #expect(!state.shouldReenableAfterSystemDisable)
    }

    @Test func untrustedOrFailedMeansUnavailable() {
        #expect(Self.state(trusted: true).systemShortcutsAvailable)
        #expect(!Self.state(trusted: false).systemShortcutsAvailable)
        // Trusted but the tap could not be created (e.g. the sandbox or TCC refused it).
        var state = Self.state()
        state.tapCreationFailed()
        #expect(!state.systemShortcutsAvailable && !state.wantsTap)
        // Not retried on a focus change while still capturing…
        state.update(capturing: true, windowKey: false, trusted: true)
        state.update(capturing: true, windowKey: true, trusted: true)
        #expect(!state.wantsTap)
        // …but on the next capture start, or when the trust changes.
        state.update(capturing: false, windowKey: true, trusted: true)
        state.update(capturing: true, windowKey: true, trusted: true)
        #expect(state.wantsTap)
        state.tapCreationFailed()
        state.update(capturing: true, windowKey: true, trusted: false)
        state.update(capturing: true, windowKey: true, trusted: true)
        #expect(state.wantsTap)
    }
}

struct AccessibilityPromptPolicyTests {
    @Test func promptsOnceOnTheFirstUntrustedCaptureStart() {
        var policy = AccessibilityPromptPolicy()
        let answers = [policy.shouldPrompt(captureStarted: false, trusted: false),   // launch, focus changes
                       policy.shouldPrompt(captureStarted: true, trusted: true),
                       policy.shouldPrompt(captureStarted: true, trusted: false),
                       policy.shouldPrompt(captureStarted: true, trusted: false)]    // later captures, other sessions
        #expect(answers == [false, false, true, false])
    }
}

@MainActor
struct SystemShortcutTapTests {
    /// Without the permission: no tap, unavailable, one prompt per run, and the debug line says so.
    @Test func untrustedNeverInstallsAndPromptsOnce() {
        SystemShortcutTap.promptPolicy = AccessibilityPromptPolicy()
        let tap = SystemShortcutTap()
        var prompts = 0
        tap.isTrusted = { false }
        tap.requestTrust = { prompts += 1 }
        tap.update(capturing: false, windowKey: true)
        #expect(prompts == 0)
        tap.update(capturing: true, windowKey: true)
        tap.update(capturing: false, windowKey: true)
        tap.update(capturing: true, windowKey: true)
        let second = SystemShortcutTap()
        second.isTrusted = { false }
        second.requestTrust = { prompts += 1 }
        second.update(capturing: true, windowKey: true)
        #expect(prompts == 1)
        #expect(!tap.isInstalled && !tap.isEnabled && !tap.systemShortcutsAvailable)
        #expect(tap.debugDescription == "tap=none trusted=false system-shortcuts=unavailable")
        tap.tearDown()
        #expect(!tap.isInstalled)
    }
}

@MainActor
struct FramebufferViewSystemShortcutTests {
    /// The view, not the toolbar, drives the tap from the capture: ⌃⌥⌘R (release) and focus loss stop
    /// it, a click (request) starts it again. Trust and prompt are stubbed before anything captures,
    /// so the test host never creates a real tap or shows a real prompt.
    @Test func captureChangesDriveTheTap() {
        let view = FramebufferView(frame: .zero)
        view.systemShortcuts.isTrusted = { false }
        view.systemShortcuts.requestTrust = {}
        var changes: [Bool] = []
        view.onCaptureChange = { changes.append($0) }
        view.input.setFocus(true)
        #expect(view.systemShortcuts.state.capturing)
        view.input.releaseCapture()
        #expect(!view.systemShortcuts.state.capturing)
        view.input.requestCapture()
        #expect(view.systemShortcuts.state.capturing)
        view.tearDownInput()
        #expect(!view.systemShortcuts.state.capturing && !view.systemShortcuts.isInstalled)
        #expect(changes == [true, false, true, false])
    }
}

/// Stands in for the CGEventTap: records what `SystemShortcutTap` does with it.
@MainActor
final class FakeEventTap: EventTapHandle {
    var isEnabled = true
    var invalidated = false
    var enableCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) {
        enableCalls.append(enabled)
        isEnabled = enabled
    }

    func invalidate() {
        invalidated = true
        isEnabled = false
    }
}

@MainActor
struct SystemShortcutTapLifecycleTests {
    /// A trusted tap with a fake handle and a private notification center: no real tap, no prompt.
    @MainActor
    final class Harness {
        let tap = SystemShortcutTap()
        let center = NotificationCenter()
        var trusted = true
        var fakes: [FakeEventTap] = []

        init() {
            // Weak: the tap can outlive the harness (its delayed trust re-check runs 0.5 s later, after
            // the test; with `unowned` that crashed the test host once the run lasted long enough).
            tap.isTrusted = { [weak self] in self?.trusted ?? false }
            tap.requestTrust = {}
            tap.trustNotificationCenter = center
            tap.makeTap = { [weak self] _ in
                let fake = FakeEventTap()
                self?.fakes.append(fake)
                return fake
            }
        }
    }

    /// One main-queue turn: blocks queued before this one have run.
    static func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func installsWhileWantedAndInvalidatesOnRemoval() {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        #expect(harness.tap.isInstalled && harness.fakes.count == 1)
        harness.tap.update(capturing: false, windowKey: true)
        #expect(!harness.tap.isInstalled && harness.fakes[0].invalidated)
    }

    /// The refcon holds the owner while a tap exists, and gives it back on removal.
    @Test func ownerOutlivesTheTap() {
        let harness = Harness()
        weak var weakTap: SystemShortcutTap?
        do {
            let tap = SystemShortcutTap()
            tap.isTrusted = { true }
            tap.requestTrust = {}
            tap.trustNotificationCenter = harness.center
            tap.makeTap = { _ in FakeEventTap() }
            tap.update(capturing: true, windowKey: true)
            weakTap = tap
        }
        #expect(weakTap != nil)   // dropped by its owner without tearDown: still alive for the callback
        weakTap?.tearDown()
        #expect(weakTap == nil)   // balanced release after invalidation
        // No tap, no extra retain.
        do {
            let tap = SystemShortcutTap()
            tap.isTrusted = { false }
            tap.update(capturing: false, windowKey: true)
            weakTap = tap
        }
        #expect(weakTap == nil)
    }

    @Test func failedCreationTakesNoRetain() {
        weak var weakTap: SystemShortcutTap?
        do {
            let tap = SystemShortcutTap()
            tap.isTrusted = { true }
            tap.requestTrust = {}
            tap.makeTap = { _ in nil }
            tap.update(capturing: true, windowKey: true)
            #expect(!tap.isInstalled && !tap.systemShortcutsAvailable)
            weakTap = tap
        }
        #expect(weakTap == nil)
    }

    /// macOS disabled the tap: re-enabled on the next main-queue turn only, after a fresh trust check.
    @Test func systemDisableReenablesLaterIfStillWanted() async {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        let fake = harness.fakes[0]
        fake.isEnabled = false
        #expect(!harness.tap.handle(.disabledBySystem))
        #expect(fake.enableCalls.isEmpty)   // not now
        await Self.nextMainTurn()
        #expect(fake.enableCalls == [true] && harness.tap.isInstalled)
    }

    /// A didResignKey already queued runs before the deferred re-check: no re-enable over another app.
    @Test func systemDisableThenFocusLossDoesNotReenable() async {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        let fake = harness.fakes[0]
        fake.isEnabled = false
        _ = harness.tap.handle(.disabledBySystem)
        harness.tap.update(capturing: false, windowKey: false)   // the pending resign
        await Self.nextMainTurn()
        #expect(fake.enableCalls.isEmpty && fake.invalidated && !harness.tap.isInstalled)
        #expect(harness.fakes.count == 1)
    }

    @Test func systemDisableWithTrustGoneRemovesTheTap() async {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        harness.trusted = false
        _ = harness.tap.handle(.disabledBySystem)
        await Self.nextMainTurn()
        #expect(!harness.tap.isInstalled && harness.fakes[0].invalidated && harness.fakes[0].enableCalls.isEmpty)
        #expect(!harness.tap.systemShortcutsAvailable)
    }

    /// `com.apple.accessibility.api` while a tap exists: trust re-read, tap removed at once if gone.
    @Test func trustNotificationRemovesTheTapWhenAccessIsRevoked() async {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        harness.trusted = false
        harness.center.post(name: SystemShortcutTap.trustChangedNotification, object: nil)
        await Self.nextMainTurn()
        #expect(!harness.tap.isInstalled && harness.fakes[0].invalidated)
    }

    @Test func trustNotificationKeepsTheTapWhileTrusted() async {
        let harness = Harness()
        harness.tap.update(capturing: true, windowKey: true)
        harness.center.post(name: SystemShortcutTap.trustChangedNotification, object: nil)
        await Self.nextMainTurn()
        #expect(harness.tap.isInstalled && !harness.fakes[0].invalidated && harness.fakes.count == 1)
    }
}
