import AppKit
import CoreGraphics
import RemoteDeckCore
import RFBKit
import Testing
@testable import RemoteDeck

struct PointerGeometryTests {
    /// Points exactly on the right/bottom edge of the content map to the last column/row (closed
    /// interval), in every mode and backing scale.
    @Test(arguments: [
        (1920, 1080, CGSize(width: 960, height: 960.75), CGFloat(1), ScalingMode.fit),
        (1920, 1080, CGSize(width: 1000, height: 700), CGFloat(2), ScalingMode.fit),
        (37, 23, CGSize(width: 30, height: 20), CGFloat(2), ScalingMode.actual),
        (2880, 1800, CGSize(width: 1440, height: 900), CGFloat(2), ScalingMode.actual),
        (640, 400, CGSize(width: 1280, height: 800), CGFloat(1), ScalingMode.fit),
    ])
    func contentEdgesClampToTheLastPixel(width: Int, height: Int, view: CGSize, backingScale: CGFloat,
                                         mode: ScalingMode) throws {
        let geometry = FramebufferGeometry(remoteWidth: width, remoteHeight: height, viewSize: view,
                                           backingScale: backingScale, mode: mode)
        let rect = geometry.contentRect
        let corner = try #require(geometry.pointerPixel(forViewPoint: CGPoint(x: rect.maxX, y: rect.maxY),
                                                        clampingOutside: false))
        #expect(corner.x == width - 1 && corner.y == height - 1)
        let origin = try #require(geometry.pointerPixel(forViewPoint: rect.origin, clampingOutside: false))
        #expect(origin.x == 0 && origin.y == 0)
        // `remotePixel` (half-open, for drawing) leaves the edge out; the pointer mapping does not.
        #expect(geometry.remotePixel(forViewPoint: CGPoint(x: rect.maxX, y: rect.maxY)) == nil)
    }

    @Test func letterboxIsNilUnlessDragging() throws {
        // 1920 × 1080 in 960 × 960.75 pt: content y 210…750.
        let geometry = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: CGSize(width: 960, height: 960.75),
                                           backingScale: 1, mode: .fit)
        #expect(geometry.pointerPixel(forViewPoint: CGPoint(x: 480, y: 100), clampingOutside: false) == nil)
        #expect(geometry.pointerPixel(forViewPoint: CGPoint(x: 480, y: 900), clampingOutside: false) == nil)
        let above = try #require(geometry.pointerPixel(forViewPoint: CGPoint(x: 480, y: 100), clampingOutside: true))
        #expect(above.x == 960 && above.y == 0)
        let below = try #require(geometry.pointerPixel(forViewPoint: CGPoint(x: 2000, y: 900), clampingOutside: true))
        #expect(below.x == 1919 && below.y == 1079)
    }
}

@MainActor
struct SessionInputControllerTests {
    /// A focused controller whose output is collected.
    @MainActor
    final class Harness {
        let controller = SessionInputController(profile: .appleRemoteDesktop)
        var sent: [ClientMessage] = []

        init() {
            controller.onInput = { [unowned self] in sent += $0 }
            controller.setFocus(true)
        }
    }

    static func key(_ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String = "",
                    flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    static func flags(_ keyCode: UInt16, _ flags: CGEventFlags) throws -> NSEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        return try #require(NSEvent(cgEvent: event))
    }

    static func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// 1920 × 1080 remote, fit into 960 × 960.75 pt at Retina scale: 0.5 pt per pixel, content y 210…750.
    static let fit = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: CGSize(width: 960, height: 960.75),
                                         backingScale: 2, mode: .fit)
    /// Same remote at actual size on Retina: 0.5 pt per pixel, scrolled by (100, 50) pt.
    static let actual = FramebufferGeometry(remoteWidth: 1920, remoteHeight: 1080, viewSize: CGSize(width: 800, height: 400),
                                            backingScale: 2, mode: .actual, scrollOffset: CGPoint(x: 100, y: 50))

    @Test func commandCFromNSEvents() throws {
        let harness = Harness()
        let cmd: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        for event in [try Self.flags(0x37, cmd), try Self.key(.keyDown, 0x08, "c", flags: [.command]),
                      try Self.key(.keyUp, 0x08, "c", flags: [.command]), try Self.flags(0x37, [])] {
            #expect(harness.controller.handleKey(event))
        }
        #expect(harness.sent == [.keyEvent(down: true, key: Keysym.altL), .keyEvent(down: true, key: 0x63),
                                 .keyEvent(down: false, key: 0x63), .keyEvent(down: false, key: Keysym.altL)])
    }

    /// ⌃⌥⌘R: the three modifiers went to the remote through flagsChanged before the R; all of them
    /// are released, the R is never sent, and the remote ends with nothing held.
    @Test func releaseShortcutReleasesEverythingAndStopsCapturing() throws {
        let harness = Harness()
        var changes: [Bool] = []
        harness.controller.onCaptureChange = { changes.append($0) }
        let ctrl = CGEventFlags(rawValue: 0x01), opt = CGEventFlags(rawValue: 0x20), cmd = CGEventFlags(rawValue: 0x08)
        _ = harness.controller.handleKey(try Self.flags(0x3B, [.maskControl, ctrl]))
        _ = harness.controller.handleKey(try Self.flags(0x3A, [.maskControl, .maskAlternate, ctrl, opt]))
        _ = harness.controller.handleKey(try Self.flags(0x37, [.maskControl, .maskAlternate, .maskCommand, ctrl, opt, cmd]))
        // AZERTY or QWERTY, the R key types "®" with ⌥ here: only the key code counts.
        #expect(harness.controller.handleKey(try Self.key(.keyDown, 0x0F, "®", flags: [.control, .option, .command, .capsLock])))
        #expect(!harness.controller.isCapturing)
        #expect(changes == [false])
        #expect(harness.sent == [.keyEvent(down: true, key: Keysym.controlL), .keyEvent(down: true, key: Keysym.metaL),
                                 .keyEvent(down: true, key: Keysym.altL),
                                 .keyEvent(down: false, key: Keysym.altL), .keyEvent(down: false, key: Keysym.metaL),
                                 .keyEvent(down: false, key: Keysym.controlL)])
        #expect(harness.controller.translator.heldKeysyms.isEmpty)
        // Released: the R's key-up, the modifier releases and other keys are left to AppKit (local
        // menus work again) until a click captures again.
        #expect(!harness.controller.handleKey(try Self.key(.keyUp, 0x0F, "r", flags: [.control, .option, .command])))
        #expect(!harness.controller.handleKey(try Self.flags(0x37, [])))
        #expect(!harness.controller.handleKey(try Self.key(.keyDown, 0x00, "a")))
        #expect(harness.sent.count == 6)
        harness.controller.requestCapture()
        #expect(harness.controller.isCapturing)
        #expect(changes == [false, true])
    }

    @Test func extraShiftIsNotTheReleaseShortcut() throws {
        let harness = Harness()
        #expect(harness.controller.handleKey(try Self.key(.keyDown, 0x0F, "R", flags: [.control, .option, .command, .shift])))
        #expect(harness.controller.isCapturing)
        #expect(harness.sent.last == .keyEvent(down: true, key: 0x52))   // R, after the modifiers, like any key
    }

    /// ⌘1…⌘9 go back to AppKit, key-up included; the remote only sees ⌘ go down and up. ⌘W still
    /// goes to the remote.
    @Test func commandDigitStaysLocal() throws {
        let harness = Harness()
        let cmd: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        #expect(harness.controller.handleKey(try Self.flags(0x37, cmd)))
        // AZERTY: the 1 key types "&" without Shift.
        #expect(!harness.controller.handleKey(try Self.key(.keyDown, 0x12, "&", flags: [.command])))
        #expect(!harness.controller.handleKey(try Self.key(.keyUp, 0x12, "&", flags: [.command])))
        #expect(harness.controller.handleKey(try Self.key(.keyDown, 0x0D, "w", flags: [.command])))
        #expect(harness.controller.handleKey(try Self.key(.keyUp, 0x0D, "w", flags: [.command])))
        #expect(harness.controller.handleKey(try Self.flags(0x37, [])))
        #expect(harness.sent == [.keyEvent(down: true, key: Keysym.altL), .keyEvent(down: true, key: 0x77),
                                 .keyEvent(down: false, key: 0x77), .keyEvent(down: false, key: Keysym.altL)])
    }

    /// The tap path takes ⌘Tab (down, repeat, and the key-up after ⌘ is already up) and nothing else;
    /// what it leaves goes to the local path. Each event is handled by one path only.
    @Test func systemComboGoesThroughTheTapPathOnly() throws {
        let harness = Harness()
        let cmd: CGEventFlags = [.maskCommand, CGEventFlags(rawValue: 0x08)]
        #expect(harness.controller.handleKey(try Self.flags(0x37, cmd)))
        #expect(harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, 0x30, "\t", flags: [.command])), down: true))
        #expect(harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, 0x30, "\t", flags: [.command])), down: true))   // repeat
        #expect(harness.controller.handleKey(try Self.flags(0x37, [])))
        #expect(harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyUp, 0x30, "\t")), down: false))
        // Not system combos: left to the local monitor.
        #expect(!harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, 0x00, "a")), down: true))
        #expect(!harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyUp, 0x00, "a")), down: false))
        #expect(!harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, 0x30, "\t")), down: true))
        #expect(harness.sent == [.keyEvent(down: true, key: Keysym.altL), .keyEvent(down: true, key: Keysym.tab),
                                 .keyEvent(down: true, key: Keysym.tab), .keyEvent(down: false, key: Keysym.tab),
                                 .keyEvent(down: false, key: Keysym.altL)])
        #expect(harness.controller.translator.heldKeysyms.isEmpty)
    }

    /// ⌘3 held (local), ⇧ added during the repeat: ⌘⇧3 is a system combo, but the key stays local until
    /// its key-up, so nothing is left behind and the next plain 3 goes to the remote.
    @Test func localKeyTurningIntoASystemComboStaysLocal() throws {
        let harness = Harness()
        let cmd = CGEventFlags(rawValue: 0x08), shift = CGEventFlags(rawValue: 0x02)
        let three: UInt16 = 0x14
        #expect(harness.controller.handleKey(try Self.flags(0x37, [.maskCommand, cmd])))
        #expect(!harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, three, "3", flags: [.command])), down: true))
        #expect(!harness.controller.handleKey(try Self.key(.keyDown, three, "3", flags: [.command])))
        #expect(harness.controller.handleKey(try Self.flags(0x38, [.maskCommand, .maskShift, cmd, shift])))
        let repeatWithShift = try Self.key(.keyDown, three, "#", flags: [.command, .shift])
        #expect(!harness.controller.handleSystemKey(KeyInput(event: repeatWithShift), down: true))
        #expect(!harness.controller.handleKey(repeatWithShift))
        let up = try Self.key(.keyUp, three, "#", flags: [.command, .shift])
        #expect(!harness.controller.handleSystemKey(KeyInput(event: up), down: false))
        #expect(!harness.controller.handleKey(up))
        #expect(harness.controller.handleKey(try Self.flags(0x38, [.maskCommand, cmd])))
        #expect(harness.controller.handleKey(try Self.flags(0x37, [])))
        harness.sent = []
        let plain = try Self.key(.keyDown, three, "3")
        #expect(!harness.controller.handleSystemKey(KeyInput(event: plain), down: true))
        #expect(harness.controller.handleKey(plain))
        #expect(harness.sent == [.keyEvent(down: true, key: 0x33)])
    }

    @Test func tapPathTakesNothingWhenNotCapturing() throws {
        let harness = Harness()
        harness.controller.releaseCapture()
        #expect(!harness.controller.handleSystemKey(KeyInput(event: try Self.key(.keyDown, 0x30, "\t", flags: [.command])), down: true))
        #expect(harness.sent.isEmpty)
    }

    /// Switching profile with ⌘ still down: released under the old keysym, pressed under the new one.
    @Test func profileChangeRepressesHeldModifiers() throws {
        let harness = Harness()
        harness.controller.currentModifierFlags = { [.command, .leftCommand] }
        _ = harness.controller.handleKey(try Self.flags(0x37, [.maskCommand, CGEventFlags(rawValue: 0x08)]))
        harness.sent = []
        harness.controller.profile = .x11
        #expect(harness.sent == [.keyEvent(down: false, key: Keysym.altL), .keyEvent(down: true, key: Keysym.superL)])
    }

    @Test func losingFocusReleasesHeldKeys() throws {
        let harness = Harness()
        _ = harness.controller.handleKey(try Self.flags(0x38, [.maskShift, CGEventFlags(rawValue: 0x02)]))
        _ = harness.controller.handleKey(try Self.key(.keyDown, 0x00, "A", flags: [.shift]))
        harness.sent = []
        harness.controller.setFocus(false)
        #expect(harness.sent == [.keyEvent(down: false, key: 0x41), .keyEvent(down: false, key: Keysym.shiftL)])
        #expect(!harness.controller.handleKey(try Self.key(.keyDown, 0x00, "a")))
    }

    @Test func pointerInFitModeOnRetina() throws {
        let harness = Harness()
        let controller = harness.controller
        controller.handlePointer(try Self.mouse(.mouseMoved), at: CGPoint(x: 480, y: 100), geometry: Self.fit)   // letterbox
        controller.handlePointer(try Self.mouse(.leftMouseDown), at: CGPoint(x: 480, y: 100), geometry: Self.fit)
        controller.handlePointer(try Self.mouse(.mouseMoved), at: CGPoint(x: 10.25, y: 215), geometry: Self.fit)
        controller.handlePointer(try Self.mouse(.leftMouseDown), at: CGPoint(x: 960, y: 750), geometry: Self.fit)  // edge
        controller.handlePointer(try Self.mouse(.leftMouseDragged), at: CGPoint(x: 2000, y: 900), geometry: Self.fit)
        controller.handlePointer(try Self.mouse(.leftMouseUp), at: CGPoint(x: 2000, y: 900), geometry: Self.fit)
        #expect(harness.sent == [.pointerEvent(buttonMask: 0, x: 20, y: 10), .pointerEvent(buttonMask: 1, x: 1919, y: 1079),
                                 .pointerEvent(buttonMask: 0, x: 1919, y: 1079)])
    }

    @Test func pointerInActualModeOnRetinaWithRightAndMiddleButtons() throws {
        let harness = Harness()
        let controller = harness.controller
        // Content origin (−100, −50) pt: view (0, 0) is remote (200, 100).
        controller.handlePointer(try Self.mouse(.rightMouseDown), at: CGPoint(x: 0, y: 0), geometry: Self.actual)
        controller.handlePointer(try Self.mouse(.rightMouseUp), at: CGPoint(x: 0.5, y: 0), geometry: Self.actual)
        let center = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                          mouseButton: .center))
        let middle = try #require(NSEvent(cgEvent: center))
        controller.handlePointer(middle, at: CGPoint(x: 1, y: 1), geometry: Self.actual)
        #expect(harness.sent == [.pointerEvent(buttonMask: 4, x: 200, y: 100), .pointerEvent(buttonMask: 0, x: 201, y: 100),
                                 .pointerEvent(buttonMask: 2, x: 202, y: 102)])
    }

    @Test func pixelScrollFromAnEvent() throws {
        let harness = Harness()
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0,
                                         wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: event))
        harness.controller.handlePointer(scroll, at: CGPoint(x: 10, y: 215), geometry: Self.fit)
        #expect(scroll.hasPreciseScrollingDeltas)
        #expect(harness.sent == [.pointerEvent(buttonMask: 8, x: 20, y: 10), .pointerEvent(buttonMask: 0, x: 20, y: 10)])
    }

    /// The main-actor share of the latency budget: NSEvent → messages handed to `onInput`. Asserted
    /// loosely (CI runners vary); the measured value is printed.
    @Test func translationCostPerEvent() throws {
        let harness = Harness()
        var count = 0
        harness.controller.onInput = { count += $0.count }
        let down = try Self.key(.keyDown, 0x00, "a"), up = try Self.key(.keyUp, 0x00, "a")
        let move = try Self.mouse(.mouseMoved)
        let clock = ContinuousClock()
        let rounds = 2_000
        let elapsed = clock.measure {
            for index in 0..<rounds {
                _ = harness.controller.handleKey(down)
                _ = harness.controller.handleKey(up)
                harness.controller.handlePointer(move, at: CGPoint(x: Double(index % 900), y: 300), geometry: Self.fit)
            }
        }
        let perEvent = elapsed / .microseconds(1) / Double(rounds * 3)
        print(String(format: "input-latency NSEvent→messages: %.2f µs per event (n=%d)", perEvent, rounds * 3))
        #expect(count == rounds * 3)
        #expect(perEvent < 1_000)
    }
}
