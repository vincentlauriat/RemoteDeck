import ClaudeKit
import CoreGraphics
import Foundation
import Testing
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

/// A scripted Apple model: answers in order, records every request. Never FoundationModels.
actor ScriptedAppleSteps: AppleStepGenerating {
    enum Reply: Sendable {
        case step(AppleStep)
        case failure(AppleGenerationError)
    }

    private var replies: [Reply]
    private(set) var requests: [AppleStepRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func generate(_ request: AppleStepRequest) async throws(AppleGenerationError) -> AppleStep {
        requests.append(request)
        guard !replies.isEmpty else { throw .failed("no more scripted steps") }
        switch replies.removeFirst() {
        case .step(let step): return step
        case .failure(let error): throw error
        }
    }
}

/// OCR results fixed in advance; counts its calls.
final class FakeTextLocator: TextLocator, @unchecked Sendable {
    let texts: [LocatedText]
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ texts: [LocatedText]) {
        self.texts = texts
    }

    func locate(in image: EncodedImage) async -> [LocatedText] {
        lock.withLock { _calls += 1 }
        return texts
    }
}

@MainActor
struct AppleEngineTests {
    let port = FakeAssistantPort()
    static let finder = LocatedText(text: "Finder", rect: CGRect(x: 100, y: 200, width: 60, height: 20))

    private func model(_ steps: ScriptedAppleSteps, texts: [LocatedText] = [AppleEngineTests.finder],
                       unavailable: AppleModelUnavailability? = nil) -> (AssistantModel, AppleEngine) {
        let engine = AppleEngine(generator: steps, locator: FakeTextLocator(texts), unavailability: { unavailable })
        return (AssistantModel(port: port, engine: engine, armDelay: .zero, sleep: { _ in }), engine)
    }

    private func ask(_ model: AssistantModel, _ text: String) {
        model.prompt = text
        model.ask()
    }

    private func items(_ model: AssistantModel) -> [AssistantModel.ActionItem] {
        model.entries.compactMap { if case .action(let item) = $0.content { return item } else { return nil } }
    }

    @Test func labelClickIsHighlightedAtTheOCRPointAndRunsOnlyOnConfirm() async throws {
        let steps = ScriptedAppleSteps([.step(AppleStep(kind: .click, label: "finder", reason: "Opening Finder.")),
                                        .step(AppleStep(kind: .answer, text: "Finder is open."))])
        let (model, _) = model(steps)
        ask(model, "open Finder")
        #expect(await waitUntil { model.phase == .confirming })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(port.sent.isEmpty, "an action ran without confirmation")
        // The 1024 × 768 framebuffer is sent as is: the OCR point is the remote point.
        #expect(model.highlight == [PointerLocation(x: 130, y: 210)])
        #expect(items(model).first?.label == "Finder")   // the highlighted text, as OCR read it
        #expect(model.entries.contains { $0.content == .progress("Opening Finder.") })

        await confirmWhenArmed(model)
        #expect(await waitUntil { model.phase == .done })
        #expect(port.sent == [[.pointerEvent(buttonMask: 0, x: 130, y: 210), .pointerEvent(buttonMask: 1, x: 130, y: 210),
                               .pointerEvent(buttonMask: 0, x: 130, y: 210)]])
        #expect(port.rows.map(\.decisionValue) == [.confirmed])
        #expect(port.rows.first?.payload == #"{"input":{"coordinate":[130,210],"label":"finder"},"remote":[[130,210]]}"#)
        #expect(model.entries.last?.content == .answer("Finder is open."))
        // Apple reports no tokens: none are invented, none are added to the SessionRecord.
        #expect(model.usage.total == 0)
        #expect(port.tokens == 0)

        let requests = await steps.requests
        #expect(requests.count == 2)
        #expect(requests[0].summary.isEmpty)
        #expect(requests[1].summary == ["click \"finder\" → OK"])
        #expect(requests[1].task == "open Finder")
        #expect(port.settles == 1)   // a fresh, settled screenshot for the second step
    }

    @Test func labelNotFoundOrAmbiguousNeverClicks() async throws {
        for (texts, label) in [([Self.finder], "Trash"),
                               ([Self.finder, LocatedText(text: "finder", rect: CGRect(x: 500, y: 500, width: 60, height: 20))], "Finder")] {
            let port = FakeAssistantPort()
            let steps = ScriptedAppleSteps([.step(AppleStep(kind: .click, label: label)),
                                            .step(AppleStep(kind: .answer, text: "I could not find it."))])
            let engine = AppleEngine(generator: steps, locator: FakeTextLocator(texts), unavailability: { nil })
            let model = AssistantModel(port: port, engine: engine, armDelay: .zero)
            ask(model, "click \(label)")
            #expect(await waitUntil { model.phase == .done })
            #expect(port.sent.isEmpty)
            #expect(port.rows.isEmpty)
            #expect(port.keyboardReleases == 0)   // never proposed
            let item = try #require(items(model).first)
            #expect(item.action == nil)
            #expect(item.targets.isEmpty)
            guard case .failed = item.status else {
                Issue.record("status \(item.status)")
                continue
            }
            // The model got one more step, told why.
            let summary = await steps.requests.last?.summary ?? []
            #expect(summary.count == 1)
            #expect(summary.first?.hasPrefix("click \"\(label)\" → Error: the label") == true)
        }
    }

    @Test func contextExceededIsCutOffAndRefusalIsRefused() async throws {
        let (cut, _) = model(ScriptedAppleSteps([.failure(.contextExceeded)]))
        ask(cut, "x")
        #expect(await waitUntil { cut.phase == .cutOff })

        let (refused, _) = model(ScriptedAppleSteps([.failure(.refused("Guardrail violation."))]))
        ask(refused, "x")
        #expect(await waitUntil { refused.phase == .refused(category: nil, explanation: "Guardrail violation.") })
        #expect(port.sent.isEmpty)
    }

    @Test func generationFailureCanBeRetried() async throws {
        let steps = ScriptedAppleSteps([.failure(.failed("boom")), .step(AppleStep(kind: .answer, text: "Hi"))])
        let (model, _) = model(steps)
        ask(model, "hello")
        #expect(await waitUntil { model.phase == .failed(.appleGeneration("boom")) })
        model.retry()
        #expect(await waitUntil { model.phase == .done })
        #expect(model.entries.last?.content == .answer("Hi"))
    }

    @Test func unavailableModelAsksNothing() async throws {
        let steps = ScriptedAppleSteps([])
        let (model, engine) = model(steps, unavailable: .appleIntelligenceOff)
        #expect(!model.isReady)
        #expect(engine.notReadyReason == .appleUnavailable(.appleIntelligenceOff))
        ask(model, "x")
        #expect(model.phase == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await steps.requests.isEmpty)
    }

    /// One generated step = at most one action per turn, whatever the step.
    @Test func neverMoreThanOneActionPerTurn() async throws {
        let all = AppleStep.Kind.allCases.map { ScriptedAppleSteps.Reply.step(AppleStep(kind: $0, label: "Finder", text: "a", direction: "up")) }
        let engine = AppleEngine(generator: ScriptedAppleSteps(all), locator: FakeTextLocator([Self.finder]),
                                 unavailability: { nil })
        let image = try ScreenshotEncoder.encode(try Framebuffer(width: 1024, height: 768))
        for _ in AppleStep.Kind.allCases {
            engine.begin(prompt: "x", screenshot: image, desktop: .mac)
            let turn = try await engine.nextTurn { nil }
            #expect(turn.actions.count <= 1)
            #expect(turn.usage == nil)
            #expect(turn.stop == (turn.actions.isEmpty ? .done : .actions))
            #expect(turn.actions.allSatisfy { $0.id.hasPrefix("apple-") })
        }
    }

    @Test func summaryKeepsTheLastSixSteps() async throws {
        var replies = (0..<8).map { _ in ScriptedAppleSteps.Reply.step(AppleStep(kind: .wait)) }
        replies.append(.step(AppleStep(kind: .done)))
        let steps = ScriptedAppleSteps(replies)
        let (model, engine) = model(steps)
        ask(model, "wait a lot")
        // Eight waits in a row confirm no action: the pause rule stops the loop (provider-independent).
        #expect(await waitUntil { model.phase == .paused })
        model.continueAfterPause()
        #expect(await waitUntil { model.phase == .done })
        #expect(engine.summary.count == AppleEngine.summaryLength)
        let last = await steps.requests.last?.summary
        #expect(last?.count == AppleEngine.summaryLength)
        #expect(last?.allSatisfy { $0 == "wait → OK" } == true)
    }
}

/// The provider seam in `AssistantModel`: the engine follows Settings between conversations only.
@MainActor
struct AssistantProviderSwitchTests {
    @Test func providerChangeAppliesToTheNextConversation() async throws {
        let port = FakeAssistantPort()
        var chosen = AssistantProvider.appleOnDevice
        let model = AssistantModel(port: port, provider: { chosen }, armDelay: .zero) { provider in
            switch provider {
            case .claude:
                ClaudeEngine(client: MessagesClient(transport: ScriptedHTTP([])), apiKey: { "" })
            case .appleOnDevice, .applePrivateCloud:
                AppleEngine(generator: ScriptedAppleSteps([.step(AppleStep(kind: .answer, text: "Hi"))]),
                            locator: FakeTextLocator([]), unavailability: { nil })
            }
        }
        #expect(model.provider == .appleOnDevice)
        model.prompt = "hello"
        model.ask()
        #expect(await waitUntil { model.phase == .done })

        chosen = .claude
        model.syncProvider()
        #expect(model.provider == .appleOnDevice)   // a conversation is open
        model.clear()
        #expect(model.provider == .claude)
        #expect(!model.isReady)                      // no key
        #expect(model.engine.notReadyReason == .noAPIKey)
    }
}

#if DEBUG
@MainActor
struct AppleDemoTests {
    /// `-LibraryDemo assistant-apple`: the scripted steps drive the real engine to the end, a click on
    /// the OCR'd label then a typed command, and never touch the model.
    @Test func appleDemoScriptRunsToTheEnd() async throws {
        let port = FakeAssistantPort()
        let model = AssistantModel(port: port, engine: LibraryDemo.appleEngine(), armDelay: .zero)
        model.prompt = "check the uptime"
        model.ask()
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .confirming })
        #expect(model.highlight.count == 1)
        await confirmWhenArmed(model)
        #expect(await waitUntil(timeout: .seconds(5)) { port.sent.count == 1 && model.awaitingID == "apple-2" })
        await confirmWhenArmed(model)
        #expect(await waitUntil(timeout: .seconds(5)) { model.phase == .done })
        #expect(port.sent.count == 2)
        #expect(model.usage.total == 0)
    }
}
#endif
