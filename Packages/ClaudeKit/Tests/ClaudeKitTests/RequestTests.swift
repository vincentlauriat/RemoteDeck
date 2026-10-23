import Foundation
import Testing
@testable import ClaudeKit

struct RequestTests {
    let configuration = RequestConfiguration(desktop: .x11)

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func toolsetEntryIsExactlyTheToolsetWithNoNameOrDisplay() throws {
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("hi")])
        let body = try JSONValue.decode(conversation.requestBody())
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 1)
        // Byte-exact entry: type + the two withheld members, nothing else (no name, no display size).
        #expect(text(tools[0].encoded())
                == #"{"configs":{"left_mouse_down":{"enabled":false},"left_mouse_up":{"enabled":false}},"type":"computer_toolset_20260801"}"#)
        let entry = try #require(tools[0].objectValue)
        for rejected in ["name", "display_width_px", "display_height_px", "display_number", "enable_zoom"] {
            #expect(entry[rejected] == nil)
        }
    }

    @Test func bodyCarriesModelThinkingEffortCacheAndSystem() throws {
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("what is on the screen?")])
        let body = try JSONValue.decode(conversation.requestBody())
        #expect(body["model"] == .string(ClaudeAPI.defaultModel))
        #expect(ClaudeAPI.defaultModel == "claude-opus-5-5")
        #expect(body["max_tokens"] == .int(8192))
        #expect(body["thinking"] == ["type": "adaptive", "display": "updates"])
        #expect(body["output_config"] == ["effort": "medium"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["system"]?.stringValue?.contains("Linux (X11)") == true)
        // Never a forced tool choice (400 on Opus 5.5), never a prefill.
        #expect(body["tool_choice"] == nil)
        #expect(body["messages"]?.arrayValue?.last?["role"] == "user")
        let keys = try #require(body.objectValue).keys.sorted()
        #expect(keys == ["cache_control", "max_tokens", "messages", "model", "output_config", "system", "thinking", "tools"])
    }

    @Test func systemPromptNamesTheMacModifiers() {
        let mac = RequestConfiguration.systemPrompt(for: .mac)
        #expect(mac.contains("super is the Command key"))
        #expect(!mac.contains("1024"))   // no screen size: it would change on a resize
    }

    @Test func historyIsAppendOnlyAndPriorTurnsKeepTheirBytes() throws {
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("open Terminal")])
        let first = conversation.requestBody()
        let assistant: [JSONValue] = [
            ["type": "thinking", "thinking": "", "signature": "sig-1"],
            ["type": "thinking", "thinking": "Opening the dock.", "signature": "sig-2"],
            toolUse("toolu_1", "left_click", ["coordinate": [10, 20]]),
        ]
        conversation.appendAssistant(assistant)
        conversation.appendUser([ContentBlock.toolResult(id: "toolu_1", text: "OK")])
        let second = conversation.requestBody()

        // The messages array of the first request is a byte prefix of the second one's.
        let firstMessages = try messagesBytes(first)
        let secondMessages = try messagesBytes(second)
        #expect(secondMessages.hasPrefix(String(firstMessages.dropLast())))
        // Everything outside the messages is byte-identical (the cached prefix).
        #expect(try withoutMessages(first) == withoutMessages(second))
        // The assistant turn goes back unchanged, empty thinking and signatures included.
        let decoded = try JSONValue.decode(second)
        #expect(decoded["messages"]?.arrayValue?[1] == ["role": "assistant", "content": .array(assistant)])
    }

    /// The API's own bytes for each block go back verbatim: `input` keys out of alphabetical order,
    /// spacing, escapes, a progress thinking block after the tool call.
    @Test func responseBlocksReplayByteIdentical() throws {
        let toolBlock = #"{"type": "tool_use", "id": "toolu_9", "name": "left_click", "toolset_name": "computer", "input": {"text": "shift", "coordinate": [5, 6]}}"#
        let thinkingBlock = #"{"type":"thinking","thinking":"Next: \"type\" ité","signature":"Zz/+=="}"#
        let raw = #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[ "# + toolBlock
            + ",\n  " + thinkingBlock + #" ],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2}}"#
        let response = try MessagesResponse(data: Data(raw.utf8))
        #expect(response.rawContent.map { String(decoding: $0, as: UTF8.self) } == [toolBlock, thinkingBlock])
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("x")])
        conversation.appendAssistant(response)
        conversation.appendUser([ContentBlock.toolResult(id: "toolu_9", text: "OK")])
        let body = text(conversation.requestBody())
        #expect(body.contains(#"{"content":["# + toolBlock + "," + thinkingBlock + #"],"role":"assistant"}"#))
        // Still valid JSON, the same request shape.
        let decoded = try JSONValue.decode(conversation.requestBody())
        #expect(decoded["messages"]?.arrayValue?.count == 3)
        #expect(decoded["messages"]?.arrayValue?[1]["content"]?.arrayValue?[0]["input"]?["coordinate"] == [5, 6])
    }

    @Test func rawScannerRejectsMalformedAndFindsEmptyArrays() {
        #expect(RawJSON.arrayElements(ofKey: "content", in: Data(#"{"content":[]}"#.utf8)) == [])
        #expect(RawJSON.arrayElements(ofKey: "content", in: Data(#"{"a":{"content":[1]},"content":[2, "]"]}"#.utf8))
                == [Data("2".utf8), Data(#""]""#.utf8)])
        #expect(RawJSON.arrayElements(ofKey: "content", in: Data(#"{"content":[1,"#.utf8)) == nil)
        #expect(RawJSON.arrayElements(ofKey: "content", in: Data(#"[1]"#.utf8)) == nil)
    }

    @Test func pendingResultsOpenTheNextUserMessage() throws {
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("task")])
        conversation.appendAssistant([toolUse("toolu_1", "key", ["text": "Return"])])
        conversation.deferResults([ContentBlock.toolResult(id: "toolu_1", text: ToolResultText.stopped, isError: true)])
        #expect(!conversation.endsWithUser)
        conversation.appendUser([ContentBlock.text("next")])
        let last = try #require(conversation.messages.last?["content"]?.arrayValue)
        #expect(last.first?["type"] == "tool_result")
        #expect(last.first?["tool_use_id"] == "toolu_1")
        #expect(last.last?["type"] == "text")
        #expect(conversation.pendingResults.isEmpty)
    }

    @Test func emptyAssistantTurnIsNotAppended() {
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("x")])
        conversation.appendAssistant([])
        #expect(conversation.messages.count == 1)
    }

    @Test func clientSendsHeadersAndKeyOnlyInTheHeader() async throws {
        let transport = FakeTransport([.json(status: 200, body: message(stop: "end_turn", content: []))])
        let client = MessagesClient(transport: transport, retry: RetryPolicy(maxRetries: 0))
        var conversation = Conversation(configuration: configuration)
        conversation.appendUser([ContentBlock.text("x")])
        _ = try await client.send(body: conversation.requestBody(), apiKey: "sk-ant-test-key")
        let request = try #require(await transport.requests.first)
        #expect(request.url == URL(string: "https://api.anthropic.com/v1/messages"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "thinking-display-updates-2026-08-18")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(!text(request.httpBody ?? Data()).contains("sk-ant-test-key"))
    }

    @Test func keyCheckIsAFreeModelsListing() async throws {
        let transport = FakeTransport([.json(status: 200, body: ["data": []])])
        try await MessagesClient(transport: transport).checkKey("sk-ant-x")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x")
        #expect(request.httpBody == nil)
        // Never a cached answer: a 200 kept for an earlier key must not validate another one.
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func jsonValueRoundTripsNumbersAndBooleans() throws {
        let value = try JSONValue.decode(Data(#"{"a":[1,true,2.5,"s",null],"b":false}"#.utf8))
        #expect(value["a"] == [1, true, .double(2.5), "s", .null])
        #expect(value["b"] == false)
        #expect(String(decoding: value.encoded(), as: UTF8.self) == #"{"a":[1,true,2.5,"s",null],"b":false}"#)
    }

    // MARK: Helpers

    private func messagesBytes(_ body: Data) throws -> String {
        let string = text(body)
        let start = try #require(string.range(of: #""messages":["#))
        let end = try #require(string.range(of: #"],"model":"#))
        return String(string[start.upperBound..<end.lowerBound]) + "]"
    }

    private func withoutMessages(_ body: Data) throws -> String {
        let string = text(body)
        let start = try #require(string.range(of: #""messages":["#))
        let end = try #require(string.range(of: #"],"model":"#))
        return String(string[..<start.lowerBound]) + String(string[end.upperBound...])
    }
}
