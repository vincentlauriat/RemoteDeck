import ClaudeKit
import Foundation
import RemoteDeckCore
import Testing
@testable import RemoteDeck

/// A terminal tab as the terminal assistant sees it: records what it is asked to type.
@MainActor
final class FakeTerminalAssistantPort: TerminalAssistantPort {
    var assistantCanAct = true
    var assistantIsSending = false
    var snapshot: TerminalSnapshot? = TerminalSnapshot(screen: ["pi@raspberrypi:~ $"], cursorRow: 0, cursorColumn: 19,
                                                       columns: 80, rows: 1)
    private(set) var typed: [String] = []
    private(set) var keys: [[TerminalNamedKey]] = []
    /// `assistantIsSending` at each type or keys call.
    private(set) var sendingFlags: [Bool] = []
    private(set) var rows: [AssistantAction] = []
    private(set) var tokens = 0
    private(set) var waits: [Duration] = []
    /// Answers each wait for output (default: settled at once).
    var waitHandler: @MainActor (Duration) async -> OutputWait = { _ in .settled }
    /// Runs after each type (the remote's answer).
    var onType: @MainActor (String) -> Void = { _ in }

    func assistantSnapshot() async -> TerminalSnapshot? { snapshot }

    func assistantType(_ command: String) {
        guard assistantCanAct else { return }
        typed.append(command)
        sendingFlags.append(assistantIsSending)
        onType(command)
    }

    func assistantSendKeys(_ keys: [TerminalNamedKey]) {
        guard assistantCanAct else { return }
        self.keys.append(keys)
        sendingFlags.append(assistantIsSending)
    }

    func assistantWaitForOutput(cap: Duration) async -> OutputWait {
        waits.append(cap)
        return await waitHandler(cap)
    }

    func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction? {
        let row = AssistantAction(kind: kind, payload: payload, decision: decision)
        rows.append(row)
        return row
    }

    func assistantSave() {}
    func assistantAddTokens(_ count: Int) { tokens += count }
}

/// Scripted turns, no model: records what the loop sends.
@MainActor
final class ScriptedTerminalEngine: TerminalAssistantEngine {
    let provider: AssistantProvider
    var isReady = true
    var notReadyReason: AssistantFailure? { isReady ? nil : .noAPIKey }
    private(set) var hasConversation = false
    var canResend: Bool { hasConversation }
    var turns: [TerminalTurn]
    private(set) var begun: [(prompt: String, snapshot: TerminalSnapshot?)] = []
    private(set) var delivered: [[TerminalActionOutcome]] = []
    private(set) var deferred: [TerminalActionOutcome] = []
    private(set) var calls = 0
    private(set) var resets = 0

    init(provider: AssistantProvider = .claude, _ turns: [TerminalTurn]) {
        self.provider = provider
        self.turns = turns
    }

    func begin(prompt: String, snapshot: TerminalSnapshot?) {
        hasConversation = true
        begun.append((prompt, snapshot))
    }

    func nextTurn() async throws(AssistantEngineError) -> TerminalTurn {
        calls += 1
        guard !turns.isEmpty else {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw .cancelled
        }
        return turns.removeFirst()
    }

    func deliver(_ outcomes: [TerminalActionOutcome]) {
        delivered.append(deferred + outcomes)
        deferred = []
    }

    func deferOutcomes(_ outcomes: [TerminalActionOutcome]) {
        deferred += outcomes
    }

    func reset() {
        hasConversation = false
        resets += 1
        deferred = []
    }
}

func answerTurn(_ text: String) -> TerminalTurn {
    TerminalTurn(blocks: [.answer(text)], stop: .done, usage: nil)
}

func commandTurn(_ id: String, _ command: String, reason: String = "check") -> TerminalTurn {
    TerminalTurn(blocks: [.action(TerminalTurnAction(id: id, action: .runCommand(command), reason: reason))],
                 stop: .actions, usage: nil)
}

func actionTurn(_ id: String, _ action: TerminalAction) -> TerminalTurn {
    TerminalTurn(blocks: [.action(TerminalTurnAction(id: id, action: action))], stop: .actions, usage: nil)
}

// Plan (terminal assistant) Task 6: the loop and every confirmation rule, over a fake port and a
// scripted engine (no model, no socket).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalAssistantModelTests {
    private func make(_ turns: [TerminalTurn], port: FakeTerminalAssistantPort = FakeTerminalAssistantPort())
        -> (TerminalAssistantModel, ScriptedTerminalEngine, FakeTerminalAssistantPort) {
        let engine = ScriptedTerminalEngine(turns)
        let model = TerminalAssistantModel(port: port, provider: { .claude }, makeEngine: { _ in engine },
                                           gate: AssistantDecisionGate(armDelay: .zero))
        return (model, engine, port)
    }

    private func ask(_ model: TerminalAssistantModel, _ text: String = "why is the disk full?") {
        model.prompt = text
        model.ask()
    }

    private func status(_ model: TerminalAssistantModel, _ id: String) -> TerminalAssistantModel.ActionItem.Status? {
        model.item(id)?.status
    }

    private func confirmWhenArmed(_ model: TerminalAssistantModel, _ id: String) async {
        #expect(await waitUntil { model.awaitingID == id && model.confirmArmed })
        model.confirm(id: id)
    }

    @Test func answerOnlyFinishesWithoutTyping() async {
        let (model, engine, port) = make([answerTurn("The disk is 91% full.")])
        ask(model)
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed.isEmpty && port.keys.isEmpty)
        #expect(engine.begun.first?.prompt == "why is the disk full?")
        #expect(engine.begun.first?.snapshot == port.snapshot)
        #expect(model.entries.contains { $0.content == .answer("The disk is 91% full.") })
    }

    @Test func commandIsTypedOnlyAfterConfirm() async {
        let (model, engine, port) = make([commandTurn("t1", "df -h"), answerTurn("done")])
        ask(model)
        #expect(await waitUntil { model.phase == .awaitingDecision(id: "t1") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(port.typed.isEmpty)
        await confirmWhenArmed(model, "t1")
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed == ["df -h"])
        #expect(port.sendingFlags == [true])
        #expect(!port.assistantIsSending)
        #expect(port.waits == [OutputSettler.actionCap])
        #expect(engine.delivered.first?.first?.text == "OK")
        #expect(engine.delivered.first?.first?.snapshot == port.snapshot)
        #expect(status(model, "t1") == .done)
        #expect(port.rows.first?.decisionValue == .confirmed)
    }

    @Test func confirmBeforeArmingIsIgnored() async {
        let port = FakeTerminalAssistantPort()
        let engine = ScriptedTerminalEngine([commandTurn("t1", "df -h")])
        let model = TerminalAssistantModel(port: port, provider: { .claude }, makeEngine: { _ in engine },
                                           gate: AssistantDecisionGate(armDelay: .seconds(60)))
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" })
        model.confirm(id: "t1")
        model.confirm(id: "t1", isKeyRepeat: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(port.typed.isEmpty)
        #expect(!model.confirmArmed)
        model.stop()
    }

    @Test func skipAnswersSkippedAndTypesNothing() async {
        let (model, engine, port) = make([commandTurn("t1", "rm -rf /var/log/old"), answerTurn("ok")])
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" })
        model.skip(id: "t1")
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed.isEmpty)
        #expect(engine.delivered.first?.first?.text == ToolResultText.skipped)
        #expect(engine.delivered.first?.first?.isError == true)
        #expect(status(model, "t1") == .skipped)
        #expect(port.rows.first?.decisionValue == .rejected)
    }

    @Test func stopDuringDecisionTypesNothing() async {
        let (model, engine, port) = make([commandTurn("t1", "reboot")])
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" && model.confirmArmed })
        model.stop()
        model.confirm(id: "t1")
        #expect(await waitUntil { model.phase == .stopped })
        #expect(port.typed.isEmpty)
        #expect(status(model, "t1") == .cancelled)
        #expect(engine.deferred.map(\.text) == [ToolResultText.stopped])
        #expect(port.rows.first?.decisionValue == .cancelled)
    }

    @Test func invalidCommandIsRefusedWithoutAProposal() async {
        let (model, engine, port) = make([commandTurn("t1", "ls\nrm x"), answerTurn("sorry")])
        var sawDecision = false
        ask(model)
        #expect(await waitUntil {
            if case .awaitingDecision = model.phase { sawDecision = true }
            return model.phase == .finished
        })
        #expect(!sawDecision)
        #expect(port.typed.isEmpty)
        let outcome = engine.delivered.first?.first
        #expect(outcome?.text == CommandRefusal.controlCharacter.resultText)
        #expect(outcome?.text.hasPrefix("Refused:") == true)
        #expect(outcome?.isError == true)
        #expect(port.rows.isEmpty)
    }

    @Test func fullScreenRefusesRunCommandButAllowsSendKeys() async {
        let port = FakeTerminalAssistantPort()
        port.snapshot = TerminalSnapshot(screen: ["top - 10:00"], cursorRow: 0, cursorColumn: 0, isAlternateScreen: true)
        let (model, engine, _) = make([commandTurn("t1", "ls"), actionTurn("t2", .sendKeys([.q])), answerTurn("out")],
                                      port: port)
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t2" })
        #expect(engine.delivered.first?.first?.text == CommandRefusal.fullScreenProgram.resultText)
        await confirmWhenArmed(model, "t2")
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed.isEmpty)
        #expect(port.keys == [[.q]])
        #expect(port.rows.map(\.kindValue) == [.keys])
        #expect(port.rows.first?.payload == #"{"keys":["q"]}"#)
    }

    @Test func waitForOutputRunsWithoutConfirmAndCountsAsAStep() async {
        let (model, engine, port) = make([actionTurn("w1", .waitForOutput(seconds: 30)), answerTurn("done")])
        port.waitHandler = { _ in .stillRunning(seconds: 30) }
        ask(model)
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.waits == [.seconds(30)])
        #expect(model.stepsWithoutAction == 1)
        #expect(status(model, "w1") == .automatic)
        #expect(engine.delivered.first?.first?.text == "Output still running after 30 s")
        #expect(port.rows.first?.decisionValue == .automatic)
    }

    @Test func pausesAfterEightTurnsWithoutAction() async {
        let turns = (1...9).map { actionTurn("w\($0)", .waitForOutput(seconds: 1)) }
        let (model, engine, port) = make(turns)
        ask(model)
        #expect(await waitUntil { model.phase == .paused })
        #expect(engine.calls == 8)
        #expect(model.stepsWithoutAction == 8)
        #expect(engine.deferred.count == 1)
        model.continueAfterPause()
        #expect(await waitUntil { engine.calls == 10 })   // the 9th turn, then a hang
        #expect(model.stepsWithoutAction == 1)
        model.stop()
        withExtendedLifetime(port) {}   // the model holds its port weakly
    }

    @Test func passwordPromptDuringSettlingWaitsForUser() async {
        let (model, engine, port) = make([commandTurn("t1", "sudo apt update"), answerTurn("updated")])
        port.waitHandler = { _ in .passwordPrompt }
        port.onType = { _ in
            port.snapshot = TerminalSnapshot(screen: ["$ sudo apt update", "[sudo] password for pi:"], cursorRow: 1,
                                             cursorColumn: 23)
        }
        ask(model)
        await confirmWhenArmed(model, "t1")
        #expect(await waitUntil { model.phase == .waitingForUser(.password) })
        let steps = model.stepsWithoutAction
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.calls == 1)   // not called again until Continue
        #expect(engine.delivered.isEmpty)
        port.snapshot = TerminalSnapshot(screen: ["$ sudo apt update", "Reading package lists... Done", "$"],
                                         cursorRow: 2, cursorColumn: 2)
        model.continueAfterUser()
        #expect(await waitUntil { model.phase == .finished })
        #expect(engine.calls == 2)
        #expect(model.stepsWithoutAction == steps)
        let outcome = engine.delivered.first?.first
        #expect(outcome?.snapshot == port.snapshot)   // the fresh one, after the user typed
        #expect(outcome?.text.contains("password") == true)
    }

    @Test func runCommandOnAPasswordPromptIsRefused() async {
        let port = FakeTerminalAssistantPort()
        port.snapshot = TerminalSnapshot(screen: ["Password:"], cursorRow: 0, cursorColumn: 9)
        let (model, engine, _) = make([commandTurn("t1", "hunter2"), actionTurn("t2", .sendKeys([.return])),
                                       answerTurn("stop")], port: port)
        ask(model)
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed.isEmpty && port.keys.isEmpty)
        #expect(engine.delivered.map { $0.first?.text } == [CommandRefusal.passwordPrompt.resultText,
                                                             CommandRefusal.passwordPrompt.resultText])
    }

    @Test func sessionEndedCancelsPendingDecisionAndWait() async {
        // A pending decision.
        let (model, engine, port) = make([commandTurn("t1", "df -h")])
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" && model.confirmArmed })
        port.assistantCanAct = false
        model.sessionEnded()
        model.confirm(id: "t1")
        #expect(await waitUntil { model.phase == .failed(.disconnected) })
        #expect(port.typed.isEmpty)
        #expect(status(model, "t1") == .cancelled)
        #expect(port.rows.first?.decisionValue == .cancelled)
        #expect(engine.deferred.map(\.text) == [ToolResultText.disconnected])

        // A settling wait.
        let (waiting, _, waitPort) = make([commandTurn("t2", "make")])
        waitPort.waitHandler = { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .sessionEnded
        }
        ask(waiting)
        await confirmWhenArmed(waiting, "t2")
        #expect(await waitUntil { waitPort.waits.count == 1 })
        waitPort.assistantCanAct = false
        waiting.sessionEnded()
        #expect(await waitUntil { waiting.phase == .failed(.disconnected) })
        #expect(waitPort.typed == ["make"])   // typed before, nothing after
    }

    @Test func snapshotIsReReadAfterConfirm() async {
        let (model, engine, port) = make([commandTurn("t1", "ls"), answerTurn("ok")])
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" })
        // A resize, and a full-screen program, between the proposal and Confirm: re-checked.
        port.snapshot = TerminalSnapshot(screen: ["vim"], cursorRow: 0, cursorColumn: 0, isAlternateScreen: true,
                                         columns: 120, rows: 40)
        await confirmWhenArmed(model, "t1")
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.typed.isEmpty)
        #expect(engine.delivered.first?.first?.text == CommandRefusal.fullScreenProgram.resultText)
        #expect(engine.delivered.first?.first?.snapshot?.columns == 120)

        let (resized, resizedEngine, resizedPort) = make([commandTurn("t2", "ls"), answerTurn("ok")])
        ask(resized)
        #expect(await waitUntil { resized.awaitingID == "t2" })
        resizedPort.snapshot = TerminalSnapshot(screen: ["$"], cursorRow: 0, cursorColumn: 2, columns: 132, rows: 50)
        await confirmWhenArmed(resized, "t2")
        #expect(await waitUntil { resized.phase == .finished })
        #expect(resizedPort.typed == ["ls"])
        #expect(resizedEngine.delivered.first?.first?.snapshot?.columns == 132)
    }

    @Test func recordsStoreLengthAndProgramOnly() async {
        let (model, _, port) = make([commandTurn("t1", "df -h"), answerTurn("ok")])
        ask(model)
        await confirmWhenArmed(model, "t1")
        #expect(await waitUntil { model.phase == .finished })
        #expect(port.rows.first?.kindValue == .command)
        #expect(port.rows.first?.payload == #"{"length":5,"program":"df"}"#)
        #expect(port.rows.first?.payload.contains("-h") == false)
        #expect(TerminalAssistantModel.commandPayload("TOKEN=abc123 curl -s x") == #"{"length":22,"program":"curl"}"#)
    }

    @Test func providerSwapsOnlyBetweenConversations() async {
        var chosen = AssistantProvider.claude
        var made: [AssistantProvider] = []
        let port = FakeTerminalAssistantPort()
        let model = TerminalAssistantModel(port: port, provider: { chosen }, makeEngine: { provider in
            made.append(provider)
            return ScriptedTerminalEngine(provider: provider, [commandTurn("t1", "ls")])
        }, gate: AssistantDecisionGate(armDelay: .zero))
        #expect(model.provider == .claude)
        ask(model)
        #expect(await waitUntil { model.awaitingID == "t1" })
        chosen = .appleOnDevice
        model.syncProvider()
        #expect(model.provider == .claude)   // busy
        model.stop()
        #expect(await waitUntil { model.phase == .stopped })
        model.syncProvider()
        #expect(model.provider == .claude)   // a conversation is open
        model.newConversation()
        #expect(model.provider == .appleOnDevice)
        #expect(made == [.claude, .appleOnDevice])
    }

    @Test func reconnectStartsANewConversation() async {
        let (model, engine, port) = make([answerTurn("hello")])
        ask(model)
        #expect(await waitUntil { model.phase == .finished })
        #expect(engine.hasConversation)
        model.shellReconnected()
        #expect(!engine.hasConversation)
        #expect(model.isNewShell)
        #expect(model.phase == .idle)
        withExtendedLifetime(port) {}
    }

    @Test func parseErrorIsAnsweredAtOnce() async {
        let bad = TerminalTurn(blocks: [.action(TerminalTurnAction(id: "t1", action: nil, parseError: "Error: f1 is not a key."))],
                               stop: .actions, usage: TokenUsage(inputTokens: 10, outputTokens: 5))
        let (model, engine, port) = make([bad, answerTurn("ok")])
        ask(model)
        #expect(await waitUntil { model.phase == .finished })
        #expect(engine.delivered.first?.first?.text == "Error: f1 is not a key.")
        #expect(port.tokens == 15)
    }
}
