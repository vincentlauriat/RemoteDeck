import ClaudeKit
import Foundation

/// One step the Apple model proposes (the plain mirror of the `@Generable` type in
/// `AppleFoundationModels.swift`, so this file, the mapper and their tests need no FoundationModels).
/// There is no coordinate field: a pointer action can only name a visible text label.
struct AppleStep: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Text only; ends the task.
        case answer
        case click, doubleClick, rightClick
        case typeText, pressKey
        case scroll
        case wait
        case done
    }

    var kind: Kind
    /// The visible text to click, or to scroll at ("" = the screen centre).
    var label: String = ""
    /// The answer, the text to type, or the key chord (`KeyChord` syntax: `return`, `cmd+c`).
    var text: String = ""
    /// up, down, left or right (scroll).
    var direction: String = ""
    /// One short sentence: why this step (shown as a progress note).
    var reason: String = ""

    var needsLabel: Bool {
        switch kind {
        case .click, .doubleClick, .rightClick: true
        case .scroll: !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }
}

/// What the engine asks the model for one step: a fresh session each time (8,192-token context), so
/// the task, the last steps in one line each, and the latest screenshot.
struct AppleStepRequest: Sendable {
    var task: String
    var summary: [String]
    var image: EncodedImage
}

enum AppleGenerationError: Error, Equatable {
    /// The context (8,192 tokens on device) was exceeded: the panel's "cut off".
    case contextExceeded
    /// A guardrail violation or a refusal (the error's description).
    case refused(String?)
    case cancelled
    case failed(String)
}

/// The model behind the Apple engine (`FoundationModelsStepGenerator` on macOS 27, scripted in tests
/// and the demo).
protocol AppleStepGenerating: Sendable {
    func generate(_ request: AppleStepRequest) async throws(AppleGenerationError) -> AppleStep
}

/// An `AppleStep` as the panel's turn: an answer, the end, or one action (pure).
enum AppleStepMapper {
    enum Mapped: Equatable {
        case answer(String)
        case done(String)
        case action(TurnAction)
    }

    /// `scroll` steps: notches per proposal (the model gives no amount).
    static let scrollAmount = 5
    /// `wait` steps: seconds (the model gives no duration).
    static let waitSeconds = 2

    /// `texts`: the OCR of the screenshot of `width × height` pixels the model saw. A label not found,
    /// or ambiguous, becomes an action that did not parse (answered with the error, never run).
    static func map(_ step: AppleStep, id: String, texts: [LocatedText], width: Int, height: Int) -> Mapped {
        let label = step.label.trimmingCharacters(in: .whitespacesAndNewlines)
        func action(_ name: String, _ input: [String: JSONValue], label: String? = nil, error: String? = nil) -> Mapped {
            var recorded = input
            if let label { recorded["label"] = .string(label) }
            let value = JSONValue.object(input)
            var parsed: ComputerAction?
            var parseError = error
            if parseError == nil {
                do throws(ComputerAction.ParseError) {
                    parsed = try ComputerAction(name: name, input: value)
                } catch {
                    parseError = error.resultText
                }
            }
            return .action(TurnAction(id: id, name: name, action: parsed, parseError: parseError,
                                      input: .object(recorded), label: label))
        }
        func point(_ name: String, extra: [String: JSONValue] = [:]) -> Mapped {
            switch LabelMatcher.match(label, in: texts) {
            case .found(let at, _):
                var input = extra
                input["coordinate"] = [.int(at.x), .int(at.y)]
                return action(name, input, label: label)
            case .notFound:
                return action(name, extra, label: label,
                              error: "Error: the label \"\(label)\" was not found on the screen.")
            case .ambiguous(let count):
                return action(name, extra, label: label,
                              error: "Error: the label \"\(label)\" appears \(count) times on the screen; name a more specific label.")
            }
        }
        let text = step.text
        switch step.kind {
        case .answer:
            return .answer(text)
        case .done:
            return .done(text)
        case .click:
            return point("left_click")
        case .doubleClick:
            return point("double_click")
        case .rightClick:
            return point("right_click")
        case .typeText:
            return action("type", ["text": .string(text)],
                          error: text.isEmpty ? ComputerAction.ParseError.invalidInput("text is required").resultText : nil)
        case .pressKey:
            let chord = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return action("key", ["text": .string(chord)],
                          error: chord.isEmpty ? ComputerAction.ParseError.invalidInput("text is required").resultText : nil)
        case .scroll:
            let scroll: [String: JSONValue] = ["scroll_direction": .string(step.direction.lowercased()),
                                               "scroll_amount": .int(scrollAmount)]
            if step.needsLabel { return point("scroll", extra: scroll) }
            var input = scroll
            input["coordinate"] = [.int(max(0, width / 2)), .int(max(0, height / 2))]
            return action("scroll", input)
        case .wait:
            return action("wait", ["duration": .int(waitSeconds)])
        }
    }

    /// The step's line in the summary of previous steps.
    static func summaryLine(_ step: AppleStep) -> String {
        let label = step.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch step.kind {
        case .click, .doubleClick, .rightClick: return "\(step.kind.rawValue) \"\(label)\""
        case .typeText: return "typeText (\(step.text.count) characters)"
        case .pressKey: return "pressKey \(step.text)"
        case .scroll: return "scroll \(step.direction)" + (label.isEmpty ? "" : " at \"\(label)\"")
        case .wait: return "wait"
        case .answer, .done: return step.kind.rawValue
        }
    }
}

/// The Apple provider (TRD › Claude Assistant › Providers): one generated `AppleStep` per turn, from
/// a fresh model session (instructions, task, the last `summaryLength` steps, the latest screenshot),
/// so zero or one action per turn, ids `apple-<n>`. Labels are resolved by OCR on the screenshot the
/// model saw; no coordinate ever comes from the model. Outcomes only feed the step summary. Reports
/// no tokens.
@MainActor
final class AppleEngine: AssistantEngine {
    static let summaryLength = 6

    let provider: AssistantProvider
    private let generator: any AppleStepGenerating
    private let locator: any TextLocator
    /// `nil` when the model is available.
    private let unavailability: @MainActor () -> AppleModelUnavailability?
    /// Reads the availability again before a step (not from a view's body: it may change state).
    private let refreshAvailability: (@MainActor () -> Void)?
    private var task: String?
    private var pendingScreenshot: EncodedImage?
    private(set) var summary: [String] = []
    private var stepCount = 0
    /// The last proposed action, waiting for its outcome (`deliver`).
    private var lastAction: (id: String, line: String)?

    init(provider: AssistantProvider = .appleOnDevice, generator: any AppleStepGenerating, locator: any TextLocator,
         unavailability: @escaping @MainActor () -> AppleModelUnavailability?,
         refreshAvailability: (@MainActor () -> Void)? = nil) {
        self.provider = provider
        self.generator = generator
        self.locator = locator
        self.unavailability = unavailability
        self.refreshAvailability = refreshAvailability
    }

    var isReady: Bool { unavailability() == nil }
    var notReadyReason: AssistantFailure? { unavailability().map { .appleUnavailable($0) } }
    var hasConversation: Bool { task != nil }
    var canResend: Bool { task != nil }

    func begin(prompt: String, screenshot: EncodedImage?, desktop: RemoteDesktopKind) {
        task = prompt
        pendingScreenshot = screenshot
    }

    func nextTurn(screenshot: @MainActor () async -> EncodedImage?) async throws(AssistantEngineError) -> AssistantTurn {
        guard let task else { throw .failed(.disconnected) }
        refreshAvailability?()
        if let reason = unavailability() { throw .notReady(.appleUnavailable(reason)) }
        let taken = pendingScreenshot
        pendingScreenshot = nil
        let image: EncodedImage? = if let taken { taken } else { await screenshot() }
        guard !Task.isCancelled else { throw .cancelled }
        guard let image else { throw .failed(.appleGeneration(ToolResultText.noFramebuffer)) }

        let step: AppleStep
        do {
            step = try await generator.generate(AppleStepRequest(task: task, summary: summary, image: image))
        } catch {
            switch error {
            case .contextExceeded:
                return AssistantTurn(blocks: [], stop: .cutOff, usage: nil)
            case .refused(let explanation):
                return AssistantTurn(blocks: [], stop: .refused(category: nil, explanation: explanation), usage: nil)
            case .cancelled:
                throw .cancelled
            case .failed(let message):
                if Task.isCancelled { throw .cancelled }
                throw .failed(.appleGeneration(message))
            }
        }
        let texts = step.needsLabel ? await locator.locate(in: image) : []
        stepCount += 1
        let id = "apple-\(stepCount)"
        var blocks: [TurnBlock] = []
        let reason = step.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { blocks.append(.progress(reason)) }
        switch AppleStepMapper.map(step, id: id, texts: texts, width: image.width, height: image.height) {
        case .answer(let text):
            if !text.isEmpty { blocks.append(.answer(text)) }
            record("answer")
            return AssistantTurn(blocks: blocks, stop: .done, usage: nil)
        case .done(let text):
            if !text.isEmpty { blocks.append(.answer(text)) }
            record("done")
            return AssistantTurn(blocks: blocks, stop: .done, usage: nil)
        case .action(let action):
            blocks.append(.action(action))
            lastAction = (id, AppleStepMapper.summaryLine(step))
            return AssistantTurn(blocks: blocks, stop: .actions, usage: nil)
        }
    }

    func deliver(_ outcomes: [ActionOutcome]) {
        absorb(outcomes)
    }

    func deferOutcomes(_ outcomes: [ActionOutcome]) {
        absorb(outcomes)
    }

    func reset() {
        task = nil
        pendingScreenshot = nil
        summary = []
        lastAction = nil
    }

    /// "click \"Finder\" → OK" lines; an error outcome keeps its text so the model can try another way.
    private func absorb(_ outcomes: [ActionOutcome]) {
        for outcome in outcomes {
            guard let last = lastAction, last.id == outcome.id else { continue }
            lastAction = nil
            record("\(last.line) → \(outcome.isError ? (outcome.text ?? "error") : "OK")")
        }
    }

    private func record(_ line: String) {
        summary.append(line)
        if summary.count > Self.summaryLength { summary.removeFirst(summary.count - Self.summaryLength) }
    }
}
