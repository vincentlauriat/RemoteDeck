import Foundation

/// A Messages API response. `content` keeps the raw blocks, which go back to the API unchanged;
/// `blocks` is the typed reading of them for the app.
public struct MessagesResponse: Sendable, Equatable {
    public enum StopReason: Sendable, Equatable {
        case endTurn
        case toolUse
        case maxTokens
        case pauseTurn
        case refusal
        case stopSequence
        case contextWindowExceeded
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "end_turn": self = .endTurn
            case "tool_use": self = .toolUse
            case "max_tokens": self = .maxTokens
            case "pause_turn": self = .pauseTurn
            case "refusal": self = .refusal
            case "stop_sequence": self = .stopSequence
            case "model_context_window_exceeded": self = .contextWindowExceeded
            default: self = .other(raw ?? "")
            }
        }
    }

    /// `stop_details` of a refusal: `category` and `explanation` may both be null (no named category).
    public struct Refusal: Sendable, Equatable {
        public var category: String?
        public var explanation: String?
    }

    public enum Block: Sendable, Equatable {
        case text(String)
        /// A thinking block. Under `display: "updates"`, a non-empty one is a progress update; an empty
        /// one (reasoning) is shown as nothing.
        case thinking(String)
        /// A member call of the computer toolset (or another tool: `toolsetName` tells).
        case toolUse(id: String, name: String, toolsetName: String?, input: JSONValue)
        /// Anything else (redacted thinking, a block type added later): kept, not shown.
        case other(type: String)
    }

    public var id: String
    public var model: String
    public var stopReason: StopReason
    public var refusal: Refusal?
    public var content: [JSONValue]
    /// Each content block's bytes exactly as the API sent them, replayed as is (`Conversation`).
    public var rawContent: [Data]
    public var usage: TokenUsage

    public var blocks: [Block] { content.map(Self.block) }

    /// The member calls, in order.
    public var toolUses: [(id: String, name: String, toolsetName: String?, input: JSONValue)] {
        blocks.compactMap {
            if case .toolUse(let id, let name, let toolsetName, let input) = $0 { return (id, name, toolsetName, input) }
            return nil
        }
    }

    public init(json: JSONValue) throws(AnthropicError) {
        guard json["type"]?.stringValue == "message", let content = json["content"]?.arrayValue else {
            throw .unexpectedResponse("not a message")
        }
        id = json["id"]?.stringValue ?? ""
        model = json["model"]?.stringValue ?? ""
        stopReason = StopReason(json["stop_reason"]?.stringValue)
        self.content = content
        rawContent = content.map { $0.encoded() }
        usage = TokenUsage(json: json["usage"])
        if stopReason == .refusal {
            let details = json["stop_details"]
            refusal = Refusal(category: details?["category"]?.stringValue,
                              explanation: details?["explanation"]?.stringValue)
        }
    }

    public init(data: Data) throws(AnthropicError) {
        let json: JSONValue
        do {
            json = try JSONValue.decode(data)
        } catch {
            throw .unexpectedResponse("invalid JSON")
        }
        try self.init(json: json)
        if let raw = RawJSON.arrayElements(ofKey: "content", in: data), raw.count == content.count {
            rawContent = raw
        }
    }

    static func block(_ value: JSONValue) -> Block {
        switch value["type"]?.stringValue {
        case "text":
            return .text(value["text"]?.stringValue ?? "")
        case "thinking":
            return .thinking(value["thinking"]?.stringValue ?? "")
        case "tool_use":
            return .toolUse(id: value["id"]?.stringValue ?? "", name: value["name"]?.stringValue ?? "",
                            toolsetName: value["toolset_name"]?.stringValue, input: value["input"] ?? [:])
        case let type:
            return .other(type: type ?? "")
        }
    }
}

/// Token counts of one response, or summed over a session (PRD open question 4).
public struct TokenUsage: Sendable, Equatable {
    /// Input after the last cache breakpoint (not read from or written to the cache).
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0,
                cacheCreationInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    init(json: JSONValue?) {
        inputTokens = json?["input_tokens"]?.intValue ?? 0
        outputTokens = json?["output_tokens"]?.intValue ?? 0
        cacheReadInputTokens = json?["cache_read_input_tokens"]?.intValue ?? 0
        cacheCreationInputTokens = json?["cache_creation_input_tokens"]?.intValue ?? 0
    }

    /// Every input token, cached or not: `input_tokens` alone leaves out the cached part.
    public var totalInputTokens: Int { inputTokens + cacheReadInputTokens + cacheCreationInputTokens }

    /// Input (all of it) + output: the session counter and SessionRecord.assistantTokens.
    public var total: Int { totalInputTokens + outputTokens }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
                   cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
                   cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens)
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}
