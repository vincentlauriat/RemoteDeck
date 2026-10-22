import AppKit
import SwiftUI
import Testing
import RemoteDeckCore
@testable import RemoteDeck

/// AppFlow › Cancel connection: Esc reaches the overlay's Cancel (`.cancelAction`) whenever the
/// session is not capturing, also when the framebuffer view showed a frame and kept the focus (a
/// Reconnect overlay after a drop).
@MainActor
struct SessionEscapeTests {
    @MainActor final class Counter: ObservableObject { var value = 0 }

    /// A window with the real framebuffer view and a SwiftUI Cancel button, as in the Session Window.
    private func makeWindow(_ counter: Counter) -> (NSWindow, () -> FramebufferView?) {
        var created: FramebufferView?
        let root = ZStack {
            FramebufferViewRepresentable(renderer: nil, scalingMode: .fit, onCreate: { created = $0 })
            Button("Cancel") { counter.value += 1 }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 400, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.layoutIfNeeded()
        return (window, { created })
    }

    private func escape(_ window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 0x35))
        window.sendEvent(event)
    }

    @Test func escapeCancelsAfterTheSessionStopped() async throws {
        let counter = Counter()
        let (window, view) = makeWindow(counter)
        defer { window.close() }
        let framebuffer = try #require(view())
        framebuffer.systemShortcuts.isTrusted = { false }
        framebuffer.systemShortcuts.requestTrust = {}

        // First frame: the view takes the focus. Then the session drops (error banner, Reconnect).
        framebuffer.startCapture()
        #expect(window.firstResponder === framebuffer)
        framebuffer.releaseCapture()

        try escape(window)
        #expect(counter.value == 1)
        framebuffer.tearDownInput()
    }
}
