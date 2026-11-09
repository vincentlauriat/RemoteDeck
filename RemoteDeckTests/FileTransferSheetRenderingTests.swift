import AppKit
import Foundation
import SSHKit
import SwiftUI
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 12 (build and look): the File Transfer Sheet drawn offscreen in each state, light and
// dark, over `FakeFileTransfer`. The PNGs land in `$TMPDIR/RemoteDeckTransferSnapshots/` to be read
// by eye (as `TerminalRenderingTests`); the test itself checks the DesignBrief width.
@MainActor
struct FileTransferSheetRenderingTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"

    private func render(_ model: FileTransferModel, dark: Bool, name: String) throws -> NSSize {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.en.rawValue
        let sheet = FileTransferSheet(model: model, machineName: "Raspberry", onEnd: {})
            .environment(settings)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: sheet)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDeckTransferSnapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        return size
    }

    @Test func testSheetStatesRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TransferRender-\(UUID().uuidString)")
        let temporaryRoot = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ bytes: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(repeating: 0x61, count: bytes).write(to: url)
            return url
        }
        let folder = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = try file("config été.toml", 1_200_000)
        let long = try file("a-very-long-file-name-for-the-raspberry-pi-configuration-backup-2026-11-09.tar.gz", 3_400_000)

        func model(_ fake: FakeFileTransfer, _ kind: FileTransferModel.Kind = .upload) -> FileTransferModel {
            FileTransferModel(kind: kind, temporaryRoot: temporaryRoot) { fake }
        }
        func choosing(_ model: FileTransferModel) -> Bool {
            if case .chooseDestination = model.step { return true }
            return false
        }
        var states: [(String, FileTransferModel)] = []

        let destination = model(FakeFileTransfer())
        destination.drop([config, long, folder])
        #expect(await waitUntil { choosing(destination) })
        states.append(("destination", destination))

        let replace = model(FakeFileTransfer(files: ["/home/pi/config été.toml": Data(), "/home/pi/\(long.lastPathComponent)": Data()]))
        replace.drop([config, long])
        #expect(await waitUntil { choosing(replace) })
        replace.start()
        #expect(await waitUntil { if case .confirmOverwrite = replace.step { true } else { false } })
        states.append(("replace", replace))

        let gated = FakeFileTransfer(gatedNames: [config.lastPathComponent])
        let progress = model(gated)
        progress.drop([config, long])
        #expect(await waitUntil { choosing(progress) })
        progress.start()
        #expect(await waitUntil { if case .transferring(let done, _) = progress.step { done > 0 } else { false } })
        states.append(("progress", progress))

        let failed = model(FakeFileTransfer(files: ["/home/pi/app.conf": Data("x".utf8)],
                                            downloadFailure: .remote("permission denied: /home/pi/app.conf")), .download)
        failed.prepare()
        #expect(await waitUntil { failed.step == .chooseRemoteFile(path: "/home/pi/") })
        failed.download(remotePath: "/home/pi/app.conf", to: root.appendingPathComponent("app.conf"))
        #expect(await waitUntil { if case .failed = failed.step { true } else { false } })
        states.append(("failed", failed))

        let missing = model(FakeFileTransfer(), .download)
        missing.prepare()
        #expect(await waitUntil { missing.step == .chooseRemoteFile(path: "/home/pi/") })
        missing.setRemotePath("/etc/missing.conf")
        missing.chooseDownloadLocation()
        #expect(await waitUntil { if case .noSuchFile = missing.step { true } else { false } })
        states.append(("no-such-file", missing))

        let finished = model(FakeFileTransfer())
        finished.drop([config])
        #expect(await waitUntil { choosing(finished) })
        finished.start()
        #expect(await waitUntil { finished.step == .finished })
        states.append(("finished", finished))

        for (name, state) in states {
            for dark in [false, true] {
                let size = try render(state, dark: dark, name: name)
                #expect(size.width == 420)   // DesignBrief › Terminal tab
            }
        }
        await gated.release(config.lastPathComponent)
        progress.cancel()
    }
}
