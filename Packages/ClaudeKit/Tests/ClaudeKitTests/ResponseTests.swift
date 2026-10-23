import Foundation
import Testing
@testable import ClaudeKit

struct ResponseTests {
    @Test func parsesSeveralMemberCallsProgressAndText() throws {
        let json = message(stop: "tool_use", content: [
            ["type": "thinking", "thinking": "", "signature": "a"],
            ["type": "text", "text": "I'll open the search field."],
            ["type": "thinking", "thinking": "Clicking the search field.", "signature": "b"],
            toolUse("toolu_1", "left_click", ["coordinate": [640, 60]]),
            toolUse("toolu_2", "type", ["text": "pictures of cats"]),
            toolUse("toolu_3", "screenshot"),
        ])
        let response = try MessagesResponse(json: json)
        #expect(response.stopReason == .toolUse)
        #expect(response.blocks == [
            .thinking(""), .text("I'll open the search field."), .thinking("Clicking the search field."),
            .toolUse(id: "toolu_1", name: "left_click", toolsetName: "computer", input: ["coordinate": [640, 60]]),
            .toolUse(id: "toolu_2", name: "type", toolsetName: "computer", input: ["text": "pictures of cats"]),
            .toolUse(id: "toolu_3", name: "screenshot", toolsetName: "computer", input: [:]),
        ])
        #expect(response.toolUses.map(\.id) == ["toolu_1", "toolu_2", "toolu_3"])
        // The raw blocks are kept as sent (signature included) for the next request.
        #expect(response.content[0]["signature"] == "a")
    }

    @Test func everyResultEchoesTheToolsetAndItsID() throws {
        let ok = ContentBlock.toolResult(id: "toolu_1", text: ToolResultText.ok)
        #expect(ok["toolset_name"] == "computer")
        #expect(ok["tool_use_id"] == "toolu_1")
        #expect(ok["type"] == "tool_result")
        #expect(ok["is_error"] == nil)
        let denied = ContentBlock.toolResult(id: "toolu_2", text: ToolResultText.skipped, isError: true)
        #expect(denied["toolset_name"] == "computer")
        #expect(denied["is_error"] == true)

        let image = EncodedImage(data: Data([0x89, 0x50]), mediaType: "image/png", width: 1, height: 1)
        let screenshot = ContentBlock.toolResult(id: "toolu_3", content: [ContentBlock.image(image)])
        #expect(screenshot["toolset_name"] == "computer")
        let block = try #require(screenshot["content"]?.arrayValue?.first)
        #expect(block["type"] == "image")
        #expect(block["source"] == ["type": "base64", "media_type": "image/png", "data": "iVA="])
    }

    @Test func refusalCarriesCategoryAndExplanation() throws {
        let response = try MessagesResponse(json: message(stop: "refusal", content: [], extra: [
            "stop_details": ["type": "refusal", "category": "cyber", "explanation": "Declined."],
        ]))
        #expect(response.stopReason == .refusal)
        #expect(response.refusal == MessagesResponse.Refusal(category: "cyber", explanation: "Declined."))
        let unnamed = try MessagesResponse(json: message(stop: "refusal", content: [], extra: [
            "stop_details": ["type": "refusal", "category": .null, "explanation": .null],
        ]))
        #expect(unnamed.refusal == MessagesResponse.Refusal(category: nil, explanation: nil))
    }

    @Test(arguments: [("max_tokens", MessagesResponse.StopReason.maxTokens), ("pause_turn", .pauseTurn),
                      ("end_turn", .endTurn), ("model_context_window_exceeded", .contextWindowExceeded),
                      ("something_new", .other("something_new"))])
    func stopReasons(_ raw: String, _ expected: MessagesResponse.StopReason) throws {
        #expect(try MessagesResponse(json: message(stop: raw, content: [])).stopReason == expected)
    }

    @Test func notAMessageIsUnexpected() {
        #expect(throws: AnthropicError.unexpectedResponse("not a message")) {
            try MessagesResponse(json: ["type": "error"])
        }
    }

    @Test func usageSumsAcrossTurnsIncludingCache() throws {
        let first = try MessagesResponse(json: message(stop: "tool_use", content: [], usage: [
            "input_tokens": 1200, "output_tokens": 300, "cache_creation_input_tokens": 4500, "cache_read_input_tokens": 0,
        ])).usage
        let second = try MessagesResponse(json: message(stop: "end_turn", content: [], usage: [
            "input_tokens": 1100, "output_tokens": 50, "cache_creation_input_tokens": 1500, "cache_read_input_tokens": 4500,
        ])).usage
        var total = TokenUsage()
        total += first
        total += second
        #expect(total == TokenUsage(inputTokens: 2300, outputTokens: 350, cacheReadInputTokens: 4500,
                                    cacheCreationInputTokens: 6000))
        #expect(total.totalInputTokens == 12800)
        #expect(total.total == 13150)
    }
}

struct ErrorTests {
    private func failing(_ status: Int, _ body: JSONValue = errorBody("x", "message"),
                         headers: [String: String] = [:]) async -> (AnthropicError?, Int, [Duration]) {
        let transport = FakeTransport([.json(status: status, body: body, headers: headers),
                                       .json(status: status, body: body, headers: headers),
                                       .json(status: status, body: body, headers: headers)])
        let delays = DelayRecorder()
        let client = MessagesClient(transport: transport, retry: delays.policy)
        var caught: AnthropicError?
        do throws(AnthropicError) {
            _ = try await client.send(body: Data("{}".utf8), apiKey: "sk-ant-x")
        } catch {
            caught = error
        }
        return (caught, await transport.requests.count, await delays.delays)
    }

    @Test func nonRetryableStatusesAreTriedOnce() async {
        let cases: [(Int, AnthropicError)] = [
            (400, .invalidRequest("bad field")), (401, .authentication), (402, .billing), (403, .permission),
            (404, .notFound), (413, .requestTooLarge),
        ]
        for (status, expected) in cases {
            let (error, attempts, delays) = await failing(status, errorBody("e", "bad field"))
            #expect(error == expected, "status \(status)")
            #expect(attempts == 1, "status \(status) must not be retried")
            #expect(delays.isEmpty)
        }
    }

    @Test func transientStatusesAreRetriedTwice() async {
        for (status, expected) in [(500, AnthropicError.server(status: 500)), (529, .overloaded),
                                   (504, .server(status: 504))] {
            let (error, attempts, delays) = await failing(status)
            #expect(error == expected)
            #expect(attempts == 3)
            #expect(delays == [.seconds(1), .seconds(2)])
        }
    }

    @Test func rateLimitWaitsRetryAfterAndSpendCapIsNotRetried() async {
        let (error, attempts, delays) = await failing(429, headers: ["retry-after": "7"])
        #expect(error == .rateLimited(retryAfter: .seconds(7)))
        #expect(attempts == 3)
        #expect(delays == [.seconds(7), .seconds(7)])

        let (capError, capAttempts, _) = await failing(429)
        #expect(capError == .rateLimited(retryAfter: nil))
        #expect(capAttempts == 1)
    }

    @Test func unusableRetryAfterValuesNeverTrap() async {
        for value in ["inf", "-inf", "nan", "-5", "soon"] {
            let (error, attempts, delays) = await failing(429, headers: ["retry-after": value])
            #expect(error == .rateLimited(retryAfter: nil), "\(value)")
            #expect(attempts == 1 && delays.isEmpty, "\(value): no usable delay, not retried")
        }
        // Huge but finite: capped at an hour before the conversion, then at the policy's 30 s.
        let (huge, _, hugeDelays) = await failing(429, headers: ["retry-after": "1e30"])
        #expect(huge == .rateLimited(retryAfter: .seconds(3600)))
        #expect(hugeDelays == [.seconds(30), .seconds(30)])
        #expect(AnthropicError.retryDelay(seconds: "2.5", milliseconds: nil) == .milliseconds(2500))
        #expect(AnthropicError.retryDelay(seconds: "9", milliseconds: "750") == .milliseconds(750))
        let (error, attempts, delays) = await failing(429, headers: ["retry-after-ms": "1500"])
        #expect(error == .rateLimited(retryAfter: .milliseconds(1500)))
        #expect(attempts == 3)
        #expect(delays == [.milliseconds(1500), .milliseconds(1500)])
    }

    @Test func networkErrorIsRetriedThenReported() async {
        let transport = FakeTransport([.failure(URLError(.notConnectedToInternet)), .failure(URLError(.timedOut)),
                                       .json(status: 200, body: message(stop: "end_turn", content: []))])
        let delays = DelayRecorder()
        let response = try? await MessagesClient(transport: transport, retry: delays.policy)
            .send(body: Data("{}".utf8), apiKey: "k")
        #expect(response?.stopReason == .endTurn)
        #expect(await transport.requests.count == 3)
    }

    @Test func cancellingStopsTheRequestWithoutRetry() async {
        let transport = FakeTransport([.hang, .hang])
        let client = MessagesClient(transport: transport, retry: RetryPolicy(sleep: { _ in }))
        let task = Task { () -> AnthropicError? in
            do throws(AnthropicError) {
                _ = try await client.send(body: Data("{}".utf8), apiKey: "k")
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(await transport.requests.count == 1)
    }
}
