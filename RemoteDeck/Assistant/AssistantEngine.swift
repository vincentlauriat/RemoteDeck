import ClaudeKit
import Foundation
import RFBKit

/// Which model answers the Assistant Panel (Settings › Assistant, `AppSettings.assistantProvider`).
enum AssistantProvider: String, CaseIterable, Sendable {
    /// The Anthropic Messages API with the computer toolset (an API key, billed per token).
    case claude
    /// Apple's on-device Foundation Model (macOS 27): no key, nothing leaves the Mac.
    case appleOnDevice
    /// Private Cloud Compute: declared, never offered (it needs a managed entitlement from Apple).
    case applePrivateCloud

    /// The rows of the Settings picker.
    static let selectable: [AssistantProvider] = [.claude, .appleOnDevice]

    var isApple: Bool { self != .claude }
}

/// Why the Apple model cannot answer (Settings › Assistant and the panel, worded in the views).
enum AppleModelUnavailability: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceOff
    /// Still downloading or preparing.
    case modelNotReady
    /// macOS 15–26: FoundationModels' vision input needs macOS 27.
    case requiresNewerOS
}

/// One proposed or read-only computer action of a turn, before it runs.
struct TurnAction: Equatable {
    /// Claude's `tool_use` id, or `apple-<n>`.
    var id: String
    /// The member name (`left_click`…), shown when the action did not parse.
    var name: String
    /// `nil` when it did not parse (the row shows `name`).
    var action: ComputerAction?
    /// Set: the action is answered with this error text at once, never proposed.
    var parseError: String?
    /// The input as the model gave it (AssistantAction.payload).
    var input: JSONValue
    /// The text label an Apple click or scroll aimed at (shown in the row).
    var label: String?
}

enum TurnBlock: Equatable {
    case answer(String)
    case progress(String)
    case action(TurnAction)
}

enum TurnStop: Equatable {
    /// The turn's actions run, then the next turn.
    case actions
    case done
    case refused(category: String?, explanation: String?)
    /// `max_tokens`, the context window, or Apple's 8,192-token context.
    case cutOff
}

/// One answer of the model: what the panel shows, and how the loop goes on.
struct AssistantTurn: Equatable {
    var blocks: [TurnBlock]
    var stop: TurnStop
    /// Tokens billed for the turn; `nil` for Apple, which reports none (never invented).
    var usage: TokenUsage?

    var actions: [TurnAction] {
        blocks.compactMap { if case .action(let action) = $0 { return action } else { return nil } }
    }
}

/// The result of one action, returned to the model with the next turn.
struct ActionOutcome: Equatable {
    var id: String
    var text: String?
    var image: EncodedImage?
    var isError: Bool

    init(id: String, text: String, isError: Bool = false) {
        self.id = id
        self.text = text
        self.isError = isError
    }

    init(id: String, image: EncodedImage) {
        self.id = id
        self.image = image
        isError = false
    }
}

enum AssistantEngineError: Error, Equatable {
    case notReady(AssistantFailure)
    case cancelled
    case failed(AssistantFailure)
}

/// The request/turn step of the Assistant Panel, behind which the provider changes (TRD › Claude
/// Assistant › Providers). `AssistantModel` keeps the loop, the transcript, Confirm/Skip/Stop, the
/// pause rule and the session port: every action that reaches the remote is confirmed first,
/// whatever the provider.
@MainActor
protocol AssistantEngine: AnyObject {
    var provider: AssistantProvider { get }
    /// Claude: a key is set; Apple: the model is available.
    var isReady: Bool { get }
    /// Why it is not ready (the panel's blocked state).
    var notReadyReason: AssistantFailure? { get }
    /// A conversation is open (Continue after a pause is possible).
    var hasConversation: Bool { get }
    /// The same request can be sent again after an error (`retry`).
    var canResend: Bool { get }
    /// A new prompt, with the screenshot of the framebuffer taken for it.
    func begin(prompt: String, screenshot: EncodedImage?, desktop: RemoteDesktopKind)
    /// Asks the model. `screenshot` takes a fresh, settled screenshot (Apple, before each step after
    /// the first); it also sets the model's coordinate mapping. A reply that arrived is returned even
    /// if the task was cancelled meanwhile (its tokens are billed); `.cancelled` only when the request
    /// itself was.
    func nextTurn(screenshot: @MainActor () async -> EncodedImage?) async throws(AssistantEngineError) -> AssistantTurn
    /// The results of the last turn's actions, sent with the next turn (also flushes deferred ones).
    func deliver(_ outcomes: [ActionOutcome])
    /// Results owed to the next `begin` or `deliver` (Claude's `pendingResults`).
    func deferOutcomes(_ outcomes: [ActionOutcome])
    /// A new conversation.
    func reset()
}
