import AppKit
import Foundation
import SSHKit
import SwiftData
import SwiftUI
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 13 (build and look): the `-LibraryDemo ssh` session drawn offscreen (`cacheDisplay`), light
// and dark, over the demo's own connection and services: the Host Key Sheet, the terminal tab once
// trusted (in a titled window, toolbar bridged), and the File Transfer Sheet before and during the
// fake upload. The PNGs land in `$TMPDIR/RemoteDeckDemoSnapshots/` to be read by eye (as
// `TerminalRenderingTests`); used when this session cannot record the screen.
@MainActor
struct LibraryDemoRenderingTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"

    private var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDeckDemoSnapshots") }

    private func write(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        return rep
    }

    private func renderSheet(_ content: some View, settings: AppSettings, dark: Bool, name: String) throws {
        let host = NSHostingView(rootView: content.environment(settings)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let rep = try write(host, name: name)
        #expect(rep.pixelsWide > 0)
    }

    @Test(.timeLimit(.minutes(1))) func testSSHDemoSessionRenders() async throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.en.rawValue

        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let context = try makeTestContext()
            let machine = LibraryDemo.sshMachine()
            context.insert(machine)
            try context.save()
            let manager = SessionManager(context: context, passwords: InMemoryPasswordStore(), tester: LibraryDemo.Tester(),
                                         makeConnection: LibraryDemo.connection, makeDisplay: { nil },
                                         pasteboard: InMemoryPasteboard(), ssh: LibraryDemo.sshServices(),
                                         makeSSHConnection: LibraryDemo.sshConnection)
            let terminal = try #require(manager.terminal(for: machine.id))

            // First Connect: the Host Key Sheet.
            #expect(await waitUntil { terminal.hostKeyPrompt != nil })
            let prompt = try #require(terminal.hostKeyPrompt)
            try renderSheet(HostKeySheet(prompt: prompt, onTrust: {}, onCancel: {}), settings: settings, dark: dark,
                            name: "hostkey-\(theme)")
            // The known_hosts line (final review, Important 1): access lost, with the grant button.
            var lost = prompt
            lost.knownHostsProblem = .accessLost
            try renderSheet(HostKeySheet(prompt: lost, onTrust: {}, onCancel: {}, onGrantAccess: {}),
                            settings: settings, dark: dark, name: "hostkey-access-lost-\(theme)")
            terminal.trustHostKey()
            #expect(await waitUntil { terminal.phase == .connected })

            // The terminal tab in a titled window, its toolbar (forwards menu, Disconnect) bridged.
            let root = TerminalSessionView(terminal: terminal, machineID: machine.id)
                .environment(settings)
                .environment(manager)
                .modelContainer(context.container)
            let host = NSHostingView(rootView: root)
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            #expect(await waitUntil { terminal.surface != nil })
            #expect(await waitUntil { terminal.target.portForwards.allSatisfy {
                terminal.forwardStates[$0.id]?.isActive == true || terminal.forwardStates[$0.id]?.isFailed == true } })
            try await Task.sleep(for: .milliseconds(500))   // the engine's first draw
            let frame = try #require(window.contentView?.superview)
            _ = try write(frame, name: "terminal-\(theme)")

            // Upload File…: the demo panel's sample file, then the fake upload's progress.
            terminal.fileTransferPanels = LibraryDemo.FileTransferPanels()
            await terminal.chooseFilesToUpload()
            let transfer = try #require(terminal.fileTransfer)
            #expect(await waitUntil { if case .chooseDestination = transfer.step { true } else { false } })
            try renderSheet(FileTransferSheet(model: transfer, machineName: machine.name, onEnd: {}),
                            settings: settings, dark: dark, name: "upload-destination-\(theme)")
            transfer.start()
            #expect(await waitUntil(timeout: .seconds(5)) {
                if case .transferring(let done, let total) = transfer.step { done * 3 >= total } else { false }
            })
            try renderSheet(FileTransferSheet(model: transfer, machineName: machine.name, onEnd: {}),
                            settings: settings, dark: dark, name: "upload-progress-\(theme)")
            terminal.endFileTransfer()
            window.close()
            manager.close(machine.id)
        }
        print("LibraryDemo snapshots: \(folder.path)")
    }
}
