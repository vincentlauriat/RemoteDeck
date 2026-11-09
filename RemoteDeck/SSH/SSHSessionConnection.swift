import Foundation
import SSHKit

// MARK: - Connection protocol

/// One SSH connection as a terminal session uses it (TRD › Architecture › SSH): `SSHConnection` in the
/// app, `FakeSSHSessionConnection` in the hosted tests (which never open a socket). A new instance
/// per attempt, as `SSHConnection.open` runs once.
protocol SSHSessionConnection: AnyObject, Sendable {
    /// Connects and authenticates (`SSHConnection.open`): `validateHostKey` is awaited during key
    /// exchange, before anything is sent to authenticate; its time is not counted in `timeout`, and
    /// its task is cancelled when the connection dies.
    func open(credentials: SSHCredentials, timeout: Duration,
              validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError)
    /// A shell on a pseudo-terminal of `columns` x `rows`, with `TERM` = `term`.
    func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> any SSHShellChannel
    /// A local port forward on 127.0.0.1 and [::1] (Task 11).
    func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError)
        -> any LocalForwarding
    /// An SFTP session (Task 12).
    func fileTransfer() async throws(SSHError) -> any FileTransferring
    /// Closes the connection and its forwards; never waits for the peer.
    func close() async
    /// Yields once when the connection ends: nil after `close()`, the error otherwise (a re-key that
    /// presented another host key is `.hostKeyRejected(newKey)`). Single consumer.
    var closed: AsyncStream<SSHError?> { get }
}

/// `SSHShell`: the shell's output and input. Closing the shell is ending the iteration of `output`
/// (cancelling the task that reads it), as `SSHShell` closes its channel then.
protocol SSHShellChannel: AnyObject, Sendable {
    /// Single consumer, unbounded: it must be drained (`TerminalOutputCoalescer`).
    var output: AsyncThrowingStream<Data, any Error> { get }
    func write(_ data: Data) async throws(SSHError)
    func resize(columns: Int, rows: Int) async
}

/// `LocalForwardHandle`.
protocol LocalForwarding: AnyObject, Sendable {
    var localPort: UInt16 { get }
    func stop() async
}

/// `SSHFileTransfer`.
protocol FileTransferring: AnyObject, Sendable {
    func homeDirectory() async throws(SSHError) -> String
    func exists(_ remotePath: String) async throws(SSHError) -> Bool
    func upload(_ local: URL, toDirectory: String, overwrite: Bool,
                progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError)
    func download(_ remotePath: String, to local: URL, progress: @Sendable (Int64, Int64) -> Void) async throws(SSHError)
    func close() async
}

// MARK: - SSHKit conformance

extension SSHShell: SSHShellChannel {}
extension LocalForwardHandle: LocalForwarding {}
extension SSHFileTransfer: FileTransferring {}

extension SSHConnection: SSHSessionConnection {
    func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> any SSHShellChannel {
        let shell: SSHShell = try await openShell(term: term, columns: columns, rows: rows)
        return shell
    }

    func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError)
        -> any LocalForwarding {
        let handle: LocalForwardHandle = try await startLocalForward(localPort: localPort, remoteHost: remoteHost,
                                                                     remotePort: remotePort)
        return handle
    }

    func fileTransfer() async throws(SSHError) -> any FileTransferring {
        let transfer: SSHFileTransfer = try await fileTransfer()
        return transfer
    }
}
