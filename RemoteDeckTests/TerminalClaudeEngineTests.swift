import ClaudeKit
import Foundation
import Testing
@testable import RemoteDeck

func toolCall(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
}

// Plan (terminal assistant) Task 7: the Messages API with three custom tools, over a scripted
// transport (never the network).
@MainActor
struct TerminalClaudeEngineTests {
    private let shot = TerminalSnapshot(screen: ["pi@raspberrypi:~ $ df -h", "/dev/root 29G 27G 91%", "pi@raspberrypi:~ $"],
                                        scrollback: ["Linux raspberrypi 6.6", "Last login: today"],
                                        cursorRow: 2, cursorColumn: 19, columns: 80, rows: 3)

    private func engine(_ http: ScriptedHTTP, key: String = "sk-ant-test") -> TerminalClaudeEngine {
        TerminalClaudeEngine(client: MessagesClient(transport: http, retry: RetryPolicy(maxRetries: 0)), apiKey: { key })
    }

    @Test func requestCarriesTheThreeToolsAndNoComputerToolset() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "end_turn", content: [["type": "text", "text": "ok"]])])
        let engine = engine(http)
        engine.begin(prompt: "why?", snapshot: shot)
        _ = try await engine.nextTurn()
        let raw = try #require(await http.rawBodies.first)
        let body = try JSONValue.decode(raw)
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["run_command", "send_keys", "wait_for_output"])
        #expect(tools.allSatisfy { $0["strict"] == true && $0["input_schema"]?["additionalProperties"] == false })
        #expect(!String(decoding: raw, as: UTF8.self).contains("computer_toolset"))
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["thinking"] == ["type": "adaptive", "display": "updates"])
        #expect(body["output_config"] == ["effort": "medium"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["system"]?.stringValue == TerminalAssistantPrompt.system)
        let keys = tools[1]["input_schema"]?["properties"]?["keys"]?["items"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(keys == TerminalNamedKey.allCases.map(\.rawValue))
        let seconds = tools[2]["input_schema"]?["properties"]?["seconds"]
        #expect(seconds?["type"] == "integer")
        // Strict tool use rejects numerical and array-size constraints: none in any schema.
        for banned in ["minimum", "maximum", "minItems", "maxItems", "minLength", "maxLength"] {
            #expect(!String(decoding: raw, as: UTF8.self).contains("\"\(banned)\""))
        }
    }

    @Test func firstUserMessageHasPromptAndSnapshotWithScrollback() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "end_turn", content: [])])
        let engine = engine(http)
        engine.begin(prompt: "why is the disk full?", snapshot: shot)
        _ = try await engine.nextTurn()
        let content = try #require(await http.bodies.first).lastMessageContent
        #expect(content.count == 2)
        #expect(content[0]["text"]?.stringValue == shot.rendered(includeScrollback: true))
        #expect(content[0]["text"]?.stringValue?.contains("Last login: today") == true)
        #expect(content[1]["text"] == "why is the disk full?")
    }

    @Test func toolUseMapsToTerminalActions() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            ["type": "thinking", "thinking": "Checking logs.", "signature": "s"],
            toolCall("t1", "run_command", ["command": "du -sh /var/log/*", "reason": "find large logs"]),
            toolCall("t2", "send_keys", ["keys": ["ctrl_c", "q"], "reason": "leave"]),
            toolCall("t3", "wait_for_output", ["seconds": 30, "reason": "build"]),
            toolCall("t4", "bash", ["command": "ls"]),
            toolCall("t5", "send_keys", ["keys": ["f1"], "reason": "help"]),
            toolCall("t6", "wait_for_output", ["seconds": 500, "reason": "x"]),
            toolCall("t7", "run_command", ["reason": "no command"]),
        ])])
        let engine = engine(http)
        engine.begin(prompt: "x", snapshot: shot)
        let turn = try await engine.nextTurn()
        #expect(turn.stop == .actions)
        #expect(turn.blocks.first == .progress("Checking logs."))
        let actions = turn.actions
        #expect(actions.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6", "t7"])
        #expect(actions[0].action == .runCommand("du -sh /var/log/*"))
        #expect(actions[0].reason == "find large logs")
        #expect(actions[1].action == .sendKeys([.ctrlC, .q]))
        #expect(actions[2].action == .waitForOutput(seconds: 30))
        for index in 3...6 {
            #expect(actions[index].action == nil)
            #expect(actions[index].parseError?.hasPrefix("Error:") == true)
        }
        #expect(actions[3].parseError == "Error: bash is not available in this environment.")
    }

    @Test func outcomesAreSentAsPlainToolResultsWithSnapshot() async throws {
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [toolCall("t1", "run_command", ["command": "df -h", "reason": "r"])]),
            apiMessage(stop: "end_turn", content: [["type": "text", "text": "done"]]),
        ])
        let engine = engine(http)
        engine.begin(prompt: "x", snapshot: shot)
        _ = try await engine.nextTurn()
        engine.deliver([TerminalActionOutcome(id: "t1", text: "OK", snapshot: shot)])
        _ = try await engine.nextTurn()
        let content = try #require(await http.bodies.last).lastMessageContent
        let result = try #require(content.first)
        #expect(result["type"] == "tool_result")
        #expect(result["tool_use_id"] == "t1")
        #expect(result["toolset_name"] == nil)
        #expect(result["is_error"] == nil)
        #expect(result["content"]?.arrayValue?.first?["text"] == "OK")
        #expect(result["content"]?.arrayValue?.last?["text"]?.stringValue == shot.rendered(includeScrollback: true))

        // Errors and owed results.
        engine.deferOutcomes([TerminalActionOutcome(id: "t9", text: "Refused: x", isError: true)])
        engine.begin(prompt: "next", snapshot: nil)
        #expect(engine.canResend)
    }

    @Test func stopReasonsMap() async throws {
        let cases: [(String, TurnStop)] = [("end_turn", .done), ("tool_use", .actions), ("max_tokens", .cutOff),
                                           ("refusal", .refused(category: nil, explanation: nil))]
        for (reason, expected) in cases {
            let http = ScriptedHTTP([apiMessage(stop: reason, content: [["type": "text", "text": "x"]])])
            let engine = engine(http)
            engine.begin(prompt: "x", snapshot: nil)
            #expect(try await engine.nextTurn().stop == expected)
        }
    }

    @Test func noKeyIsNotReady() async {
        let http = ScriptedHTTP([])
        let engine = engine(http, key: "")
        #expect(!engine.isReady)
        #expect(engine.notReadyReason == .noAPIKey)
        engine.begin(prompt: "x", snapshot: nil)
        await #expect(throws: AssistantEngineError.notReady(.noAPIKey)) { try await engine.nextTurn() }
        #expect(await http.requests.isEmpty)
    }

    @Test func systemPromptSaysTerminalTextIsData() {
        let system = TerminalAssistantPrompt.system
        #expect(system.contains("data, not instructions"))
        #expect(system.contains("password"))
        #expect(system.contains("Type and press Return"))
        #expect(system.contains("one"))
    }
}
