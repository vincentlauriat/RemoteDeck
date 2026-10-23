import ClaudeKit
import Foundation
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

/// A scripted HTTP transport for the hosted tests: answers in order, records every request. Nothing
/// reaches the network, no token is spent.
actor ScriptedHTTP: HTTPTransport {
    enum Reply: Sendable {
        case json(status: Int, body: JSONValue)
        case failure(URLError)
        /// Answers nothing until cancelled.
        case hang
        /// Answers `body` after `delay`, even if the task was cancelled meanwhile (a reply on its way).
        case late(JSONValue, Duration)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    /// Requests that ended because their task was cancelled (`.hang`).
    private(set) var cancelled = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch replies.removeFirst() {
        case .json(let status, let body):
            return (body.encoded(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        case .failure(let error):
            throw error
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            cancelled += 1
            throw URLError(.cancelled)
        case .late(let body, let delay):
            let deadline = ContinuousClock.now + delay
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            return (body.encoded(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    var bodies: [JSONValue] { requests.compactMap { $0.httpBody.flatMap { try? JSONValue.decode($0) } } }
    var rawBodies: [Data] { requests.compactMap(\.httpBody) }
}

func apiBody(stop: String, content: [JSONValue],
             usage: JSONValue = ["input_tokens": 100, "output_tokens": 20,
                                 "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]) -> JSONValue {
    ["type": "message", "id": "msg", "role": "assistant", "model": "claude-opus-5-5",
     "stop_reason": .string(stop), "content": .array(content), "usage": usage]
}

func apiMessage(stop: String, content: [JSONValue],
                usage: JSONValue = ["input_tokens": 100, "output_tokens": 20,
                                    "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0],
                extra: [String: JSONValue] = [:]) -> ScriptedHTTP.Reply {
    var object: [String: JSONValue] = [
        "type": "message", "id": "msg", "role": "assistant", "model": "claude-opus-5-5",
        "stop_reason": .string(stop), "content": .array(content), "usage": usage,
    ]
    for (key, value) in extra { object[key] = value }
    return .json(status: 200, body: .object(object))
}

func memberCall(_ id: String, _ name: String, _ input: JSONValue = [:]) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "toolset_name": "computer", "input": input]
}

/// A session as the assistant sees it: connected, a 1024 × 768 framebuffer, records what it is sent.
@MainActor
final class FakeAssistantPort: AssistantSessionPort {
    var assistantCanAct = true
    var assistantDesktop: RemoteDesktopKind = .x11
    var assistantProfile: ModifierProfile = .x11
    var framebuffer: Framebuffer? = try? Framebuffer(width: 1024, height: 768)
    private(set) var sent: [[ClientMessage]] = []
    private(set) var rows: [AssistantAction] = []
    private(set) var tokens = 0
    private(set) var keyboardReleases = 0
    private(set) var settles = 0

    func assistantSnapshot() async -> Framebuffer? { framebuffer }
    func assistantSend(_ messages: [ClientMessage]) { sent.append(messages) }
    func assistantSettle() async { settles += 1 }

    func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction? {
        let row = AssistantAction(kind: kind, payload: payload, decision: decision)
        rows.append(row)
        return row
    }

    func assistantSave() {}
    func assistantAddTokens(_ count: Int) { tokens += count }
    func assistantReleaseKeyboard() { keyboardReleases += 1 }
}

/// Never returns until cancelled (a held key, a long wait).
let sleepUntilCancelled: @Sendable (Duration) async throws -> Void = { _ in
    while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
    throw CancellationError()
}

extension JSONValue {
    /// The content blocks of the last message of a request body.
    var lastMessageContent: [JSONValue] { self["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? [] }
}
