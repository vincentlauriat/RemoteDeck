import Foundation
@testable import ClaudeKit

/// A scripted HTTP transport: answers the queued replies in order and records every request. No test
/// ever reaches the network.
actor FakeTransport: HTTPTransport {
    enum Reply: Sendable {
        case json(status: Int, body: JSONValue, headers: [String: String] = [:])
        case failure(URLError)
        /// Never answers until the task is cancelled.
        case hang
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func enqueue(_ reply: Reply) { replies.append(reply) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch replies.removeFirst() {
        case .json(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            return (body.encoded(), response)
        case .failure(let error):
            throw error
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw URLError(.cancelled)
        }
    }

    var bodies: [JSONValue] {
        requests.compactMap { $0.httpBody.flatMap { try? JSONValue.decode($0) } }
    }
}

/// A Messages API response body.
func message(stop: String, content: [JSONValue], usage: JSONValue = ["input_tokens": 10, "output_tokens": 5],
             extra: [String: JSONValue] = [:]) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": "message", "id": "msg_test", "role": "assistant", "model": "claude-opus-5-5",
        "stop_reason": .string(stop), "content": .array(content), "usage": usage,
    ]
    for (key, value) in extra { object[key] = value }
    return .object(object)
}

func toolUse(_ id: String, _ name: String, _ input: JSONValue = [:]) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "toolset_name": "computer", "input": input]
}

func errorBody(_ type: String, _ message: String) -> JSONValue {
    ["type": "error", "error": ["type": .string(type), "message": .string(message)], "request_id": "req_test"]
}

/// Records the retry delays asked for, without sleeping.
actor DelayRecorder {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }

    nonisolated var policy: RetryPolicy {
        RetryPolicy(sleep: { [self] delay in await self.record(delay) })
    }
}
