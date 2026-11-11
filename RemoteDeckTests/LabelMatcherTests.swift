import ClaudeKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteDeck

/// Label resolution for the Apple provider (pure): a click never lands on a text the matcher was not
/// sure of.
struct LabelMatcherTests {
    private func text(_ string: String, x: Double = 0, y: Double = 0, w: Double = 40, h: Double = 20) -> LocatedText {
        LocatedText(text: string, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func exactMatchIgnoresCaseDiacriticsAndPunctuation() {
        let texts = [text("Préférences…", x: 100, y: 200, w: 60, h: 20), text("Finder", x: 10, y: 10)]
        #expect(LabelMatcher.match("preferences", in: texts) == .found(ScreenPoint(x: 130, y: 210), texts[0]))
        #expect(LabelMatcher.match("  FINDER ", in: texts) == .found(ScreenPoint(x: 30, y: 20), texts[1]))
    }

    @Test func exactMatchWinsOverContainingTexts() {
        let texts = [text("Open Finder settings", x: 0), text("Finder", x: 200), text("Finder window", x: 400)]
        #expect(LabelMatcher.match("Finder", in: texts) == .found(ScreenPoint(x: 220, y: 10), texts[1]))
    }

    @Test func uniqueContainingTextIsAccepted() {
        let texts = [text("Utilities folder", x: 100), text("Applications", x: 300)]
        #expect(LabelMatcher.match("utilities", in: texts) == .found(ScreenPoint(x: 120, y: 10), texts[0]))
    }

    @Test func severalExactMatchesAreAmbiguous() {
        let texts = [text("OK", x: 0), text("ok", x: 100), text("Cancel", x: 200)]
        #expect(LabelMatcher.match("OK", in: texts) == .ambiguous(2))
    }

    @Test func severalContainingMatchesAreAmbiguous() {
        let texts = [text("Save as PDF", x: 0), text("Save a copy", x: 100)]
        #expect(LabelMatcher.match("save", in: texts) == .ambiguous(2))
    }

    /// A partial match needs whole tokens: a label inside another word never matches.
    @Test func labelInsideAWordIsNotFound() {
        #expect(LabelMatcher.match("OK", in: [text("Bookmarks")]) == .notFound)
    }

    @Test func labelAsWholeTokensMatches() {
        let texts = [text("Click OK", x: 100)]
        #expect(LabelMatcher.match("OK", in: texts) == .found(ScreenPoint(x: 120, y: 10), texts[0]))
    }

    @Test func onlyTheWholeWordCandidateMatches() {
        let texts = [text("Save As…", x: 0), text("Autosave", x: 100)]
        #expect(LabelMatcher.match("save", in: texts) == .found(ScreenPoint(x: 20, y: 10), texts[0]))
    }

    @Test func multiWordLabelPrefersTheExactText() {
        let texts = [text("Time Machine", x: 0), text("Machine", x: 100)]
        #expect(LabelMatcher.match("Time Machine", in: texts) == .found(ScreenPoint(x: 20, y: 10), texts[0]))
        #expect(LabelMatcher.match("time machine", in: [text("Open Time Machine settings")])
                == .found(ScreenPoint(x: 20, y: 10), text("Open Time Machine settings")))
        #expect(LabelMatcher.match("Time Machine", in: [text("Machine Time")]) == .notFound)
    }

    @Test func missingOrEmptyLabelIsNotFound() {
        let texts = [text("Finder")]
        #expect(LabelMatcher.match("Trash", in: texts) == .notFound)
        #expect(LabelMatcher.match("", in: texts) == .notFound)
        #expect(LabelMatcher.match("…", in: texts) == .notFound)
        #expect(LabelMatcher.match("Finder", in: []) == .notFound)
    }

    /// Vision's boxes are normalised with the origin bottom-left: a text near the top of the image has
    /// a high `y` there and a small one in image pixels.
    @Test func visionBoxIsFlippedToTopLeftImagePixels() {
        let box = CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.2)   // top band of the image
        let rect = LabelMatcher.imageRect(normalized: box, width: 1000, height: 800)
        #expect(rect.minX == 250)
        #expect(rect.width == 500)
        #expect(abs(rect.minY - 40) < 0.001)       // (1 − 0.95) × 800
        #expect(abs(rect.height - 160) < 0.001)
        #expect(LabelMatcher.centre(of: rect) == ScreenPoint(x: 500, y: 120))
    }
}

/// `AppleStep` → the action the panel proposes (pure).
struct AppleStepMapperTests {
    private let texts = [LocatedText(text: "Finder", rect: CGRect(x: 100, y: 200, width: 60, height: 20))]

    private func action(_ mapped: AppleStepMapper.Mapped) -> TurnAction? {
        if case .action(let action) = mapped { return action }
        return nil
    }

    private func map(_ step: AppleStep, texts: [LocatedText]? = nil) -> AppleStepMapper.Mapped {
        AppleStepMapper.map(step, id: "apple-1", texts: texts ?? self.texts, width: 1024, height: 768)
    }

    @Test func labelClicksResolveToTheTextCentre() throws {
        for (kind, expected) in [(AppleStep.Kind.click, ComputerAction.click(.left, count: 1, at: ScreenPoint(x: 130, y: 210), modifiers: "")),
                                 (.doubleClick, .click(.left, count: 2, at: ScreenPoint(x: 130, y: 210), modifiers: "")),
                                 (.rightClick, .click(.right, count: 1, at: ScreenPoint(x: 130, y: 210), modifiers: ""))] {
            let use = try #require(action(map(AppleStep(kind: kind, label: "finder"))))
            #expect(use.action == expected)
            #expect(use.parseError == nil)
            #expect(use.label == "Finder")   // the OCR text the point comes from
            #expect(use.id == "apple-1")
        }
    }

    /// A partial match: the row names the text that is highlighted ("Click OK"), not the model's
    /// word ("OK"); the model's label stays in the payload.
    @Test func rowShowsTheMatchedTextNotTheModelsWord() throws {
        let texts = [LocatedText(text: "Click OK", rect: CGRect(x: 0, y: 0, width: 80, height: 20))]
        let use = try #require(action(map(AppleStep(kind: .click, label: "OK"), texts: texts)))
        #expect(use.label == "Click OK")
        #expect(use.input["label"] == "OK")
        #expect(use.action == .click(.left, count: 1, at: ScreenPoint(x: 40, y: 10), modifiers: ""))
    }

    @Test func unresolvedLabelsBecomeErrorsWithoutAnAction() throws {
        let missing = try #require(action(map(AppleStep(kind: .click, label: "Trash"))))
        #expect(missing.action == nil)
        #expect(missing.parseError == "Error: the label \"Trash\" was not found on the screen.")
        #expect(missing.input["coordinate"] == nil)

        let twice = texts + [LocatedText(text: "Finder", rect: CGRect(x: 500, y: 500, width: 60, height: 20))]
        let ambiguous = try #require(action(map(AppleStep(kind: .doubleClick, label: "Finder"), texts: twice)))
        #expect(ambiguous.action == nil)
        #expect(ambiguous.parseError?.contains("appears 2 times") == true)
    }

    @Test func keyboardWaitAndScrollSteps() throws {
        #expect(try #require(action(map(AppleStep(kind: .typeText, text: "uptime\n")))).action == .type("uptime\n"))
        #expect(try #require(action(map(AppleStep(kind: .pressKey, text: " cmd+c ")))).action == .key("cmd+c", repeat: 1))
        #expect(try #require(action(map(AppleStep(kind: .wait)))).action == .wait(duration: 2))
        // No label: at the screen centre, never at the pointer (`nil` would mean the pointer).
        #expect(try #require(action(map(AppleStep(kind: .scroll, direction: "Down")))).action
                == .scroll(.down, amount: 5, at: ScreenPoint(x: 512, y: 384), modifiers: ""))
        #expect(try #require(action(map(AppleStep(kind: .scroll, label: "Finder", direction: "up")))).action
                == .scroll(.up, amount: 5, at: ScreenPoint(x: 130, y: 210), modifiers: ""))
        #expect(try #require(action(map(AppleStep(kind: .scroll, direction: "sideways")))).action == nil)
    }

    /// The same bounds as Claude's members (T5.3 M2): an over-long text is never proposed.
    @Test func inputBoundsAreComputerActionsOwn() throws {
        let long = String(repeating: "a", count: ComputerAction.maxTypeLength + 1)
        let typed = try #require(action(map(AppleStep(kind: .typeText, text: long))))
        #expect(typed.action == nil)
        #expect(typed.parseError != nil)
        #expect(try #require(action(map(AppleStep(kind: .typeText, text: "")))).action == nil)
        #expect(try #require(action(map(AppleStep(kind: .pressKey, text: "  ")))).action == nil)
    }

    @Test func answersAndDoneCarryNoAction() {
        #expect(map(AppleStep(kind: .answer, text: "It is a login window.")) == .answer("It is a login window."))
        #expect(map(AppleStep(kind: .done)) == .done(""))
    }

    /// The anti-goal "a click lands on something not highlighted": the step has no coordinate field at
    /// all, so the model cannot propose one.
    @Test func appleStepHasNoCoordinateField() {
        let fields = Mirror(reflecting: AppleStep(kind: .click)).children.compactMap(\.label)
        #expect(Set(fields) == ["kind", "label", "text", "direction", "reason"])
    }

    @Test func summaryNeverHoldsTypedText() {
        #expect(AppleStepMapper.summaryLine(AppleStep(kind: .typeText, text: "hunter2")) == "typeText (7 characters)")
        #expect(AppleStepMapper.summaryLine(AppleStep(kind: .click, label: "OK")) == "click \"OK\"")
    }
}
