import Citadel
import Darwin
import Foundation
import NIOCore

/// The `sftp` subsystem of `TestSSHServer`: Citadel's SFTP server answering from a real directory.
struct TestSFTPOptions: Sendable {
    /// The real directory served as the remote `/`. Use a resolved path (`/private/var/…`).
    var root: URL
    /// The remote home directory (`realpath(".")`), relative paths resolve against it. The rig
    /// creates it.
    var home = "/home/tester"
    /// A read or write reaching past this many bytes of a file closes the whole TCP connection
    /// before it is applied: a network drop mid-transfer.
    var dropConnectionAfterBytes: Int64?
    /// A write reaching past this many bytes is answered with SSH_FX_FAILURE (disk full); the
    /// connection and the SFTP channel stay up.
    var failWritesAfterBytes: Int64?
}

/// File operations on `options.root`, through POSIX calls on the paths' own UTF-8 bytes (no
/// Foundation path API, which could normalize names). Errors are thrown as `SFTPStatusCode`, which
/// the patched Citadel server answers as SSH_FXP_STATUS. RENAME refuses an existing target, as
/// OpenSSH's SFTP v3 rename does.
final class TestSFTPDelegate: SFTPDelegate {
    let options: TestSFTPOptions
    /// The server's TCP connection, closed by `dropConnectionAfterBytes`.
    let connection: any Channel

    init(options: TestSFTPOptions, connection: any Channel) {
        self.options = options
        self.connection = connection
    }

    /// `path` as a remote absolute path: resolved against `home`, `.` and `..` removed (never above `/`).
    func virtualPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : options.home + "/" + path
        var components: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { _ = components.popLast(); continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    func realPath(_ path: String) -> String {
        options.root.path + virtualPath(path)
    }

    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        var info = Darwin.stat()
        guard realPath(path).withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { throw Self.status(errno) }
        return Self.attributes(info)
    }

    func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
        var mode: Int32 = flags.contains(.read) && flags.contains(.write) ? O_RDWR : flags.contains(.write) ? O_WRONLY : O_RDONLY
        if flags.contains(.create) { mode |= O_CREAT }
        if flags.contains(.truncate) { mode |= O_TRUNC }
        if flags.contains(.forceCreate) { mode |= O_EXCL }
        if flags.contains(.append) { mode |= O_APPEND }
        let fd = realPath(filePath).withCString { Darwin.open($0, mode, 0o644) }
        guard fd >= 0 else { throw Self.status(errno) }
        return TestSFTPFile(fd: fd, options: options, connection: connection)
    }

    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        realPath(filePath).withCString { unlink($0) } == 0 ? .ok : Self.status(errno)
    }

    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode {
        realPath(filePath).withCString { mkdir($0, 0o755) } == 0 ? .ok : Self.status(errno)
    }

    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        realPath(filePath).withCString { rmdir($0) } == 0 ? .ok : Self.status(errno)
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let path = virtualPath(canonicalUrl)
        return [SFTPPathComponent(filename: path, longname: path, attributes: .none)]
    }

    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        throw SFTPStatusCode.unsupportedOperation
    }

    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode {
        .ok
    }

    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode {
        .unsupportedOperation
    }

    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        throw SFTPStatusCode.unsupportedOperation
    }

    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        let target = realPath(newPath)
        var info = Darwin.stat()
        if target.withCString({ lstat($0, &info) }) == 0 { return .failure }
        return realPath(oldPath).withCString { old in target.withCString { Darwin.rename(old, $0) } } == 0 ? .ok : Self.status(errno)
    }

    static func status(_ code: Int32) -> SFTPStatusCode {
        switch code {
        case ENOENT, ENOTDIR: .noSuchFile
        case EACCES, EPERM: .permissionDenied
        default: .failure
        }
    }

    static func attributes(_ info: Darwin.stat) -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes(size: UInt64(info.st_size))
        attributes.permissions = UInt32(info.st_mode)
        return attributes
    }
}

/// An open file of `TestSFTPDelegate`.
final class TestSFTPFile: SFTPFileHandle, Sendable {
    let fd: Int32
    let options: TestSFTPOptions
    let connection: any Channel

    init(fd: Int32, options: TestSFTPOptions, connection: any Channel) {
        self.fd = fd
        self.options = options
        self.connection = connection
    }

    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        var bytes = [UInt8](repeating: 0, count: Int(min(length, 256 * 1024)))
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
        guard count >= 0 else { throw TestSFTPDelegate.status(errno) }
        if let limit = options.dropConnectionAfterBytes, Int64(offset) + Int64(count) > limit {
            connection.close(promise: nil)
            throw SFTPStatusCode.connectionLost
        }
        return ByteBuffer(bytes: bytes.prefix(count))
    }

    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        let end = Int64(offset) + Int64(data.readableBytes)
        if let limit = options.dropConnectionAfterBytes, end > limit {
            connection.close(promise: nil)
            return .connectionLost
        }
        if let limit = options.failWritesAfterBytes, end > limit { return .failure }
        let written = data.withUnsafeReadableBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(offset)) }
        return written == data.readableBytes ? .ok : .failure
    }

    func close() async throws -> SFTPStatusCode {
        Darwin.close(fd) == 0 ? .ok : .failure
    }

    func readFileAttributes() async throws -> SFTPFileAttributes {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw TestSFTPDelegate.status(errno) }
        return TestSFTPDelegate.attributes(info)
    }

    func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
}
