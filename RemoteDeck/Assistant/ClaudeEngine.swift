import ClaudeKit
import Foundation

/// The Claude provider: the Messages API with the computer toolset, over an append-only
/// `Conversation` (T4.4). Byte for byte what `AssistantModel` sent before the engine seam: the
/// same request bodies, tool results matched by `tool_use` id, owed results opening the next user
/// message.
@MainActor
final class ClaudeEngine: AssistantEngine {
    let provider = AssistantProvider.claude
    private let client: MessagesClient
    private let apiKey: @MainActor () -> String
    private let model: String
    private var conversation: Conversation?

    init(client: MessagesClient, apiKey: @escaping @MainActor () -> String, model: String = ClaudeAPI.defaultModel) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
    }

    var isReady: Bool { !apiKey().isEmpty }
    var notReadyReason: AssistantFailure? { isReady ? nil : .noAPIKey }
    var hasConversation: Bool { conversation != nil }
    var canResend: Bool { conversation?.endsWithUser == true }

    /// The request body that would be sent now (tests).
    var currentRequestBody: Data? { conversation?.requestBody() }

    func begin(prompt: String, screenshot: EncodedImage?, desktop: RemoteDesktopKind) {
        if conversation == nil {
            conversation = Conversation(configuration: RequestConfiguration(model: model, desktop: desktop))
        }
        var content: [JSONValue] = []
        if let screenshot { content.append(ContentBlock.image(screenshot)) }
        content.append(ContentBlock.text(prompt))
        conversation?.appendUser(content)
    }

    func nextTurn(screenshot: @MainActor () async -> EncodedImage?) async throws(AssistantEngineError) -> AssistantTurn {
        guard let conversation else { throw .failed(.disconnected) }
        let key = apiKey()
        guard !key.isEmpty else { throw .notReady(.noAPIKey) }
        let response: MessagesResponse
        do {
            response = try await client.send(body: conversation.requestBody(), apiKey: key)
        } catch {
            if error == .cancelled || Task.isCancelled { throw .cancelled }
            throw .failed(.api(error))
        }
        // Every path appends the turn unchanged; any call in it that will not run is answered.
        self.conversation?.appendAssistant(response)
        return AssistantTurn(blocks: Self.blocks(response), stop: Self.stop(response), usage: response.usage)
    }

    func deliver(_ outcomes: [ActionOutcome]) {
        conversation?.appendUser(outcomes.map(Self.result))
    }

    func deferOutcomes(_ outcomes: [ActionOutcome]) {
        conversation?.deferResults(outcomes.map(Self.result))
    }

    func reset() {
        conversation = nil
    }

    /// The response's text, progress updates (non-empty thinking under `display: "updates"`) and
    /// member calls. A call outside the computer toolset is answered with an error before parsing.
    static func blocks(_ response: MessagesResponse) -> [TurnBlock] {
        response.blocks.compactMap { block in
            switch block {
            case .text(let text) where !text.isEmpty:
                return .answer(text)
            case .thinking(let text) where !text.isEmpty:
                return .progress(text)
            case .toolUse(let id, let name, let toolsetName, let input):
                var parseError: String?
                if toolsetName != ClaudeAPI.toolsetName {
                    parseError = "Error: \(name) is not available in this environment."
                } else {
                    do throws(ComputerAction.ParseError) {
                        _ = try ComputerAction(name: name, input: input)
                    } catch {
                        parseError = error.resultText
                    }
                }
                return .action(TurnAction(id: id, name: name, action: try? ComputerAction(name: name, input: input),
                                          parseError: parseError, input: input))
            default:
                return nil
            }
        }
    }

    static func stop(_ response: MessagesResponse) -> TurnStop {
        switch response.stopReason {
        case .toolUse: .actions
        case .refusal: .refused(category: response.refusal?.category, explanation: response.refusal?.explanation)
        // `pause_turn` comes from server tools (none here). Its documented continuation would end the
        // request with an assistant message, a prefill Opus 5.5 rejects: treated as cut off.
        case .maxTokens, .contextWindowExceeded, .pauseTurn: .cutOff
        case .endTurn, .stopSequence, .other: .done
        }
    }

    static func result(_ outcome: ActionOutcome) -> JSONValue {
        if let image = outcome.image {
            return ContentBlock.toolResult(id: outcome.id, content: [ContentBlock.image(image)], isError: outcome.isError)
        }
        return ContentBlock.toolResult(id: outcome.id, text: outcome.text ?? "", isError: outcome.isError)
    }
}
