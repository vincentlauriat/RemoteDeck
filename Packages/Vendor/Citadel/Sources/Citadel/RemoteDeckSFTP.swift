// Added for RemoteDeck (see Packages/Vendor/PATCHES.md). Part of the vendored Citadel, under its
// MIT licence (`LICENSE`).
//
// Citadel reaches its SFTP client only through `SSHClient.openSFTP()` and its SFTP server only
// through `SSHServer`. RemoteDeck's SSHKit drives swift-nio-ssh itself (no `SSHClient`), so this
// file attaches Citadel's existing SFTP protocol code to a channel SSHKit already opened, and
// installs Citadel's SFTP server on a channel of SSHKit's test server. No protocol code is new.

import Logging
import NIO
import NIOSSH

/// Entry points onto Citadel's SFTP client and server for an SSH channel opened elsewhere.
public enum RemoteDeckSFTP {
    /// Attaches Citadel's SFTP client to `channel`: a session channel on which the server already
    /// accepted the `sftp` subsystem. Sends `SSH_FXP_INIT` (version 3) and succeeds once the
    /// server's `SSH_FXP_VERSION` arrived; fails if the channel closes first or the version is
    /// not 3. Call it on `channel`'s event loop.
    ///
    /// The client logs nothing: the logger is a no-op, so file names never reach a log.
    public static func attachClient(to channel: Channel) -> EventLoopFuture<SFTPClient> {
        let logger = Logger(label: "remotedeck.sftp", factory: { _ in SwiftLogNoOpLogHandler() })
        return SFTPClient.setupChannelHanders(channel: channel, logger: logger).flatMap { client in
            client.channel.writeAndFlush(SFTPMessage.initialize(.init(version: .v3))).flatMap {
                client.responses.sftpVersion.futureResult
            }.flatMapThrowing { version in
                guard version.version == .v3 else { throw SFTPError.unsupportedVersion(version.version) }
                return client
            }
        }
    }

    /// Installs Citadel's SFTP server on `channel` (a session channel whose `sftp` subsystem
    /// request is being accepted), answering with `delegate`. For tests. Call it on `channel`'s
    /// event loop, before replying to the subsystem request.
    public static func installServer(on channel: Channel, delegate: SFTPDelegate, username: String?) -> EventLoopFuture<Void> {
        let logger = Logger(label: "remotedeck.sftp-server", factory: { _ in SwiftLogNoOpLogHandler() })
        return SFTPServerSubsystem.setupChannelHanders(channel: channel, sftp: delegate, logger: logger, username: username)
    }
}

/// A status a server `SFTPDelegate` can throw: the request is answered with this code (see the
/// `SFTPServerInboundHandler` patch in PATCHES.md).
extension SFTPStatusCode: Error {}

// MARK: - Handle-level client requests

/// One request per call, with the file handle as the server gave it, so a caller can keep several
/// reads or writes in flight (`SFTPFile` sends one at a time, and is not `Sendable`). A non-`ok`
/// status is thrown as `SFTPMessage.Status`.
extension SFTPClient {
    /// `SSH_FXP_OPEN`; returns the handle.
    public func remoteDeckOpen(_ path: String, flags: SFTPOpenFileFlags, attributes: SFTPFileAttributes = .none) async throws -> ByteBuffer {
        let response = try await sendRequest(.openFile(.init(
            requestId: allocateRequestId(), filePath: path, pFlags: flags, attributes: attributes
        )))
        guard case .handle(let handle) = response else { throw SFTPError.invalidResponse }
        return handle.handle
    }

    /// `SSH_FXP_CLOSE`.
    public func remoteDeckClose(_ handle: ByteBuffer) async throws {
        let response = try await sendRequest(.closeFile(.init(requestId: allocateRequestId(), handle: handle)))
        guard case .status(let status) = response else { throw SFTPError.invalidResponse }
        guard status.errorCode == .ok else { throw status }
    }

    /// `SSH_FXP_READ` of at most `length` bytes at `offset`; an empty buffer at end of file.
    public func remoteDeckRead(_ handle: ByteBuffer, offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        let response = try await sendRequest(.read(.init(
            requestId: allocateRequestId(), handle: handle, offset: offset, length: length
        )))
        switch response {
        case .data(let data): return data.data
        case .status(let status) where status.errorCode == .eof: return ByteBuffer()
        case .status(let status): throw status
        default: throw SFTPError.invalidResponse
        }
    }

    /// `SSH_FXP_WRITE` of `data` at `offset`, in one request: the caller keeps `data` small enough
    /// for one SSH packet (Citadel's own `SFTPFile.write` slices at 32,000 bytes).
    public func remoteDeckWrite(_ handle: ByteBuffer, offset: UInt64, data: ByteBuffer) async throws {
        let response = try await sendRequest(.write(.init(
            requestId: allocateRequestId(), handle: handle, offset: offset, data: data
        )))
        guard case .status(let status) = response else { throw SFTPError.invalidResponse }
        guard status.errorCode == .ok else { throw status }
    }

    /// Closes the SFTP channel without waiting: every request in flight fails at once with
    /// `SFTPError.connectionClosed`. Safe from any thread, and more than once.
    public func remoteDeckCloseChannel() {
        channel.close(promise: nil)
    }
}

// MARK: - Server error replies

extension SFTPServerInboundHandler {
    /// Answers request `requestId` with `SSH_FXP_STATUS` after its delegate threw: the code the
    /// error carries (`SFTPStatusCode`, `SFTPMessage.Status`), else `SSH_FX_FAILURE`.
    func remoteDeckReplyStatus(for error: Error, requestId: UInt32, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let code = (error as? SFTPStatusCode) ?? (error as? SFTPMessage.Status)?.errorCode ?? .failure
        return context.channel.writeAndFlush(SFTPMessage.status(.init(
            requestId: requestId, errorCode: code, message: "", languageTag: "EN"
        )))
    }
}
