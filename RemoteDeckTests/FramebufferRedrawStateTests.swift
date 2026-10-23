import CoreGraphics
import RemoteDeckCore
import Testing
@testable import RemoteDeck

struct FramebufferRedrawStateTests {
    /// A state that has drawn its first frame and is idle.
    static func idle() -> FramebufferRedrawState {
        var state = FramebufferRedrawState()
        state.setDrawableSize(CGSize(width: 2560, height: 1520))
        state.tick(drawSucceeded: true)
        return state
    }

    @Test func owesTheFirstFrameThenIdles() {
        var state = FramebufferRedrawState()
        #expect(state.needsRedraw && !state.isPaused)
        state.tick(drawSucceeded: true)
        #expect(!state.needsRedraw && state.isPaused)
        // Idle ticks (the link fires once more before pausing) owe nothing.
        state.tick(drawSucceeded: true)
        #expect(state.isPaused)
    }

    /// A background session tab: nothing drawn while hidden, whatever arrives; one frame once shown.
    @Test func hiddenOwesNoTickUntilShown() {
        var state = Self.idle()
        state.setVisible(false)
        #expect(state.isPaused)
        state.contentChanged()
        state.setScalingMode(.actual)
        #expect(state.needsRedraw && state.isPaused)
        state.setVisible(true)
        #expect(!state.isPaused)
        state.tick(drawSucceeded: true)
        #expect(state.isPaused)
        // Shown again with nothing new: one frame anyway (the current texture).
        state.setVisible(false)
        state.setVisible(true)
        #expect(!state.isPaused)
        state.setVisible(true)   // unchanged: nothing more
        state.tick(drawSucceeded: true)
        #expect(state.isPaused)
    }

    @Test func retriesAfterAFailedDraw() {
        var state = Self.idle()
        state.contentChanged()
        state.tick(drawSucceeded: false)   // no drawable this tick
        #expect(state.needsRedraw && !state.isPaused)
        state.tick(drawSucceeded: false)
        #expect(state.needsRedraw)
        state.tick(drawSucceeded: true)
        #expect(state.isPaused)
    }

    @Test func everyTriggerOwesOneFrame() {
        let triggers: [(String, (inout FramebufferRedrawState) -> Void)] = [
            ("upload or resize", { $0.contentChanged() }),
            ("scaling mode", { $0.setScalingMode(.actual) }),
            ("scroll offset", { $0.setScrollOffset(CGPoint(x: 10, y: 0)) }),
            ("backing scale", { $0.setBackingScale(1) }),
            ("drawable size", { $0.setDrawableSize(CGSize(width: 100, height: 100)) }),
        ]
        for (name, trigger) in triggers {
            var state = Self.idle()
            trigger(&state)
            #expect(!state.isPaused, "\(name)")
            state.tick(drawSucceeded: true)
            #expect(state.isPaused, "\(name)")
        }
    }

    @Test func unchangedValuesOweNothing() {
        var state = Self.idle()
        state.setScalingMode(.fit)
        state.setScrollOffset(.zero)
        state.setBackingScale(2)
        state.setDrawableSize(CGSize(width: 2560, height: 1520))
        #expect(state.isPaused)
    }

    @Test func storesTheLatestValues() {
        var state = Self.idle()
        state.setScalingMode(.actual)
        state.setScrollOffset(CGPoint(x: 3, y: 4))
        state.setBackingScale(1)
        #expect(state.scalingMode == .actual)
        #expect(state.scrollOffset == CGPoint(x: 3, y: 4))
        #expect(state.backingScale == 1)
        #expect(state.drawableSize == CGSize(width: 2560, height: 1520))
    }
}
