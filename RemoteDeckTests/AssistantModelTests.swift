import ClaudeKit
import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

/// Confirms the proposal waiting, once it is armed.
@MainActor
func confirmWhenArmed(_ model: AssistantModel) async {
    #expect(await waitUntil { model.confirmArmed })
    if let id = model.awaitingID { model.confirm(id) }
}

@MainActor
struct AssistantModelTests {
    let port = FakeAssistantPort()

    private func model(_ http: ScriptedHTTP, key: String = "sk-ant-test",
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> AssistantModel {
        AssistantModel(port: port, client: MessagesClient(transport: http, retry: RetryPolicy(maxRetries: 0)),
                       apiKey: { key }, armDelay: .zero, sleep: sleep)
    }

    private func ask(_ model: AssistantModel, _ text: String) {
        model.prompt = text
        model.ask()
    }

    private static let click = memberCall("toolu_click", "left_click", ["coordinate": [100, 200]])
    private static let clickMessages: [ClientMessage] = [
        .pointerEvent(buttonMask: 0, x: 100, y: 200), .pointerEvent(buttonMask: 1, x: 100, y: 200),
        .pointerEvent(buttonMask: 0, x: 100, y: 200),
    ]

    // MARK: Confirmation (PRD acceptance criterion 8, ImplementationPlan T4.4 done criterion)

    @Test func proposedClickReachesNothingUntilConfirmed() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [Self.click]),
                                 apiMessage(stop: "end_turn", content: [["type": "text", "text": "Done."]])])
        let model = model(http)
        ask(model, "click the button")
        #expect(await waitUntil { model.phase == .confirming })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(port.sent.isEmpty, "an action ran without confirmation")
        #expect(await http.requests.count == 1)
        #expect(model.highlight == [PointerLocation(x: 100, y: 200)])
        #expect(port.keyboardReleases == 1)

        await confirmWhenArmed(model)
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent == [Self.clickMessages])
        #expect(port.rows.map(\.decisionValue) == [.confirmed])
        #expect(port.rows.first?.kindValue == .click)
        #expect(model.highlight.isEmpty)

        let bodies = await http.bodies
        // The first request: a screenshot of the framebuffer, then the prompt.
        #expect(bodies[0].lastMessageContent.map { $0["type"] } == ["image", "text"])
        // The second: one result, matched by id, echoing the toolset.
        let results = bodies[1].lastMessageContent
        #expect(results.count == 1)
        #expect(results[0]["tool_use_id"] == "toolu_click")
        #expect(results[0]["toolset_name"] == "computer")
        #expect(results[0]["is_error"] == nil)
        #expect(model.entries.last?.content == .answer("Done."))
    }

    @Test func skipSendsNothingAndReportsTheDenialAndTheRestOfTheTurn() async throws {
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [Self.click, memberCall("toolu_type", "type", ["text": "uptime"])]),
            apiMessage(stop: "end_turn", content: [["type": "text", "text": "OK, I won't."]]),
        ])
        let model = model(http)
        ask(model, "run uptime")
        #expect(await waitUntil { model.phase == .confirming })
        model.skip(try #require(model.awaitingID))
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent.isEmpty)
        #expect(port.rows.map(\.decisionValue) == [.rejected])
        let results = await http.bodies[1].lastMessageContent
        #expect(results.map { $0["tool_use_id"] } == ["toolu_click", "toolu_type"])
        #expect(results.allSatisfy { $0["toolset_name"] == "computer" && $0["is_error"] == true })
        #expect(results[0]["content"]?.arrayValue?.first?["text"] == .string(ToolResultText.skipped))
        #expect(results[1]["content"]?.arrayValue?.first?["text"] == .string(ToolResultText.notExecuted))
        let statuses = model.entries.compactMap { entry -> AssistantModel.ActionItem.Status? in
            if case .action(let item) = entry.content { return item.status }
            return nil
        }
        #expect(statuses == [.skipped, .notExecuted])
    }

    @Test func readOnlyActionsRunWithoutAskingAndReturnAnImage() async throws {
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [
                ["type": "thinking", "thinking": "Taking a closer look.", "signature": "s"],
                memberCall("toolu_shot", "screenshot"),
                memberCall("toolu_zoom", "zoom", ["region": [0, 0, 100, 100]]),
            ]),
            apiMessage(stop: "end_turn", content: [["type": "text", "text": "A desktop."]]),
        ])
        let model = model(http)
        ask(model, "what is on the screen?")
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent.isEmpty)
        #expect(port.keyboardReleases == 0)
        #expect(port.rows.map(\.decisionValue) == [.automatic, .automatic])
        #expect(port.rows.map(\.kindValue) == [.screenshot, .zoom])
        let results = await http.bodies[1].lastMessageContent
        #expect(results.map { $0["content"]?.arrayValue?.first?["type"] } == ["image", "image"])
        #expect(results.allSatisfy { $0["toolset_name"] == "computer" })
        #expect(model.entries.contains { $0.content == .progress("Taking a closer look.") })
    }

    @Test func outOfBoundsAndUnknownKeysAreAnsweredWithoutAsking() async throws {
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [memberCall("toolu_key", "key", ["text": "ctrl+Hyper"])]),
            apiMessage(stop: "tool_use", content: [memberCall("toolu_far", "left_click", ["coordinate": [5000, 10]])]),
            apiMessage(stop: "end_turn", content: []),
        ])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent.isEmpty)
        let bodies = await http.bodies
        #expect(bodies[1].lastMessageContent.first?["is_error"] == true)
        #expect(bodies[1].lastMessageContent.first?["content"]?.arrayValue?.first?["text"]
                == "Error: unknown key name \"Hyper\".")
        #expect(bodies[2].lastMessageContent.first?["content"]?.arrayValue?.first?["text"]
                == "Error: coordinate (5000, 10) is outside the 1024x768 screenshot.")
    }

    // MARK: Stop

    @Test func stopWhileWaitingSendsNothingAndOwesTheResults() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [Self.click]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "click")
        #expect(await waitUntil { model.phase == .confirming })
        model.stop()
        #expect(await waitUntil { model.phase == .stopped })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(port.sent.isEmpty)
        #expect(port.rows.map(\.decisionValue) == [.cancelled])

        ask(model, "never mind")
        #expect(await waitUntil { model.phase == .done })
        let content = await http.bodies[1].lastMessageContent
        #expect(content.map { $0["type"] } == ["tool_result", "image", "text"])
        #expect(content[0]["tool_use_id"] == "toolu_click")
        #expect(content[0]["content"]?.arrayValue?.first?["text"] == .string(ToolResultText.stopped))
    }

    @Test func stopCancelsTheRequestInFlight() async throws {
        let http = ScriptedHTTP([.hang, apiMessage(stop: "end_turn", content: [["type": "text", "text": "Hi"]])])
        let model = model(http)
        ask(model, "hello")
        #expect(await waitUntilAsync { await http.requests.count == 1 })   // the request is in flight
        model.stop()
        #expect(await waitUntil { model.phase == .stopped })
        #expect(await waitUntilAsync { await http.cancelled == 1 })   // the request itself was cancelled
        ask(model, "again")
        #expect(await waitUntil { model.phase == .done })
        #expect(await http.requests.count == 2)
    }

    @Test func sessionEndRunningAHeldKeyReleasesIt() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            memberCall("toolu_hold", "hold_key", ["text": "shift", "duration": 30]),
        ])])
        let model = model(http, sleep: sleepUntilCancelled)
        ask(model, "hold shift")
        #expect(await waitUntil { model.phase == .confirming })
        await confirmWhenArmed(model)
        #expect(await waitUntil { model.phase == .running })
        #expect(port.sent == [[.keyEvent(down: true, key: Keysym.shiftL)]])
        model.sessionEnded()
        // Released at once, inside sessionEnded: before the session finishes its input sender.
        #expect(port.sent.last == [.keyEvent(down: false, key: Keysym.shiftL)])
        #expect(await waitUntil { model.phase == .failed(.disconnected) })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(port.sent.count == 2)   // released once
    }

    // MARK: Stop reasons and errors

    @Test func refusalShowsTheCategory() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "refusal", content: [], extra: [
            "stop_details": ["type": "refusal", "category": "cyber", "explanation": "Declined."],
        ])])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .refused(category: "cyber", explanation: "Declined.") })
    }

    @Test func maxTokensStopsAndOwesTheCutOffActions() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "max_tokens", content: [Self.click]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .cutOff })
        #expect(port.sent.isEmpty)
        ask(model, "continue")
        #expect(await waitUntil { model.phase == .done })
        let content = await http.bodies[1].lastMessageContent
        #expect(content.first?["content"]?.arrayValue?.first?["text"] == .string(ToolResultText.cutOff))
    }

    /// `pause_turn` is not continued (that request would end with an assistant message, a prefill
    /// Opus 5.5 rejects): cut off, and its calls answered at the next Ask.
    @Test func pauseTurnIsTreatedAsCutOff() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "pause_turn", content: [["type": "text", "text": "Working…"], Self.click]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .cutOff })
        #expect(await http.requests.count == 1)
        ask(model, "go on")
        #expect(await waitUntil { model.phase == .done })
        let bodies = await http.bodies
        #expect(bodies[1]["messages"]?.arrayValue?.last?["role"] == "user")
        #expect(bodies[1].lastMessageContent.first?["tool_use_id"] == "toolu_click")
    }

    // MARK: Review fixes

    @Test func endTurnOrRefusalWithAToolCallStillAnswersIt() async throws {
        for (stop, extra) in [("end_turn", [String: JSONValue]()),
                              ("refusal", ["stop_details": ["type": "refusal", "category": .null, "explanation": .null]])] {
            let http = ScriptedHTTP([apiMessage(stop: stop, content: [Self.click], extra: extra),
                                     apiMessage(stop: "end_turn", content: [])])
            let model = model(http)
            ask(model, "x")
            #expect(await waitUntil { !model.phase.isBusy })
            #expect(port.sent.isEmpty)
            ask(model, "next")
            #expect(await waitUntil { model.phase == .done })
            let content = await http.bodies[1].lastMessageContent
            #expect(content.first?["tool_use_id"] == "toolu_click", "\(stop)")
            #expect(content.first?["is_error"] == true)
        }
    }

    @Test func staleOrEarlyOrRepeatedConfirmDoesNothing() async throws {
        let second = memberCall("toolu_two", "left_click", ["coordinate": [300, 300]])
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [Self.click, second]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "two clicks")
        #expect(await waitUntil { model.confirmArmed && model.awaitingID == "toolu_click" })
        model.confirm("toolu_click", isKeyRepeat: true)   // a held ⌘Return
        #expect(model.awaitingID == "toolu_click")
        model.confirm("toolu_click")
        #expect(await waitUntil { model.awaitingID == "toolu_two" })
        model.confirm("toolu_click")                       // stale id: the next proposal stays
        model.confirm("toolu_click")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(port.sent.count == 1)
        #expect(model.awaitingID == "toolu_two")
        model.stop()

        // Before arming (the real 400 ms, here a minute), Confirm is refused too.
        let early = AssistantModel(port: port, client: MessagesClient(transport: ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [Self.click])])), apiKey: { "sk-ant-x" }, armDelay: .seconds(60))
        ask(early, "click")
        #expect(await waitUntil { early.awaitingID == "toolu_click" })
        early.confirm("toolu_click")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!early.confirmArmed)
        #expect(early.phase == .confirming)
        #expect(port.sent.count == 1)
        early.stop()
    }

    @Test func noAskUntilTheStoppedTaskHasSettledItsResults() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [Self.click]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "click")
        #expect(await waitUntil { model.phase == .confirming })
        model.stop()
        #expect(model.phase == .stopping)
        #expect(!model.canAsk || model.trimmedPrompt.isEmpty)
        model.prompt = "quick"
        #expect(!model.canAsk)
        model.ask()                                        // refused while the old task winds down
        #expect(model.prompt == "quick")
        #expect(await waitUntil { model.phase == .stopped })
        model.ask()
        #expect(await waitUntil { model.phase == .done })
        let content = await http.bodies[1].lastMessageContent
        #expect(content.map { $0["type"] } == ["tool_result", "image", "text"])
    }

    @Test func usageOfAReplyArrivingAfterStopIsCounted() async throws {
        let http = ScriptedHTTP([.late(apiBody(stop: "end_turn", content: []), .milliseconds(200))])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntilAsync { await http.requests.count == 1 })
        model.stop()
        #expect(await waitUntil { model.phase == .stopped })
        #expect(model.usage.total == 120)
        #expect(port.tokens == 120)
    }

    @Test func typedTextIsNotStored() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [memberCall("toolu_t", "type", ["text": "hunter2"])]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "type my password")
        await confirmWhenArmed(model)
        #expect(await waitUntil { model.phase == .done })
        #expect(port.rows.first?.payload == #"{"input":{"length":7}}"#)
        #expect(port.rows.first?.payload.contains("hunter2") == false)
    }

    @Test func clickWithoutCoordinateHighlightsThePointer() async throws {
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            memberCall("toolu_move", "mouse_move", ["coordinate": [50, 60]]), memberCall("toolu_here", "left_click"),
        ]), apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "click there")
        await confirmWhenArmed(model)
        #expect(await waitUntil { model.awaitingID == "toolu_here" })
        #expect(model.highlight == [PointerLocation(x: 50, y: 60)])
        model.stop()
    }

    @Test func errorThenRetrySendsTheSameBytes() async throws {
        let http = ScriptedHTTP([.json(status: 529, body: ["type": "error", "error": ["type": "overloaded_error", "message": "busy"]]),
                                 apiMessage(stop: "end_turn", content: [])])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .failed(.api(.overloaded)) })
        model.retry()
        #expect(await waitUntil { model.phase == .done })
        let raw = await http.rawBodies
        #expect(raw.count == 2)
        #expect(raw[0] == raw[1])
    }

    @Test func noKeyAsksNothing() async throws {
        let http = ScriptedHTTP([])
        let model = model(http, key: "")
        ask(model, "x")
        #expect(!model.hasAPIKey)
        #expect(model.phase == .idle)
        #expect(await http.requests.isEmpty)
    }

    @Test func tokenCounterSumsEveryTurn() async throws {
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [memberCall("toolu_shot", "screenshot")],
                       usage: ["input_tokens": 1000, "output_tokens": 100, "cache_creation_input_tokens": 4500,
                               "cache_read_input_tokens": 0]),
            apiMessage(stop: "end_turn", content: [],
                       usage: ["input_tokens": 1100, "output_tokens": 50, "cache_creation_input_tokens": 1000,
                               "cache_read_input_tokens": 4500]),
        ])
        let model = model(http)
        ask(model, "x")
        #expect(await waitUntil { model.phase == .done })
        #expect(model.usage.total == 5600 + 6650)
        #expect(port.tokens == 12250)
    }
}

// MARK: - Through a real SessionModel

@MainActor
struct AssistantSessionTests {
    @Test func confirmedClickGoesThroughTheSessionsInputSender() async throws {
        let container = try RemoteDeckSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let machine = Machine(name: "VM", kind: .anthropicVM, host: "127.0.0.1", port: 5901)
        context.insert(machine)
        try context.save()
        let log = SessionLog()
        let fake = FakeSessionConnection(log: log, sendDelay: .zero)
        await fake.setSnapshot(try Framebuffer(width: 1024, height: 768))
        let session = SessionModel(machine: machine, context: context, passwords: FakePasswordStore(), display: nil,
                                   pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil) { _ in fake }
        let http = ScriptedHTTP([
            apiMessage(stop: "tool_use", content: [memberCall("toolu_1", "left_click", ["coordinate": [10, 20]])]),
            apiMessage(stop: "end_turn", content: []),
        ])
        let assistant = AssistantModel(port: session, client: MessagesClient(transport: http), apiKey: { "sk-ant-x" },
                                       armDelay: .zero)
        session.assistant = assistant
        session.assistantSettleLimit = .zero
        session.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { session.phase == .connected })

        assistant.prompt = "click"
        assistant.ask()
        #expect(await waitUntil { assistant.phase == .confirming })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await fake.sent.isEmpty)

        await confirmWhenArmed(assistant)
        #expect(await waitUntil { assistant.phase == .done })
        #expect(await waitUntilAsync { await fake.sent.flatMap { $0 }.count == 3 })
        #expect(await fake.sent.flatMap { $0 } == [.pointerEvent(buttonMask: 0, x: 10, y: 20),
                                                    .pointerEvent(buttonMask: 1, x: 10, y: 20),
                                                    .pointerEvent(buttonMask: 0, x: 10, y: 20)])
        let rows = try context.fetch(FetchDescriptor<AssistantAction>())
        #expect(rows.map(\.decisionValue) == [.confirmed])
        #expect(rows.first?.session === session.record)
        #expect(rows.first?.payload == #"{"input":{"coordinate":[10,20]},"remote":[[10,20]]}"#)
        #expect(session.record?.assistantTokens == 240)
        await session.close()
    }

    @Test func viewInputIsHeldBackWhileAnActionRunsAndTheHeldKeyIsReleasedOnClose() async throws {
        let container = try RemoteDeckSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let machine = Machine(name: "VM", kind: .anthropicVM, host: "127.0.0.1", port: 5901)
        context.insert(machine)
        try context.save()
        let fake = FakeSessionConnection(log: SessionLog(), sendDelay: .zero)
        await fake.setSnapshot(try Framebuffer(width: 1024, height: 768))
        let session = SessionModel(machine: machine, context: context, passwords: FakePasswordStore(), display: nil,
                                   pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil) { _ in fake }
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            memberCall("toolu_hold", "hold_key", ["text": "shift", "duration": 30]),
        ])])
        let assistant = AssistantModel(port: session, client: MessagesClient(transport: http), apiKey: { "sk-ant-x" },
                                       armDelay: .zero, sleep: sleepUntilCancelled)
        session.assistant = assistant
        session.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { session.phase == .connected })
        assistant.prompt = "hold shift"
        assistant.ask()
        #expect(await waitUntil { assistant.phase == .confirming })
        await confirmWhenArmed(assistant)
        #expect(await waitUntil { assistant.phase == .running })
        session.sendInput([.pointerEvent(buttonMask: 0, x: 5, y: 5)])   // the user's mouse over the view
        #expect(await waitUntilAsync { await fake.sent.flatMap { $0 } == [.keyEvent(down: true, key: Keysym.shiftL)] })

        await session.close()   // Shift released by the assistant before the sender finishes
        let sent = await fake.sent.flatMap { $0 }
        #expect(sent == [.keyEvent(down: true, key: Keysym.shiftL), .keyEvent(down: false, key: Keysym.shiftL)])
        #expect(await waitUntil { assistant.phase == .failed(.disconnected) })
    }
}

@MainActor
struct AssistantReleasePassTests {
    @Test func viewReleasesStillReachTheRemoteWhileAnActionRuns() async throws {
        let container = try RemoteDeckSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let machine = Machine(name: "VM", kind: .anthropicVM, host: "127.0.0.1", port: 5901)
        context.insert(machine)
        try context.save()
        let fake = FakeSessionConnection(log: SessionLog(), sendDelay: .zero)
        await fake.setSnapshot(try Framebuffer(width: 1024, height: 768))
        let session = SessionModel(machine: machine, context: context, passwords: FakePasswordStore(), display: nil,
                                   pasteboard: InMemoryPasteboard(), clipboardPollInterval: nil) { _ in fake }
        let http = ScriptedHTTP([apiMessage(stop: "tool_use", content: [
            memberCall("toolu_wait", "hold_key", ["text": "shift", "duration": 30]),
        ])])
        let assistant = AssistantModel(port: session, client: MessagesClient(transport: http), apiKey: { "sk-ant-x" },
                                       armDelay: .zero, sleep: sleepUntilCancelled)
        session.assistant = assistant
        session.connect()
        #expect(await waitUntilAsync { await fake.hasEvents })
        await fake.emit(frame)
        #expect(await waitUntil { session.phase == .connected })
        session.sendInput([.pointerEvent(buttonMask: 1, x: 9, y: 9)])   // the user holds the button
        assistant.prompt = "hold shift"
        assistant.ask()
        await confirmWhenArmed(assistant)
        #expect(await waitUntil { assistant.phase == .running })
        session.sendInput([.keyEvent(down: true, key: 0x61), .keyEvent(down: false, key: 0x62),
                           .pointerEvent(buttonMask: 0, x: 9, y: 9), .pointerEvent(buttonMask: 0, x: 20, y: 20)])
        let expected: [ClientMessage] = [.pointerEvent(buttonMask: 1, x: 9, y: 9), .keyEvent(down: true, key: Keysym.shiftL),
                                         .keyEvent(down: false, key: 0x62), .pointerEvent(buttonMask: 0, x: 9, y: 9)]
        _ = await waitUntilAsync { await fake.sent.flatMap { $0 } == expected }
        let sent = await fake.sent.flatMap { $0 }
        #expect(sent == expected)
        await session.close()
    }
}

// MARK: - Debug demo script

#if DEBUG
@MainActor
struct AssistantDemoTests {
    /// `-LibraryDemo assistant`'s scripted answers parse and drive the loop to the end.
    @Test func demoScriptRunsToTheEnd() async throws {
        let port = FakeAssistantPort()
        let model = AssistantModel(port: port, client: LibraryDemo.assistantClient(), apiKey: { LibraryDemo.assistantKey },
                                   armDelay: .zero)
        model.prompt = "what is on the screen?"
        model.ask()
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .confirming })
        await confirmWhenArmed(model)
        #expect(await waitUntil { port.sent.count == 1 && model.awaitingID == "toolu_demo_type" })
        await confirmWhenArmed(model)
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .done })
        #expect(port.sent.count == 2)
        #expect(model.usage.total > 0)
    }
}
#endif
