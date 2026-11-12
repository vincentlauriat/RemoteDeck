import Foundation
import RemoteDeckCore

/// What the terminal assistant needs from its terminal tab (`TerminalSessionModel` in the app, a fake
/// in tests). Every byte goes through the session's one ordered writer.
@MainActor
protocol TerminalAssistantPort: AnyObject {
    /// Connected with the shell open: actions may run.
    var assistantCanAct: Bool { get }
    /// The tab as text, once every byte received so far is parsed.
    func assistantSnapshot() async -> TerminalSnapshot?
    /// One line then Return, in one write (the caller validated it).
    func assistantType(_ command: String)
    /// Named keys, in one write.
    func assistantSendKeys(_ keys: [TerminalNamedKey])
    /// Waits for the output to settle (`OutputSettler`), at most `cap`.
    func assistantWaitForOutput(cap: Duration) async -> OutputWait
    /// Inserts an AssistantAction row (BackendSchema) for the current SessionRecord.
    func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction?
    func assistantSave()
    /// Adds to SessionRecord.assistantTokens.
    func assistantAddTokens(_ count: Int)
    /// The assistant is sending: the user's own input is held back meanwhile.
    var assistantIsSending: Bool { get set }
}
