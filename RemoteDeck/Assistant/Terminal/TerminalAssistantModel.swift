import ClaudeKit
import Foundation
import Observation
import RemoteDeckCore

/// The terminal assistant of one SSH terminal tab (spec 2026-11-12, TRD › Claude Assistant ›
/// Terminal): on demand only, it reads the terminal as text and proposes one line or key sequence at a
/// time; nothing reaches the shell before Confirm.
///
/// Ask → (snapshot + prompt) → the engine (Claude or Apple) → for each action, in order:
/// `wait_for_output` runs at once; `run_command` is validated (one line, no control character, no
/// full-screen program, no password prompt) and refused at once when it fails, else proposed;
/// `send_keys` is proposed. After Confirm the terminal is read again and re-checked, the bytes go out
/// in one write with the user's own input held back, then the output settles (`OutputSettler`). A
/// password prompt during settling waits for the user (`continueAfterUser`). The confirmation rules
/// are `AssistantDecisionGate`'s, shared with the screen assistant.
@Observable
@MainActor
final class TerminalAssistantModel {
    enum WaitReason: Equatable { case password }

    enum Phase: Equatable {
        case idle
        /// A request is in flight, or an automatic action runs.
        case running
        case awaitingDecision(id: String)
        /// A password prompt shows: the user types it in the terminal, then Continue.
        case waitingForUser(WaitReason)
        /// `maxStepsWithoutAction` turns without a confirmed action: Continue or Stop.
        case paused
        /// Stop or a teardown was asked; the loop is winding down.
        case stopping
        case failed(AssistantFailure)
        case finished
        case refused(category: String?, explanation: String?)
        case cutOff
        case stopped

        var isBusy: Bool {
            switch self {
            case .running, .awaitingDecision, .waitingForUser, .paused, .stopping: true
            default: false
            }
        }
    }

    struct ActionItem: Equatable {
        enum Status: Equatable {
            case queued, awaiting, running, done, automatic, skipped, notExecuted, cancelled
            case failed(String)
        }

        var id: String
        var action: TerminalAction?
        var reason: String?
        var status: Status
        /// The cursor's row when proposed: where the text lands.
        var promptLine: String?
        /// Text already typed after the prompt (best effort): the row says so.
        var commandLineNotEmpty = false
    }

    enum Content: Equatable {
        case prompt(String)
        case progress(String)
        case answer(String)
        case action(ActionItem)
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        var content: Content
    }

    static let maxPromptLength = 2000

    private(set) var phase: Phase = .idle
    private(set) var entries: [Entry] = []
    private(set) var usage = TokenUsage()
    var prompt = ""
    /// The shell was reconnected: the previous conversation was about another shell.
    private(set) var isNewShell = false
    private(set) var engine: any TerminalAssistantEngine

    var awaitingID: String? { gate.pendingID }
    var confirmArmed: Bool { gate.isArmed }
    var stepsWithoutAction: Int { gate.stepsWithoutAction }

    @ObservationIgnored weak var port: (any TerminalAssistantPort)?
    private let gate: AssistantDecisionGate
    @ObservationIgnored private let providerChoice: @MainActor () -> AssistantProvider
    @ObservationIgnored private let makeEngine: @MainActor (AssistantProvider) -> any TerminalAssistantEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var finalPhase: Phase?
    @ObservationIgnored private var turnConfirmedAnAction = false
    @ObservationIgnored private var nextEntryID = 0
    /// The turn's results while a password prompt waits for the user.
    @ObservationIgnored private var heldOutcomes: [TerminalActionOutcome]?

    init(port: (any TerminalAssistantPort)?, provider: @escaping @MainActor () -> AssistantProvider,
         makeEngine: @escaping @MainActor (AssistantProvider) -> any TerminalAssistantEngine,
         gate: AssistantDecisionGate = AssistantDecisionGate()) {
        self.port = port
        providerChoice = provider
        self.makeEngine = makeEngine
        self.gate = gate
        engine = makeEngine(provider())
    }

    var provider: AssistantProvider { engine.provider }
    var isReady: Bool { engine.isReady }
    var sessionConnected: Bool { port?.assistantCanAct == true }
    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canAsk: Bool {
        !phase.isBusy && isReady && !trimmedPrompt.isEmpty && trimmedPrompt.count <= Self.maxPromptLength
            && port?.assistantCanAct == true
    }

    /// Takes the provider chosen in Settings, between conversations only.
    func syncProvider() {
        guard !phase.isBusy, !engine.hasConversation else { return }
        let chosen = providerChoice()
        guard chosen != engine.provider else { return }
        engine = makeEngine(chosen)
        if case .failed = phase { phase = .idle }
    }

    func item(_ id: String) -> ActionItem? {
        for entry in entries.reversed() {
            if case .action(let item) = entry.content, item.id == id { return item }
        }
        return nil
    }

    // MARK: Ask, Continue, Stop

    func ask() {
        syncProvider()
        let text = trimmedPrompt
        guard canAsk else { return }
        prompt = ""
        isNewShell = false
        gate.resetSteps()
        append(.prompt(text))
        start { [weak self] in
            guard let self else { return }
            let snapshot = await self.port?.assistantSnapshot()
            self.engine.begin(prompt: text, snapshot: snapshot?.bounded())
            await self.loop()
        }
    }

    /// The same prompt again: `prompt` set, then `ask`.
    func ask(_ text: String) {
        prompt = text
        ask()
    }

    /// After an error: the same request again.
    func retry() {
        guard case .failed(let failure) = phase, !failure.isPermanent, engine.canResend, isReady else { return }
        start { [weak self] in await self?.loop() }
    }

    func continueAfterPause() {
        guard phase == .paused, engine.hasConversation, isReady else { return }
        gate.resetSteps()
        start { [weak self] in
            self?.engine.deliver([])
            await self?.loop()
        }
    }

    /// The user typed the password in the terminal: the turn's results go out with the terminal as it
    /// is now. The step counter is not advanced by the wait.
    func continueAfterUser() {
        guard phase == .waitingForUser(.password), let held = heldOutcomes else { return }
        heldOutcomes = nil
        start { [weak self] in
            guard let self else { return }
            let snapshot = await self.port?.assistantSnapshot()?.bounded()
            let outcomes = held.map { outcome in
                guard outcome.text == Self.passwordWaitText else { return outcome }
                return TerminalActionOutcome(id: outcome.id, text: Self.passwordDoneText, snapshot: snapshot)
            }
            self.engine.deliver(outcomes)
            await self.loop()
        }
    }

    func stop() {
        guard phase.isBusy else { return }
        interrupt(as: .stopped)
    }

    /// The shell went away (tab close, sleep, network loss, the shell exiting): before the teardown.
    func sessionEnded() {
        guard phase.isBusy else { return }
        interrupt(as: .failed(.disconnected))
    }

    /// A new shell after a reconnect: the conversation does not carry over.
    func shellReconnected() {
        if phase.isBusy { interrupt(as: .failed(.disconnected)) }
        engine.reset()
        heldOutcomes = nil
        isNewShell = true
        if !phase.isBusy { phase = .idle }
    }

    func newConversation() {
        guard !phase.isBusy else { return }
        engine.reset()
        entries = []
        isNewShell = false
        phase = .idle
        syncProvider()
    }

    func confirm(id: String, isKeyRepeat: Bool = false) {
        guard !isKeyRepeat else { return }
        gate.confirm(id: id)
    }

    func skip(id: String) {
        gate.skip(id: id)
    }

    private func interrupt(as final: Phase) {
        if let held = heldOutcomes {
            heldOutcomes = nil
            engine.deferOutcomes(held.map { TerminalActionOutcome(id: $0.id, text: $0.text, snapshot: nil, isError: $0.isError) })
        }
        if task == nil {
            phase = final
        } else {
            finalPhase = final
            phase = .stopping
            task?.cancel()
        }
        gate.stopAll()
    }

    private func start(_ body: @escaping @MainActor () async -> Void) {
        generation += 1
        let generation = self.generation
        phase = .running
        task = Task {
            await body()
            self.taskEnded(generation)
        }
    }

    private func taskEnded(_ generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        if phase == .stopping { phase = finalPhase ?? .stopped }
        finalPhase = nil
    }

    private func setPhase(_ value: Phase) {
        guard phase != .stopping else { return }
        phase = value
    }

    private func owe(_ turn: TerminalTurn, _ text: String) {
        let ids = turn.actions.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { setStatus(.notExecuted, for: id) }
        engine.deferOutcomes(ids.map { TerminalActionOutcome(id: $0, text: text, isError: true) })
    }

    // MARK: Loop

    private func loop() async {
        while !Task.isCancelled, engine.hasConversation {
            setPhase(.running)
            let turn: TerminalTurn
            do {
                turn = try await engine.nextTurn()
            } catch {
                switch error {
                case .notReady(let failure): setPhase(.failed(failure))
                case .failed(let failure): if !Task.isCancelled { setPhase(.failed(failure)) }
                case .cancelled: break
                }
                return
            }
            if let usage = turn.usage {
                self.usage += usage
                port?.assistantAddTokens(usage.total)
                port?.assistantSave()
            }
            guard !Task.isCancelled else {
                owe(turn, ToolResultText.stopped)
                return
            }
            show(turn)
            switch turn.stop {
            case .actions:
                turnConfirmedAnAction = false
                let (results, passwordWait) = await run(turn.actions)
                if Task.isCancelled {
                    engine.deferOutcomes(results)
                    return
                }
                gate.recordTurn(confirmedAction: turnConfirmedAnAction)
                if passwordWait {
                    heldOutcomes = results
                    setPhase(.waitingForUser(.password))
                    return
                }
                if gate.shouldPause {
                    engine.deferOutcomes(results)
                    setPhase(.paused)
                    return
                }
                engine.deliver(results)
            case .refused(let category, let explanation):
                owe(turn, ToolResultText.notExecuted)
                setPhase(.refused(category: category, explanation: explanation))
                return
            case .cutOff:
                owe(turn, ToolResultText.cutOff)
                setPhase(.cutOff)
                return
            case .done:
                owe(turn, ToolResultText.notExecuted)
                setPhase(.finished)
                return
            }
        }
    }

    private func show(_ turn: TerminalTurn) {
        for block in turn.blocks {
            switch block {
            case .answer(let text): append(.answer(text))
            case .progress(let text): append(.progress(text))
            case .action(let use):
                append(.action(ActionItem(id: use.id, action: use.action, reason: use.reason, status: .queued)))
            }
        }
    }

    /// The turn's actions in order, one result each; after a skip or a failure the rest are not run.
    /// `passwordWait`: a password prompt showed while settling.
    private func run(_ uses: [TerminalTurnAction]) async -> ([TerminalActionOutcome], Bool) {
        var results: [TerminalActionOutcome] = []
        var halted = false
        var passwordWait = false
        for use in uses {
            if Task.isCancelled {
                results.append(TerminalActionOutcome(id: use.id, text: ToolResultText.stopped, isError: true))
                setStatus(.cancelled, for: use.id)
                continue
            }
            if halted || passwordWait {
                results.append(TerminalActionOutcome(id: use.id, text: ToolResultText.notExecuted, isError: true))
                setStatus(.notExecuted, for: use.id)
                continue
            }
            let outcome = await runOne(use)
            results.append(outcome.result)
            halted = outcome.halts
            passwordWait = outcome.passwordWait
        }
        return (results, passwordWait)
    }

    private typealias Step = (result: TerminalActionOutcome, halts: Bool, passwordWait: Bool)

    private func runOne(_ use: TerminalTurnAction) async -> Step {
        func failure(_ text: String, _ snapshot: TerminalSnapshot? = nil) -> Step {
            setStatus(.failed(text), for: use.id)
            return (TerminalActionOutcome(id: use.id, text: text, snapshot: snapshot?.bounded(), isError: true), true, false)
        }
        if let parseError = use.parseError { return failure(parseError) }
        guard let action = use.action else { return failure("Error: the action could not be read.") }
        guard let port, port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (TerminalActionOutcome(id: use.id, text: ToolResultText.disconnected, isError: true), true, false)
        }

        if case .waitForOutput(let seconds) = action {
            let seconds = max(1, min(seconds, OutputSettler.maxWaitSeconds))
            _ = port.assistantRecord(kind: .wait, payload: Self.json(["seconds": .int(seconds)]), decision: .automatic)
            setStatus(.running, for: use.id)
            let wait = await port.assistantWaitForOutput(cap: .seconds(seconds))
            let snapshot = await port.assistantSnapshot()?.bounded()
            setStatus(.automatic, for: use.id)
            return settled(wait, id: use.id, snapshot: snapshot)
        }

        // Checked before asking: a proposal that cannot run is answered at once.
        let snapshot = await port.assistantSnapshot()
        if let refusal = refusal(for: action, snapshot: snapshot) { return failure(refusal.resultText, snapshot) }
        let row = port.assistantRecord(kind: action.recordKind, payload: Self.payload(action), decision: .pending)
        update(use.id) {
            $0.promptLine = snapshot?.promptLine
            $0.commandLineNotEmpty = snapshot.map { !$0.commandLineLooksEmpty } ?? false
            $0.status = .awaiting
        }
        setPhase(.awaitingDecision(id: use.id))
        let decision = await gate.decide(id: use.id)
        switch decision {
        case .stopped:
            row?.decisionValue = .cancelled
            port.assistantSave()
            setStatus(.cancelled, for: use.id)
            let text = finalPhase == .failed(.disconnected) ? ToolResultText.disconnected : ToolResultText.stopped
            return (TerminalActionOutcome(id: use.id, text: text, isError: true), true, false)
        case .skipped:
            row?.decisionValue = .rejected
            port.assistantSave()
            setStatus(.skipped, for: use.id)
            setPhase(.running)
            return (TerminalActionOutcome(id: use.id, text: ToolResultText.skipped, isError: true), true, false)
        case .confirmed:
            row?.decisionValue = .confirmed
            port.assistantSave()
            turnConfirmedAnAction = true
        }
        setPhase(.running)
        // The terminal may have changed since the proposal (a resize, a program started): read again.
        let current = await port.assistantSnapshot()
        guard !Task.isCancelled, port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (TerminalActionOutcome(id: use.id, text: ToolResultText.disconnected, isError: true), true, false)
        }
        if let refusal = refusal(for: action, snapshot: current) { return failure(refusal.resultText, current) }
        setStatus(.running, for: use.id)
        port.assistantIsSending = true
        switch action {
        case .runCommand(let command): port.assistantType(command)
        case .sendKeys(let keys): port.assistantSendKeys(keys)
        case .waitForOutput: break
        }
        port.assistantIsSending = false
        let wait = await port.assistantWaitForOutput(cap: OutputSettler.actionCap)
        // The shell went away (or Stop) while the output settled: typed, but the row ends cancelled.
        if wait == .sessionEnded || Task.isCancelled {
            setStatus(.cancelled, for: use.id)
            let text = finalPhase == .failed(.disconnected) || wait == .sessionEnded
                ? ToolResultText.disconnected : ToolResultText.stopped
            return (TerminalActionOutcome(id: use.id, text: text, isError: true), true, false)
        }
        let after = await port.assistantSnapshot()?.bounded()
        setStatus(.done, for: use.id)
        return settled(wait, id: use.id, snapshot: after)
    }

    private func refusal(for action: TerminalAction, snapshot: TerminalSnapshot?) -> CommandRefusal? {
        let connected = port?.assistantCanAct == true
        switch action {
        case .runCommand(let command):
            return TerminalCommandValidator.validate(command, snapshot: snapshot, connected: connected)
        case .sendKeys:
            guard connected else { return .notConnected }
            if let snapshot, PasswordPromptDetector.isShowing(in: snapshot) { return .passwordPrompt }
            return nil
        case .waitForOutput:
            return nil
        }
    }

    static let passwordWaitText = "A password prompt is showing; the user is typing it."
    static let passwordDoneText = "OK. A password prompt showed; the user typed the password in the terminal and clicked Continue."

    private func settled(_ wait: OutputWait, id: String, snapshot: TerminalSnapshot?) -> Step {
        switch wait {
        case .settled:
            return (TerminalActionOutcome(id: id, text: ToolResultText.ok, snapshot: snapshot), false, false)
        case .commandEnded(let code):
            let text = code.map { "OK. The command ended with exit code \($0)." } ?? ToolResultText.ok
            return (TerminalActionOutcome(id: id, text: text, snapshot: snapshot), false, false)
        case .stillRunning(let seconds):
            return (TerminalActionOutcome(id: id, text: "Output still running after \(seconds) s", snapshot: snapshot),
                    false, false)
        case .passwordPrompt:
            return (TerminalActionOutcome(id: id, text: Self.passwordWaitText, snapshot: snapshot), false, true)
        case .sessionEnded:
            return (TerminalActionOutcome(id: id, text: ToolResultText.disconnected, isError: true), true, false)
        }
    }

    // MARK: Records

    /// AssistantAction.payload: never the command text (it may hold a secret), only its length and
    /// the program (its first word that is not an environment assignment).
    static func commandPayload(_ command: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace)
        let program = words.first { !$0.contains("=") }.map { String($0.prefix(64)) } ?? ""
        return json(["length": .int(command.count), "program": .string(program)])
    }

    static func payload(_ action: TerminalAction) -> String {
        switch action {
        case .runCommand(let command): commandPayload(command)
        case .sendKeys(let keys): json(["keys": .array(keys.map { .string($0.rawValue) })])
        case .waitForOutput(let seconds): json(["seconds": .int(seconds)])
        }
    }

    private static func json(_ object: [String: JSONValue]) -> String {
        String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)
    }

    // MARK: Transcript

    private func append(_ content: Content) {
        entries.append(Entry(id: nextEntryID, content: content))
        nextEntryID += 1
    }

    private func update(_ id: String, _ change: (inout ActionItem) -> Void) {
        guard let index = entries.lastIndex(where: {
            if case .action(let item) = $0.content { return item.id == id }
            return false
        }), case .action(var item) = entries[index].content else { return }
        change(&item)
        entries[index].content = .action(item)
    }

    private func setStatus(_ status: ActionItem.Status, for id: String) {
        update(id) { $0.status = status }
    }
}

extension TerminalAction {
    var recordKind: AssistantActionKind {
        switch self {
        case .runCommand: .command
        case .sendKeys: .keys
        case .waitForOutput: .wait
        }
    }
}
