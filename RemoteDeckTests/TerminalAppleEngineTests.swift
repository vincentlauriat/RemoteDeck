import Foundation
import Testing
@testable import RemoteDeck

/// A scripted Apple model for the terminal: answers in order, records every request. Never
/// FoundationModels.
actor ScriptedTerminalAppleSteps: TerminalAppleStepGenerating {
    enum Reply: Sendable {
        case step(TerminalAppleStep)
        case failure(AppleGenerationError)
    }

    private var replies: [Reply]
    private(set) var requests: [TerminalAppleStepRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func next(_ request: TerminalAppleStepRequest) async throws(AppleGenerationError) -> TerminalAppleStep {
        requests.append(request)
        guard !replies.isEmpty else { throw .failed("no more scripted steps") }
        switch replies.removeFirst() {
        case .step(let step): return step
        case .failure(let error): throw error
        }
    }
}

// Plan (terminal assistant) Task 8: the Apple on-device engine for terminals (text only, macOS 26+)
// and the two capabilities of Settings › Assistant.
@MainActor
struct TerminalAppleEngineTests {
    private let shot = TerminalSnapshot(screen: ["pi@raspberrypi:~ $"], scrollback: ["old secret-looking row"],
                                        cursorRow: 0, cursorColumn: 19, columns: 80, rows: 1)
    private let ready = FixedAppleModelChecker(reason: .requiresNewerOS(major: 27), terminalReason: nil)

    private func engine(_ steps: ScriptedTerminalAppleSteps, checker: FixedAppleModelChecker? = nil) -> TerminalAppleEngine {
        TerminalAppleEngine(generator: steps, checker: checker ?? ready)
    }

    @Test func stepsMapToActions() async throws {
        let steps = ScriptedTerminalAppleSteps([
            .step(TerminalAppleStep(kind: .runCommand, command: "df -h", reason: "disk usage")),
            .step(TerminalAppleStep(kind: .sendKeys, keys: [.ctrlC], reason: "stop")),
            .step(TerminalAppleStep(kind: .wait, seconds: 500)),
            .step(TerminalAppleStep(kind: .runCommand, command: "  ")),
            .step(TerminalAppleStep(kind: .sendKeys)),
            .step(TerminalAppleStep(kind: .answer, text: "The disk is full.")),
            .step(TerminalAppleStep(kind: .done, text: "")),
        ])
        let engine = engine(steps)
        engine.begin(prompt: "free some space", snapshot: shot)
        var turn = try await engine.nextTurn()
        #expect(turn.stop == .actions)
        #expect(turn.blocks.first == .progress("disk usage"))
        #expect(turn.actions.first?.action == .runCommand("df -h"))
        #expect(turn.actions.first?.id == "apple-1")
        #expect(turn.usage == nil)
        engine.deliver([TerminalActionOutcome(id: "apple-1", text: "OK", snapshot: shot)])
        turn = try await engine.nextTurn()
        #expect(turn.actions.first?.action == .sendKeys([.ctrlC]))
        turn = try await engine.nextTurn()
        #expect(turn.actions.first?.action == .waitForOutput(seconds: 120))   // clamped
        turn = try await engine.nextTurn()
        #expect(turn.actions.first?.action == nil)
        #expect(turn.actions.first?.parseError?.hasPrefix("Error:") == true)
        turn = try await engine.nextTurn()
        #expect(turn.actions.first?.parseError?.hasPrefix("Error:") == true)
        turn = try await engine.nextTurn()
        #expect(turn == TerminalTurn(blocks: [.answer("The disk is full.")], stop: .done, usage: nil))
        turn = try await engine.nextTurn()
        #expect(turn.stop == .done)
    }

    @Test func requestHasViewportOnlyAndLastSixSummaries() async throws {
        let replies: [ScriptedTerminalAppleSteps.Reply] = (1...8).map {
            .step(TerminalAppleStep(kind: .runCommand, command: "echo \($0)"))
        }
        let steps = ScriptedTerminalAppleSteps(replies)
        let engine = engine(steps)
        engine.begin(prompt: "task", snapshot: shot)
        for index in 1...8 {
            let turn = try await engine.nextTurn()
            let id = try #require(turn.actions.first?.id)
            engine.deliver([TerminalActionOutcome(id: id, text: index == 2 ? "Refused: x" : "OK", snapshot: shot,
                                                  isError: index == 2)])
        }
        let requests = await steps.requests
        let first = try #require(requests.first)
        #expect(first.task == "task")
        #expect(first.screen == shot.rendered(includeScrollback: false))
        #expect(!first.screen.contains("old secret-looking row"))
        #expect(first.summary.isEmpty)
        #expect(requests[2].summary == [#"run_command "echo 1" → OK"#, #"run_command "echo 2" → Refused: x"#])
        let last = try #require(requests.last)
        #expect(last.summary.count == 6)
        #expect(last.summary.last == #"run_command "echo 7" → OK"#)
    }

    @Test func contextExceededIsCutOff() async throws {
        let engine = engine(ScriptedTerminalAppleSteps([.failure(.contextExceeded)]))
        engine.begin(prompt: "x", snapshot: shot)
        #expect(try await engine.nextTurn().stop == .cutOff)
    }

    @Test func refusalIsRefused() async throws {
        let engine = engine(ScriptedTerminalAppleSteps([.failure(.refused("no"))]))
        engine.begin(prompt: "x", snapshot: shot)
        #expect(try await engine.nextTurn().stop == .refused(category: nil, explanation: "no"))
    }

    @Test func terminalsReadyOnMacOS26WithoutVision() {
        let status = AppleModelStatus(checker: ready)
        #expect(status.terminalUnavailability == nil)
        #expect(status.isTerminalAvailable)
        #expect(!status.isAvailable)
        #expect(status.isSupportedOS)   // the Apple row is selectable: terminals can use it
        let engine = engine(ScriptedTerminalAppleSteps([]))
        #expect(engine.isReady)
        let blocked = TerminalAppleEngine(generator: ScriptedTerminalAppleSteps([]),
                                          checker: FixedAppleModelChecker(reason: nil, terminalReason: .appleIntelligenceOff))
        #expect(!blocked.isReady)
        #expect(blocked.notReadyReason == .appleUnavailable(.appleIntelligenceOff))
    }

    @Test func screensStillRequire27() {
        #expect(AppleModelUse.screens.minimumMacOS == 27)
        #expect(AppleModelUse.terminals.minimumMacOS == 26)
        let old = AppleModelStatus(checker: FixedAppleModelChecker(reason: .requiresNewerOS(major: 27),
                                                                   terminalReason: .requiresNewerOS(major: 26)))
        #expect(!old.isSupportedOS)
        // The single-reason checker keeps today's answer for both.
        #expect(FixedAppleModelChecker(reason: .modelNotReady).unavailability(for: .terminals) == .modelNotReady)
        #expect(FixedAppleModelChecker(reason: nil).unavailability() == nil)
    }

    @Test func settingsShowBothLines() {
        let suiteName = "TerminalAppleEngineTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.en.rawValue
        let status = AppleModelStatus(checker: ready)
        let lines = AssistantCopy.appleStatusLines(status) { settings.t($0) }
        #expect(lines == ["Screens: Apple's model requires macOS 27.", "Terminals: Ready: Apple's model is available on this Mac."])
        settings.languageRaw = AppLanguage.fr.rawValue
        let french = AssistantCopy.appleStatusLines(AppleModelStatus(checker: FixedAppleModelChecker(
            reason: .requiresNewerOS(major: 27), terminalReason: .requiresNewerOS(major: 26)))) { settings.t($0) }
        #expect(french == ["Écrans : Le modèle d'Apple demande macOS 27.", "Terminaux : Le modèle d'Apple demande macOS 26."])
    }
}
