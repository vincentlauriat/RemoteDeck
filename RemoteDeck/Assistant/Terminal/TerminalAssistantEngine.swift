import ClaudeKit
import Foundation

/// One step the terminal assistant may take (the tools `run_command`, `send_keys`, `wait_for_output`).
enum TerminalAction: Equatable, Sendable {
    /// One line typed into whatever has the keyboard, then Return. Confirmed first.
    case runCommand(String)
    /// Named keys. Confirmed first.
    case sendKeys([TerminalNamedKey])
    /// Waits up to `seconds` (1…120) for the output, then a fresh snapshot. Runs without asking.
    case waitForOutput(seconds: Int)
}

/// One proposed or automatic action of a turn, before it runs.
struct TerminalTurnAction: Equatable, Sendable {
    /// Claude's `tool_use` id, or `apple-<n>`.
    var id: String
    /// `nil` when it did not parse (`parseError` says why).
    var action: TerminalAction?
    /// Set: answered with this error text at once, never proposed.
    var parseError: String?
    /// Why the model wants it (shown in the row).
    var reason: String?

    init(id: String, action: TerminalAction?, parseError: String? = nil, reason: String? = nil) {
        self.id = id
        self.action = action
        self.parseError = parseError
        self.reason = reason
    }
}

enum TerminalTurnBlock: Equatable, Sendable {
    case answer(String)
    case progress(String)
    case action(TerminalTurnAction)
}

struct TerminalTurn: Equatable, Sendable {
    var blocks: [TerminalTurnBlock]
    var stop: TurnStop
    /// `nil` for Apple, which reports none.
    var usage: TokenUsage?

    var actions: [TerminalTurnAction] {
        blocks.compactMap { if case .action(let action) = $0 { return action } else { return nil } }
    }
}

/// The result of one action, returned to the model with the next turn: a text, then the fresh
/// snapshot when there is one.
struct TerminalActionOutcome: Equatable, Sendable {
    var id: String
    var text: String
    var snapshot: TerminalSnapshot?
    var isError: Bool

    init(id: String, text: String, snapshot: TerminalSnapshot? = nil, isError: Bool = false) {
        self.id = id
        self.text = text
        self.snapshot = snapshot
        self.isError = isError
    }
}

/// The request/turn step of the terminal assistant (Claude or Apple). `TerminalAssistantModel` keeps
/// the loop and every confirmation rule, whatever the provider.
@MainActor
protocol TerminalAssistantEngine: AnyObject {
    var provider: AssistantProvider { get }
    var isReady: Bool { get }
    var notReadyReason: AssistantFailure? { get }
    var hasConversation: Bool { get }
    var canResend: Bool { get }
    /// A user message (a new prompt, or the note after a password wait), with the terminal as it is.
    func begin(prompt: String, snapshot: TerminalSnapshot?)
    func nextTurn() async throws(AssistantEngineError) -> TerminalTurn
    /// The last turn's results, sent with the next turn (deferred ones first).
    func deliver(_ outcomes: [TerminalActionOutcome])
    /// Results owed to the next `begin` or `deliver`.
    func deferOutcomes(_ outcomes: [TerminalActionOutcome])
    func reset()
}
