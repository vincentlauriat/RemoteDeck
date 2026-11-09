import Citadel
import Darwin
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization

extension SSHConnection {
    /// Opens an SFTP session on this connection: a session channel with the `sftp` subsystem
    /// (what `scp` uses on current OpenSSH).
    ///
    /// - Throws `.sftpUnavailable` when the server refuses the subsystem, or closes the channel
    ///   before the SFTP version exchange; the connection stays usable.
    /// - Throws `.connectionClosed` if the connection is not open, `.timedOut` if the server does
    ///   not answer within `SSHFileTransfer.openTimeout`.
    public func fileTransfer() async throws(SSHError) -> SSHFileTransfer {
        let control = try await openSFTPClient()
        return SSHFileTransfer(connection: self, control: control)
    }

    /// One SFTP channel, ready (version 3 agreed). Cancelling the calling task abandons the open
    /// (`.connectionClosed`).
    func openSFTPClient() async throws(SSHError) -> SFTPClient {
        guard let (loop, ssh) = forwardingContext() else { throw .connectionClosed }
        let ready = loop.makePromise(of: SFTPClient.self)
        loop.execute {
            let created = loop.makePromise(of: (any Channel).self)
            let accepted = loop.makePromise(of: Void.self)
            ssh.value.createChannel(created, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SFTPSubsystemRequest(accepted: accepted))
                }
            }
            created.futureResult.flatMap { child in
                accepted.futureResult.flatMap { RemoteDeckSFTP.attachClient(to: child) }
            }.cascade(to: ready)
            let timer = loop.scheduleTask(in: TimeAmount(SSHFileTransfer.openTimeout)) {
                ready.fail(SSHError.timedOut)
            }
            ready.futureResult.whenComplete { result in
                timer.cancel()
                // A failed or abandoned open closes its channel, and completes `accepted`, which
                // only the channel's handler completes otherwise (never, if the channel was refused).
                if case .failure = result {
                    accepted.fail(SSHError.connectionClosed)
                    created.futureResult.whenSuccess { $0.close(promise: nil) }
                }
            }
        }

        let result: Result<SFTPClient, any Error> = await withTaskCancellationHandler {
            do {
                return .success(try await ready.futureResult.get())
            } catch {
                return .failure(error)
            }
        } onCancel: {
            ready.fail(SSHError.connectionClosed)
        }
        switch result {
        case .success(let client):
            return client
        case .failure(let error as SSHError):
            throw error
        case .failure:
            // The channel was refused, or closed before the SFTP version exchange.
            throw forwardingContext() == nil ? .connectionClosed : .sftpUnavailable
        }
    }
}

/// SFTP on one SSH connection, opened by `SSHConnection.fileTransfer()`: `scp`-like upload and
/// download of single files.
///
/// - Every transfer runs on its own SFTP channel, so cancelling one leaves the others and this
///   object usable; lookups and clean-up go through a shared channel, reopened if it closed.
/// - Cancelling the task that runs `upload` or `download` stops it at once: its channel is closed
///   (a server that stopped answering cannot hold it), the partial file is removed, and the call
///   throws `.connectionClosed`, as `SSHConnection.open` does on cancellation.
/// - Errors the server reports (permission denied, disk full) are `.remote` with its status; a
///   local file that cannot be read or written is `.remote` too, with the local path.
/// - Single requests have no timeout of their own: a server that stops answering mid-request is
///   ended by the connection's keepalive (`SSHKeepalive`), which fails the call with
///   `.connectionClosed`.
public actor SSHFileTransfer {
    /// How long opening an SFTP channel may take, version exchange included.
    static let openTimeout: Duration = .seconds(15)
    /// Bytes per SSH_FXP_WRITE / SSH_FXP_READ: one SSH packet each (Citadel's own slice size).
    static let chunkSize = 32_000
    /// Requests in flight per transfer: 16 x 32,000 bytes, so a fast link is not limited to one
    /// round trip per chunk, and neither side buffers without bound.
    static let maxOutstanding = 16
    /// Appended to the target's name while an upload or download is in progress.
    static let partSuffix = ".remotedeck-part"
    /// How long removing a partial remote file may take after a failure.
    static let cleanupTimeout: Duration = .seconds(5)

    private let connection: SSHConnection
    /// For lookups and clean-up; reopened when it closed (a cancelled transfer never closes it).
    private var control: SFTPClient?

    init(connection: SSHConnection, control: SFTPClient) {
        self.connection = connection
        self.control = control
    }

    /// The directory the server starts in: `realpath(".")`, the user's home on OpenSSH.
    public func homeDirectory() async throws(SSHError) -> String {
        let client = try await controlClient()
        do {
            return try await client.getRealPath(atPath: ".")
        } catch {
            throw Self.sshError(error)
        }
    }

    /// Whether `remotePath` exists (a file, a directory, or anything else `stat` follows to).
    public func exists(_ remotePath: String) async throws(SSHError) -> Bool {
        try await attributes(remotePath) != nil
    }

    /// Uploads the local file `local` into the remote directory `toDirectory`, under the local
    /// file's name, byte for byte as the local file system spells it (no Unicode normalization).
    ///
    /// - Throws `.noSuchDirectory(toDirectory)` if it does not exist or is not a directory, and
    ///   `.fileExists(target)` if the target exists and `overwrite` is false; nothing is written.
    /// - The bytes go to `<target>.remotedeck-part`, renamed onto the target once all are written:
    ///   the target never holds a partial file. Any failure removes the part file (best effort,
    ///   over the shared channel, never hiding the original error); a lost connection cannot.
    /// - Overwriting removes the existing target, then renames: SFTP v3's rename refuses an
    ///   existing target, and OpenSSH's atomic `posix-rename@openssh.com` extension is not
    ///   available in the SFTP code used. The moment between the two is the only one at which the
    ///   target name is missing; if the rename then fails, the part file is kept, since it is then
    ///   the only complete copy.
    /// - `progress(done, total)` follows the bytes the server acknowledged: `done` only grows, and
    ///   the last call is `(size, size)`, `(0, 0)` for an empty file.
    public func upload(_ local: URL, toDirectory: String, overwrite: Bool, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
        let source = try LocalSource(local)
        defer { source.close() }

        let directory = try await attributes(toDirectory)
        // A server that sent no mode is trusted: the open of the part file then fails if need be.
        guard let directory, directory.isDirectory != false else { throw .noSuchDirectory(toDirectory) }
        let target = Self.join(toDirectory, source.name)
        let part = target + Self.partSuffix
        let targetExists = try await attributes(target) != nil
        if targetExists, !overwrite { throw .fileExists(target) }

        let channel = try await connection.openSFTPClient()
        defer { channel.remoteDeckCloseChannel() }
        var partCreated = false
        var targetRemoved = false
        do {
            try await withTaskCancellationHandler {
                // Set before the request: a server can still create the file after a cancel closed
                // the channel under it, and removing a file that does not exist is harmless.
                partCreated = true
                let handle = try await channel.remoteDeckOpen(part, flags: [.write, .create, .truncate])
                do {
                    try await Self.write(source, to: channel, handle: handle, progress: progress)
                } catch {
                    try? await channel.remoteDeckClose(handle)
                    throw error
                }
                try await channel.remoteDeckClose(handle)
                try Task.checkCancellation()
            } onCancel: {
                channel.remoteDeckCloseChannel()
            }
            let control = try await controlClient()
            if targetExists {
                do {
                    try await control.remove(at: target)
                } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {}
                targetRemoved = true
            }
            do {
                try await control.rename(at: part, to: target)
            } catch {
                if !overwrite, try await attributes(target) != nil { throw SSHError.fileExists(target) }
                throw error
            }
        } catch {
            let failure = Task.isCancelled ? .connectionClosed : Self.sshError(error, channel: channel)
            if partCreated, !targetRemoved {
                await removeRemote(part)
            }
            throw failure
        }
    }

    /// Downloads the remote file `remotePath` to `local`, replacing it if it exists.
    ///
    /// - The bytes go to `<local>.remotedeck-part` next to it, renamed onto `local` once complete
    ///   (an atomic replace): a failure, or a cancellation, removes the part file and leaves no
    ///   partial `local`.
    /// - The size copied is the one `stat` gave when the download started (as `scp` does); a
    ///   file that shrank meanwhile fails the download.
    /// - `progress(done, total)`: as for `upload`, over the bytes written locally.
    public func download(_ remotePath: String, to local: URL, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError) {
        guard let attributes = try await attributes(remotePath) else {
            throw .remote("no such remote file: \(remotePath)")
        }
        if attributes.isDirectory == true { throw .remote("not a file: \(remotePath)") }
        let destination = try LocalDestination(local)

        let channel: SFTPClient
        do {
            channel = try await connection.openSFTPClient()
        } catch {
            destination.discard()
            throw error
        }
        defer { channel.remoteDeckCloseChannel() }
        do {
            try await withTaskCancellationHandler {
                let handle = try await channel.remoteDeckOpen(remotePath, flags: .read)
                do {
                    try await Self.read(channel, handle: handle, size: attributes.size, into: destination, progress: progress)
                } catch {
                    try? await channel.remoteDeckClose(handle)
                    throw error
                }
                try? await channel.remoteDeckClose(handle)
                try Task.checkCancellation()
            } onCancel: {
                channel.remoteDeckCloseChannel()
            }
            try destination.commit()
        } catch {
            destination.discard()
            throw Task.isCancelled ? .connectionClosed : Self.sshError(error, channel: channel)
        }
    }

    // MARK: Transfers

    /// Writes all of `source` with up to `maxOutstanding` writes in flight.
    private static func write(_ source: LocalSource, to client: SFTPClient, handle: ByteBuffer, progress: @Sendable (Int64, Int64) -> Void) async throws {
        let size = source.size
        var acknowledged: Int64 = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            var offset: Int64 = 0
            var inFlight = 0
            var atEnd = false
            while true {
                while !atEnd, inFlight < maxOutstanding {
                    try Task.checkCancellation()
                    let chunk = try source.read(at: offset, count: chunkSize)
                    guard chunk.readableBytes > 0 else {
                        atEnd = true
                        break
                    }
                    let at = UInt64(offset)
                    group.addTask {
                        try await client.remoteDeckWrite(handle, offset: at, data: chunk)
                        return chunk.readableBytes
                    }
                    offset += Int64(chunk.readableBytes)
                    inFlight += 1
                }
                guard let written = try await group.next() else { break }
                inFlight -= 1
                acknowledged += Int64(written)
                progress(acknowledged, max(size, acknowledged))
            }
        }
        // (size, size) last; a file that changed size while read ends at what was sent.
        if acknowledged == 0 || acknowledged != size {
            progress(acknowledged, acknowledged)
        }
    }

    /// Reads `size` bytes (to end of file when the server gave no size) into `destination`, with
    /// up to `maxOutstanding` reads in flight; a short read asks again for the rest.
    private static func read(_ client: SFTPClient, handle: ByteBuffer, size: UInt64?, into destination: LocalDestination, progress: @Sendable (Int64, Int64) -> Void) async throws {
        guard let size else {
            try await readToEnd(client, handle: handle, into: destination, progress: progress)
            return
        }
        let total = Int64(size)
        var written: Int64 = 0
        try await withThrowingTaskGroup(of: (offset: UInt64, length: UInt32, data: ByteBuffer).self) { group in
            var next: UInt64 = 0
            var gaps: [(offset: UInt64, length: UInt32)] = []
            var inFlight = 0
            while true {
                while inFlight < maxOutstanding {
                    try Task.checkCancellation()
                    let request: (offset: UInt64, length: UInt32)
                    if !gaps.isEmpty {
                        request = gaps.removeFirst()
                    } else if next < size {
                        request = (next, UInt32(min(UInt64(chunkSize), size - next)))
                        next += UInt64(request.length)
                    } else {
                        break
                    }
                    group.addTask {
                        (request.offset, request.length, try await client.remoteDeckRead(handle, offset: request.offset, length: request.length))
                    }
                    inFlight += 1
                }
                guard let reply = try await group.next() else { break }
                inFlight -= 1
                let count = reply.data.readableBytes
                guard count > 0 else { throw SSHError.remote("the remote file shrank during the download") }
                try destination.write(reply.data, at: reply.offset)
                written += Int64(count)
                progress(written, total)
                if count < Int(reply.length) {
                    gaps.append((reply.offset + UInt64(count), reply.length - UInt32(count)))
                }
            }
        }
        if total == 0 { progress(0, 0) }
    }

    /// One read at a time to end of file, for a server that sent no size.
    private static func readToEnd(_ client: SFTPClient, handle: ByteBuffer, into destination: LocalDestination, progress: @Sendable (Int64, Int64) -> Void) async throws {
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await client.remoteDeckRead(handle, offset: offset, length: UInt32(chunkSize))
            guard data.readableBytes > 0 else { break }
            try destination.write(data, at: offset)
            offset += UInt64(data.readableBytes)
            progress(Int64(offset), Int64(offset))
        }
        if offset == 0 { progress(0, 0) }
    }

    // MARK: Helpers

    private func controlClient() async throws(SSHError) -> SFTPClient {
        if let control, control.isActive { return control }
        control = nil
        let client = try await connection.openSFTPClient()
        control = client
        return client
    }

    /// `stat` of `path`; nil when it does not exist.
    private func attributes(_ path: String) async throws(SSHError) -> SFTPFileAttributes? {
        let client = try await controlClient()
        do {
            return try await client.getAttributes(at: path)
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return nil
        } catch {
            throw Self.sshError(error)
        }
    }

    /// Removes a partial remote file, best effort: errors are ignored, and the wait is bounded by
    /// `cleanupTimeout` (a pending SFTP request cannot be cancelled, so the wait is a race). Runs
    /// in tasks of its own, so it is not cut short when the caller's task is cancelled.
    private func removeRemote(_ path: String) async {
        let timeout = Self.cleanupTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Mutex(false)
            let finish: @Sendable () -> Void = {
                if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume() }
            }
            Task {
                if let client = try? await self.controlClient() {
                    try? await client.remove(at: path)
                }
                finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                finish()
            }
        }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// The library's errors as `SSHError`. Any failure other than a server status, once the
    /// transfer's channel is closed, is the connection's end.
    static func sshError(_ error: any Error, channel: SFTPClient) -> SSHError {
        let mapped = sshError(error)
        if case .remote = mapped, !(error is SFTPMessage.Status), !channel.isActive { return .connectionClosed }
        return mapped
    }

    /// The library's errors as `SSHError`.
    static func sshError(_ error: any Error) -> SSHError {
        switch error {
        case let error as SSHError:
            return error
        case is CancellationError:
            return .connectionClosed
        case let status as SFTPMessage.Status:
            return .remote("SFTP \(status.errorCode.debugDescription)\(status.message.isEmpty ? "" : ": \(status.message)")")
        case SFTPError.connectionClosed, SFTPError.missingResponse:
            return .connectionClosed
        case let error as NIOSSHError where error.type == .tcpShutdown:
            // The TCP connection under the SFTP channel ended.
            return .connectionClosed
        case is IOError:
            // A socket error (EPIPE, ECONNRESET): the TCP connection broke.
            return .connectionClosed
        case let error as ChannelError where [.ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed].contains(error):
            return .connectionClosed
        default:
            return .remote(String(describing: error))
        }
    }
}

extension SFTPFileAttributes {
    /// Whether `permissions` carries the directory type; nil when the server sent no mode.
    var isDirectory: Bool? {
        permissions.map { $0 & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    }
}

// MARK: - Channel setup

/// First on a new session channel: asks for the `sftp` subsystem, and completes `accepted` on the
/// server's answer (the outbound event's promise only says the request was written). A refusal,
/// or the channel closing first, is `.sftpUnavailable` (`.connectionClosed` if the connection
/// went with it).
private final class SFTPSubsystemRequest: ChannelInboundHandler {
    typealias InboundIn = Any

    private let accepted: EventLoopPromise<Void>
    private var started = false
    private var answered = false

    init(accepted: EventLoopPromise<Void>) {
        self.accepted = accepted
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { start(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    private func start(context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard !answered else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        switch event {
        case is ChannelSuccessEvent:
            answered = true
            accepted.succeed(())
        case is ChannelFailureEvent:
            answered = true
            accepted.fail(SSHError.sftpUnavailable)
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(context: context)
        context.fireChannelInactive()
    }

    /// A channel torn down without ever becoming active.
    func handlerRemoved(context: ChannelHandlerContext) {
        fail(context: context)
    }

    private func fail(context: ChannelHandlerContext) {
        guard !answered else { return }
        answered = true
        accepted.fail(context.channel.parent?.isActive == true ? SSHError.sftpUnavailable : SSHError.connectionClosed)
    }
}

// MARK: - Local files

/// The local file of an upload, read with `pread` (never loaded whole).
private final class LocalSource: Sendable {
    let fd: Int32
    let size: Int64
    /// The file's name as its path's file system representation spells it.
    let name: String
    let path: String

    init(_ url: URL) throws(SSHError) {
        path = url.path
        let representation = url.withUnsafeFileSystemRepresentation { $0.map { Array(UnsafeBufferPointer(start: $0, count: strlen($0))) } }
        guard let bytes = representation?.map(UInt8.init(bitPattern:)),
              let last = bytes.split(separator: UInt8(ascii: "/")).last, !last.isEmpty
        else { throw .remote("cannot read \(url.path)") }
        name = String(decoding: last, as: UTF8.self)
        let fd = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { throw .remote("cannot read \(url.path): \(String(cString: strerror(errno)))") }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw .remote("not a regular file: \(url.path)")
        }
        self.fd = fd
        size = Int64(info.st_size)
    }

    /// Up to `count` bytes at `offset`; empty at end of file.
    func read(at offset: Int64, count: Int) throws -> ByteBuffer {
        var buffer = ByteBuffer()
        var result = 0
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: count) { pointer in
            result = pread(fd, pointer.baseAddress, count, off_t(offset))
            return max(0, result)
        }
        if result < 0 {
            throw SSHError.remote("cannot read \(path): \(String(cString: strerror(errno)))")
        }
        return buffer
    }

    func close() {
        Darwin.close(fd)
    }
}

/// The part file of a download, next to its destination, renamed onto it by `commit`.
private final class LocalDestination: Sendable {
    let fd: Int32
    let destination: String
    let part: String
    private let closed = Mutex(false)

    init(_ url: URL) throws(SSHError) {
        destination = url.path
        part = url.path + SSHFileTransfer.partSuffix
        let fd = part.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666) }
        guard fd >= 0 else { throw .remote("cannot write \(part): \(String(cString: strerror(errno)))") }
        self.fd = fd
    }

    func write(_ data: ByteBuffer, at offset: UInt64) throws {
        let ok = data.withUnsafeReadableBytes { bytes in
            var done = 0
            while done < bytes.count {
                let count = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
                guard count > 0 else { return false }
                done += count
            }
            return true
        }
        if !ok { throw SSHError.remote("cannot write \(part): \(String(cString: strerror(errno)))") }
    }

    /// Closes the part file and renames it onto the destination (replacing it atomically).
    func commit() throws {
        guard closeOnce() else {
            unlinkPart()
            throw SSHError.remote("cannot write \(part): \(String(cString: strerror(errno)))")
        }
        let renamed = part.withCString { old in destination.withCString { rename(old, $0) } } == 0
        if !renamed {
            let reason = String(cString: strerror(errno))
            unlinkPart()
            throw SSHError.remote("cannot write \(destination): \(reason)")
        }
    }

    /// Closes and removes the part file.
    func discard() {
        _ = closeOnce()
        unlinkPart()
    }

    /// Closes the descriptor the first time only (a second close could hit a reused number);
    /// false if that close failed.
    private func closeOnce() -> Bool {
        guard closed.withLock({ done in defer { done = true }; return !done }) else { return true }
        return Darwin.close(fd) == 0
    }

    private func unlinkPart() {
        _ = part.withCString { unlink($0) }
    }
}
