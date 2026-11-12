import ClaudeKit
import Foundation

/// The Claude provider of the terminal assistant: the Messages API with three custom tools over an
/// append-only `Conversation` (same model, thinking, effort and caching as the screen assistant).
/// Snapshots go as text blocks; results as plain tool results (no `toolset_name`).
@MainActor
final class TerminalClaudeEngine: TerminalAssistantEngine {
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

    func begin(prompt: String, snapshot: TerminalSnapshot?) {
        if conversation == nil { conversation = Conversation(configuration: TerminalAssistantPrompt.configuration(model: model)) }
        var content: [JSONValue] = []
        if let snapshot { content.append(ContentBlock.text(snapshot.rendered(includeScrollback: true))) }
        content.append(ContentBlock.text(prompt))
        conversation?.appendUser(content)
    }

    func nextTurn() async throws(AssistantEngineError) -> TerminalTurn {
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
        self.conversation?.appendAssistant(response)
        return TerminalTurn(blocks: Self.blocks(response), stop: ClaudeEngine.stop(response), usage: response.usage)
    }

    func deliver(_ outcomes: [TerminalActionOutcome]) {
        conversation?.appendUser(outcomes.map(Self.result))
    }

    func deferOutcomes(_ outcomes: [TerminalActionOutcome]) {
        conversation?.deferResults(outcomes.map(Self.result))
    }

    func reset() {
        conversation = nil
    }

    static func blocks(_ response: MessagesResponse) -> [TerminalTurnBlock] {
        response.blocks.compactMap { block in
            switch block {
            case .text(let text) where !text.isEmpty: .answer(text)
            case .thinking(let text) where !text.isEmpty: .progress(text)
            case .toolUse(let id, let name, _, let input): .action(action(id: id, name: name, input: input))
            default: nil
            }
        }
    }

    /// A tool call, or the error text it is answered with.
    static func action(id: String, name: String, input: JSONValue) -> TerminalTurnAction {
        let reason = input["reason"]?.stringValue
        func error(_ text: String) -> TerminalTurnAction {
            TerminalTurnAction(id: id, action: nil, parseError: "Error: \(text)", reason: reason)
        }
        switch name {
        case "run_command":
            guard let command = input["command"]?.stringValue else { return error("run_command needs a command string.") }
            return TerminalTurnAction(id: id, action: .runCommand(command), reason: reason)
        case "send_keys":
            guard let names = input["keys"]?.arrayValue, (1...16).contains(names.count) else { return error("send_keys needs 1 to 16 keys.") }
            var keys: [TerminalNamedKey] = []
            for value in names {
                guard let raw = value.stringValue, let key = TerminalNamedKey(rawValue: raw) else {
                    return error("\(value.stringValue ?? "?") is not one of the keys send_keys accepts.")
                }
                keys.append(key)
            }
            return TerminalTurnAction(id: id, action: .sendKeys(keys), reason: reason)
        case "wait_for_output":
            guard let seconds = input["seconds"]?.intValue, (1...OutputSettler.maxWaitSeconds).contains(seconds) else {
                return error("wait_for_output needs seconds from 1 to \(OutputSettler.maxWaitSeconds).")
            }
            return TerminalTurnAction(id: id, action: .waitForOutput(seconds: seconds), reason: reason)
        default:
            return error("\(name) is not available in this environment.")
        }
    }

    static func result(_ outcome: TerminalActionOutcome) -> JSONValue {
        guard let snapshot = outcome.snapshot else {
            return ContentBlock.plainToolResult(id: outcome.id, text: outcome.text, isError: outcome.isError)
        }
        var result = ContentBlock.plainToolResult(id: outcome.id, text: outcome.text, isError: outcome.isError)
        if case .object(var object) = result {
            object["content"] = [ContentBlock.text(outcome.text), ContentBlock.text(snapshot.rendered(includeScrollback: true))]
            result = .object(object)
        }
        return result
    }
}
