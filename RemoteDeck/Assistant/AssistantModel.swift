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
}

/// The Claude Assistant of one session (AppFlow › Claude Assistant Panel, PRD acceptance criterion 8):
/// on demand only, every action that reaches the remote confirmed first.
///
/// Ask → (screenshot of the framebuffer + prompt) → Messages API → for each member `tool_use`, in
/// order: read-only ones (screenshot, zoom, cursor_position, wait) run at once; any other is shown as
/// a proposal and runs only on Confirm. Skip answers it with an error result and the rest of that
/// turn with the documented "Not executed" text, then Claude answers. Stop cancels the request and
/// the loop; results owed by then go out at the start of the next Ask (`Conversation.pendingResults`).
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
    static let defaultArmDelay: Duration = .milliseconds(400)
    /// Consecutive API turns without a confirmed action (screenshots, zooms, waits, cursor positions,
    /// skips, errors) before the loop pauses (T5.3 M3): a task cannot run up tokens unattended.
    static let maxStepsWithoutAction = 8
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
    private(set) var awaitingID: String?
    /// Confirm is accepted (`defaultArmDelay` after the proposal appeared, or after its text was
    /// opened when it had to be).
    private(set) var confirmArmed = false
    /// The awaiting proposal is a `type` whose text must be opened first (`typeTextNeedsReveal`).
    private(set) var awaitingNeedsReveal = false
    /// The awaiting proposal's full text was opened.
    private(set) var awaitingRevealed = false
    /// API turns in a row that confirmed no action (`maxStepsWithoutAction`).
    private(set) var stepsWithoutAction = 0

    @ObservationIgnored weak var port: (any AssistantSessionPort)?
    @ObservationIgnored private let client: MessagesClient
    @ObservationIgnored private let apiKey: @MainActor () -> String
    @ObservationIgnored private let model: String
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Decision, Never>?
    /// What a running plan still has to release if it is interrupted.
    @ObservationIgnored private var pendingRelease: [ClientMessage]?
    /// The last screenshot sent: Claude's coordinates are in its pixel space.
    @ObservationIgnored private(set) var mapping: ScreenMapping?
    /// Where the assistant left the pointer (remote pixels).
    @ObservationIgnored private var pointer: PointerLocation?
    @ObservationIgnored private var nextEntryID = 0
    @ObservationIgnored private let armDelay: Duration
    /// The loop task's generation: a late end of a stopped task changes nothing.
    @ObservationIgnored private var generation = 0
    /// Where a `stopping` phase ends.
    @ObservationIgnored private var finalPhase: Phase?
    /// The user confirmed an action in the turn being run.
    @ObservationIgnored private var turnConfirmedAnAction = false

    init(port: (any AssistantSessionPort)?, client: MessagesClient, apiKey: @escaping @MainActor () -> String,
         model: String = ClaudeAPI.defaultModel, armDelay: Duration = AssistantModel.defaultArmDelay,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.client = client
        self.apiKey = apiKey
        self.model = model
        self.armDelay = armDelay
        self.sleep = sleep
    }

    var hasAPIKey: Bool { !apiKey().isEmpty }

    var sessionConnected: Bool { port?.assistantCanAct == true }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canAsk: Bool {
        !phase.isBusy && hasAPIKey && !trimmedPrompt.isEmpty && trimmedPrompt.count <= Self.maxPromptLength
            && port?.assistantCanAct == true
    }

    /// The request body that would be sent now (tests).
    var currentRequestBody: Data? { conversation?.requestBody() }

    // MARK: Ask, Retry, Stop

    func ask() {
        let text = trimmedPrompt
        guard canAsk else { return }
        prompt = ""
        stepsWithoutAction = 0   // the user is here: a new count
        append(.prompt(text))
        if conversation == nil, let port {
            conversation = Conversation(configuration: RequestConfiguration(model: model, desktop: port.assistantDesktop))
        }
        start { [weak self] in
            guard let self else { return }
            var content: [JSONValue] = []
            if let image = await self.screenshot() { content.append(ContentBlock.image(image)) }
            content.append(ContentBlock.text(text))
            self.conversation?.appendUser(content)
            await self.loop()
        }
    }

    /// After an error: sends the same request again (the history did not change).
    func retry() {
        guard case .failed(let failure) = phase, failure != .disconnected, conversation?.endsWithUser == true,
              hasAPIKey else { return }
        start { [weak self] in await self?.loop() }
    }

    /// Continue after a pause: a new count, then the turn's results go out with the next request.
    func continueAfterPause() {
        guard phase == .paused, conversation != nil, hasAPIKey else { return }
        stepsWithoutAction = 0
        start { [weak self] in
            self?.conversation?.appendUser([])   // the deferred results, alone
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
        conversation = nil
        entries = []
        mapping = nil
        phase = .idle
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
        arm(id)
    }

    private func arm(_ id: String) {
        Task { [weak self, armDelay] in
            try? await Task.sleep(for: armDelay)
            if let self, self.awaitingID == id { self.confirmArmed = true }
        }
    }

    private func resolve(_ value: Decision) {
        awaitingID = nil
        confirmArmed = false
        awaitingNeedsReveal = false
        awaitingRevealed = false
        guard let decision else { return }
        self.decision = nil
        decision.resume(returning: value)
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
    private func owe(_ response: MessagesResponse, _ text: String) {
        let ids = response.toolUses.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { setStatus(.notExecuted, for: id) }
        conversation?.deferResults(ids.map { ContentBlock.toolResult(id: $0, text: text, isError: true) })
    }

    // MARK: Loop

    private func loop() async {
        while !Task.isCancelled, let conversation {
            setPhase(.sending)
            let key = apiKey()
            guard !key.isEmpty else {
                setPhase(.failed(.noAPIKey))
                return
            }
            let response: MessagesResponse
            do {
                response = try await client.send(body: conversation.requestBody(), apiKey: key)
            } catch {
                if error != .cancelled, !Task.isCancelled { setPhase(.failed(.api(error))) }
                return
            }
            // Billed whatever happens next.
            usage += response.usage
            port?.assistantAddTokens(response.usage.total)
            port?.assistantSave()
            // Every path appends the turn unchanged; any call in it that will not run is answered.
            self.conversation?.appendAssistant(response)
            guard !Task.isCancelled else {
                owe(response, ToolResultText.stopped)
                return
            }

            switch response.stopReason {
            case .toolUse:
                show(response, actions: true)
                turnConfirmedAnAction = false
                let results = await run(response.toolUses)
                if Task.isCancelled {
                    self.conversation?.deferResults(results)
                    return
                }
                stepsWithoutAction = turnConfirmedAnAction ? 0 : stepsWithoutAction + 1
                if stepsWithoutAction >= Self.maxStepsWithoutAction {
                    // Not sent yet: Continue sends them alone, a Stop leaves them for the next Ask.
                    self.conversation?.deferResults(results)
                    setPhase(.paused)
                    return
                }
                self.conversation?.appendUser(results)
            case .refusal:
                show(response, actions: true)
                owe(response, ToolResultText.notExecuted)
                setPhase(.refused(category: response.refusal?.category, explanation: response.refusal?.explanation))
                return
            case .maxTokens, .contextWindowExceeded, .pauseTurn:
                // `pause_turn` comes from server tools (none here). Its documented continuation would end
                // the request with an assistant message, a prefill Opus 5.5 rejects: treated as cut off.
                show(response, actions: true)
                owe(response, ToolResultText.cutOff)
                setPhase(.cutOff)
                return
            case .endTurn, .stopSequence, .other:
                show(response, actions: true)
                owe(response, ToolResultText.notExecuted)
                setPhase(.done)
                return
            }
        }
    }

    /// Adds the response's text, progress updates and proposed actions to the transcript.
    private func show(_ response: MessagesResponse, actions: Bool) {
        for block in response.blocks {
            switch block {
            case .text(let text) where !text.isEmpty:
                append(.answer(text))
            case .thinking(let text) where !text.isEmpty:
                append(.progress(text))
            case .toolUse(let id, let name, _, let input) where actions:
                let action = try? ComputerAction(name: name, input: input)
                let targets = (action?.points ?? []).compactMap { remotePoint($0) }
                append(.action(ActionItem(toolUseID: id, name: name, action: action, targets: targets, status: .queued)))
            default:
                break
            }
        }
    }

    /// Runs the turn's member calls in order and returns one result per call. After a skip or a
    /// failure the rest are not run (computer use docs, "Batch actions"). On Stop, the calls not run
    /// yet get the "stopped" result.
    private func run(_ uses: [(id: String, name: String, toolsetName: String?, input: JSONValue)]) async -> [JSONValue] {
        var results: [JSONValue] = []
        var halted = false
        for use in uses {
            if Task.isCancelled {
                results.append(ContentBlock.toolResult(id: use.id, text: ToolResultText.stopped, isError: true))
                setStatus(.cancelled, for: use.id)
                continue
            }
            if halted {
                results.append(ContentBlock.toolResult(id: use.id, text: ToolResultText.notExecuted, isError: true))
                setStatus(.notExecuted, for: use.id)
                continue
            }
            let outcome = await runOne(use)
            results.append(outcome.result)
            halted = outcome.halts
        }
        return results
    }

    private func runOne(_ use: (id: String, name: String, toolsetName: String?, input: JSONValue)) async
        -> (result: JSONValue, halts: Bool) {
        func failure(_ text: String) -> (JSONValue, Bool) {
            setStatus(.failed(text), for: use.id)
            return (ContentBlock.toolResult(id: use.id, text: text, isError: true), true)
        }
        guard use.toolsetName == ClaudeAPI.toolsetName else {
            return failure("Error: \(use.name) is not available in this environment.")
        }
        let action: ComputerAction
        do {
            action = try ComputerAction(name: use.name, input: use.input)
        } catch {
            return failure(error.resultText)
        }
        guard let port, port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (ContentBlock.toolResult(id: use.id, text: ToolResultText.disconnected, isError: true), true)
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
        let decision: Decision = await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: .stop)
                return
            }
            self.decision = continuation
            self.awaitingID = use.id
            self.confirmArmed = false
            self.awaitingRevealed = false
            if case .type(let text) = action, Self.typeTextNeedsReveal(text) {
                self.awaitingNeedsReveal = true   // armed by `reveal`
            } else {
                self.awaitingNeedsReveal = false
                self.arm(use.id)
            }
        }
        highlight = []
        switch decision {
        case .stop:
            row?.decisionValue = .cancelled
            port.assistantSave()
            setStatus(.cancelled, for: use.id)
            let text = finalPhase == .failed(.disconnected) ? ToolResultText.disconnected : ToolResultText.stopped
            return (ContentBlock.toolResult(id: use.id, text: text, isError: true), true)
        case .skip:
            row?.decisionValue = .rejected
            port.assistantSave()
            setStatus(.skipped, for: use.id)
            setPhase(.sending)
            return (ContentBlock.toolResult(id: use.id, text: ToolResultText.skipped, isError: true), true)
        case .confirm:
            row?.decisionValue = .confirmed
            port.assistantSave()
            turnConfirmedAnAction = true
        }
        guard port.assistantCanAct else {
            setStatus(.cancelled, for: use.id)
            return (ContentBlock.toolResult(id: use.id, text: ToolResultText.disconnected, isError: true), true)
        }
        setPhase(.running)
        setStatus(.running, for: use.id)
        let completed = await execute(plan)
        guard completed else {
            setStatus(.cancelled, for: use.id)
            return (ContentBlock.toolResult(id: use.id, text: ToolResultText.stopped, isError: true), true)
        }
        pointer = plan.pointer ?? pointer
        setStatus(.done, for: use.id)
        setPhase(.sending)
        return (ContentBlock.toolResult(id: use.id, text: ToolResultText.ok), false)
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

    private func runReadOnly(_ action: ComputerAction, id: String) async -> JSONValue {
        switch action {
        case .screenshot:
            await port?.assistantSettle()
            guard let image = await screenshot() else {
                setStatus(.failed(ToolResultText.noFramebuffer), for: id)
                return ContentBlock.toolResult(id: id, text: ToolResultText.noFramebuffer, isError: true)
            }
            return ContentBlock.toolResult(id: id, content: [ContentBlock.image(image)])
        case .zoom(let x0, let y0, let x1, let y1):
            await port?.assistantSettle()
            guard let framebuffer = await port?.assistantSnapshot() else {
                setStatus(.failed(ToolResultText.noFramebuffer), for: id)
                return ContentBlock.toolResult(id: id, text: ToolResultText.noFramebuffer, isError: true)
            }
            let mapping = currentMapping(for: framebuffer)
            guard let rect = mapping.remoteRect(x0: x0, y0: y0, x1: x1, y1: y1),
                  let image = await Self.encode(framebuffer, region: rect) else {
                let text = "Error: region [\(x0), \(y0), \(x1), \(y1)] is not inside the \(mapping.imageWidth)x\(mapping.imageHeight) screenshot."
                setStatus(.failed(text), for: id)
                return ContentBlock.toolResult(id: id, text: text, isError: true)
            }
            return ContentBlock.toolResult(id: id, content: [ContentBlock.image(image)])
        case .cursorPosition:
            guard let pointer else {
                let text = "Error: the cursor position is not known yet."
                setStatus(.failed(text), for: id)
                return ContentBlock.toolResult(id: id, text: text, isError: true)
            }
            let point = currentMapping().imagePoint(pointer)
            return ContentBlock.toolResult(id: id, text: "X=\(point.x), Y=\(point.y)")
        case .wait(let seconds):
            do {
                try await sleep(.milliseconds(Int(seconds * 1000)))
            } catch {
                return ContentBlock.toolResult(id: id, text: ToolResultText.stopped, isError: true)
            }
            return ContentBlock.toolResult(id: id, text: ToolResultText.ok)
        default:
            return ContentBlock.toolResult(id: id, text: ToolResultText.ok)
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
