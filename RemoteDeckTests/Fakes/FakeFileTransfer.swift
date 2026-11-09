import Foundation
import SSHKit
@testable import RemoteDeck

/// A scripted `FileTransferring` (plan Task 12), honouring `SSHFileTransfer`'s contract: an upload
/// into a missing directory is `.noSuchDirectory`, onto an existing target without `overwrite`
/// `.fileExists`; cancelling the task of a transfer makes it throw `.connectionClosed`. A gated
/// transfer reports half its bytes, then waits for `release` (or its cancellation).
actor FakeFileTransfer: FileTransferring {
    struct Upload: Equatable {
        let name: String
        let directory: String
        let overwrite: Bool
    }

    let home: String
    /// Paths that exist: directories and files.
    private var directories: Set<String>
    private var files: [String: Data]
    /// Names (local file names) whose upload waits at half its bytes.
    private var gatedNames: Set<String>
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    /// A download that writes half the bytes into its destination, then fails with this error.
    private let downloadFailure: SSHError?
    private let downloadGated: Bool
    private var downloadGate: CheckedContinuation<Void, Never>?

    private(set) var uploads: [Upload] = []
    private(set) var cancelled: [String] = []
    private(set) var downloadDestinations: [URL] = []
    private(set) var existsQueries: [String] = []
    private(set) var closeCount = 0
    private var closedWaiters: [CheckedContinuation<Void, Never>] = []

    init(home: String = "/home/pi", directories: Set<String> = ["/home/pi"], files: [String: Data] = [:],
         gatedNames: Set<String> = [], downloadFailure: SSHError? = nil, downloadGated: Bool = false) {
        self.home = home
        self.directories = directories
        self.files = files
        self.gatedNames = gatedNames
        self.downloadFailure = downloadFailure
        self.downloadGated = downloadGated
    }

    func homeDirectory() async throws(SSHError) -> String { home }

    func exists(_ remotePath: String) async throws(SSHError) -> Bool {
        existsQueries.append(remotePath)
        return directories.contains(remotePath) || files[remotePath] != nil
    }

    func upload(_ local: URL, toDirectory: String, overwrite: Bool,
                progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
        guard directories.contains(toDirectory) else { throw .noSuchDirectory(toDirectory) }
        let name = local.lastPathComponent
        let target = toDirectory.hasSuffix("/") ? toDirectory + name : toDirectory + "/" + name
        if files[target] != nil, !overwrite { throw .fileExists(target) }
        guard let data = try? Data(contentsOf: local) else { throw .remote("cannot read \(local.path)") }
        uploads.append(Upload(name: name, directory: toDirectory, overwrite: overwrite))
        let size = Int64(data.count)
        if gatedNames.contains(name) {
            progress(size / 2, size)
            await withTaskCancellationHandler {
                await withCheckedContinuation { gates[name] = $0 }
            } onCancel: {
                Task { await self.releaseCancelled(name) }
            }
            if Task.isCancelled {
                cancelled.append(name)
                throw .connectionClosed
            }
        }
        progress(size, size)
        files[target] = data
    }

    func download(_ remotePath: String, to local: URL,
                  progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
        downloadDestinations.append(local)
        guard let data = files[remotePath] else { throw .remote("no such remote file: \(remotePath)") }
        let size = Int64(data.count)
        let part = local.appendingPathExtension("remotedeck-part")
        try? data.prefix(data.count / 2).write(to: part)
        progress(size / 2, size)
        if let downloadFailure {
            try? FileManager.default.removeItem(at: part)
            throw downloadFailure
        }
        if downloadGated {
            await withTaskCancellationHandler {
                await withCheckedContinuation { downloadGate = $0 }
            } onCancel: {
                Task { await self.releaseDownload() }
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: part)
                cancelled.append(remotePath)
                throw .connectionClosed
            }
        }
        try? data.write(to: part)
        do {
            if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
            try FileManager.default.moveItem(at: part, to: local)
        } catch {
            throw .remote("cannot write \(local.path)")
        }
        progress(size, size)
    }

    func close() async {
        closeCount += 1
        closedWaiters.forEach { $0.resume() }
        closedWaiters = []
    }

    // MARK: Test controls

    func isWaiting(_ name: String) -> Bool { gates[name] != nil }
    var isDownloadWaiting: Bool { downloadGate != nil }

    func release(_ name: String) {
        gatedNames.remove(name)
        gates.removeValue(forKey: name)?.resume()
    }

    func releaseDownload() {
        downloadGate?.resume()
        downloadGate = nil
    }

    private func releaseCancelled(_ name: String) {
        gates.removeValue(forKey: name)?.resume()
    }

    func addFile(_ path: String, _ data: Data = Data("x".utf8)) { files[path] = data }
    func addDirectory(_ path: String) { directories.insert(path) }
    func contents(_ path: String) -> Data? { files[path] }
}
