import ClaudeKit
import Foundation
import Observation
import RemoteDeckCore
import RFBKit

/// What the Claude Assistant needs from its session (`SessionModel` in the app, a fake in tests).
@MainActor
protocol AssistantSessionPort: AnyObject {
    /// Connected, with an input sender: actions may run.
    var assistantCanAct: Bool { get }
    var assistantDesktop: RemoteDesktopKind { get }
    var assistantProfile: ModifierProfile { get }
    /// The current framebuffer (`RFBConnection.framebufferSnapshot`).
    func assistantSnapshot() async -> Framebuffer?
    /// One batch of input, through the session's `InputSender` (in order, never bypassed).
    func assistantSend(_ messages: [ClientMessage])
    /// Before a screenshot that follows an action: waits for the remote to redraw (next framebuffer
    /// update, capped).
    func assistantSettle() async
    /// Inserts an AssistantAction row (BackendSchema) for the current SessionRecord.
    func assistantRecord(kind: AssistantActionKind, payload: String, decision: AssistantDecision) -> AssistantAction?
    func assistantSave()
    /// Adds to SessionRecord.assistantTokens.
    func assistantAddTokens(_ count: Int)
    /// Gives the keyboard back to the Mac (releases the capture), so the panel's buttons and field
    /// get the keys while Claude waits for a confirmation.
    func assistantReleaseKeyboard()
}

/// Why a request or the loop stopped with an error (the panel's banner; the copy is in the view).
enum AssistantFailure: Equatable, Sendable {
    case noAPIKey
    case api(AnthropicError)
    case disconnected
    /// The Apple model cannot answer on this Mac (Settings › Assistant shows the same reason).
    case appleUnavailable(AppleModelUnavailability)
    /// The Apple model failed a step (the error's description).
    case appleGeneration(String)

    /// Retry cannot help: the panel shows no Retry button.
    var isPermanent: Bool {
        switch self {
        case .disconnected, .noAPIKey, .appleUnavailable: true
        case .api, .appleGeneration: false
        }
    }
}

/// The Claude Assistant of one session (AppFlow › Claude Assistant Panel, PRD acceptance criterion 8):
/// on demand only, every action that reaches the remote confirmed first.
///
/// Ask → (screenshot of the framebuffer + prompt) → the engine (Claude's Messages API, or Apple's
/// on-device model, `AssistantEngine`) → for each proposed action, in order: read-only ones
/// (screenshot, zoom, cursor_position, wait) run at once; any other is shown as a proposal and runs
/// only on Confirm. Skip answers it with an error result and the rest of that turn with the
/// documented "Not executed" text, then the model answers. Stop cancels the request and the loop;
/// results owed by then go out at the start of the next Ask (`AssistantEngine.deferOutcomes`).
@Observable
@MainActor
final class AssistantModel {
    enum Phase: Equatable {
        case idle
        /// "Claude is looking…"
        case sending
        /// A proposed action waits for Confirm or Skip.
        case confirming
        /// A confirmed action is running on the remote.
        case running
        case done
        case refused(category: String?, explanation: String?)
        /// `max_tokens` or the context window: the turn ended early.
        case cutOff
        case stopped
        case failed(AssistantFailure)
        /// Stop or a disconnect was asked: the loop's task is winding down (it still owes the turn's
        /// results to the conversation). Busy, so no Ask starts before it ends; then `stopped` or
        /// `failed(.disconnected)`.
        case stopping
        /// `maxStepsWithoutAction` turns in a row confirmed no action (T5.3 M3): the loop waits for
        /// Continue or Stop. The turn's results wait in the conversation (`deferResults`).
        case paused

        var isBusy: Bool {
            self == .sending || self == .confirming || self == .running || self == .stopping || self == .paused
        }
    }

    struct ActionItem: Equatable {
        enum Status: Equatable {
            /// Waiting for its turn in the batch.
            case queued
            /// Waiting for Confirm or Skip.
            case awaiting
            case running
            case done
            /// Ran without asking (read-only).
            case automatic
            case skipped
            /// Not run: an earlier action of the turn was skipped or failed.
            case notExecuted
            case cancelled
            case failed(String)
        }

        var toolUseID: String
        /// The member name (`left_click`…), as Claude sent it.
        var name: String
        var action: ComputerAction?
        /// The target in remote pixels (for the description and the highlight).
        var targets: [PointerLocation]
        var status: Status
        /// The visible text an Apple click or scroll aims at (its point is in `targets`).
        var label: String? = nil
    }

    enum Content: Equatable {
        case prompt(String)
        /// A progress update (a non-empty thinking block under `display: "updates"`).
        case progress(String)
        case answer(String)
        case action(ActionItem)
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        var content: Content
    }

    enum Decision { case confirm, skip, stop }

    static let maxPromptLength = 2000
    /// Confirm (button or ⌘Return) is accepted only this long after a proposal is shown, so a held
    /// ⌘Return or a double click cannot confirm the next proposal unseen.
    static let defaultArmDelay: Duration = AssistantDecisionGate.defaultArmDelay
    /// Consecutive API turns without a confirmed action (screenshots, zooms, waits, cursor positions,
    /// skips, errors) before the loop pauses (T5.3 M3): a task cannot run up tokens unattended.
    static let maxStepsWithoutAction = AssistantDecisionGate.maxStepsWithoutAction
    /// A `type` text longer than this (Unicode scalars, as `ComputerAction.maxTypeLength`) or on several lines (a single trailing line end
    /// aside) is shown in a block the user must open before Confirm arms (T5.3 M2).
    nonisolated static let typeRevealThreshold = 80

    /// Whether a proposed `type` text must be opened (shown whole) before it can be confirmed.
    nonisolated static func typeTextNeedsReveal(_ text: String) -> Bool {
        // One trailing line end (a command then Return) is still one line, shown whole in the row.
        var lines = Substring(text)
        if lines.last?.isNewline == true { lines = lines.dropLast() }
        return text.unicodeScalars.count > typeRevealThreshold || lines.contains(where: \.isNewline)
    }

    private(set) var phase: Phase = .idle
    private(set) var entries: [Entry] = []
    /// Tokens of this session, every request summed (PRD open question 4).
    private(set) var usage = TokenUsage()
    var prompt = ""
    /// Remote pixels of the action waiting for confirmation (drawn on the framebuffer).
    private(set) var highlight: [PointerLocation] = []
    /// The `tool_use` id of the proposal waiting for Confirm or Skip.
    var awaitingID: String? { gate.pendingID }
    /// Confirm is accepted (`defaultArmDelay` after the proposal appeared, or after its text was
    /// opened when it had to be).
    var confirmArmed: Bool { gate.isArmed }
    /// The awaiting proposal is a `type` whose text must be opened first (`typeTextNeedsReveal`).
    private(set) var awaitingNeedsReveal = false
    /// The awaiting proposal's full text was opened.
    private(set) var awaitingRevealed = false
    /// API turns in a row that confirmed no action (`maxStepsWithoutAction`).
    var stepsWithoutAction: Int { gate.stepsWithoutAction }
    /// The confirmation rules shared with the terminal assistant (observable: the panel reads them).
    private let gate: AssistantDecisionGate

    @ObservationIgnored weak var port: (any AssistantSessionPort)?
    /// Changes only between conversations (`syncProvider`).
    private(set) var engine: any AssistantEngine
    /// The provider chosen in Settings, and how to build its engine (nil: the engine is fixed).
    @ObservationIgnored private let providerChoice: (@MainActor () -> AssistantProvider)?
    @ObservationIgnored private let makeEngine: (@MainActor (AssistantProvider) -> any AssistantEngine)?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// What a running plan still has to release if it is interrupted.
    @ObservationIgnored private var pendingRelease: [ClientMessage]?
    /// The last screenshot sent: Claude's coordinates are in its pixel space.
    @ObservationIgnored private(set) var mapping: ScreenMapping?
    /// Where the assistant left the pointer (remote pixels).
    @ObservationIgnored private var pointer: PointerLocation?
    @ObservationIgnored private var nextEntryID = 0
    /// The loop task's generation: a late end of a stopped task changes nothing.
    @ObservationIgnored private var generation = 0
    /// Where a `stopping` phase ends.
    @ObservationIgnored private var finalPhase: Phase?
    /// The user confirmed an action in the turn being run.
    @ObservationIgnored private var turnConfirmedAnAction = false

    init(port: (any AssistantSessionPort)?, engine: any AssistantEngine,
         armDelay: Duration = AssistantModel.defaultArmDelay,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.engine = engine
        providerChoice = nil
        makeEngine = nil
        gate = AssistantDecisionGate(armDelay: armDelay)
        self.sleep = sleep
    }

    /// The app's: the engine of the provider chosen in Settings, rebuilt when the choice changed and
    /// no conversation is open (a new session, New conversation, or the panel shown again).
    init(port: (any AssistantSessionPort)?, provider: @escaping @MainActor () -> AssistantProvider,
         armDelay: Duration = AssistantModel.defaultArmDelay,
         makeEngine: @escaping @MainActor (AssistantProvider) -> any AssistantEngine) {
        self.port = port
        engine = makeEngine(provider())
        providerChoice = provider
        self.makeEngine = makeEngine
        gate = AssistantDecisionGate(armDelay: armDelay)
        sleep = { try await Task.sleep(for: $0) }
    }

    /// Takes the provider chosen in Settings, between conversations only.
    func syncProvider() {
        guard let providerChoice, let makeEngine, !phase.isBusy, !engine.hasConversation else { return }
        let chosen = providerChoice()
        guard chosen != engine.provider else { return }
        engine = makeEngine(chosen)
        if case .failed = phase { phase = .idle }
    }

    /// The Claude provider (`ClaudeEngine`).
    convenience init(port: (any AssistantSessionPort)?, client: MessagesClient, apiKey: @escaping @MainActor () -> String,
                     model: String = ClaudeAPI.defaultModel, armDelay: Duration = AssistantModel.defaultArmDelay,
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(port: port, engine: ClaudeEngine(client: client, apiKey: apiKey, model: model),
                  armDelay: armDelay, sleep: sleep)
    }

    var provider: AssistantProvider { engine.provider }

    /// The engine can answer: Claude has a key, the Apple model is available.
    var isReady: Bool { engine.isReady }

    /// Claude's name for `isReady` (a key is set).
    var hasAPIKey: Bool { isReady }

    var sessionConnected: Bool { port?.assistantCanAct == true }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canAsk: Bool {
        !phase.isBusy && isReady && !trimmedPrompt.isEmpty && trimmedPrompt.count <= Self.maxPromptLength
            && port?.assistantCanAct == true
    }

    /// The request body that would be sent now (tests).
    var currentRequestBody: Data? { (engine as? ClaudeEngine)?.currentRequestBody }

    // MARK: Ask, Retry, Stop

    func ask() {
        syncProvider()
        let text = trimmedPrompt
        guard canAsk else { return }
        prompt = ""
        gate.resetSteps()   // the user is here: a new count
        append(.prompt(text))
        let desktop = port?.assistantDesktop ?? .x11
        start { [weak self] in
            guard let self else { return }
            let image = await self.screenshot()
            self.engine.begin(prompt: text, screenshot: image, desktop: desktop)
            await self.loop()
        }
    }

    /// After an error: sends the same request again (the history did not change).
    func retry() {
        guard case .failed(let failure) = phase, failure != .disconnected, engine.canResend,
              isReady else { return }
        start { [weak self] in await self?.loop() }
    }

    /// Continue after a pause: a new count, then the turn's results go out with the next request.
    func continueAfterPause() {
        guard phase == .paused, engine.hasConversation, isReady else { return }
        gate.resetSteps()
        start { [weak self] in
            self?.engine.deliver([])   // the deferred results, alone
            await self?.loop()
        }
    }

    /// Stop (⌘.): cancels the request in flight and the loop. Nothing more is sent to the remote,
    /// except the release of what a running action holds.
    func stop() {
        guard phase.isBusy else { return }
        interrupt(as: .stopped)
    }

    /// The session left `.connected` (drop, close): pending actions are cancelled at once, and a running
    /// action's releases are enqueued now, before the session finishes its input sender.
    func sessionEnded() {
        guard phase.isBusy else { return }
        interrupt(as: .failed(.disconnected))
    }

    /// A new conversation (the token counter keeps the session's total).
    func clear() {
        guard !phase.isBusy else { return }
        engine.reset()
        entries = []
        mapping = nil
        phase = .idle
        syncProvider()
    }

    /// Confirm of the proposal `id`: ignored for any other (stale) id, before the proposal is armed,
    /// and for a key repeat (a held ⌘Return).
    func confirm(_ id: String, isKeyRepeat: Bool = false) {
        guard id == awaitingID, confirmArmed, !isKeyRepeat else { return }
        resolve(.confirm)
    }

    func skip(_ id: String) {
        guard id == awaitingID else { return }
        resolve(.skip)
    }

    /// Opens the full text of the awaiting `type` proposal; Confirm arms `defaultArmDelay` later.
    func reveal(_ id: String) {
        guard id == awaitingID, awaitingNeedsReveal, !awaitingRevealed else { return }
        awaitingRevealed = true
        gate.arm(id)
    }

    private func resolve(_ value: Decision) {
        awaitingNeedsReveal = false
        awaitingRevealed = false
        switch value {
        case .confirm: gate.confirm(id: awaitingID ?? "")
        case .skip: gate.skip(id: awaitingID ?? "")
        case .stop: gate.stopAll()
        }
    }

    private func interrupt(as final: Phase) {
        if let release = pendingRelease {
            pendingRelease = nil
            if !release.isEmpty { port?.assistantSend(release) }
        }
        highlight = []
        if task == nil {
            phase = final
        } else {
            finalPhase = final
            phase = .stopping
            task?.cancel()
        }
        resolve(.stop)
    }

    private func start(_ body: @escaping @MainActor () async -> Void) {
        generation += 1
        let generation = self.generation
        phase = .sending
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

    /// A phase change from inside the loop; once Stop or a disconnect asked, only `taskEnded` moves on.
    private func setPhase(_ value: Phase) {
        guard phase != .stopping else { return }
        phase = value
    }

    /// Error results for the turn's calls that will not run, owed to the next user message: without
    /// them the conversation would hold an unanswered `tool_use` and every later request would fail.
    private func owe(_ turn: AssistantTurn, _ text: String) {
        let ids = turn.actions.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { setStatus(.notExecuted, for: id) }
        engine.deferOutcomes(ids.map { ActionOutcome(id: $0, text: text, isError: true) })
    }

    // MARK: Loop

    private func loop() async {
        while !Task.isCancelled, engine.hasConversation {
            setPhase(.sending)
            let turn: AssistantTurn
            do {
                turn = try await engine.nextTurn { [weak self] in
                    await self?.port?.assistantSettle()
                    return await self?.screenshot()
                }
            } catch {
                switch error {
                case .notReady(let failure): setPhase(.failed(failure))
                case .failed(let failure): if !Task.isCancelled { setPhase(.failed(failure)) }
                case .cancelled: break
                }
                return
            }
            // Billed whatever happens next (Claude only: Apple reports no tokens).
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
                let results = await run(turn.actions)
                if Task.isCancelled {
                    engine.deferOutcomes(results)
                    return
                }
                gate.recordTurn(confirmedAction: turnConfirmedAnAction)
                if gate.shouldPause {
                    // Not sent yet: Continue sends them alone, a Stop leaves them for the next Ask.
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
                setPhase(.done)
                return
            }
        }
    }

    /// Adds the turn's text, progress updates and proposed actions to the transcript.
    private func show(_ turn: AssistantTurn) {
        for block in turn.blocks {
            switch block {
            case .answer(let text):
                append(.answer(text))
            case .progress(let text):
                append(.progress(text))
            case .action(let use):
                let targets = (use.action?.points ?? []).compactMap { remotePoint($0) }
                append(.action(ActionItem(toolUseID: use.id, name: use.name, action: use.action, targets: targets,
                                          status: .queued, label: use.label)))
            }
        }
    }

    /// Runs the turn's actions in order and returns one result per action. After a skip or a
    /// failure the rest are not run (computer use docs, "Batch actions"). On Stop, the actions not
    /// run yet get the "stopped" result.
    private func run(_ uses: [TurnAction]) async -> [ActionOutcome] {
        var results: [ActionOutcome] = []
        var halted = false
        for use in uses {
            if Task.isCancelled {
                results.append(ActionOutcome(id: use.id, text: ToolResultText.stopped, isError: true))
                setStatus(.cancelled, for: use.id)
                continue
            }
            if halted {
                results.append(ActionOutcome(id: use.id, text: ToolResultText.notExecuted, isError: true))
                setStatus(.notExecuted, for: use.id)
                continue
            }
            let outcome = await runOne(use)
            results.append(outcome.result)
            halted = outcome.halts
        }
        return results
    }

    private func runOne(_ use: TurnAction) async -> (result: ActionOutcome, halts: Bool) {
        func failure(_ text: String) -> (ActionOutcome, Bool) {
            setStatus(.failed(text), for: use.id)
            return (ActionOutcome(id: use.id, text: text, isError: true), true)
        }
        if let parseError = use.parseError { return failure(parseError) }
        guard let action = use.action else {
            return failure(ComputerAction.ParseError.unsupported(use.name).resultText)
        }
        guard let port, port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (ActionOutcome(id: use.id, text: ToolResultText.disconnected, isError: true), true)
        }

        if action.isReadOnly {
            _ = port.assistantRecord(kind: action.recordKind, payload: payload(action, input: use.input),
                                     decision: .automatic)
            setStatus(.running, for: use.id)
            let result = await runReadOnly(action, id: use.id)
            if case .failed = status(of: use.id) { return (result, true) }
            setStatus(.automatic, for: use.id)
            return (result, false)
        }

        // Checked before asking: a proposal that cannot run is answered at once.
        let plan: ActionPlan
        do {
            plan = try ActionPlanner.plan(action, mapping: currentMapping(), profile: port.assistantProfile,
                                          pointer: pointer)
        } catch {
            return failure(error.resultText)
        }
        let row = port.assistantRecord(kind: action.recordKind, payload: payload(action, input: use.input),
                                       decision: .pending)
        // A click or scroll without a coordinate happens where the pointer is: show that.
        if targets(of: use.id).isEmpty, action.usesPointer, let at = plan.pointer { setTargets([at], for: use.id) }
        setStatus(.awaiting, for: use.id)
        highlight = targets(of: use.id)
        setPhase(.confirming)
        port.assistantReleaseKeyboard()
        var needsReveal = false
        if case .type(let text) = action, Self.typeTextNeedsReveal(text) { needsReveal = true }   // armed by `reveal`
        if !Task.isCancelled {
            awaitingRevealed = false
            awaitingNeedsReveal = needsReveal
        }
        let decision = await gate.decide(id: use.id, armsNow: !needsReveal)
        highlight = []
        switch decision {
        case .stopped:
            row?.decisionValue = .cancelled
            port.assistantSave()
            setStatus(.cancelled, for: use.id)
            let text = finalPhase == .failed(.disconnected) ? ToolResultText.disconnected : ToolResultText.stopped
            return (ActionOutcome(id: use.id, text: text, isError: true), true)
        case .skipped:
            row?.decisionValue = .rejected
            port.assistantSave()
            setStatus(.skipped, for: use.id)
            setPhase(.sending)
            return (ActionOutcome(id: use.id, text: ToolResultText.skipped, isError: true), true)
        case .confirmed:
            row?.decisionValue = .confirmed
            port.assistantSave()
            turnConfirmedAnAction = true
        }
        guard port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (ActionOutcome(id: use.id, text: ToolResultText.disconnected, isError: true), true)
        }
        setPhase(.running)
        setStatus(.running, for: use.id)
        let completed = await execute(plan)
        guard completed else {
            setStatus(.cancelled, for: use.id)
            return (ActionOutcome(id: use.id, text: ToolResultText.stopped, isError: true), true)
        }
        pointer = plan.pointer ?? pointer
        setStatus(.done, for: use.id)
        setPhase(.sending)
        return (ActionOutcome(id: use.id, text: ToolResultText.ok), false)
    }

    /// Sends the plan's batches with its pauses. `false` when interrupted: what it held is released
    /// (by `interrupt` if that came first).
    private func execute(_ plan: ActionPlan) async -> Bool {
        pendingRelease = plan.release
        defer { pendingRelease = nil }
        for step in plan.steps {
            guard !Task.isCancelled, let port, port.assistantCanAct else {
                if let release = pendingRelease, !release.isEmpty { port?.assistantSend(release) }
                return false
            }
            switch step {
            case .send(let messages):
                port.assistantSend(messages)
            case .pause(let duration):
                do {
                    try await sleep(duration)
                } catch {
                    if let release = pendingRelease, !release.isEmpty { port.assistantSend(release) }
                    return false
                }
            }
        }
        return !Task.isCancelled
    }

    private func runReadOnly(_ action: ComputerAction, id: String) async -> ActionOutcome {
        switch action {
        case .screenshot:
            await port?.assistantSettle()
            guard let image = await screenshot() else {
                setStatus(.failed(ToolResultText.noFramebuffer), for: id)
                return ActionOutcome(id: id, text: ToolResultText.noFramebuffer, isError: true)
            }
            return ActionOutcome(id: id, image: image)
        case .zoom(let x0, let y0, let x1, let y1):
            await port?.assistantSettle()
            guard let framebuffer = await port?.assistantSnapshot() else {
                setStatus(.failed(ToolResultText.noFramebuffer), for: id)
                return ActionOutcome(id: id, text: ToolResultText.noFramebuffer, isError: true)
            }
            let mapping = currentMapping(for: framebuffer)
            guard let rect = mapping.remoteRect(x0: x0, y0: y0, x1: x1, y1: y1),
                  let image = await Self.encode(framebuffer, region: rect) else {
                let text = "Error: region [\(x0), \(y0), \(x1), \(y1)] is not inside the \(mapping.imageWidth)x\(mapping.imageHeight) screenshot."
                setStatus(.failed(text), for: id)
                return ActionOutcome(id: id, text: text, isError: true)
            }
            return ActionOutcome(id: id, image: image)
        case .cursorPosition:
            guard let pointer else {
                let text = "Error: the cursor position is not known yet."
                setStatus(.failed(text), for: id)
                return ActionOutcome(id: id, text: text, isError: true)
            }
            let point = currentMapping().imagePoint(pointer)
            return ActionOutcome(id: id, text: "X=\(point.x), Y=\(point.y)")
        case .wait(let seconds):
            do {
                try await sleep(.milliseconds(Int(seconds * 1000)))
            } catch {
                return ActionOutcome(id: id, text: ToolResultText.stopped, isError: true)
            }
            return ActionOutcome(id: id, text: ToolResultText.ok)
        default:
            return ActionOutcome(id: id, text: ToolResultText.ok)
        }
    }

    // MARK: Screenshots and coordinates

    /// The framebuffer as an image within the limits; sets the mapping Claude's coordinates use.
    private func screenshot() async -> EncodedImage? {
        guard let framebuffer = await port?.assistantSnapshot() else { return nil }
        guard let image = await Self.encode(framebuffer, region: nil) else { return nil }
        mapping = ScreenMapping(remoteWidth: framebuffer.width, remoteHeight: framebuffer.height,
                                imageWidth: image.width, imageHeight: image.height)
        return image
    }

    /// PNG/JPEG encoding off the main actor (a 1280 × 800 PNG takes tens of milliseconds).
    nonisolated private static func encode(_ framebuffer: Framebuffer, region: RFBRect?) async -> EncodedImage? {
        await Task.detached(priority: .userInitiated) {
            try? ScreenshotEncoder.encode(framebuffer, region: region)
        }.value
    }

    /// The last screenshot's pixel space, mapped onto the framebuffer size it had.
    private func currentMapping() -> ScreenMapping {
        mapping ?? ScreenMapping(remoteWidth: 1, remoteHeight: 1, imageWidth: 1, imageHeight: 1)
    }

    /// The last screenshot's pixel space onto `framebuffer` (its size may have changed since).
    private func currentMapping(for framebuffer: Framebuffer) -> ScreenMapping {
        guard let mapping else { return ScreenMapping(remoteWidth: framebuffer.width, remoteHeight: framebuffer.height) }
        return ScreenMapping(remoteWidth: framebuffer.width, remoteHeight: framebuffer.height,
                             imageWidth: mapping.imageWidth, imageHeight: mapping.imageHeight)
    }

    private func remotePoint(_ point: ScreenPoint) -> PointerLocation? {
        mapping?.remotePoint(x: point.x, y: point.y)
    }

    // MARK: Transcript

    private func append(_ content: Content) {
        entries.append(Entry(id: nextEntryID, content: content))
        nextEntryID += 1
    }

    private func setStatus(_ status: ActionItem.Status, for id: String) {
        guard let index = entries.lastIndex(where: {
            if case .action(let item) = $0.content { return item.toolUseID == id }
            return false
        }), case .action(var item) = entries[index].content else { return }
        item.status = status
        entries[index].content = .action(item)
    }

    private func status(of id: String) -> ActionItem.Status? {
        for entry in entries.reversed() {
            if case .action(let item) = entry.content, item.toolUseID == id { return item.status }
        }
        return nil
    }

    private func setTargets(_ targets: [PointerLocation], for id: String) {
        guard let index = entries.lastIndex(where: {
            if case .action(let item) = $0.content { return item.toolUseID == id }
            return false
        }), case .action(var item) = entries[index].content else { return }
        item.targets = targets
        entries[index].content = .action(item)
    }

    private func targets(of id: String) -> [PointerLocation] {
        for entry in entries.reversed() {
            if case .action(let item) = entry.content, item.toolUseID == id { return item.targets }
        }
        return []
    }

    /// AssistantAction.payload: the member's input as Claude sent it (screenshot pixels), plus the
    /// remote pixels it maps to.
    /// Typed text is never stored (it may be a password): only its length.
    private func payload(_ action: ComputerAction, input: JSONValue) -> String {
        var object: [String: JSONValue] = ["input": input]
        if case .type(let text) = action { object["input"] = ["length": .int(text.count)] }
        let remote = action.points.compactMap { remotePoint($0) }
        if !remote.isEmpty { object["remote"] = .array(remote.map { [.int(Int($0.x)), .int(Int($0.y))] }) }
        return String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)
    }
}

extension ComputerAction {
    /// Clicks and scrolls without a coordinate act where the pointer is.
    var usesPointer: Bool {
        switch self {
        case .click(_, _, nil, _), .scroll(_, _, nil, _): true
        default: false
        }
    }

    /// AssistantAction.kind.
    var recordKind: AssistantActionKind {
        switch self {
        case .screenshot: .screenshot
        case .zoom: .zoom
        case .click(.left, let count, _, _): count >= 3 ? .tripleClick : count == 2 ? .doubleClick : .click
        case .click(.right, _, _, _): .rightClick
        case .click(.middle, _, _, _): .middleClick
        case .drag: .drag
        case .mouseMove: .mouseMove
        case .cursorPosition: .cursorPosition
        case .scroll: .scroll
        case .type: .type
        case .key: .key
        case .holdKey: .holdKey
        case .wait: .wait
        }
    }
}
