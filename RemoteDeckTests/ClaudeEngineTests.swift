import ClaudeKit
import Foundation
import RFBKit
import Testing
@testable import RemoteDeck

/// The Claude provider behind the engine seam: the same wire as before it (the end-to-end request
/// body tests stay in `AssistantModelTests`, which build the model through `ClaudeEngine`).
@MainActor
struct ClaudeEngineTests {
    private func engine(_ http: ScriptedHTTP, key: String = "sk-ant-test") -> ClaudeEngine {
        ClaudeEngine(client: MessagesClient(transport: http, retry: RetryPolicy(maxRetries: 0)), apiKey: { key })
    }

    @Test func turnMapsBlocksStopAndUsage() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            ["type": "thinking", "thinking": "", "signature": "s"],
            ["type": "thinking", "thinking": "Looking.", "signature": "s"],
            ["type": "text", "text": "Clicking."],
            memberCall("toolu_1", "left_click", ["coordinate": [10, 20]]),
            memberCall("toolu_2", "left_mouse_down"),
            ["type": "tool_use", "id": "toolu_3", "name": "left_click", "input": ["coordinate": [1, 1]]],
        ])])
        let engine = engine(http)
        engine.begin(prompt: "x", screenshot: nil, desktop: .x11)
        let turn = try await engine.nextTurn { nil }
        #expect(turn.stop == .actions)
        #expect(turn.usage?.total == 120)
        #expect(turn.blocks.prefix(2) == [.progress("Looking."), .answer("Clicking.")])
        let actions = turn.actions
        #expect(actions.map(\.id) == ["toolu_1", "toolu_2", "toolu_3"])
        #expect(actions[0].action == .click(.left, count: 1, at: ScreenPoint(x: 10, y: 20), modifiers: ""))
        #expect(actions[0].parseError == nil)
        #expect(actions[1].parseError == "Error: left_mouse_down is not available in this environment.")
        // Outside the computer toolset: refused before parsing, still shown as a click.
        #expect(actions[2].parseError == "Error: left_click is not available in this environment.")
        #expect(actions[2].action != nil)
    }

    @Test func outcomesAreTheSameToolResults() async throws {
        let image = try ScreenshotEncoder.encode(try Framebuffer(width: 64, height: 48))
        #expect(ClaudeEngine.result(ActionOutcome(id: "a", text: ToolResultText.ok))
                == ContentBlock.toolResult(id: "a", text: ToolResultText.ok))
        #expect(ClaudeEngine.result(ActionOutcome(id: "b", text: ToolResultText.skipped, isError: true))
                == ContentBlock.toolResult(id: "b", text: ToolResultText.skipped, isError: true))
        #expect(ClaudeEngine.result(ActionOutcome(id: "c", image: image))
                == ContentBlock.toolResult(id: "c", content: [ContentBlock.image(image)]))
    }

    @Test func noKeyIsNotReadyAndSendsNothing() async throws {
        let http = ScriptedHTTP([])
        let engine = engine(http, key: "")
        #expect(!engine.isReady)
        #expect(engine.notReadyReason == .noAPIKey)
        engine.begin(prompt: "x", screenshot: nil, desktop: .x11)
        await #expect(throws: AssistantEngineError.notReady(.noAPIKey)) { try await engine.nextTurn { nil } }
        #expect(await http.requests.isEmpty)
    }

    @Test func stopReasonsMapToTurnStops() async throws {
        for (raw, stop) in [("end_turn", TurnStop.done), ("max_tokens", .cutOff), ("pause_turn", .cutOff),
                            ("model_context_window_exceeded", .cutOff), ("stop_sequence", .done)] {
            let engine = engine(ScriptedHTTP([apiMessage(stop: raw, content: [])]))
            engine.begin(prompt: "x", screenshot: nil, desktop: .x11)
            #expect(try await engine.nextTurn { nil }.stop == stop, "\(raw)")
        }
    }
}

