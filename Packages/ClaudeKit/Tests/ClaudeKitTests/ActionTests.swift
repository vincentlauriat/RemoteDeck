import Foundation
import RFBKit
import Testing
@testable import ClaudeKit

struct ActionTests {
    let identity = ScreenMapping(remoteWidth: 1024, remoteHeight: 768)
    let half = ScreenMapping(remoteWidth: 2048, remoteHeight: 1536, imageWidth: 1024, imageHeight: 768)

    private func plan(_ name: String, _ input: JSONValue, mapping: ScreenMapping? = nil,
                      profile: ModifierProfile = .x11, pointer: PointerLocation? = nil) throws -> ActionPlan {
        try ActionPlanner.plan(try ComputerAction(name: name, input: input), mapping: mapping ?? identity,
                               profile: profile, pointer: pointer)
    }

    private func pointer(_ mask: UInt8, _ x: UInt16, _ y: UInt16) -> ClientMessage {
        .pointerEvent(buttonMask: mask, x: x, y: y)
    }

    private func key(_ down: Bool, _ keysym: UInt32) -> ClientMessage { .keyEvent(down: down, key: keysym) }

    @Test func parsesEveryMember() throws {
        #expect(try ComputerAction(name: "screenshot", input: [:]) == .screenshot)
        #expect(try ComputerAction(name: "zoom", input: ["region": [1, 2, 3, 4]]) == .zoom(x0: 1, y0: 2, x1: 3, y1: 4))
        #expect(try ComputerAction(name: "triple_click", input: ["coordinate": [5, 6]])
                == .click(.left, count: 3, at: ScreenPoint(x: 5, y: 6), modifiers: ""))
        #expect(try ComputerAction(name: "right_click", input: [:]) == .click(.right, count: 1, at: nil, modifiers: ""))
        #expect(try ComputerAction(name: "left_click_drag", input: ["start_coordinate": [1, 1], "coordinate": [9, 9]])
                == .drag(from: ScreenPoint(x: 1, y: 1), to: ScreenPoint(x: 9, y: 9), modifiers: ""))
        #expect(try ComputerAction(name: "scroll", input: ["scroll_direction": "down", "scroll_amount": 3])
                == .scroll(.down, amount: 3, at: nil, modifiers: ""))
        #expect(try ComputerAction(name: "key", input: ["text": "Tab", "repeat": 4]) == .key("Tab", repeat: 4))
        #expect(try ComputerAction(name: "hold_key", input: ["text": "shift", "duration": 1.5]) == .holdKey("shift", duration: 1.5))
        #expect(try ComputerAction(name: "wait", input: ["duration": 2]) == .wait(duration: 2))
        #expect(try ComputerAction(name: "cursor_position", input: [:]) == .cursorPosition)
        #expect(try ComputerAction(name: "mouse_move", input: ["coordinate": [3, 4]]) == .mouseMove(ScreenPoint(x: 3, y: 4)))
    }

    @Test func badOrWithheldMembersAreErrorsNotCrashes() {
        #expect(throws: ComputerAction.ParseError.unsupported("left_mouse_down")) {
            try ComputerAction(name: "left_mouse_down", input: [:])
        }
        #expect(throws: ComputerAction.ParseError.self) { try ComputerAction(name: "left_click", input: ["coordinate": [1]]) }
        #expect(throws: ComputerAction.ParseError.self) { try ComputerAction(name: "key", input: ["text": "a", "repeat": 101]) }
        #expect(throws: ComputerAction.ParseError.self) { try ComputerAction(name: "wait", input: ["duration": 301]) }
        #expect(throws: ComputerAction.ParseError.self) { try ComputerAction(name: "type", input: [:]) }
        #expect(ComputerAction.ParseError.unsupported("x").resultText == "Error: x is not available in this environment.")
    }

    @Test func readOnlyMembers() throws {
        for name in ["screenshot", "cursor_position"] { #expect(try ComputerAction(name: name, input: [:]).isReadOnly) }
        #expect(try ComputerAction(name: "zoom", input: ["region": [0, 0, 1, 1]]).isReadOnly)
        #expect(try ComputerAction(name: "wait", input: ["duration": 1]).isReadOnly)
        #expect(!(try ComputerAction(name: "left_click", input: [:]).isReadOnly))
        #expect(!(try ComputerAction(name: "type", input: ["text": "x"]).isReadOnly))
    }

    @Test func clickMovesPressesAndReleasesAtTheMappedPixel() throws {
        let result = try plan("left_click", ["coordinate": [100, 50]], mapping: half)
        #expect(result.messages == [pointer(0, 201, 101), pointer(1, 201, 101), pointer(0, 201, 101)])
        #expect(result.pointer == PointerLocation(x: 201, y: 101))
        let double = try plan("double_click", ["coordinate": [10, 10]])
        #expect(double.messages == [pointer(0, 10, 10), pointer(1, 10, 10), pointer(0, 10, 10), pointer(1, 10, 10), pointer(0, 10, 10)])
        let right = try plan("right_click", ["coordinate": [10, 10]])
        #expect(right.messages == [pointer(0, 10, 10), pointer(4, 10, 10), pointer(0, 10, 10)])
        let middle = try plan("middle_click", ["coordinate": [10, 10]])
        #expect(middle.messages[1] == pointer(2, 10, 10))
    }

    @Test func clickWithModifiersHoldsThemAroundTheClick() throws {
        let result = try plan("left_click", ["coordinate": [1, 2], "text": "ctrl+shift"])
        #expect(result.messages == [key(true, Keysym.controlL), key(true, Keysym.shiftL), pointer(0, 1, 2),
                                    pointer(1, 1, 2), pointer(0, 1, 2), key(false, Keysym.shiftL), key(false, Keysym.controlL)])
    }

    @Test func clickWithoutCoordinateUsesThePointerOrFails() throws {
        let result = try plan("left_click", [:], pointer: PointerLocation(x: 7, y: 8))
        #expect(result.messages == [pointer(0, 7, 8), pointer(1, 7, 8), pointer(0, 7, 8)])
        #expect(throws: ActionPlanner.Failure.noPointer) { try plan("left_click", [:]) }
    }

    @Test func outsideTheScreenshotIsRejected() {
        #expect(throws: ActionPlanner.Failure.outsideScreenshot(ScreenPoint(x: 1024, y: 10), width: 1024, height: 768)) {
            try plan("left_click", ["coordinate": [1024, 10]])
        }
        #expect(ActionPlanner.Failure.outsideScreenshot(ScreenPoint(x: 1024, y: 10), width: 1024, height: 768).resultText
                == "Error: coordinate (1024, 10) is outside the 1024x768 screenshot.")
    }

    @Test func dragHoldsTheButtonWithPausesAndReleasesAtTheEnd() throws {
        let result = try plan("left_click_drag", ["start_coordinate": [10, 10], "coordinate": [30, 50]])
        #expect(result.messages == [pointer(0, 10, 10), pointer(1, 10, 10), pointer(1, 20, 30), pointer(1, 30, 50),
                                    pointer(0, 30, 50)])
        #expect(result.steps.filter { if case .pause = $0 { true } else { false } }.count == 3)
        #expect(result.release == [pointer(0, 30, 50)])
    }

    @Test func scrollIsButtonSteps() throws {
        let down = try plan("scroll", ["coordinate": [5, 5], "scroll_direction": "down", "scroll_amount": 2])
        #expect(down.messages == [pointer(0, 5, 5), pointer(16, 5, 5), pointer(0, 5, 5), pointer(16, 5, 5), pointer(0, 5, 5)])
        for (direction, mask) in [("up", UInt8(8)), ("left", 32), ("right", 64)] {
            let result = try plan("scroll", ["coordinate": [5, 5], "scroll_direction": .string(direction), "scroll_amount": 1])
            #expect(result.messages[1] == pointer(mask, 5, 5))
        }
    }

    @Test func typeAndKeyUseKeysymsAndTheProfile() throws {
        let typed = try plan("type", ["text": "Hé\n"])
        #expect(typed.messages == [key(true, 0x48), key(false, 0x48), key(true, 0xE9), key(false, 0xE9),
                                   key(true, Keysym.return), key(false, Keysym.return)])
        let copyMac = try plan("key", ["text": "super+c"], profile: .appleRemoteDesktop)
        #expect(copyMac.messages == [key(true, Keysym.altL), key(true, 0x63), key(false, 0x63), key(false, Keysym.altL)])
        let copyX11 = try plan("key", ["text": "super+c"], profile: .x11)
        #expect(copyX11.messages.first == key(true, Keysym.superL))
        let tabs = try plan("key", ["text": "Tab", "repeat": 3])
        #expect(tabs.messages.count == 6)
        #expect(throws: ActionPlanner.Failure.badKey(.unknownKey("Hyper"))) { try plan("key", ["text": "ctrl+Hyper"]) }
        #expect(throws: ActionPlanner.Failure.untypable) { try plan("type", ["text": "a\u{7}"]) }
    }

    @Test func holdKeyPressesWaitsAndReleases() throws {
        let result = try plan("hold_key", ["text": "shift", "duration": 0.5])
        #expect(result.steps == [.send([key(true, Keysym.shiftL)]), .pause(.milliseconds(500)),
                                 .send([key(false, Keysym.shiftL)])])
        #expect(result.release == [key(false, Keysym.shiftL)])
    }

    /// Every complete plan ends with nothing held: as many key-ups as key-downs, last pointer mask 0.
    @Test func completePlansLeaveNothingHeld() throws {
        let plans = try [
            plan("left_click", ["coordinate": [1, 1], "text": "alt+shift"]),
            plan("left_click_drag", ["start_coordinate": [1, 1], "coordinate": [9, 9], "text": "super"]),
            plan("scroll", ["coordinate": [1, 1], "scroll_direction": "up", "scroll_amount": 3, "text": "ctrl"]),
            plan("key", ["text": "ctrl+alt+Delete"]),
            plan("hold_key", ["text": "ctrl+shift", "duration": 0]),
            plan("type", ["text": "Hello"]),
        ]
        for result in plans {
            var held: [UInt32: Int] = [:]
            var mask: UInt8 = 0
            for message in result.messages {
                switch message {
                case .keyEvent(let down, let keysym): held[keysym, default: 0] += down ? 1 : -1
                case .pointerEvent(let buttons, _, _): mask = buttons
                default: break
                }
            }
            #expect(held.values.allSatisfy { $0 == 0 })
            #expect(mask == 0)
        }
    }
}
