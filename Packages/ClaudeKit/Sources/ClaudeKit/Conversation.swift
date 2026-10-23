import Foundation

/// One Claude Assistant conversation: the messages sent so far and the request body for the next call.
///
/// **Append-only, byte for byte.** Earlier turns are never edited, reordered or dropped. Assistant
/// turns go back with each content block's **original bytes** as the API returned them (key order,
/// whitespace and all: `MessagesResponse.rawContent`), so a thinking block's binding to everything
/// before it is never disturbed by a re-encoding. The blocks this client writes (user text, images,
/// tool results) are encoded once with sorted keys. Each message's bytes are kept, so the messages
/// already sent are identical in every later request and the cached prefix keeps matching.
///
/// **Every `tool_use` gets its `tool_result`.** Results that could not go out with the turn they
/// answer (the loop was stopped, the response was cut off or ended) wait in `pendingResults`; the
/// next user message starts with them, before its prompt text.
public struct Conversation: Sendable {
    public let configuration: RequestConfiguration
    /// The messages, parsed (for reading; the request uses `rawMessages`).
    public private(set) var messages: [JSONValue] = []
    /// Each message's exact bytes in the request.
    public private(set) var rawMessages: [Data] = []
    /// Results owed to the last assistant turn, sent at the start of the next user message.
    public private(set) var pendingResults: [JSONValue] = []

    public init(configuration: RequestConfiguration) {
        self.configuration = configuration
    }

    /// The last message is from the user: the next request can be sent (no assistant prefill).
    public var endsWithUser: Bool { messages.last?["role"] == "user" }

    /// A user message: the pending results first, then `content`.
    public mutating func appendUser(_ content: [JSONValue]) {
        let blocks = pendingResults + content
        pendingResults = []
        guard !blocks.isEmpty else { return }
        let message: JSONValue = ["role": "user", "content": .array(blocks)]
        messages.append(message)
        rawMessages.append(message.encoded())
    }

    /// The assistant turn of a response, each block replayed with the bytes it came with. An empty
    /// one (a refusal before any output) is not added: the API rejects empty content in a non-final
    /// message.
    public mutating func appendAssistant(_ response: MessagesResponse) {
        appendAssistant(rawBlocks: response.rawContent, content: response.content)
    }

    /// Blocks given as values (tests): encoded with sorted keys.
    public mutating func appendAssistant(_ content: [JSONValue]) {
        appendAssistant(rawBlocks: content.map { $0.encoded() }, content: content)
    }

    private mutating func appendAssistant(rawBlocks: [Data], content: [JSONValue]) {
        guard !content.isEmpty, rawBlocks.count == content.count else { return }
        messages.append(["role": "assistant", "content": .array(content)])
        var raw = Data(#"{"content":["#.utf8)
        for (index, block) in rawBlocks.enumerated() {
            if index > 0 { raw.append(UInt8(ascii: ",")) }
            raw.append(block)
        }
        raw.append(contentsOf: Data(#"],"role":"assistant"}"#.utf8))
        rawMessages.append(raw)
    }

    /// Results that will open the next user message.
    public mutating func deferResults(_ results: [JSONValue]) {
        pendingResults += results
    }

    /// The request body: the configuration (the same in every request, sorted keys) and the messages'
    /// own bytes.
    public func requestBody() -> Data {
        func field(_ key: String, _ value: JSONValue) -> Data {
            JSONValue.string(key).encoded() + Data(":".utf8) + value.encoded()
        }
        var body = Data("{".utf8)
        body += field("cache_control", ClaudeAPI.cacheControl) + Data(",".utf8)
        body += field("max_tokens", .int(configuration.maxTokens)) + Data(",".utf8)
        body += Data(#""messages":["#.utf8)
        for (index, message) in rawMessages.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body += message
        }
        body += Data("],".utf8)
        body += field("model", .string(configuration.model)) + Data(",".utf8)
        body += field("output_config", ["effort": .string(configuration.effort)]) + Data(",".utf8)
        body += field("system", .string(configuration.system)) + Data(",".utf8)
        body += field("thinking", ClaudeAPI.thinking) + Data(",".utf8)
        body += field("tools", [ClaudeAPI.computerToolset])
        body += Data("}".utf8)
        return body
    }
}

// MARK: - Content blocks

/// The user-side blocks the assistant sends.
public enum ContentBlock {
    public static func text(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }

    /// A base64 PNG or JPEG.
    public static func image(_ image: EncodedImage) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType),
                                     "data": .string(image.data.base64EncodedString())]]
    }

    /// A member result. Every one carries `toolset_name: "computer"` (a result without it is rejected).
    /// `content` holds text and image blocks only.
    public static func toolResult(id: String, content: [JSONValue], isError: Bool = false) -> JSONValue {
        var result: [String: JSONValue] = [
            "type": "tool_result",
            "tool_use_id": .string(id),
            "toolset_name": .string(ClaudeAPI.toolsetName),
            "content": .array(content),
        ]
        if isError { result["is_error"] = true }
        return .object(result)
    }

    /// `OK`-style or error text result.
    public static func toolResult(id: String, text: String, isError: Bool = false) -> JSONValue {
        toolResult(id: id, content: [Self.text(text)], isError: isError)
    }
}

/// Result texts sent back to Claude (part of the conversation, so in English and stable).
public enum ToolResultText {
    public static let ok = "OK"
    /// The documented text for the blocks after a failed one in the same turn (computer use docs,
    /// "Batch actions").
    public static let notExecuted = "Not executed: an earlier computer action in this turn failed."
    public static let skipped = "The user skipped this action; it was not executed."
    public static let stopped = "Not executed: the user stopped the assistant."
    public static let disconnected = "Not executed: the remote session is disconnected."
    public static let cutOff = "Not executed: the response was cut off before this action could be confirmed."
    public static let noFramebuffer = "Error: no screen image is available yet."
}
