import Foundation
import Testing
@testable import RemoteDeck

// Plan (terminal assistant) Task 2: the pure pieces — snapshot, command validation, password prompts.

private func snapshot(_ screen: [String], cursor: (Int, Int)? = nil, alternate: Bool = false,
                      scrollback: [String] = []) -> TerminalSnapshot {
    TerminalSnapshot(screen: screen, scrollback: scrollback, cursorRow: cursor?.0, cursorColumn: cursor?.1,
                     isAlternateScreen: alternate, columns: 80)
}

@MainActor
struct TerminalAssistantPureTests {
    private let prompt = snapshot(["pi@raspberrypi:~ $"], cursor: (0, 19))

    @Test func validationTable() {
        func check(_ command: String, _ expected: CommandRefusal?, snapshot: TerminalSnapshot? = nil,
                   connected: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(TerminalCommandValidator.validate(command, snapshot: snapshot ?? prompt, connected: connected) == expected,
                    sourceLocation: sourceLocation)
        }
        check("", .empty)
        check(String(repeating: "a", count: 4000), nil)
        check(String(repeating: "a", count: 4001), .tooLong)
        for bad in ["ls\n", "ls\r", "a\u{1B}b", "a\u{7F}", "a\u{85}", "a\tb", "a\u{00}", "a\u{9F}"] {
            check(bad, .controlCharacter)
        }
        check("ls", .fullScreenProgram, snapshot: snapshot(["~"], cursor: (0, 0), alternate: true))
        check("ls", .passwordPrompt, snapshot: snapshot(["[sudo] password for pi: "], cursor: (0, 24)))
        check("ls", .notConnected, connected: false)
        // Review Focus 1: only control characters are refused.
        check("printf 'é 🎉 日本'", nil)
        check("echo ça\u{301}va", nil)
    }

    @Test func passwordPrompts() {
        for line in ["[sudo] password for pi: ", "Password:", "pi@host's password: ",
                     "Enter passphrase for key '/x': ", "Enter PIN for 'y':"] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            #expect(PasswordPromptDetector.isShowing(in: snapshot(["$ sudo ls", line], cursor: (1, line.count))),
                    "\(line)")
            #expect(PasswordPromptDetector.isShowing(in: snapshot([trimmed], cursor: (0, trimmed.count))), "\(line)")
        }
        // The cursor elsewhere on the row.
        #expect(!PasswordPromptDetector.isShowing(in: snapshot(["password: set"], cursor: (0, 3))))
        #expect(!PasswordPromptDetector.isShowing(in: snapshot(["password: set"], cursor: (0, 13))))
        // The cursor on another row.
        #expect(!PasswordPromptDetector.isShowing(in: snapshot(["$ echo password:", "password:", "$ "], cursor: (2, 2))))
        #expect(!PasswordPromptDetector.isShowing(in: snapshot(["Password:"], cursor: nil)))
    }

    @Test func snapshotBounds() {
        let many = snapshot(["$"], cursor: (0, 1), scrollback: (1...500).map { "line \($0)" })
        let lines = many.bounded()
        #expect(lines.scrollback.count == 200)
        #expect(lines.scrollback.last == "line 500")
        #expect(lines.scrollback.first == "line 301")

        let long = snapshot(["$"], cursor: (0, 1), scrollback: (1...100).map { String(format: "%03d", $0) + String(repeating: "x", count: 197) })
        #expect(long.scrollback.reduce(0) { $0 + $1.count } == 20_000)
        let kept = long.bounded()
        #expect(kept.scrollback.reduce(0) { $0 + $1.count + 1 } <= 16_000)
        #expect(kept.scrollback.last == long.scrollback.last)
        #expect(kept.scrollback.allSatisfy { $0.count == 200 })   // whole rows
        #expect(kept.scrollback.count == 79)

        let both = snapshot(["$ ls", "a b"], cursor: (1, 3), scrollback: ["old row"])
        #expect(both.rendered(includeScrollback: true).contains("old row"))
        #expect(!both.rendered(includeScrollback: false).contains("old row"))
        #expect(!both.rendered(includeScrollback: false).contains("--- scrollback ---"))
    }

    @Test func renderedFormat() {
        let shot = TerminalSnapshot(screen: ["$ top", "", ""], cursorRow: 0, cursorColumn: 5, isAlternateScreen: false,
                                    title: "pi@\"pi\"", columns: 40, rows: 3)
        #expect(shot.rendered(includeScrollback: true) == """
            <terminal cols=40 rows=3 alternate=no title="pi@'pi'" cursor=0,5>
            --- screen ---
            $ top
            </terminal>
            """)
        let control = TerminalSnapshot(screen: ["a\u{1B}b"], cursorRow: nil, cursorColumn: nil, isAlternateScreen: true,
                                       title: "", columns: 3, rows: 1)
        #expect(control.rendered(includeScrollback: false) == """
            <terminal cols=3 rows=1 alternate=yes title="" cursor=none>
            --- screen ---
            a b
            </terminal>
            """)
    }

    @Test func wideCharactersRenderWithoutPadding() {
        let surface = GhosttyTerminalSurface(columns: 20, rows: 3)
        surface.feed(Data("日本語\r\n$ ".utf8))
        let shot = surface.snapshot()
        #expect(shot?.screen == ["日本語", "$", ""])
        #expect(shot?.cursorRow == 1)
        #expect(shot?.cursorColumn == 2)
        #expect(shot?.columns == 20)
        #expect(shot?.rows == 3)
    }

    @Test func surfaceSnapshotReadsScrollbackAndAlternateScreen() {
        let surface = GhosttyTerminalSurface(columns: 20, rows: 3)
        surface.feed(Data(((1...6).map { "l\($0)" }.joined(separator: "\r\n")).utf8))
        #expect(surface.snapshot()?.scrollback == ["l1", "l2", "l3"])
        #expect(surface.snapshot()?.isAlternateScreen == false)
        surface.feed(Data("\u{1B}]2;vim x\u{07}\u{1B}[?1049h".utf8))
        #expect(surface.snapshot()?.isAlternateScreen == true)
        #expect(surface.snapshot()?.title == "vim x")
    }

    @Test func promptLineIsTheCursorRow() {
        let shot = snapshot(["Welcome", "pi@raspberrypi:~ $ ls", "a  b", "pi@raspberrypi:~ $"], cursor: (3, 19))
        #expect(shot.promptLine == "pi@raspberrypi:~ $")
        #expect(snapshot(["x"], cursor: nil).promptLine == nil)
        #expect(snapshot(["x"], cursor: (4, 0)).promptLine == nil)
    }

    @Test func namedKeysEncode() {
        #expect(TerminalNamedKey.ctrlC.bytes() == Data([0x03]))
        #expect(TerminalNamedKey.ctrlD.bytes() == Data([0x04]))
        #expect(TerminalNamedKey.return.bytes() == Data([0x0D]))
        #expect(TerminalNamedKey.up.bytes() == Data([0x1B, 0x5B, 0x41]))
        #expect(TerminalNamedKey.up.bytes(cursorKeysApplication: true) == Data([0x1B, 0x4F, 0x41]))
        #expect(TerminalNamedKey.pageDown.bytes() == Data("\u{1B}[6~".utf8))
        #expect(TerminalNamedKey.allCases.map(\.rawValue) == ["ctrl_c", "ctrl_d", "escape", "q", "return", "tab", "up",
                                                              "down", "left", "right", "page_up", "page_down"])
    }
}
