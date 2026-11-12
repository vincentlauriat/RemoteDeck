import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RemoteDeck

// Plan (terminal assistant) Task 9: the panel in a terminal tab, drawn offscreen in each state (fr and
// en, light and dark) into `$TMPDIR/RemoteDeckTerminalAssistantSnapshots/`, read by eye; the tests
// check what the row says through the copy the view draws (`TerminalAssistantCopy`, the item's
// fields): SwiftUI builds no accessibility tree for an offscreen hosting view.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalAssistantPanelRenderingTests {
    private static let longCommand = "find /var/log -type f -name '*.log' -size +10M -mtime +30 -print0 | "
        + "xargs -0 ls -lh | sort -k5 -h | tail -n 20 && journalctl --disk-usage && du -sh /var/log/* "
        + "2>/dev/null | sort -h | tail -n 15 && df -h / /boot && echo 'end of the disk usage report for the "
        + "raspberry pi in the living room, written on a Sunday evening after the backups'"

    private func model(_ turns: [TerminalTurn], port: FakeTerminalAssistantPort) -> TerminalAssistantModel {
        TerminalAssistantModel(port: port, provider: { .claude }, makeEngine: { _ in ScriptedTerminalEngine(turns) },
                               gate: AssistantDecisionGate(armDelay: .zero))
    }

    /// Renders the panel into a PNG (checked to be written).
    private func render(_ model: TerminalAssistantModel, name: String, language: AppLanguage = .en,
                        dark: Bool = false) throws {
        let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = language.rawValue
        let panel = TerminalAssistantPanelView(model: model)
            .environment(settings)
            .frame(width: 320, height: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = NSSize(width: 320, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDeckTerminalAssistantSnapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)
        try png.write(to: folder.appendingPathComponent("\(name)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
    }

    private func english() throws -> AppSettings {
        let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.en.rawValue
        return settings
    }

    private func awaiting(_ command: String, port: FakeTerminalAssistantPort = FakeTerminalAssistantPort())
        async -> TerminalAssistantModel {
        let model = model([commandTurn("t1", command, reason: "Find what fills the disk.")], port: port)
        model.ask("why is the disk full?")
        _ = await waitUntil { model.awaitingID == "t1" && model.confirmArmed }
        return model
    }

    @Test func panelRendersAProposedCommandVerbatim() async throws {
        #expect(Self.longCommand.count >= 300)
        let port = FakeTerminalAssistantPort()
        let model = await awaiting(Self.longCommand, port: port)
        let item = try #require(model.item("t1"))
        #expect(TerminalAssistantCopy.commandText(item) == Self.longCommand)
        let settings = try english()
        #expect(TerminalAssistantCopy.title(item) { settings.t($0) } == "Type and press Return")
        #expect(item.status == .awaiting)
        try render(model, name: "proposal")
        try render(model, name: "proposal", dark: true)
        try render(model, name: "proposal", language: .fr)
        try render(model, name: "proposal", language: .fr, dark: true)
        model.stop()
        withExtendedLifetime(port) {}
    }

    @Test func panelShowsThePromptLineAndNonEmptyNote() async throws {
        let port = FakeTerminalAssistantPort()
        port.snapshot = TerminalSnapshot(screen: ["pi@raspberrypi:~ $ git sta"], cursorRow: 0, cursorColumn: 27)
        let model = await awaiting("df -h", port: port)
        let item = try #require(model.item("t1"))
        #expect(item.promptLine == "pi@raspberrypi:~ $ git sta")
        #expect(item.commandLineNotEmpty)
        #expect(try english().t("assistant_terminal_line_not_empty") == "The command line isn't empty")
        try render(model, name: "line-not-empty")

        let clean = FakeTerminalAssistantPort()
        let empty = await awaiting("df -h", port: clean)
        #expect(empty.item("t1")?.commandLineNotEmpty == false)
        try render(empty, name: "line-empty")
        model.stop()
        empty.stop()
        withExtendedLifetime((port, clean)) {}
    }

    @Test func passwordWaitShowsContinue() async throws {
        let port = FakeTerminalAssistantPort()
        port.waitHandler = { _ in .passwordPrompt }
        let model = model([commandTurn("t1", "sudo apt update")], port: port)
        model.ask("update the packages")
        #expect(await waitUntil { model.confirmArmed })
        model.confirm(id: "t1")
        #expect(await waitUntil { model.phase == .waitingForUser(.password) })
        #expect(try english().t("assistant_terminal_password_wait") == "Type your password in the terminal, then click Continue.")
        try render(model, name: "password")
        try render(model, name: "password", language: .fr, dark: true)
        model.stop()
        withExtendedLifetime(port) {}
    }

    @Test func destructiveBadgeIsShownForRmRf() async throws {
        for command in ["rm -rf /var/log/old", "sudo mkfs.ext4 /dev/sda1", "dd if=x of=/dev/sdb", "sudo reboot",
                        "shutdown -h now", "cat x > /dev/sda"] {
            #expect(TerminalCommandValidator.looksDestructive(command), "\(command)")
        }
        for command in ["ls -la", "df -h", "echo rm", "grep -r 'rm -rf' docs"] {
            #expect(!TerminalCommandValidator.looksDestructive(command), "\(command)")
        }
        let port = FakeTerminalAssistantPort()
        let model = await awaiting("rm -rf /var/log/old", port: port)
        #expect(TerminalAssistantCopy.commandText(try #require(model.item("t1"))).map(TerminalCommandValidator.looksDestructive) == true)
        try render(model, name: "destructive")
        try render(model, name: "destructive", dark: true)
        model.stop()
        withExtendedLifetime(port) {}
    }

    @Test func newShellNoticeAfterAReconnect() async throws {
        let port = FakeTerminalAssistantPort()
        let model = model([answerTurn("Your disk is 91% full.")], port: port)
        model.ask("why?")
        #expect(await waitUntil { model.phase == .finished })
        try render(model, name: "answer")
        model.shellReconnected()
        #expect(model.isNewShell)
        try render(model, name: "new-shell")
        withExtendedLifetime(port) {}
    }

    @Test func stringsMatchInBothLanguages() {
        let fr = Set(Strings.table["fr"]?.keys.filter { $0.hasPrefix("assistant_terminal_") } ?? [])
        let en = Set(Strings.table["en"]?.keys.filter { $0.hasPrefix("assistant_terminal_") } ?? [])
        #expect(!en.isEmpty)
        #expect(fr == en)
    }
}

// Every way a terminal tab's shell goes away ends its assistant before the teardown.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalAssistantWiringTests {
    private func running(_ harness: TerminalHarness) async throws -> (TerminalSessionModel, TerminalAssistantModel, FakeSSHSessionConnection) {
        let terminal = harness.model()
        let engine = ScriptedTerminalEngine([])   // nextTurn hangs: a request in flight
        let assistant = TerminalAssistantModel(port: terminal, provider: { .claude }, makeEngine: { _ in engine },
                                               gate: AssistantDecisionGate(armDelay: .zero))
        terminal.terminalAssistant = assistant
        terminal.connect()
        try await harness.connected(terminal)
        assistant.ask("hello")
        #expect(assistant.phase == .running)
        return (terminal, assistant, try #require(harness.last))
    }

    @Test func teardownPathsCallSessionEnded() async throws {
        // Tab close.
        let closing = try TerminalHarness()
        closing.trustServerKey()
        let (terminal, assistant, _) = try await running(closing)
        await terminal.close()
        #expect(await waitUntil { assistant.phase == .failed(.disconnected) })

        // Sleep.
        let sleeping = try TerminalHarness()
        sleeping.trustServerKey()
        let (asleep, sleepAssistant, _) = try await running(sleeping)
        asleep.suspendForSleep()
        #expect(await waitUntil { sleepAssistant.phase == .failed(.disconnected) })
        await asleep.close()

        // The remote shell exits.
        let exiting = try TerminalHarness()
        exiting.trustServerKey()
        let (exited, exitAssistant, fake) = try await running(exiting)
        fake.shell.finish()
        #expect(await waitUntil { exited.phase == .ended })
        #expect(exitAssistant.phase == .failed(.disconnected))

        // Reconnect: a new shell, a new conversation.
        exited.connect()
        try await exiting.connected(exited)
        #expect(exitAssistant.isNewShell)
        #expect(!exitAssistant.engine.hasConversation)
        await exited.close()
    }

    @Test func sessionManagerGivesEachTerminalItsAssistant() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let manager = SessionManager(context: harness.context, passwords: harness.passwords,
                                     tester: FakeConnectionTester(), makeDisplay: { nil },
                                     pasteboard: InMemoryPasteboard(), notificationCenter: NotificationCenter(),
                                     reconnectClock: harness.reconnectClock,
                                     ssh: SSHServices(folder: harness.folder, trustedHostKeys: harness.trust,
                                                      secrets: harness.secrets),
                                     makeSSHConnection: { [log = harness.log] _ in
                                         FakeSSHSessionConnection(log: log, hostKey: serverKey)
                                     },
                                     makeTerminalAssistant: { terminal in
                                         TerminalAssistantModel(port: terminal, provider: { .claude },
                                                                makeEngine: { _ in ScriptedTerminalEngine([]) })
                                     })
        defer { manager.stop() }
        #expect(manager.requestWindow(for: harness.machine.id))
        let terminal = try #require(manager.terminals[harness.machine.id])
        #expect(terminal.terminalAssistant != nil)
        #expect(terminal.terminalAssistant?.port === terminal)
        manager.close(harness.machine.id)
    }
}
