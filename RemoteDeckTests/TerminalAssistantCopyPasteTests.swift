import Foundation
import Testing
@testable import RemoteDeck

// Copy/paste between the terminal assistant panel and the SSH terminal (AppFlow › Terminal tab ›
// Assistant Panel): Copy on a command or an answer, "Ask Assistant About Selection". The real
// pasteboard is never touched (`InMemoryPasteboard`).
@MainActor
struct TerminalAssistantCopyPasteTests {
    private func make(_ turns: [TerminalTurn] = [], pasteboard: InMemoryPasteboard? = InMemoryPasteboard())
        -> (TerminalAssistantModel, FakeTerminalAssistantPort) {
        let port = FakeTerminalAssistantPort()
        let model = TerminalAssistantModel(port: port, provider: { .claude },
                                           makeEngine: { _ in ScriptedTerminalEngine(turns) },
                                           gate: AssistantDecisionGate(armDelay: .zero), pasteboard: pasteboard)
        return (model, port)
    }

    private func pasted(_ pasteboard: InMemoryPasteboard) -> String? {
        if case .text(let text) = pasteboard.content { text } else { nil }
    }

    // MARK: Copy

    @Test func copyCommandPutsTheExactTextOnThePasteboard() async {
        let pasteboard = InMemoryPasteboard()
        let command = "find /var/log -name '*.gz' | xargs ls -l  \"a b\""
        let (model, port) = make([commandTurn("t1", command)], pasteboard: pasteboard)
        model.prompt = "q"
        model.ask()
        #expect(await waitUntil { model.awaitingID == "t1" })
        #expect(model.copyCommand(id: "t1"))
        #expect(pasted(pasteboard) == command)
        model.stop()
        withExtendedLifetime(port) {}
    }

    @Test func copyCommandIgnoresKeysAndUnknownIDs() async {
        let pasteboard = InMemoryPasteboard()
        let (model, port) = make([actionTurn("k1", .waitForOutput(seconds: 5)), answerTurn("done")],
                              pasteboard: pasteboard)
        model.prompt = "q"
        model.ask()
        #expect(await waitUntil { model.phase == .finished })
        #expect(!model.copyCommand(id: "k1"))
        #expect(!model.copyCommand(id: "nope"))
        #expect(pasteboard.content == .none)
        withExtendedLifetime(port) {}
    }

    @Test func copyAnswerPutsTheAnswerOnThePasteboard() async {
        let pasteboard = InMemoryPasteboard()
        let (model, port) = make([answerTurn("The disk is 91% full.\nClean /var/log.")], pasteboard: pasteboard)
        model.prompt = "q"
        model.ask()
        #expect(await waitUntil { model.phase == .finished })
        #expect(model.copy("The disk is 91% full.\nClean /var/log."))
        #expect(pasted(pasteboard) == "The disk is 91% full.\nClean /var/log.")
        withExtendedLifetime(port) {}
    }

    @Test func copyIsUnavailableWithoutAPasteboardOrText() {
        let (withoutBoard, _) = make(pasteboard: nil)
        #expect(!withoutBoard.canCopy)
        #expect(!withoutBoard.copy("x"))
        let pasteboard = InMemoryPasteboard()
        let (model, _) = make(pasteboard: pasteboard)
        #expect(model.canCopy)
        #expect(!model.copy(""))
        #expect(pasteboard.content == .none)
    }

    // MARK: Ask about the selection

    @Test func selectionBecomesAFencedBlockWithoutSending() {
        let (model, port) = make()
        #expect(model.attachSelection("drwxr-xr-x  2 root root 4096 Nov 13 log\nerror: no space left"))
        #expect(model.prompt == "```\ndrwxr-xr-x  2 root root 4096 Nov 13 log\nerror: no space left\n```\n")
        #expect(model.entries.isEmpty)
        #expect(model.phase == .idle)
        #expect(port.typed.isEmpty)
    }

    @Test func selectionGoesAfterExistingPromptText() {
        let (model, _) = make()
        model.prompt = "What does this mean?\n"
        #expect(model.attachSelection("segfault at 0"))
        #expect(model.prompt == "What does this mean?\n\n```\nsegfault at 0\n```\n")
    }

    @Test func blankSelectionIsRefused() {
        let (model, _) = make()
        model.prompt = "keep"
        #expect(!model.attachSelection(nil))
        #expect(!model.attachSelection(""))
        #expect(!model.attachSelection(" \n\t "))
        #expect(model.prompt == "keep")
    }

    @Test func longSelectionIsCappedAndSaysSo() {
        let (model, _) = make()
        let selection = String(repeating: "a", count: TerminalAssistantModel.maxSelectionLength + 500)
        #expect(model.attachSelection(selection))
        let capped = String(repeating: "a", count: TerminalAssistantModel.maxSelectionLength)
        #expect(model.prompt.hasPrefix("```\n" + capped + "\n```\n"))
        #expect(model.prompt.contains("truncated"))
        #expect(!model.prompt.contains(capped + "a"))
        // The block must not make the prompt unsendable.
        #expect(model.trimmedPrompt.count <= TerminalAssistantModel.maxPromptLength)
    }

    @Test func selectionWithBackticksGetsALongerFence() {
        let (model, _) = make()
        #expect(model.attachSelection("echo ```x```"))
        #expect(model.prompt == "````\necho ```x```\n````\n")
    }

    // MARK: Session

    @Test func sessionAsksAboutTheSurfaceSelection() throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        #expect(!model.askAssistantAboutSelection())   // no assistant
        let (assistant, _) = make()
        model.terminalAssistant = assistant
        harness.surface.selectionValue = nil
        #expect(!model.askAssistantAboutSelection())   // no selection
        #expect(assistant.prompt.isEmpty)
        harness.surface.selectionValue = "Permission denied"
        #expect(model.askAssistantAboutSelection())
        #expect(assistant.prompt == "```\nPermission denied\n```\n")
    }
}
