import AppKit
import Foundation
import Observation
import SSHKit

// MARK: - Panels

/// The open and save panels of a file transfer (AppFlow › Terminal tab › Upload File… / Download
/// File…): `SystemFileTransferPanels` in the app, a fake in tests (never a real panel there).
@MainActor
protocol FileTransferPanels {
    /// Upload File… (⌘U): files only, several allowed; empty when cancelled.
    func chooseFilesToUpload() async -> [URL]
    /// Download File…: where to save the remote file; nil when cancelled. The panel asks itself
    /// before replacing an existing file.
    func chooseDownloadDestination(suggestedName: String) async -> URL?
    /// Closes a save panel still showing (the sheet was cancelled or the tab closed): its
    /// `chooseDownloadDestination` answers nil.
    func cancelPanels()
}

/// The default of models built without the app's panels: never a panel.
struct NoFileTransferPanels: FileTransferPanels {
    func chooseFilesToUpload() async -> [URL] { [] }
    func chooseDownloadDestination(suggestedName: String) async -> URL? { nil }
    func cancelPanels() {}
}

/// `NSOpenPanel` / `NSSavePanel` as their own windows (`begin`), never a sheet on the session
/// window, which may already carry the File Transfer Sheet. The sandbox grants the app the files
/// chosen (the saved one only: not its folder).
@MainActor
final class SystemFileTransferPanels: FileTransferPanels {
    /// The save panel showing, if any (non-modal: the tab can close under it).
    private var savePanel: NSSavePanel?

    func chooseFilesToUpload() async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls : []
    }

    func chooseDownloadDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        savePanel = panel
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        if savePanel === panel { savePanel = nil }
        return response == .OK ? panel.url : nil
    }

    func cancelPanels() {
        savePanel?.cancel(nil)
        savePanel = nil
    }
}

// MARK: - Model

/// The File Transfer Sheet of a terminal tab (AppFlow › Terminal tab, DesignBrief › Terminal tab,
/// PRD AC 16): upload dropped or chosen files into a remote folder, or download one remote file to
/// a place the save panel gives, over one SFTP session (`FileTransferring`) opened for the sheet
/// and closed once it is done (finished, failed or cancelled): each SFTP session counts against the
/// server's `MaxSessions`.
///
/// - Upload: folders in a drop are refused (`refusedFolders`, the files go on); the remote folder
///   is pre-filled with the remote home (`~` and `~/…` mean it too: SFTP does not expand them).
///   `start` checks the folder, then every target, before any byte: a missing folder is
///   `.failed(.noSuchDirectory)`, existing targets are listed by `.confirmOverwrite` and only
///   `confirmOverwrite()` replaces them (Cancel transfers nothing). Progress sums every file.
/// - Download: SSHKit writes beside its destination, which the sandbox refuses next to a file the
///   save panel granted alone; so the file is downloaded into the app's temporary folder, then
///   committed into the chosen URL (`commitDownload`), and the temporary copy is removed on every
///   path. A missing remote path is `.noSuchFile`, found before the save panel shows.
/// - `cancel()` stops the running transfer (SSHKit removes its partial file), skips the rest and
///   closes the session; calling it again does nothing.
@Observable
@MainActor
final class FileTransferModel {
    enum Kind: Equatable { case upload, download }

    enum Step: Equatable {
        /// Opening the SFTP session and reading the remote home.
        case preparing
        /// Upload: the files and the remote folder (editable).
        case chooseDestination(files: [URL], directory: String)
        /// Download: the remote path (editable).
        case chooseRemoteFile(path: String)
        /// Upload: these remote files exist; `confirmOverwrite()` replaces them.
        case confirmOverwrite([String])
        /// Bytes of every file of the transfer.
        case transferring(done: Int64, total: Int64)
        case finished
        /// Download: the remote path does not exist (the path can be edited again).
        case noSuchFile(String)
        case failed(SSHError)
    }

    typealias Opener = @MainActor () async throws -> any FileTransferring

    let kind: Kind
    private(set) var step: Step = .preparing
    /// Names of the folders a drop held: not uploaded ("Folders are not supported yet").
    private(set) var refusedFolders: [String] = []
    /// A check runs (the folder and targets, or the remote path) before the next step.
    private(set) var isChecking = false
    /// Cancelled, or the tab went away: nothing more happens.
    private(set) var isEnded = false
    /// The release of the SFTP session, once the work stopped (tests await it).
    @ObservationIgnored private(set) var closing: Task<Void, Never>?

    @ObservationIgnored private let open: Opener
    @ObservationIgnored private let panels: any FileTransferPanels
    @ObservationIgnored private let temporaryRoot: URL
    @ObservationIgnored private var transfer: (any FileTransferring)?
    @ObservationIgnored private var home: String?
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var files: [URL] = []
    @ObservationIgnored private var plan: UploadPlan?

    private struct PlannedFile {
        let url: URL
        /// The remote name, spelt as SSHKit spells it (the local file system representation).
        let name: String
        let size: Int64
    }

    private struct UploadPlan {
        let directory: String
        let files: [PlannedFile]
        var overwrite: Set<String> = []
        /// The first file not uploaded yet, and the bytes of those before it.
        var next = 0
        var doneBefore: Int64 = 0
        var total: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    init(kind: Kind, panels: any FileTransferPanels = NoFileTransferPanels(),
         temporaryRoot: URL = FileManager.default.temporaryDirectory, open: @escaping Opener) {
        self.kind = kind
        self.panels = panels
        self.temporaryRoot = temporaryRoot
        self.open = open
    }

    // MARK: Opening

    /// Opens the SFTP session and reads the remote home; then the first step of `kind`.
    func prepare() {
        guard !isEnded, preparing == nil, transfer == nil else { return }
        preparing = Task { await self.runPreparation() }
    }

    private func runPreparation() async {
        let handle: any FileTransferring
        do {
            handle = try await open()
        } catch {
            guard !isEnded else { return }
            fail((error as? SSHError) ?? .remote("\(error)"))
            return
        }
        guard !isEnded else {
            await handle.close()   // opened after a Cancel: never left open
            return
        }
        transfer = handle
        let home: String
        do {
            home = try await handle.homeDirectory()
        } catch {
            guard !isEnded else { return }
            fail(error)
            return
        }
        guard !isEnded else { return }
        self.home = home
        switch kind {
        case .upload: showUploadChoice()
        case .download: step = .chooseRemoteFile(path: home.hasSuffix("/") ? home : home + "/")
        }
    }

    // MARK: Upload

    /// Files dropped on the terminal (or chosen in the open panel). Folders are refused and named;
    /// several files are allowed. Folders only: nothing to upload, and no SFTP session is opened.
    func drop(_ urls: [URL]) {
        guard !isEnded, kind == .upload else { return }
        switch step {
        case .preparing, .chooseDestination: break
        default: return
        }
        for url in urls {
            // A symlink to a folder is a folder (`isDirectory` of the link itself says no).
            let isDirectory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            if isDirectory {
                refusedFolders.append(url.lastPathComponent)
            } else if !files.contains(url) {
                files.append(url)
            }
        }
        if files.isEmpty {
            step = .chooseDestination(files: [], directory: "")
        } else if home != nil {
            showUploadChoice()
        } else {
            prepare()
        }
    }

    private func showUploadChoice() {
        var directory = home ?? ""
        if case .chooseDestination(_, let typed) = step, !typed.isEmpty { directory = typed }
        step = .chooseDestination(files: files, directory: directory)
    }

    /// The remote folder field.
    func setDirectory(_ path: String) {
        guard case .chooseDestination(let files, _) = step else { return }
        step = .chooseDestination(files: files, directory: path)
    }

    /// Upload: checks the folder, then every target, before any byte.
    func start() {
        guard !isEnded, work == nil, case .chooseDestination(let urls, let typed) = step, !urls.isEmpty,
              let transfer, let home else { return }
        let directory = Self.resolve(typed, home: home)
        let planned = urls.map { PlannedFile(url: $0, name: Self.remoteName(of: $0), size: Self.size(of: $0)) }
        let plan = UploadPlan(directory: directory, files: planned)
        isChecking = true
        work = Task { await self.check(plan, on: transfer) }
    }

    private func check(_ plan: UploadPlan, on transfer: any FileTransferring) async {
        var existing: [String] = []
        do {
            guard try await transfer.exists(plan.directory) else {
                isChecking = false
                guard !isEnded else { return }
                fail(.noSuchDirectory(plan.directory))
                return
            }
            for file in plan.files {
                if try await transfer.exists(Self.join(plan.directory, file.name)) { existing.append(file.name) }
            }
        } catch {
            isChecking = false
            guard !isEnded else { return }
            fail(error)
            return
        }
        isChecking = false
        guard !isEnded else { return }
        if existing.isEmpty {
            await upload(plan, on: transfer)
        } else {
            self.plan = plan
            step = .confirmOverwrite(existing)
            work = nil
        }
    }

    /// "Replace <name>?" › Replace: those files are overwritten, the others uploaded as new.
    func confirmOverwrite() {
        guard !isEnded, work == nil, case .confirmOverwrite(let names) = step, var plan, let transfer else { return }
        plan.overwrite.formUnion(names)
        self.plan = nil
        work = Task { await self.upload(plan, on: transfer) }
    }

    private func upload(_ initial: UploadPlan, on transfer: any FileTransferring) async {
        var plan = initial
        let total = plan.total
        var done = plan.doneBefore
        step = .transferring(done: done, total: total)
        for index in plan.files.indices where index >= plan.next {
            guard !isEnded else { return }
            let file = plan.files[index]
            let base = done
            let (stream, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
            let consumer = Task {
                for await bytes in stream where !self.isEnded {
                    self.step = .transferring(done: min(base + bytes, total), total: total)
                }
            }
            var failure: SSHError?
            do {
                try await transfer.upload(file.url, toDirectory: plan.directory,
                                          overwrite: plan.overwrite.contains(file.name)) { bytes, _ in
                    continuation.yield(bytes)
                }
            } catch {
                failure = error
            }
            continuation.finish()
            await consumer.value
            guard !isEnded else { return }
            if let failure {
                if case .fileExists = failure {
                    // Created on the server since the check: ask for this one too, then go on.
                    plan.next = index
                    plan.doneBefore = base
                    self.plan = plan
                    step = .confirmOverwrite([file.name])
                    work = nil
                } else {
                    fail(failure)
                }
                return
            }
            done = min(base + file.size, total)
            step = .transferring(done: done, total: total)
        }
        guard !isEnded else { return }
        step = .finished
        release(after: [])
    }

    // MARK: Download

    /// The remote path field (also after "No such file").
    func setRemotePath(_ path: String) {
        switch step {
        case .chooseRemoteFile, .noSuchFile: step = .chooseRemoteFile(path: path)
        default: break
        }
    }

    /// Download…: checks the remote path, then asks where to save it, then downloads.
    func chooseDownloadLocation() {
        guard !isEnded, work == nil, let typed = typedRemotePath, let transfer, let home else { return }
        let remote = Self.resolve(typed, home: home)
        // A folder path (the pre-filled home and "/") names no file: never a save panel for it.
        guard let name = Self.fileName(of: remote) else {
            step = .noSuchFile(remote)
            return
        }
        isChecking = true
        work = Task { await self.askDestination(remote, name: name, on: transfer) }
    }

    private func askDestination(_ remote: String, name: String, on transfer: any FileTransferring) async {
        let found: Bool
        do {
            found = try await transfer.exists(remote)
        } catch {
            isChecking = false
            if !isEnded { fail(error) }
            return
        }
        isChecking = false
        guard !isEnded else { return }
        guard found else {
            step = .noSuchFile(remote)
            work = nil
            return
        }
        guard let destination = await panels.chooseDownloadDestination(suggestedName: name), !isEnded else {
            work = nil   // save panel cancelled: the sheet stays
            return
        }
        await runDownload(remote, to: destination, on: transfer, checked: true)
    }

    /// Downloads `remotePath` into the app's temporary folder, then into `destination` (a URL the
    /// save panel granted).
    func download(remotePath: String, to destination: URL) {
        guard !isEnded, work == nil, let transfer, let home else { return }
        let remote = Self.resolve(remotePath, home: home)
        work = Task { await self.runDownload(remote, to: destination, on: transfer) }
    }

    /// `checked`: the path was just found by `askDestination` (no second round trip).
    private func runDownload(_ remote: String, to destination: URL, on transfer: any FileTransferring,
                             checked: Bool = false) async {
        if !checked {
            do {
                guard try await transfer.exists(remote) else {
                    guard !isEnded else { return }
                    step = .noSuchFile(remote)
                    work = nil
                    return
                }
            } catch {
                if !isEnded { fail(error) }
                return
            }
        }
        guard !isEnded else { return }
        let folder = temporaryRoot.appendingPathComponent("RemoteDeck-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail(.remote("cannot write \(folder.path)"))
            return
        }
        let temporary = folder.appendingPathComponent(destination.lastPathComponent)
        step = .transferring(done: 0, total: 0)
        let (stream, continuation) = AsyncStream.makeStream(of: (Int64, Int64).self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task {
            for await (done, total) in stream where !self.isEnded {
                self.step = .transferring(done: done, total: total)
            }
        }
        var failure: SSHError?
        do {
            try await transfer.download(remote, to: temporary) { done, total in continuation.yield((done, total)) }
        } catch {
            failure = error
        }
        continuation.finish()
        await consumer.value
        guard !isEnded else { return }   // cancelled: nothing reaches the chosen file
        if let failure {
            fail(failure)
            return
        }
        // Off the main actor: a replace across volumes, or the copy, can take long on a big file.
        let committed = await Task.detached(priority: .userInitiated) {
            FileTransferModel.commitResult(temporary, to: destination)
        }.value
        guard !isEnded else { return }
        if case .failure(let error) = committed {
            fail(error)
            return
        }
        step = .finished
        release(after: [])
    }

    /// Puts the downloaded `temporary` file at `destination`: replaced atomically when the sandbox
    /// allows it (`replace`), else its bytes are written into the granted file itself (created if
    /// need be, truncated, copied by 1 MiB chunks).
    /// `commitDownload` as a value (a typed-throws `Task` closure crashes the compiler).
    nonisolated private static func commitResult(_ temporary: URL, to destination: URL) -> Result<Void, SSHError> {
        do {
            try commitDownload(temporary, to: destination)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func commitDownload(_ temporary: URL, to destination: URL,
                               replace: (URL, URL) throws -> Void = { destination, temporary in
                                   _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                               }) throws(SSHError) {
        if (try? replace(destination, temporary)) != nil { return }
        do {
            let manager = FileManager.default
            if !manager.fileExists(atPath: destination.path) {
                guard manager.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            let reader = try FileHandle(forReadingFrom: temporary)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try writer.synchronize()
        } catch {
            throw .remote("cannot write \(destination.path)")
        }
    }

    // MARK: Ending

    /// Cancel (or the tab closing): stops the running transfer, skips the rest, closes the SFTP
    /// session once the transfer stopped (so SSHKit can still remove its partial file).
    func cancel() {
        guard !isEnded else { return }
        isEnded = true
        let running = [work, preparing]
        work?.cancel()
        preparing?.cancel()
        panels.cancelPanels()   // a save panel still up answers nil, so the work can end
        release(after: running)
    }

    private func fail(_ error: SSHError) {
        step = .failed(error)
        release(after: [])
    }

    /// Closes the SFTP session once `tasks` ended; once only.
    private func release(after tasks: [Task<Void, Never>?]) {
        work = nil
        guard closing == nil else { return }
        closing = Task {
            for task in tasks { await task?.value }
            await self.transfer?.close()
        }
    }

    // MARK: Paths and messages

    /// `~` and `~/…` are the remote home; an empty field too.
    static func resolve(_ typed: String, home: String) -> String {
        let path = typed.trimmingCharacters(in: .newlines)
        if path.isEmpty || path == "~" { return home }
        if path.hasPrefix("~/") { return join(home, String(path.dropFirst(2))) }
        return path
    }

    /// The last component of a remote file path; nil for a path ending in "/" (a folder).
    static func fileName(of path: String) -> String? {
        guard !path.hasSuffix("/"), let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        return String(last)
    }

    /// Download…: a path that can name a file (not empty, not ending in "/").
    var canChooseDownloadLocation: Bool {
        guard !isChecking, let typed = typedRemotePath else { return false }
        let path = typed.trimmingCharacters(in: .newlines)
        return !path.isEmpty && path != "~" && Self.fileName(of: path) != nil
    }

    /// The path field's text, in `.chooseRemoteFile` and after "No such file" (Download… may try
    /// the same path again: it may exist by now).
    private var typedRemotePath: String? {
        switch step {
        case .chooseRemoteFile(let path), .noSuchFile(let path): path
        default: nil
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The name SSHKit gives the remote file (the local name in NFC), so the overwrite check asks
    /// about the very file the upload would replace.
    static func remoteName(of url: URL) -> String { SSHFileTransfer.remoteName(of: url) }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// The sheet's words for a failure (AppFlow › Terminal tab).
    static func message(for error: SSHError, _ t: (String) -> String) -> String {
        switch error {
        case .sftpUnavailable: t("transfer_sftp_unavailable")
        case .noSuchDirectory: t("transfer_no_such_folder")
        case .connectionClosed: t("session_connection_lost")
        case .timedOut: t("session_timeout")
        case .unreachable: t("test_unreachable")
        default: t("transfer_failed")
        }
    }
}
