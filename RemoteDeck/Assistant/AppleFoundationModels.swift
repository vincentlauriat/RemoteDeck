import ClaudeKit
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

// The only file that uses FoundationModels (weak-linked: the app still launches on macOS 15–26).
// Every symbol is behind `@available(macOS 27, *)`: the vision attachment and the generic
// `LanguageModelSession(model:)` are macOS 27 API. Never built under XCTest or `-LibraryDemo`
// (`AppleAssistant.makeEngine`).

/// The real availability of the on-device model.
/// Terminals (text only) are checked in `TerminalAppleFoundationModels.swift` (macOS 26).
struct SystemAppleModelChecker: AppleModelChecking {
    func unavailability(for use: AppleModelUse) -> AppleModelUnavailability? {
        if use == .terminals { return SystemTerminalModelCheck.unavailability() }
        guard #available(macOS 27, *) else { return .requiresNewerOS(major: AppleModelUse.screens.minimumMacOS) }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            // Every step sends a screenshot.
            return model.capabilities.contains(.vision) ? nil : .deviceNotEligible
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }
}

@available(macOS 27, *)
@Generable(description: "The one next step on the remote computer's screen.")
struct GeneratedAppleStep {
    @Guide(description: "answer: reply to the user in text and end the task. click, doubleClick, rightClick: on a visible text label. typeText: type text. pressKey: press a key chord. scroll: scroll the screen. wait: let the screen settle. done: the task is complete.")
    var kind: GeneratedAppleStepKind
    @Guide(description: "For click, doubleClick, rightClick and scroll: a text visible in the screenshot, copied exactly as shown. Empty otherwise.")
    var label: String
    @Guide(description: "For answer: the reply. For typeText: the exact text to type. For pressKey: keys such as return, tab, escape, cmd+c. Empty otherwise.")
    var text: String
    @Guide(description: "For scroll: up, down, left or right. Empty otherwise.")
    var direction: String
    @Guide(description: "One short sentence: why this step.")
    var reason: String
}

@available(macOS 27, *)
@Generable
enum GeneratedAppleStepKind {
    case answer, click, doubleClick, rightClick, typeText, pressKey, scroll, wait, done
}

@available(macOS 27, *)
extension AppleStep {
    init(_ generated: GeneratedAppleStep) {
        let kind: Kind = switch generated.kind {
        case .answer: .answer
        case .click: .click
        case .doubleClick: .doubleClick
        case .rightClick: .rightClick
        case .typeText: .typeText
        case .pressKey: .pressKey
        case .scroll: .scroll
        case .wait: .wait
        case .done: .done
        }
        self.init(kind: kind, label: generated.label, text: generated.text, direction: generated.direction,
                  reason: generated.reason)
    }
}

/// One step from a Foundation Model: a fresh `LanguageModelSession` per step (no accumulating
/// transcript: the on-device context is 8,192 tokens). Generic over the model, so Private Cloud
/// Compute is a different `Model` (and its entitlement), not a different engine.
@available(macOS 27, *)
struct FoundationModelsStepGenerator<Model: LanguageModel>: AppleStepGenerating {
    let model: Model

    static var instructions: String {
        """
        You operate a remote computer for the user, one step at a time. You see the current screen. \
        Propose exactly one step. To click or scroll at something, name a text label that is visible \
        on the screen, copied exactly; never invent one. When the task is done or cannot be done, \
        use answer and say so in the user's language.
        """
    }

    static func prompt(_ request: AppleStepRequest) -> String {
        var lines = ["Task: \(request.task)"]
        if !request.summary.isEmpty {
            lines.append("Previous steps:")
            lines += request.summary.map { "- \($0)" }
        }
        lines.append("Next step?")
        return lines.joined(separator: "\n")
    }

    func generate(_ request: AppleStepRequest) async throws(AppleGenerationError) -> AppleStep {
        guard let source = CGImageSourceCreateWithData(request.image.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw .failed(ToolResultText.noFramebuffer)
        }
        let session = LanguageModelSession(model: model, tools: [], instructions: Self.instructions)
        let text = Self.prompt(request)
        do {
            let response = try await session.respond(to: Prompt {
                Attachment(image)
                text
            }, generating: GeneratedAppleStep.self)
            return AppleStep(response.content)
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded: throw .contextExceeded
            case .guardrailViolation, .refusal: throw .refused(error.localizedDescription)
            default: throw .failed(error.localizedDescription)
            }
        } catch let error as LanguageModelSession.GenerationError {
            // The pre-27 error type, deprecated in macOS 27 (the deprecation warnings stay in this file):
            // a model may still throw it.
            switch error {
            case .exceededContextWindowSize: throw .contextExceeded
            case .guardrailViolation, .refusal: throw .refused(error.localizedDescription)
            default: throw .failed(error.localizedDescription)
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            if Task.isCancelled { throw .cancelled }
            throw .failed(error.localizedDescription)
        }
    }
}

/// What a Mac without macOS 27 answers (never asked: the engine is not ready there).
struct UnsupportedStepGenerator: AppleStepGenerating {
    func generate(_ request: AppleStepRequest) async throws(AppleGenerationError) -> AppleStep {
        throw .failed("FoundationModels requires macOS 27.")
    }
}

/// Builds the Apple provider of a session.
enum AppleAssistant {
    /// The on-device model with Vision OCR. Only in a normal launch: the hosted tests and the demo
    /// pass their own generator and locator.
    @MainActor
    static func makeEngine(status: AppleModelStatus) -> AppleEngine {
        let generator: any AppleStepGenerating
        if #available(macOS 27, *) {
            generator = FoundationModelsStepGenerator(model: SystemLanguageModel.default)
        } else {
            generator = UnsupportedStepGenerator()
        }
        return AppleEngine(provider: .appleOnDevice, generator: generator, locator: VisionTextLocator(),
                           unavailability: { status.unavailability }, refreshAvailability: { status.refresh() })
    }

    /// Under XCTest and in the demo modes but `assistant-apple`: an engine that never answers (and
    /// never touches the model).
    @MainActor
    static func inertEngine() -> AppleEngine {
        AppleEngine(provider: .appleOnDevice, generator: UnsupportedStepGenerator(), locator: NoTextLocator(),
                    unavailability: { .modelNotReady })
    }
}

struct NoTextLocator: TextLocator {
    func locate(in image: EncodedImage) async -> [LocatedText] { [] }
}
