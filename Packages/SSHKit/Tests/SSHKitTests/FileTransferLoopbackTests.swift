import Crypto
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SSHKit

/// SFTP upload and download against the in-process `TestSSHServer`, whose `sftp` subsystem is
/// Citadel's SFTP server on a temporary directory (`TestSFTPDelegate`). Names are compared as the
/// bytes `readdir` returns on both sides, never as `String` (whose `==` equates NFC and NFD).
/// Every wait is bounded.
@Suite(.timeLimit(.minutes(1)))
struct FileTransferLoopbackTests {
    // MARK: Upload

    @Test func uploadsBytesExactly() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("payload.bin", bytes: 3 * 1024 * 1024)
        let transfer = try await rig.transfer()
        try await bounded(.seconds(30)) {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
        }
        let remote = rig.home.appendingPathComponent("payload.bin")
        #expect(try sha256(remote) == sha256(local))
        // Only the target: the part file was renamed onto it.
        #expect(rig.remoteNames() == [Array("payload.bin".utf8)])
        await rig.stop()
    }

    @Test func uploadNameWithSpacesAndAccents() async throws {
        // Precomposed é (NFC), as typed on a Mac keyboard: arrives NFC.
        try await uploadArrivesNFC("config \u{E9}t\u{E9}.toml")
    }

    @Test func uploadDecomposedNameArrivesPrecomposed() async throws {
        // e + combining acute (NFD), as the Mac's file APIs hand names out: arrives NFC, so it
        // matches (and replaces) the name a user typed on the server.
        try await uploadArrivesNFC("config e\u{301}te\u{301}.toml")
    }

    private func uploadArrivesNFC(_ name: String) async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile(name, bytes: 1000)
        let transfer = try await rig.transfer()
        try await bounded {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
        }
        let nfc = Array("config \u{E9}t\u{E9}.toml".utf8)
        #expect(Array(SSHFileTransfer.remoteName(of: local).utf8) == nfc)
        #expect(rig.remoteNames() == [nfc])
        await rig.stop()
    }

    @Test func existingFileWithoutOverwriteThrows() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("app.conf", bytes: 2000)
        let remote = rig.home.appendingPathComponent("app.conf")
        try Data("original\n".utf8).write(to: remote)
        let transfer = try await rig.transfer()
        let target = rig.homePath + "/app.conf"
        await #expect(throws: SSHError.fileExists(target)) {
            try await bounded {
                try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
            }
        }
        #expect(try Data(contentsOf: remote) == Data("original\n".utf8))
        #expect(rig.remoteNames() == [Array("app.conf".utf8)])
        await rig.stop()
    }

    @Test func overwriteReplacesTheFile() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("app.conf", bytes: 5000)
        let remote = rig.home.appendingPathComponent("app.conf")
        try Data("original\n".utf8).write(to: remote)
        let transfer = try await rig.transfer()
        try await bounded {
            try await transfer.upload(local, toDirectory: rig.homePath + "/", overwrite: true) { _, _ in }
        }
        #expect(try sha256(remote) == sha256(local))
        #expect(rig.remoteNames() == [Array("app.conf".utf8)])
        await rig.stop()
    }

    @Test func overwriteKeepsTheTargetsMode() async throws {
        let rig = try await SFTPRig.start()
        let transfer = try await rig.transfer()
        for mode in [0o600, 0o755] as [mode_t] {
            let local = try rig.makeLocalFile("tool-\(mode)", bytes: 4000)
            let remote = rig.home.appendingPathComponent("tool-\(mode)")
            try Data("old".utf8).write(to: remote)
            #expect(chmod(remote.path, mode) == 0)
            try await bounded {
                try await transfer.upload(local, toDirectory: rig.homePath, overwrite: true) { _, _ in }
            }
            #expect(try sha256(remote) == sha256(local))
            #expect(try fileMode(remote) == mode, "mode \(String(mode, radix: 8))")
        }
        await rig.stop()
    }

    @Test func stalePartFileIsReplaced() async throws {
        // A part file left by a dropped connection, longer than the new upload: truncated and reused.
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("app.conf", bytes: 1000)
        try randomData(50_000).write(to: rig.home.appendingPathComponent("app.conf.remotedeck-part"))
        let transfer = try await rig.transfer()
        try await bounded {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
        }
        #expect(try sha256(rig.home.appendingPathComponent("app.conf")) == sha256(local))
        #expect(rig.remoteNames() == [Array("app.conf".utf8)])
        await rig.stop()
    }

    @Test func missingDirectoryThrowsAndLeavesNothing() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("a.txt", bytes: 100)
        try Data("x".utf8).write(to: rig.home.appendingPathComponent("plain-file"))
        let transfer = try await rig.transfer()
        let before = try treeNames(rig.root)
        for directory in [rig.homePath + "/missing", "/nowhere/at/all", rig.homePath + "/plain-file", ""] {
            await #expect(throws: SSHError.noSuchDirectory(directory)) {
                try await bounded {
                    try await transfer.upload(local, toDirectory: directory, overwrite: true) { _, _ in }
                }
            }
        }
        #expect(try treeNames(rig.root) == before)
        await rig.stop()
    }

    @Test func failedUploadRemovesPartialFile() async throws {
        // The server's TCP connection drops after 1 MB of a 3 MB upload. The target name never
        // appears: the bytes went to the part file, renamed only once complete. (The part file
        // itself can remain: with the connection gone, nothing can reach the server to remove it.)
        // The rig has no keepalive and the bound is 10 s: the drop is seen from the TCP close.
        let rig = try await SFTPRig.start(dropConnectionAfterBytes: 1024 * 1024)
        let local = try rig.makeLocalFile("big.bin", bytes: 3 * 1024 * 1024)
        let transfer = try await rig.transfer()
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded(.seconds(10)) {
                try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
            }
        }
        #expect(!rig.remoteNames().contains(Array("big.bin".utf8)))
        #expect(rig.remoteNames().allSatisfy { $0 == Array("big.bin.remotedeck-part".utf8) })
        await rig.stop()
    }

    @Test func failedWriteRemovesThePartFile() async throws {
        // The server refuses a write (disk full) with the connection up: the part file is removed
        // and the server's error is the one thrown.
        let rig = try await SFTPRig.start(failWritesAfterBytes: 512 * 1024)
        let local = try rig.makeLocalFile("big.bin", bytes: 2 * 1024 * 1024)
        let transfer = try await rig.transfer()
        var thrown: SSHError?
        do {
            try await bounded(.seconds(30)) {
                try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
            }
        } catch let error as SSHError {
            thrown = error
        }
        guard case .remote = thrown else {
            Issue.record("expected .remote, got \(String(describing: thrown))")
            return
        }
        #expect(rig.remoteNames().isEmpty)
        await rig.stop()
    }

    @Test func cancelledUploadRemovesThePartFile() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("big.bin", bytes: 8 * 1024 * 1024)
        let transfer = try await rig.transfer()
        let log = ProgressLog()
        let task = Task {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { done, total in
                log.append(done, total)
                // Cancel the transfer's own task once bytes are on the server: deterministic.
                if done > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded(.seconds(20)) { try await task.value }
        }
        #expect(log.calls.contains { $0.done > 0 })
        #expect(log.calls.last.map { $0.done < $0.total } == true)
        #expect(rig.remoteNames().isEmpty)
        // The same SSHFileTransfer still works after a cancelled transfer.
        try await bounded(.seconds(30)) {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { _, _ in }
        }
        #expect(try sha256(rig.home.appendingPathComponent("big.bin")) == sha256(local))
        await rig.stop()
    }

    @Test func progressReachesTotal() async throws {
        let rig = try await SFTPRig.start()
        let size = 1024 * 1024 + 123
        let local = try rig.makeLocalFile("p.bin", bytes: size)
        let transfer = try await rig.transfer()
        let up = ProgressLog()
        try await bounded {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { up.append($0, $1) }
        }
        up.expectMonotonicEnding(at: Int64(size))
        #expect(up.calls.count > 1)

        let down = ProgressLog()
        let destination = rig.local.appendingPathComponent("p-copy.bin")
        try await bounded {
            try await transfer.download(rig.homePath + "/p.bin", to: destination) { down.append($0, $1) }
        }
        down.expectMonotonicEnding(at: Int64(size))
        #expect(down.calls.count > 1)
        await rig.stop()
    }

    @Test func emptyFileReportsZeroOfZero() async throws {
        let rig = try await SFTPRig.start()
        let local = try rig.makeLocalFile("empty", bytes: 0)
        let transfer = try await rig.transfer()
        let up = ProgressLog()
        try await bounded {
            try await transfer.upload(local, toDirectory: rig.homePath, overwrite: false) { up.append($0, $1) }
        }
        #expect(up.calls.map(\.done) == [0] && up.calls.map(\.total) == [0])
        #expect(try Data(contentsOf: rig.home.appendingPathComponent("empty")).isEmpty)

        let down = ProgressLog()
        let destination = rig.local.appendingPathComponent("empty-copy")
        try await bounded {
            try await transfer.download(rig.homePath + "/empty", to: destination) { down.append($0, $1) }
        }
        #expect(down.calls.map(\.done) == [0] && down.calls.map(\.total) == [0])
        #expect(try Data(contentsOf: destination).isEmpty)
        await rig.stop()
    }

    // MARK: Download

    @Test func downloadsBytesExactly() async throws {
        let rig = try await SFTPRig.start()
        let remote = rig.home.appendingPathComponent("remote.bin")
        try randomData(3 * 1024 * 1024 + 7).write(to: remote)
        let transfer = try await rig.transfer()
        let destination = rig.local.appendingPathComponent("remote.bin")
        try await bounded(.seconds(30)) {
            try await transfer.download(rig.homePath + "/remote.bin", to: destination) { _, _ in }
        }
        #expect(try sha256(destination) == sha256(remote))
        #expect(try directoryNames(rig.local) == [Array("remote.bin".utf8)])
        await rig.stop()
    }

    @Test func downloadReplacesAnExistingDestination() async throws {
        let rig = try await SFTPRig.start()
        let remote = rig.home.appendingPathComponent("remote.bin")
        try randomData(70_000).write(to: remote)
        let destination = rig.local.appendingPathComponent("remote.bin")
        try Data("old".utf8).write(to: destination)
        let transfer = try await rig.transfer()
        try await bounded {
            try await transfer.download(rig.homePath + "/remote.bin", to: destination) { _, _ in }
        }
        #expect(try sha256(destination) == sha256(remote))
        #expect(try directoryNames(rig.local) == [Array("remote.bin".utf8)])
        await rig.stop()
    }

    @Test func failedDownloadLeavesNoPartialFile() async throws {
        let rig = try await SFTPRig.start(dropConnectionAfterBytes: 1024 * 1024)
        let remote = rig.home.appendingPathComponent("remote.bin")
        try randomData(3 * 1024 * 1024).write(to: remote)
        let transfer = try await rig.transfer()
        let destination = rig.local.appendingPathComponent("remote.bin")
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded(.seconds(10)) {
                try await transfer.download(rig.homePath + "/remote.bin", to: destination) { _, _ in }
            }
        }
        #expect(try directoryNames(rig.local).isEmpty)
        await rig.stop()
    }

    @Test func cancelledDownloadLeavesNoPartialFile() async throws {
        let rig = try await SFTPRig.start()
        let remote = rig.home.appendingPathComponent("remote.bin")
        try randomData(8 * 1024 * 1024).write(to: remote)
        let transfer = try await rig.transfer()
        let destination = rig.local.appendingPathComponent("remote.bin")
        let task = Task {
            try await transfer.download(rig.homePath + "/remote.bin", to: destination) { done, _ in
                if done > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded(.seconds(20)) { try await task.value }
        }
        #expect(try directoryNames(rig.local).isEmpty)
        await rig.stop()
    }

    @Test func downloadOfAMissingFileThrowsAndCreatesNothing() async throws {
        let rig = try await SFTPRig.start()
        let transfer = try await rig.transfer()
        let destination = rig.local.appendingPathComponent("nothing")
        await #expect(throws: SSHError.self) {
            try await bounded {
                try await transfer.download(rig.homePath + "/nothing", to: destination) { _, _ in }
            }
        }
        #expect(try directoryNames(rig.local).isEmpty)
        await rig.stop()
    }

    // MARK: Session

    @Test func homeDirectoryIsRealpathOfDot() async throws {
        let rig = try await SFTPRig.start()
        let transfer = try await rig.transfer()
        #expect(try await bounded { try await transfer.homeDirectory() } == "/home/tester")
        await rig.stop()
    }

    @Test func existsSeesFilesAndDirectories() async throws {
        let rig = try await SFTPRig.start()
        try Data("x".utf8).write(to: rig.home.appendingPathComponent("here"))
        let transfer = try await rig.transfer()
        #expect(try await bounded { try await transfer.exists(rig.homePath + "/here") })
        #expect(try await bounded { try await transfer.exists(rig.homePath) })
        #expect(try await bounded { try await transfer.exists(rig.homePath + "/absent") } == false)
        await rig.stop()
    }

    @Test func noSFTPSubsystemIsSFTPUnavailable() async throws {
        let rig = try await SFTPRig.start(sftp: false)
        let connection = rig.connection
        await #expect(throws: SSHError.sftpUnavailable) {
            try await bounded { try await connection.fileTransfer() }
        }
        #expect(rig.server.record.subsystemRequests == ["sftp"])
        // The connection is still usable.
        _ = try await bounded { try await connection.openShell(term: "xterm-256color", columns: 80, rows: 24) }
        await rig.stop()
    }

    @Test func refusedSessionChannelIsSFTPUnavailable() async throws {
        // CHANNEL_OPEN_FAILURE for the session channel: a typed error, the connection still open.
        let rig = try await SFTPRig.start(refuseSessions: true)
        let connection = rig.connection
        await #expect(throws: SSHError.sftpUnavailable) {
            try await bounded { try await connection.fileTransfer() }
        }
        #expect(rig.server.record.subsystemRequests.isEmpty)
        let forward = try await bounded { try await connection.startLocalForward(localPort: 0, remoteHost: "localhost", remotePort: 9) }
        await forward.stop()
        await rig.stop()
    }

    @Test func closedTransfersReleaseTheirSessions() async throws {
        // The server allows 3 sessions at once; 15 transfers opened and closed in turn all work.
        let rig = try await SFTPRig.start(maxSessions: 3)
        let connection = rig.connection
        for _ in 0 ..< 15 {
            let transfer = try await bounded { try await connection.fileTransfer() }
            #expect(try await bounded { try await transfer.homeDirectory() } == "/home/tester")
            await transfer.close()
            await transfer.close()  // idempotent
            await #expect(throws: SSHError.connectionClosed) {
                try await bounded { try await transfer.homeDirectory() }
            }
        }
        #expect(rig.server.record.refusedSessions == 0)
        #expect(await pollAsync(within: .seconds(5)) { rig.server.record.openSessions == 0 })
        await rig.stop()
    }

    @Test func droppedTransferReleasesItsSession() async throws {
        let rig = try await SFTPRig.start()
        let connection = rig.connection
        do {
            let transfer = try await bounded { try await connection.fileTransfer() }
            _ = try await bounded { try await transfer.homeDirectory() }
        }
        // The last reference is gone: deinit closed the channel.
        #expect(await pollAsync(within: .seconds(5)) { rig.server.record.openSessions == 0 })
        await rig.stop()
    }

    @Test func concurrentLookupsShareOneControlChannel() async throws {
        let rig = try await SFTPRig.start()
        let transfer = try await rig.transfer()
        // Make the control channel need reopening, then ask from many tasks at once.
        await transfer.dropControlChannelForTests()
        #expect(await pollAsync(within: .seconds(5)) { rig.server.record.openSessions == 0 })
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await transfer.exists(rig.homePath) }
            }
            for try await found in group { #expect(found) }
        }
        #expect(rig.server.record.openSessions == 1)
        await rig.stop()
    }

    @Test func closedConnectionIsConnectionClosed() async throws {
        let rig = try await SFTPRig.start()
        let transfer = try await rig.transfer()
        await rig.connection.close()
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded { try await transfer.homeDirectory() }
        }
        await #expect(throws: SSHError.connectionClosed) {
            try await bounded { try await rig.connection.fileTransfer() }
        }
        await rig.stop()
    }
}

// MARK: - Support

/// A `TestSSHServer` with the `sftp` subsystem on a temporary `root` (remote `/home/tester` is
/// `home`), a connected `SSHConnection`, and an empty local directory.
private struct SFTPRig {
    let server: TestSSHServer
    let connection: SSHConnection
    /// The served directory, resolved (`/private/var/…`).
    let root: URL
    let home: URL
    let homePath = "/home/tester"
    /// The local side's directory.
    let local: URL

    static func start(
        sftp: Bool = true, dropConnectionAfterBytes: Int64? = nil, failWritesAfterBytes: Int64? = nil, refuseSessions: Bool = false,
        maxSessions: Int? = nil
    ) async throws -> SFTPRig {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("sshkit-sftp-\(UUID().uuidString)")
        let root = base.appendingPathComponent("remote")
        let home = root.appendingPathComponent("home/tester")
        let local = base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let options = sftp ? TestSFTPOptions(root: root, dropConnectionAfterBytes: dropConnectionAfterBytes, failWritesAfterBytes: failWritesAfterBytes) : nil
        let server = try await TestSSHServer.start(.init(sftp: options, refuseSessions: refuseSessions, maxSessions: maxSessions))
        // No keepalive: a dropped connection must be seen from the TCP close, not a missed reply.
        let connection = SSHConnection(host: "127.0.0.1", port: server.port, keepalive: .init(interval: .zero))
        try await bounded {
            try await connection.open(credentials: .password(user: "tester", password: "s3cret"), timeout: .seconds(5)) { _ in true }
        }
        return SFTPRig(server: server, connection: connection, root: root, home: home, local: local)
    }

    func transfer() async throws -> SSHFileTransfer {
        let connection = self.connection
        return try await bounded { try await connection.fileTransfer() }
    }

    /// A local file of `bytes` random bytes.
    func makeLocalFile(_ name: String, bytes: Int) throws -> URL {
        let url = local.appendingPathComponent(name)
        try randomData(bytes).write(to: url)
        return url
    }

    /// The names in the remote home directory, as `readdir` returns them.
    func remoteNames() -> [[UInt8]] {
        (try? directoryNames(home)) ?? []
    }

    func stop() async {
        await connection.close()
        await server.stop()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// The entry names of `directory` as `readdir` returns their bytes (`.` and `..` left out), sorted.
private func directoryNames(_ directory: URL) throws -> [[UInt8]] {
    guard let handle = directory.path.withCString({ opendir($0) }) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { closedir(handle) }
    var names: [[UInt8]] = []
    while let entry = readdir(handle) {
        var name = entry.pointee.d_name
        let length = Int(entry.pointee.d_namlen)
        let bytes = withUnsafeBytes(of: &name) { Array($0.prefix(length)) }
        if bytes != [0x2E], bytes != [0x2E, 0x2E] { names.append(bytes) }
    }
    return names.sorted { $0.lexicographicallyPrecedes($1) }
}

/// Every path under `directory`, relative, sorted.
private func treeNames(_ directory: URL) throws -> [String] {
    (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []).sorted()
}

private func fileMode(_ url: URL) throws -> mode_t {
    var info = Darwin.stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return info.st_mode & 0o7777
}

private func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        var index = 0
        while index < buffer.count {
            withUnsafeBytes(of: generator.next()) { word in
                for byte in word where index < buffer.count {
                    buffer[index] = byte
                    index += 1
                }
            }
        }
    }
    return data
}

private func sha256(_ url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url)))
}

/// The progress calls of one transfer.
private final class ProgressLog: Sendable {
    private let state = Mutex<[(done: Int64, total: Int64)]>([])

    func append(_ done: Int64, _ total: Int64) {
        state.withLock { $0.append((done, total)) }
    }

    var calls: [(done: Int64, total: Int64)] { state.withLock { $0 } }

    /// `done` never decreases, never passes `total`, and the last call is (size, size).
    func expectMonotonicEnding(at size: Int64, sourceLocation: SourceLocation = #_sourceLocation) {
        let calls = self.calls
        #expect(zip(calls, calls.dropFirst()).allSatisfy { $0.done <= $1.done }, sourceLocation: sourceLocation)
        #expect(calls.allSatisfy { $0.done <= $0.total }, sourceLocation: sourceLocation)
        #expect(calls.last?.done == size && calls.last?.total == size, sourceLocation: sourceLocation)
    }
}
