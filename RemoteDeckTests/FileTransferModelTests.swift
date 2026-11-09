import AppKit
import Foundation
import SSHKit
import Testing
@testable import RemoteDeck

// Plan Task 12 (AppFlow › Terminal tab › Upload File… / Download File…, PRD AC 16, Review Focus 4):
// the file transfer sheet's model over fakes only. `FakeFileTransfer` stands for SFTP, panels are
// `FakePanels`, and the local files live in a throwaway folder of the test's temporary directory.

/// A throwaway local folder: the files to upload, the chosen download destinations, and the
/// temporary root the model downloads into.
@MainActor
private final class LocalFiles {
    let root: URL
    let temporaryRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FileTransferTests-\(UUID().uuidString)")
        temporaryRoot = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    func file(_ name: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What is left in the model's temporary root.
    var temporaryLeftovers: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class FakePanels: FileTransferPanels {
    var uploadChoice: [URL] = []
    var downloadChoice: URL?
    private(set) var savePanelNames: [String] = []

    func chooseFilesToUpload() async -> [URL] { uploadChoice }

    func chooseDownloadDestination(suggestedName: String) async -> URL? {
        savePanelNames.append(suggestedName)
        return downloadChoice
    }
}

@MainActor
private final class Opener {
    let transfer: FakeFileTransfer?
    let error: SSHError
    private(set) var count = 0

    init(_ transfer: FakeFileTransfer?, error: SSHError = .sftpUnavailable) {
        self.transfer = transfer
        self.error = error
    }

    func open() async throws -> any FileTransferring {
        count += 1
        guard let transfer else { throw error }
        return transfer
    }
}

@MainActor
struct FileTransferModelTests {
    private func model(_ kind: FileTransferModel.Kind, _ opener: Opener, files: LocalFiles,
                       panels: FakePanels = FakePanels()) -> FileTransferModel {
        FileTransferModel(kind: kind, panels: panels, temporaryRoot: files.temporaryRoot) { try await opener.open() }
    }

    private func isChoosing(_ model: FileTransferModel) -> Bool {
        if case .chooseDestination = model.step { return true }
        return false
    }

    // MARK: Upload

    @Test func testDropPrefillsRemoteHome() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config été.toml", bytes: 12)
        let model = model(.upload, Opener(FakeFileTransfer()), files: files)
        model.drop([config])
        #expect(await waitUntil { model.step == .chooseDestination(files: [config], directory: "/home/pi") })
        #expect(model.refusedFolders.isEmpty)
    }

    @Test func testDroppedFolderIsRefused() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let folder = try files.folder("dotfiles")
        let config = try files.file("config.toml", bytes: 4)
        // A mixed drop: the files go on, the folder is named in the sheet.
        let mixed = model(.upload, Opener(FakeFileTransfer()), files: files)
        mixed.drop([folder, config])
        #expect(await waitUntil { mixed.step == .chooseDestination(files: [config], directory: "/home/pi") })
        #expect(mixed.refusedFolders == ["dotfiles"])

        // Folders only: nothing to upload, no SFTP channel opened for nothing.
        let opener = Opener(FakeFileTransfer())
        let only = model(.upload, opener, files: files)
        only.drop([folder])
        #expect(only.refusedFolders == ["dotfiles"])
        #expect(only.step == .chooseDestination(files: [], directory: ""))
        only.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(opener.count == 0)
        #expect(english("transfer_folders_refused") == "Folders are not supported yet")
    }

    /// Review Focus 4: an existing remote file is never overwritten without asking.
    @Test func testExistingRemoteFileAsksBeforeOverwrite() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let notes = try files.file("notes.txt", bytes: 4)
        let fake = FakeFileTransfer(files: ["/home/pi/config.toml": Data("old".utf8)])
        let model = model(.upload, Opener(fake), files: files)
        model.drop([config, notes])
        #expect(await waitUntil { isChoosing(model) })
        model.start()
        #expect(await waitUntil { model.step == .confirmOverwrite(["config.toml"]) })
        #expect(await fake.uploads.isEmpty)

        model.confirmOverwrite()
        #expect(await waitUntil { model.step == .finished })
        let uploads = await fake.uploads
        #expect(uploads == [.init(name: "config.toml", directory: "/home/pi", overwrite: true),
                            .init(name: "notes.txt", directory: "/home/pi", overwrite: false)])
        #expect(await fake.contents("/home/pi/config.toml") == Data("aaaa".utf8))
    }

    @Test func testOverwriteCancelTransfersNothing() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let notes = try files.file("notes.txt", bytes: 4)
        let fake = FakeFileTransfer(files: ["/home/pi/config.toml": Data("old".utf8)])
        let model = model(.upload, Opener(fake), files: files)
        model.drop([config, notes])
        #expect(await waitUntil { isChoosing(model) })
        model.start()
        #expect(await waitUntil { model.step == .confirmOverwrite(["config.toml"]) })
        model.cancel()
        model.confirmOverwrite()   // a late click does nothing
        await model.closing?.value
        #expect(await fake.uploads.isEmpty)
        #expect(await fake.contents("/home/pi/config.toml") == Data("old".utf8))
        #expect(await fake.closeCount == 1)
    }

    @Test func testMissingDirectoryShowsError() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let fake = FakeFileTransfer()
        let model = model(.upload, Opener(fake), files: files)
        model.drop([config])
        #expect(await waitUntil { isChoosing(model) })
        model.setDirectory("/home/pi/nope")
        model.start()
        #expect(await waitUntil { model.step == .failed(.noSuchDirectory("/home/pi/nope")) })
        #expect(await fake.uploads.isEmpty)
        #expect(english("transfer_no_such_folder") == "No such folder")
    }

    /// A leading `~` is the remote home (SFTP itself does not expand it).
    @Test func testTildeIsTheRemoteHome() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let fake = FakeFileTransfer(directories: ["/home/pi", "/home/pi/.config"])
        let model = model(.upload, Opener(fake), files: files)
        model.drop([config])
        #expect(await waitUntil { isChoosing(model) })
        model.setDirectory("~/.config")
        model.start()
        #expect(await waitUntil { model.step == .finished })
        #expect(await fake.uploads == [.init(name: "config.toml", directory: "/home/pi/.config", overwrite: false)])
    }

    @Test func testMultipleFilesProgressSumsTotals() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let small = try files.file("small.txt", bytes: 10)
        let large = try files.file("large.bin", bytes: 30)
        let fake = FakeFileTransfer(gatedNames: ["small.txt", "large.bin"])
        let model = model(.upload, Opener(fake), files: files)
        model.drop([small, large])
        #expect(await waitUntil { isChoosing(model) })
        model.start()
        #expect(await waitUntil { model.step == .transferring(done: 5, total: 40) })
        await fake.release("small.txt")
        #expect(await waitUntil { model.step == .transferring(done: 25, total: 40) })
        await fake.release("large.bin")
        #expect(await waitUntil { model.step == .finished })
        #expect(await fake.uploads.map(\.name) == ["small.txt", "large.bin"])
    }

    @Test func testCancelStopsTransfer() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let first = try files.file("first.txt", bytes: 10)
        let second = try files.file("second.txt", bytes: 10)
        let fake = FakeFileTransfer(gatedNames: ["first.txt"])
        let model = model(.upload, Opener(fake), files: files)
        model.drop([first, second])
        #expect(await waitUntil { isChoosing(model) })
        model.start()
        #expect(await waitUntil { model.step == .transferring(done: 5, total: 20) })
        model.cancel()
        await model.closing?.value
        #expect(await fake.cancelled == ["first.txt"])
        #expect(await fake.uploads.map(\.name) == ["first.txt"])   // the rest is skipped
        #expect(model.step != .finished)
        #expect(model.isEnded)
        #expect(await fake.closeCount == 1)
    }

    @Test func testSFTPUnavailableIsClear() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let model = model(.upload, Opener(nil), files: files)
        model.drop([config])
        #expect(await waitUntil { model.step == .failed(.sftpUnavailable) })
        #expect(FileTransferModel.message(for: .sftpUnavailable, english) == "SFTP is not available on this server")
    }

    /// The SFTP session is released once the sheet is done: finished, failed or cancelled.
    @Test func testCloseReleasesFileTransfer() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let fake = FakeFileTransfer()
        let model = model(.upload, Opener(fake), files: files)
        model.drop([config])
        #expect(await waitUntil { isChoosing(model) })
        model.start()
        #expect(await waitUntil { model.step == .finished })
        #expect(await fake.closeCount == 1)
        model.cancel()   // Done after finishing: closing again is harmless
        await model.closing?.value

        let failing = FakeFileTransfer()
        let failed = self.model(.upload, Opener(failing), files: files)
        failed.drop([config])
        #expect(await waitUntil { isChoosing(failed) })
        failed.setDirectory("/nope")
        failed.start()
        #expect(await waitUntil { failed.step == .failed(.noSuchDirectory("/nope")) })
        #expect(await failing.closeCount == 1)

        // Cancelled before the home folder arrived: the channel opened late is closed too.
        let early = FakeFileTransfer()
        let cancelled = self.model(.upload, Opener(early), files: files)
        cancelled.drop([config])
        cancelled.cancel()
        await cancelled.closing?.value
        #expect(await waitUntil { cancelled.isEnded })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await early.closeCount >= 1)
    }

    // MARK: Download

    @Test func testDownloadToChosenURLViaTemporaryFile() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let fake = FakeFileTransfer(files: ["/home/pi/app.conf": Data("remote bytes".utf8)])
        let panels = FakePanels()
        let destination = files.root.appendingPathComponent("chosen.conf")
        panels.downloadChoice = destination
        let model = model(.download, Opener(fake), files: files, panels: panels)
        model.prepare()
        #expect(await waitUntil { model.step == .chooseRemoteFile(path: "/home/pi/") })
        model.setRemotePath("~/app.conf")
        model.chooseDownloadLocation()
        #expect(await waitUntil { model.step == .finished })
        #expect(panels.savePanelNames == ["app.conf"])
        #expect(try Data(contentsOf: destination) == Data("remote bytes".utf8))
        // SSHKit wrote into the app's temporary folder, never beside the chosen file.
        let written = try #require(await fake.downloadDestinations.first)
        #expect(written.path.hasPrefix(files.temporaryRoot.path))
        #expect(files.temporaryLeftovers.isEmpty)
        #expect(await fake.closeCount == 1)
    }

    @Test func testDownloadMissingRemoteFileSaysNoSuchFile() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let fake = FakeFileTransfer()
        let panels = FakePanels()
        panels.downloadChoice = files.root.appendingPathComponent("x")
        let model = model(.download, Opener(fake), files: files, panels: panels)
        model.prepare()
        #expect(await waitUntil { model.step == .chooseRemoteFile(path: "/home/pi/") })
        model.setRemotePath("/home/pi/missing.conf")
        model.chooseDownloadLocation()
        #expect(await waitUntil { model.step == .noSuchFile("/home/pi/missing.conf") })
        #expect(panels.savePanelNames.isEmpty)   // asked before the save panel
        #expect(await fake.downloadDestinations.isEmpty)
        #expect(english("transfer_no_such_file") == "No such file")
    }

    @Test func testDownloadFailureRemovesTemporaryFile() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let fake = FakeFileTransfer(files: ["/home/pi/app.conf": Data("remote bytes".utf8)],
                                    downloadFailure: .remote("permission denied"))
        let destination = files.root.appendingPathComponent("chosen.conf")
        try Data("old".utf8).write(to: destination)
        let model = model(.download, Opener(fake), files: files)
        model.prepare()
        #expect(await waitUntil { model.step == .chooseRemoteFile(path: "/home/pi/") })
        model.download(remotePath: "/home/pi/app.conf", to: destination)
        #expect(await waitUntil { model.step == .failed(.remote("permission denied")) })
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(files.temporaryLeftovers.isEmpty)
        #expect(await fake.closeCount == 1)
    }

    @Test func testDownloadCancelRemovesTemporaryFile() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let fake = FakeFileTransfer(files: ["/home/pi/app.conf": Data("remote bytes".utf8)], downloadGated: true)
        let destination = files.root.appendingPathComponent("chosen.conf")
        let model = model(.download, Opener(fake), files: files)
        model.prepare()
        #expect(await waitUntil { model.step == .chooseRemoteFile(path: "/home/pi/") })
        model.download(remotePath: "/home/pi/app.conf", to: destination)
        #expect(await waitUntil { model.step == .transferring(done: 6, total: 12) })
        model.cancel()
        await model.closing?.value
        #expect(await fake.cancelled == ["/home/pi/app.conf"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(files.temporaryLeftovers.isEmpty)
        #expect(await fake.closeCount == 1)
    }

    /// The sandbox grants the save panel's file only: when replacing it is refused, its contents
    /// are written in place.
    @Test func testCommitCopiesIntoGrantedFileWhenReplaceIsRefused() throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let temporary = try files.file("downloaded", bytes: 3)
        let existing = files.root.appendingPathComponent("existing.conf")
        try Data("older and longer".utf8).write(to: existing)
        struct Refused: Error {}
        try FileTransferModel.commitDownload(temporary, to: existing, replace: { _, _ in throw Refused() })
        #expect(try Data(contentsOf: existing) == Data("aaa".utf8))

        let fresh = files.root.appendingPathComponent("fresh.conf")
        try FileTransferModel.commitDownload(temporary, to: fresh, replace: { _, _ in throw Refused() })
        #expect(try Data(contentsOf: fresh) == Data("aaa".utf8))
    }
}

// MARK: - Terminal tab

@MainActor
struct TerminalFileTransferTests {
    private func harness(_ fake: FakeFileTransfer) throws -> TerminalHarness {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        harness.makeFake = { _, log in FakeSSHSessionConnection(log: log, hostKey: serverKey, fileTransfer: fake) }
        return harness
    }

    /// Upload File… and Download File… (and a drop) only while the shell is up.
    @Test func testMenuDisabledWhenNotConnected() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let harness = try harness(FakeFileTransfer())
        let model = harness.model()
        #expect(!model.canTransferFiles)
        model.beginUpload([config])
        model.beginDownload()
        #expect(model.fileTransfer == nil)

        model.connect()
        #expect(!model.canTransferFiles)   // connecting
        try await harness.connected(model)
        #expect(model.canTransferFiles)
        model.beginUpload([config])
        #expect(model.fileTransfer?.kind == .upload)
        #expect(!model.canTransferFiles)   // one sheet at a time
        model.endFileTransfer()
        #expect(model.fileTransfer == nil)
        #expect(model.canTransferFiles)

        await model.close()
        #expect(!model.canTransferFiles)
    }

    /// Closing the tab mid-transfer stops the transfer and releases the SFTP session.
    @Test func testClosingTheTabReleasesTheFileTransfer() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 10)
        let fake = FakeFileTransfer(gatedNames: ["config.toml"])
        let harness = try harness(fake)
        let model = harness.model()
        model.transferTemporaryRoot = files.temporaryRoot
        model.connect()
        try await harness.connected(model)
        model.beginUpload([config])
        let transfer = try #require(model.fileTransfer)
        #expect(await waitUntil {
            if case .chooseDestination = transfer.step { return true }
            return false
        })
        transfer.start()
        #expect(await waitUntil { transfer.step == .transferring(done: 5, total: 10) })
        await model.close()
        #expect(model.fileTransfer == nil)
        #expect(await waitUntil(timeout: .seconds(3)) { transfer.isEnded })
        await transfer.closing?.value
        #expect(await fake.cancelled == ["config.toml"])
        #expect(await fake.closeCount == 1)
    }

    /// ⌘U: the open panel's files go to the sheet.
    @Test func testUploadMenuUsesTheOpenPanel() async throws {
        let files = try LocalFiles()
        defer { files.remove() }
        let config = try files.file("config.toml", bytes: 4)
        let harness = try harness(FakeFileTransfer())
        let model = harness.model()
        let panels = FakePanels()
        panels.uploadChoice = [config]
        model.fileTransferPanels = panels
        model.connect()
        try await harness.connected(model)
        await model.chooseFilesToUpload()
        let transfer = try #require(model.fileTransfer)
        #expect(await waitUntil { transfer.step == .chooseDestination(files: [config], directory: "/home/pi") })
    }
}

// MARK: - Menu bar

@MainActor
struct FileTransferMenuTests {
    private func items(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }

    /// AppFlow › Shortcuts: ⌘U and ⇧⌘D are taken by these items only, in the real menu bar.
    @Test func testUploadAndDownloadShortcutsAreUniqueInTheMenuBar() async throws {
        #expect(await waitUntil(timeout: .seconds(5)) { NSApp.mainMenu.map { !items($0).isEmpty } ?? false })
        let all = items(NSApp.mainMenu)
        func chord(_ item: NSMenuItem) -> String {
            let flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            var key = item.keyEquivalent
            var shift = flags.contains(.shift)
            if key != key.lowercased() { shift = true; key = key.lowercased() }   // "D" means ⇧D
            return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (shift ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
        }
        let upload = all.filter { !$0.keyEquivalent.isEmpty && chord($0) == "⌘u" }
        let download = all.filter { !$0.keyEquivalent.isEmpty && chord($0) == "⇧⌘d" }
        // The menus follow the app's language (French or English).
        func titles(_ key: String) -> Set<String> { Set(Strings.table.values.compactMap { $0[key] }) }
        #expect(upload.count == 1)
        #expect(download.count == 1)
        #expect(upload.allSatisfy { titles("menu_upload_file").contains($0.title) })
        #expect(download.allSatisfy { titles("menu_download_file").contains($0.title) })
        // No terminal tab is focused: both are disabled.
        #expect(upload.allSatisfy { !$0.isEnabled } && download.allSatisfy { !$0.isEnabled })
    }
}
