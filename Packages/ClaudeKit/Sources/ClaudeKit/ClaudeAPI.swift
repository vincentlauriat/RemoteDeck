import Foundation

/// Fixed facts of the Messages API as the Claude Assistant uses it (TRD › Claude Assistant). Every
/// value that is rendered into the prompt (model, thinking, effort, tools, system prompt) stays the
/// same for a whole conversation: changing one starts the prompt cache over and invalidates the
/// thinking blocks already returned.
public enum ClaudeAPI {
    /// The one model constant (Claude Opus 5.5: computer use only through `computer_toolset_20260801`).
    public static let defaultModel = "claude-opus-5-5"

    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The API key check: lists one model, so no tokens are billed.
    public static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    public static let version = "2023-06-01"
    /// `thinking.display: "updates"` is a beta: without this header it is a 400 (thinking docs,
    /// "Progress updates between tool calls").
    public static let thinkingUpdatesBeta = "thinking-display-updates-2026-08-18"

    /// Room for thinking (it counts toward `max_tokens`), a few tool calls and a short answer. A
    /// non-streaming request this size stays far below the 10-minute limit.
    public static let maxTokens = 8192

    /// Opus 5.5's own default, sent explicitly so a default change cannot move the cache prefix.
    /// `low` would bill fewer thinking tokens, but each wrong step costs a screenshot round trip and a
    /// confirmation from the user; one constant to change if live use says otherwise.
    public static let effort = "medium"

    /// The computer use toolset. No `name`, no display size, no beta header (GA). `left_mouse_down` and
    /// `left_mouse_up` are withheld: they leave the button held across actions, while every action
    /// here ends with nothing held on the remote (`left_click_drag` covers drags). The other 15
    /// members are on, zoom included (cropped from the framebuffer at full resolution).
    public static let computerToolset: JSONValue = [
        "type": "computer_toolset_20260801",
        "configs": [
            "left_mouse_down": ["enabled": false],
            "left_mouse_up": ["enabled": false],
        ],
    ]

    /// `toolset_name` of the member calls, echoed on every result.
    public static let toolsetName = "computer"

    /// Adaptive thinking (Opus 5.5 cannot turn it off) with progress updates as short readable notes.
    public static let thinking: JSONValue = ["type": "adaptive", "display": "updates"]

    /// Automatic caching: the breakpoint follows the last cacheable block as the conversation grows.
    public static let cacheControl: JSONValue = ["type": "ephemeral"]

    /// Request headers, without the key. `x-api-key` is added by `MessagesClient` only.
    public static let headers: [String: String] = [
        "anthropic-version": version,
        "anthropic-beta": thinkingUpdatesBeta,
        "content-type": "application/json",
    ]
}

/// What the remote machine is, for the system prompt (which modifier is ⌘).
public enum RemoteDesktopKind: Sendable, Equatable {
    /// A Mac (Apple Remote Desktop / Screen Sharing).
    case mac
    /// A Linux or other X11 desktop (generic VNC, Anthropic's computer use container).
    case x11
}

/// The constant part of every request of a conversation.
public struct RequestConfiguration: Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var effort: String
    public var system: String

    public init(model: String = ClaudeAPI.defaultModel, maxTokens: Int = ClaudeAPI.maxTokens,
                effort: String = ClaudeAPI.effort, system: String) {
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.system = system
    }

    public init(model: String = ClaudeAPI.defaultModel, desktop: RemoteDesktopKind) {
        self.init(model: model, system: Self.systemPrompt(for: desktop))
    }

    /// The system prompt. Holds nothing that changes during a session (no screen size): it is part of
    /// the cached prefix.
    public static func systemPrompt(for desktop: RemoteDesktopKind) -> String {
        let machine = switch desktop {
        case .mac:
            "The remote machine is a Mac. In key and modifier names, super is the Command key and alt is the Option key (super+c copies, super+v pastes)."
        case .x11:
            "The remote machine is a Linux (X11) desktop. Use ctrl for shortcuts (ctrl+c, ctrl+v); super is the Windows key."
        }
        return """
            You are the Claude Assistant of RemoteDeck, a VNC client on the user's Mac. The screenshots show \
            the screen of a remote machine that the user is connected to. \(machine)
            The user confirms every action before it runs, except screenshot, zoom, cursor_position and wait. \
            An action the user skipped comes back as an error result: do not try it again, say what you \
            wanted to do and ask the user.
            When the user asks about the screen, answer from the screenshot and take no action. Act only \
            when the user asks for a task, with as few actions as possible. Keep progress updates to one \
            short sentence. Answer in the language the user writes in. Never type a password or secret \
            the user did not give you in this conversation.
            """
    }
}
