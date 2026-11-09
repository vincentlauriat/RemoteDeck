import Foundation
import os
import SSHKit
@testable import RemoteDeck

/// A scripted `SSHSessionConnection`, honouring `SSHConnection.open`'s contract: the validator runs
/// in its own task during "key exchange", nothing authenticates before it answered true, and the
/// connection dying (or `close()`) cancels it. `log` gets "open", "auth", "hostKeyRejected", "shell",
/// "shellClosed" (the read of the output was cancelled) and "close".
actor FakeSSHSessionConnection: SSHSessionConnection {
    let log: SessionLog
    let hostKey: SSHHostKey
    let shell: FakeShell
    nonisolated let closed: AsyncStream<SSHError?>
    private let closedContinuation: AsyncStream<SSHError?>.Continuation
    private let openResult: Result<Void, SSHError>
    private let shellResult: Result<Void, SSHError>
    private let hangsAfterValidation: Bool
    /// `openShell` never answers (until `close()`), as a server that never confirms the shell.
    private let shellHangs: Bool
    /// The validator's task returned (answered or was resumed by the model).
    private(set) var validationEnded = false
    private var shellHang: CheckedContinuation<Void, Never>?
    /// Set only once the validator accepted the key: what was sent to authenticate.
    private(set) var credentials: SSHCredentials?
    private(set) var validationStarted = false
    private(set) var shellRequest: (term: String, columns: Int, rows: Int)?
    private var validation: Task<Bool, Never>?
    private var hang: CheckedContinuation<Void, Never>?
    private var isClosed = false

    init(log: SessionLog, hostKey: SSHHostKey, openResult: Result<Void, SSHError> = .success(()),
         shellResult: Result<Void, SSHError> = .success(()), hangsAfterValidation: Bool = false,
         shellHangs: Bool = false) {
        self.shellHangs = shellHangs
        self.log = log
        self.hostKey = hostKey
        self.openResult = openResult
        self.shellResult = shellResult
        self.hangsAfterValidation = hangsAfterValidation
        shell = FakeShell(log: log)
        (closed, closedContinuation) = AsyncStream.makeStream(of: SSHError?.self, bufferingPolicy: .bufferingNewest(1))
    }

    func open(credentials: SSHCredentials, timeout: Duration,
              validateHostKey: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError) {
        log.append("open")
        guard !isClosed else { throw .connectionClosed }
        let key = hostKey
        let validation = Task { await validateHostKey(key) }
        self.validation = validation
        validationStarted = true
        let accepted = await withTaskCancellationHandler {
            await validation.value
        } onCancel: {
            validation.cancel()
        }
        self.validation = nil
        validationEnded = true
        guard !isClosed else { throw .connectionClosed }
        guard accepted else {
            log.append("hostKeyRejected")
            end(.hostKeyRejected(key))
            throw .hostKeyRejected(key)
        }
        self.credentials = credentials
        log.append("auth")
        if hangsAfterValidation {
            await withCheckedContinuation { hang = $0 }
            throw .connectionClosed
        }
        if case .failure(let error) = openResult {
            end(error)
            throw error
        }
    }

    func openShell(term: String, columns: Int, rows: Int) async throws(SSHError) -> any SSHShellChannel {
        log.append("shell")
        guard !isClosed else { throw .connectionClosed }
        shellRequest = (term, columns, rows)
        if shellHangs {
            await withCheckedContinuation { shellHang = $0 }
            throw .connectionClosed
        }
        if case .failure(let error) = shellResult { throw error }
        return shell
    }

    func startLocalForward(localPort: UInt16, remoteHost: String, remotePort: UInt16) async throws(SSHError)
        -> any LocalForwarding {
        throw .channelFailed("not in this fake")
    }

    func fileTransfer() async throws(SSHError) -> any FileTransferring {
        throw .sftpUnavailable
    }

    func close() async {
        log.append("close")
        guard !isClosed else { return }
        isClosed = true
        validation?.cancel()
        hang?.resume()
        hang = nil
        shellHang?.resume()
        shellHang = nil
        closedContinuation.yield(nil)
        closedContinuation.finish()
    }

    /// The connection dies while the validator waits (a prompt is up): it is cancelled, `open` throws.
    func dieDuringValidation() {
        isClosed = true
        validation?.cancel()
        end(.connectionClosed)
    }

    /// The network drops under a running shell: the output fails and `closed` says why.
    func drop(_ error: SSHError = .connectionClosed) {
        shell.fail(error)
        end(error)
    }

    /// A re-key presented another host key: only `closed` says so (the shell's output fails too).
    func rekeyRejected(_ key: SSHHostKey) {
        end(.hostKeyRejected(key))
        shell.fail(.connectionClosed)
    }

    var hasShell: Bool { shellRequest != nil }

    private func end(_ error: SSHError) {
        isClosed = true
        closedContinuation.yield(error)
        closedContinuation.finish()
    }
}

/// The shell of `FakeSSHSessionConnection`: the test pushes output; writes and resizes are recorded.
final class FakeShell: SSHShellChannel {
    private struct State {
        var written = Data()
        var resizes: [[Int]] = []
    }

    let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(log: SessionLog) {
        (output, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        continuation.onTermination = { termination in
            if case .cancelled = termination { log.append("shellClosed") }
        }
    }

    func write(_ data: Data) async throws(SSHError) {
        state.withLock { $0.written.append(data) }
    }

    func resize(columns: Int, rows: Int) async {
        state.withLock { $0.resizes.append([columns, rows]) }
    }

    var written: Data { state.withLock { $0.written } }
    var resizes: [[Int]] { state.withLock { $0.resizes } }

    func emit(_ data: Data) { continuation.yield(data) }
    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    /// The remote shell exits (`exit`): the output ends normally.
    func finish() { continuation.finish() }
    func fail(_ error: SSHError) { continuation.finish(throwing: error) }
}
