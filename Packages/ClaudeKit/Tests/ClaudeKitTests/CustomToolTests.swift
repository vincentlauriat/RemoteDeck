import Foundation
import Testing
@testable import ClaudeKit

/// Custom client tools (terminal assistant): the configuration's tools replace the computer toolset,
/// and their results carry no `toolset_name`.
struct CustomToolTests {
    private let runCommand: JSONValue = [
        "name": "run_command",
        "description": "Type one line, then Return.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": ["command": ["type": "string"], "reason": ["type": "string"]],
            "required": ["command", "reason"],
            "additionalProperties": false,
        ],
    ]

    @Test func customToolsReplaceTheToolset() throws {
        let configuration = RequestConfiguration(system: "terminal", tools: [runCommand])
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("hi")])
        let raw = String(decoding: conversation.requestBody(), as: UTF8.self)
        let body = try JSONValue.decode(conversation.requestBody())
        #expect(body["tools"] == [runCommand])
        #expect(!raw.contains("computer_toolset_20260801"))
        #expect(body["system"] == "terminal")
        // Everything else is the screen assistant's.
        #expect(body["model"] == .string(ClaudeAPI.defaultModel))
        #expect(body["thinking"] == ClaudeAPI.thinking)
        #expect(body["output_config"] == ["effort": "medium"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
    }

    @Test func defaultToolsAreTheComputerToolset() {
        #expect(RequestConfiguration(system: "x").tools == [ClaudeAPI.computerToolset])
        #expect(RequestConfiguration(desktop: .mac).tools == [ClaudeAPI.computerToolset])
    }

    @Test func plainToolResultHasNoToolsetName() throws {
        let ok = ContentBlock.plainToolResult(id: "toolu_1", text: "OK")
        #expect(ok == ["type": "tool_result", "tool_use_id": "toolu_1", "content": [["type": "text", "text": "OK"]]])
        #expect(ok["toolset_name"] == nil)
        #expect(ok["is_error"] == nil)
        let refused = ContentBlock.plainToolResult(id: "toolu_2", text: "Refused: x", isError: true)
        #expect(refused["is_error"] == true)
        #expect(refused["toolset_name"] == nil)
        #expect(refused["content"] == [["type": "text", "text": "Refused: x"]])
    }
}
