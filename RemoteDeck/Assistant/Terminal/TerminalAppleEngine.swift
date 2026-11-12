import Foundation

/// One step the Apple model proposes for a terminal (the `@Generable` type maps to it).
struct TerminalAppleStep: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case answer, runCommand, sendKeys, wait, done
    }

    var kind: Kind
    var text: String?
    var command: String?
    var keys: [TerminalNamedKey] = []
    var seconds: Int?
    var reason: String?
}

/// What one step sees: the task, the last steps, the viewport only (the on-device context is 8,192
/// tokens: no scrollback).
struct TerminalAppleStepRequest: Sendable, Equatable {
    var task: String
    var summary: [String]
    var screen: String
}

protocol TerminalAppleStepGenerating: Sendable {
    func next(_ request: TerminalAppleStepRequest) async throws(AppleGenerationError) -> TerminalAppleStep
}

/// The Apple on-device provider of the terminal assistant (macOS 26+, text only): one generated step
/// per turn from a fresh session, at most one action, mapped to the same `TerminalAction`s as Claude's
/// tools, so every confirmation rule is `TerminalAssistantModel`'s. No tokens are reported.
@MainActor
final class TerminalAppleEngine: TerminalAssistantEngine {
    static let summaryLength = 6
    static let defaultWaitSeconds = 5

    let provider: AssistantProvider
    private let generator: any TerminalAppleStepGenerating
    private let checker: any AppleModelChecking
    private var task: String?
    private var snapshot: TerminalSnapshot?
    private(set) var summary: [String] = []
    private var stepCount = 0
    private var lastAction: (id: String, line: String)?

    init(provider: AssistantProvider = .appleOnDevice, generator: any TerminalAppleStepGenerating,
         checker: any AppleModelChecking) {
        self.provider = provider
        self.generator = generator
        self.checker = checker
    }

    private var unavailability: AppleModelUnavailability? { checker.unavailability(for: .terminals) }
    var isReady: Bool { unavailability == nil }
    var notReadyReason: AssistantFailure? { unavailability.map { .appleUnavailable($0) } }
    var hasConversation: Bool { task != nil }
    var canResend: Bool { task != nil }

    func begin(prompt: String, snapshot: TerminalSnapshot?) {
        task = prompt
        if let snapshot { self.snapshot = snapshot }
    }

    func nextTurn() async throws(AssistantEngineError) -> TerminalTurn {
        guard let task else { throw .failed(.disconnected) }
        if let reason = unavailability { throw .notReady(.appleUnavailable(reason)) }
        let screen = snapshot?.rendered(includeScrollback: false) ?? "<terminal>\n(no terminal output yet)\n</terminal>"
        let step: TerminalAppleStep
        do {
            step = try await generator.next(TerminalAppleStepRequest(task: task, summary: summary, screen: screen))
        } catch {
            switch error {
            case .contextExceeded: return TerminalTurn(blocks: [], stop: .cutOff, usage: nil)
            case .refused(let explanation):
                return TerminalTurn(blocks: [], stop: .refused(category: nil, explanation: explanation), usage: nil)
            case .cancelled: throw .cancelled
            case .failed(let message):
                if Task.isCancelled { throw .cancelled }
                throw .failed(.appleGeneration(message))
            }
        }
        stepCount += 1
        let id = "apple-\(stepCount)"
        var blocks: [TerminalTurnBlock] = []
        let reason = step.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reason.isEmpty { blocks.append(.progress(reason)) }
        let text = step.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func action(_ action: TerminalAction?, error: String? = nil, line: String) -> TerminalTurn {
            blocks.append(.action(TerminalTurnAction(id: id, action: action, parseError: error,
                                                     reason: reason.isEmpty ? nil : reason)))
            lastAction = (id, line)
            return TerminalTurn(blocks: blocks, stop: .actions, usage: nil)
        }
        switch step.kind {
        case .answer, .done:
            if !text.isEmpty { blocks.append(.answer(text)) }
            record(step.kind.rawValue)
            return TerminalTurn(blocks: blocks, stop: .done, usage: nil)
        case .runCommand:
            let command = step.command ?? ""
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                return action(nil, error: "Error: runCommand needs a command.", line: "run_command (empty)")
            }
            return action(.runCommand(command), line: "run_command \"\(command)\"")
        case .sendKeys:
            guard !step.keys.isEmpty else {
                return action(nil, error: "Error: sendKeys needs at least one key.", line: "send_keys (none)")
            }
            return action(.sendKeys(step.keys), line: "send_keys " + step.keys.map(\.rawValue).joined(separator: " "))
        case .wait:
            let seconds = max(1, min(step.seconds ?? Self.defaultWaitSeconds, OutputSettler.maxWaitSeconds))
            return action(.waitForOutput(seconds: seconds), line: "wait \(seconds) s")
        }
    }

    func deliver(_ outcomes: [TerminalActionOutcome]) {
        absorb(outcomes)
    }

    func deferOutcomes(_ outcomes: [TerminalActionOutcome]) {
        absorb(outcomes)
    }

    func reset() {
        task = nil
        snapshot = nil
        summary = []
        lastAction = nil
    }

    /// `run_command "df -h" → OK` lines, and the newest snapshot for the next step.
    private func absorb(_ outcomes: [TerminalActionOutcome]) {
        for outcome in outcomes {
            if let shot = outcome.snapshot { snapshot = shot }
            guard let last = lastAction, last.id == outcome.id else { continue }
            lastAction = nil
            record("\(last.line) → \(outcome.text)")
        }
    }

    private func record(_ line: String) {
        summary.append(line)
        if summary.count > Self.summaryLength { summary.removeFirst(summary.count - Self.summaryLength) }
    }
}
