import Foundation
import RFBKit

/// A point in the pixel space of the screenshots sent to Claude.
public struct ScreenPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// One member call of the computer toolset, read from its `tool_use` block: the action is the block's
/// `name`, its fields are the `input` (computer use docs, member table). `left_mouse_down` and
/// `left_mouse_up` are withheld in the tools entry, so they come back as `unsupported`.
public enum ComputerAction: Sendable, Equatable {
    public enum MouseButton: Sendable, Equatable { case left, middle, right }
    public enum ScrollDirection: String, Sendable, Equatable { case up, down, left, right }

    case screenshot
    /// `region: [x0, y0, x1, y1]`.
    case zoom(x0: Int, y0: Int, x1: Int, y1: Int)
    /// `left_click`, `right_click`, `middle_click`, `double_click` (count 2), `triple_click` (count 3);
    /// at `point`, or where the cursor is; `modifiers` held during the click (`text`).
    case click(MouseButton, count: Int, at: ScreenPoint?, modifiers: String)
    case drag(from: ScreenPoint, to: ScreenPoint, modifiers: String)
    case mouseMove(ScreenPoint)
    case cursorPosition
    case scroll(ScrollDirection, amount: Int, at: ScreenPoint?, modifiers: String)
    case type(String)
    case key(String, repeat: Int)
    /// Seconds, at most `maxDuration`.
    case holdKey(String, duration: Double)
    case wait(duration: Double)

    /// `hold_key` and `wait` accept up to 300 s.
    public static let maxDuration = 300.0
    /// `key` repeats 1…100.
    public static let maxRepeat = 100

    public enum ParseError: Error, Sendable, Equatable {
        /// A member this client does not run (withheld, or unknown): answered with `is_error`.
        case unsupported(String)
        /// A field missing or of the wrong shape.
        case invalidInput(String)

        /// The `is_error` result text.
        public var resultText: String {
            switch self {
            case .unsupported(let name): "Error: \(name) is not available in this environment."
            case .invalidInput(let detail): "Error: invalid input: \(detail)."
            }
        }
    }

    public init(name: String, input: JSONValue) throws(ParseError) {
        func point(_ key: String) throws(ParseError) -> ScreenPoint? {
            guard let value = input[key] else { return nil }
            guard let pair = value.arrayValue, pair.count == 2, let x = pair[0].intValue, let y = pair[1].intValue else {
                throw .invalidInput("\(key) must be [x, y]")
            }
            return ScreenPoint(x: x, y: y)
        }
        func required(_ key: String) throws(ParseError) -> ScreenPoint {
            guard let value = try point(key) else { throw .invalidInput("\(key) is required") }
            return value
        }
        func text(required: Bool = true) throws(ParseError) -> String {
            guard let value = input["text"] else {
                if required { throw .invalidInput("text is required") }
                return ""
            }
            guard let string = value.stringValue else { throw .invalidInput("text must be a string") }
            return string
        }
        func duration() throws(ParseError) -> Double {
            guard let seconds = input["duration"]?.doubleValue, seconds >= 0, seconds <= Self.maxDuration else {
                throw .invalidInput("duration must be 0…\(Int(Self.maxDuration)) seconds")
            }
            return seconds
        }

        switch name {
        case "screenshot":
            self = .screenshot
        case "zoom":
            guard let region = input["region"]?.arrayValue, region.count == 4,
                  let x0 = region[0].intValue, let y0 = region[1].intValue,
                  let x1 = region[2].intValue, let y1 = region[3].intValue else {
                throw .invalidInput("region must be [x0, y0, x1, y1]")
            }
            self = .zoom(x0: x0, y0: y0, x1: x1, y1: y1)
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let button: MouseButton = name == "right_click" ? .right : name == "middle_click" ? .middle : .left
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            self = .click(button, count: count, at: try point("coordinate"), modifiers: try text(required: false))
        case "left_click_drag":
            self = .drag(from: try required("start_coordinate"), to: try required("coordinate"),
                         modifiers: try text(required: false))
        case "mouse_move":
            self = .mouseMove(try required("coordinate"))
        case "cursor_position":
            self = .cursorPosition
        case "scroll":
            guard let raw = input["scroll_direction"]?.stringValue, let direction = ScrollDirection(rawValue: raw) else {
                throw .invalidInput("scroll_direction must be up, down, left or right")
            }
            guard let amount = input["scroll_amount"]?.intValue, amount >= 1 else {
                throw .invalidInput("scroll_amount must be a positive number")
            }
            self = .scroll(direction, amount: min(amount, 50), at: try point("coordinate"),
                           modifiers: try text(required: false))
        case "type":
            self = .type(try text())
        case "key":
            let count = input["repeat"]?.intValue ?? 1
            guard (1...Self.maxRepeat).contains(count) else { throw .invalidInput("repeat must be 1…100") }
            self = .key(try text(), repeat: count)
        case "hold_key":
            self = .holdKey(try text(), duration: try duration())
        case "wait":
            self = .wait(duration: try duration())
        default:
            throw .unsupported(name)
        }
    }

    /// Reads the screen or only waits: runs without asking the user (no input reaches the remote).
    public var isReadOnly: Bool {
        switch self {
        case .screenshot, .zoom, .cursorPosition, .wait: true
        default: false
        }
    }

    /// The points the action targets (for the bounds check and the highlight).
    public var points: [ScreenPoint] {
        switch self {
        case .click(_, _, let point?, _), .scroll(_, _, let point?, _): [point]
        case .mouseMove(let point): [point]
        case .drag(let from, let to, _): [from, to]
        default: []
        }
    }
}

// MARK: - Planning

/// What runs on the remote for one action: input batches with pauses between them. Every batch is
/// handed to the session's `InputSender` in one call, so the user's own input cannot land inside it.
/// `release` is what an interrupted plan still sends (Stop during a drag or a held key): everything
/// a completed plan pressed, it also released.
public struct ActionPlan: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case send([ClientMessage])
        case pause(Duration)
    }

    public var steps: [Step]
    public var release: [ClientMessage]
    /// Where the pointer is once the plan ran (remote pixels).
    public var pointer: PointerLocation?

    /// Every message, in order (tests).
    public var messages: [ClientMessage] {
        steps.flatMap { step -> [ClientMessage] in
            if case .send(let messages) = step { return messages }
            return []
        }
    }
}

public enum ActionPlanner {
    public enum Failure: Error, Sendable, Equatable {
        case outsideScreenshot(ScreenPoint, width: Int, height: Int)
        case noPointer
        case badKey(KeyChord.ParseError)
        case untypable

        /// The `is_error` result text (computer use docs: "coordinates outside the display bounds").
        public var resultText: String {
            switch self {
            case .outsideScreenshot(let point, let width, let height):
                "Error: coordinate (\(point.x), \(point.y)) is outside the \(width)x\(height) screenshot."
            case .noPointer:
                "Error: the cursor position is not known yet; give a coordinate."
            case .badKey(.unknownKey(let name)), .badKey(.notAModifier(let name)):
                "Error: unknown key name \"\(name)\"."
            case .badKey(.empty):
                "Error: no key given."
            case .untypable:
                "Error: the text contains a control character that cannot be typed."
            }
        }
    }

    /// Pause inside a drag, so the remote sees press, motion and release as separate moments.
    public static let dragPause: Duration = .milliseconds(60)

    /// The plan for a non-read-only action. `pointer` is where the pointer was left, for clicks and
    /// scrolls without a coordinate.
    public static func plan(_ action: ComputerAction, mapping: ScreenMapping, profile: ModifierProfile,
                            pointer: PointerLocation?) throws(Failure) -> ActionPlan {
        func remote(_ point: ScreenPoint) throws(Failure) -> PointerLocation {
            guard let location = mapping.remotePoint(x: point.x, y: point.y) else {
                throw .outsideScreenshot(point, width: mapping.imageWidth, height: mapping.imageHeight)
            }
            return location
        }
        func modifiers(_ text: String) throws(Failure) -> KeyChord {
            do { return try KeyChord.parseModifiers(text, profile: profile) } catch { throw .badKey(error) }
        }
        func chord(_ text: String) throws(Failure) -> KeyChord {
            do { return try KeyChord.parse(text, profile: profile) } catch { throw .badKey(error) }
        }
        func move(_ at: PointerLocation, mask: UInt8 = 0) -> ClientMessage {
            .pointerEvent(buttonMask: mask, x: at.x, y: at.y)
        }

        switch action {
        case .click(let button, let count, let point, let text):
            let held = try modifiers(text)
            guard let at = try point.map(remote) ?? pointer else { throw .noPointer }
            let mask: UInt8 = switch button {
            case .left: 1
            case .middle: 2
            case .right: 4
            }
            var messages = held.press + [move(at)]
            for _ in 0..<count { messages += [move(at, mask: mask), move(at)] }
            return ActionPlan(steps: [.send(messages + held.release)], release: held.release + [move(at)], pointer: at)

        case .drag(let from, let to, let text):
            let held = try modifiers(text)
            let start = try remote(from)
            let end = try remote(to)
            let middle = PointerLocation(x: UInt16((Int(start.x) + Int(end.x)) / 2), y: UInt16((Int(start.y) + Int(end.y)) / 2))
            return ActionPlan(steps: [.send(held.press + [move(start), move(start, mask: 1)]), .pause(dragPause),
                                      .send([move(middle, mask: 1)]), .pause(dragPause),
                                      .send([move(end, mask: 1)]), .pause(dragPause),
                                      .send([move(end)] + held.release)],
                              release: [move(end)] + held.release, pointer: end)

        case .mouseMove(let point):
            let at = try remote(point)
            return ActionPlan(steps: [.send([move(at)])], release: [], pointer: at)

        case .scroll(let direction, let amount, let point, let text):
            let held = try modifiers(text)
            guard let at = try point.map(remote) ?? pointer else { throw .noPointer }
            // Buttons 4/5 up/down, 6/7 left/right (masks 8, 16, 32, 64), each step a press + release.
            let mask: UInt8 = switch direction {
            case .up: 8
            case .down: 16
            case .left: 32
            case .right: 64
            }
            var messages = held.press + [move(at)]
            for _ in 0..<amount { messages += [move(at, mask: mask), move(at)] }
            return ActionPlan(steps: [.send(messages + held.release)], release: held.release, pointer: at)

        case .type(let text):
            guard let messages = KeyChord.typing(text) else { throw .untypable }
            return ActionPlan(steps: messages.isEmpty ? [] : [.send(messages)], release: [], pointer: pointer)

        case .key(let text, let count):
            let keys = try chord(text)
            let messages = Array(repeating: keys.pressAndRelease, count: count).flatMap { $0 }
            return ActionPlan(steps: [.send(messages)], release: [], pointer: pointer)

        case .holdKey(let text, let seconds):
            let keys = try chord(text)
            return ActionPlan(steps: [.send(keys.press), .pause(.milliseconds(Int(seconds * 1000))), .send(keys.release)],
                              release: keys.release, pointer: pointer)

        case .wait(let seconds):
            return ActionPlan(steps: [.pause(.milliseconds(Int(seconds * 1000)))], release: [], pointer: pointer)

        case .screenshot, .zoom, .cursorPosition:
            return ActionPlan(steps: [], release: [], pointer: pointer)
        }
    }
}
