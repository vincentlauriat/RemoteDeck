import Foundation
import os
import SSHKit
@testable import RemoteDeck

/// A scripted `SSHSessionConnection`, honouring `SSHConnection.open`'s contract: the validator runs
/// in its own task during "key exchange", nothing authenticates before it answered true, and the
/// connection dying (or `close()`) cancels it. `log` gets "open", "auth", "hostKeyRejected", "shell",
/// "shellClosed" (the read of the output was cancelled), "forward:<port>" (a start asked),
/// "forwardStopped:<port>" (`stop()` of a started forward) and "close".
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
    /// Local ports whose start fails, with the error (`portInUse`, `channelFailed`…).
    private var forwardFailures: [UInt16: SSHError]
    /// Local ports whose start waits for `finishForwardStart` (a bind that ends after the close).
    private let forwardHangs: Set<UInt16>
    private var forwardWaiters: [UInt16: CheckedContinuation<Void, Never>] = [:]
    /// Every start asked, in order, and the forwards handed out.
    private(set) var forwardStarts: [(localPort: UInt16, remoteHost: String, remotePort: UInt16)] = []
    private(set) var forwards: [FakeForward] = []
    /// What `fileTransfer()` hands out (Task 12); nil: `.sftpUnavailable`.
    private let transfer: (any FileTransferring)?
    private(set) var fileTransferOpenCount = 0

    init(log: SessionLog, hostKey: SSHHostKey, openResult: Result<Void, SSHError> = .success(()),
         shellResult: Result<Void, SSHError> = .success(()), hangsAfterValidation: Bool = false,
         shellHangs: Bool = false, forwardFailures: [UInt16: SSHError] = [:], forwardHangs: Set<UInt16> = [],
         fileTransfer: (any FileTransferring)? = nil) {
        transfer = fileTransfer
        self.shellHangs = shellHangs
        self.forwardFailures = forwardFailures
        self.forwardHangs = forwardHangs
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
        log.append("forward:\(localPort)")
        forwardStarts.append((localPort, remoteHost, remotePort))
        if forwardHangs.contains(localPort) {
            await withCheckedContinuation { forwardWaiters[localPort] = $0 }
        } else if isClosed {
            throw .connectionClosed
        }
        if let error = forwardFailures[localPort] { throw error }
        let forward = FakeForward(localPort: localPort, log: log)
        forwards.append(forward)
        return forward
    }

    /// A start of `forwardHangs` succeeds now, whether the connection was closed meanwhile or not.
    func finishForwardStart(_ localPort: UInt16) {
        forwardWaiters.removeValue(forKey: localPort)?.resume()
    }

    func isWaitingForForward(_ localPort: UInt16) -> Bool { forwardWaiters[localPort] != nil }

    /// The next start of `localPort` succeeds (the other app freed the port).
    func clearForwardFailure(_ localPort: UInt16) { forwardFailures[localPort] = nil }

    var forwardStartCount: Int { forwardStarts.count }

    /// Forwards handed out and not stopped.
    var runningForwardCount: Int { forwards.filter { !$0.isStopped }.count }

    /// The forwards started on `localPort` and still running.
    func runningForwards(_ localPort: UInt16) -> Int {
        forwards.filter { $0.localPort == localPort && !$0.isStopped }.count
    }

    func fileTransfer() async throws(SSHError) -> any FileTransferring {
        log.append("sftp")
        fileTransferOpenCount += 1
        guard !isClosed else { throw .connectionClosed }
        guard let transfer else { throw .sftpUnavailable }
        return transfer
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

/// A forward handed out by `FakeSSHSessionConnection`; `stop()` is recorded.
final class FakeForward: LocalForwarding {
    let localPort: UInt16
    private let log: SessionLog
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(localPort: UInt16, log: SessionLog) {
        self.localPort = localPort
        self.log = log
    }

    var isStopped: Bool { stopped.withLock { $0 } }

    func stop() async {
        stopped.withLock { $0 = true }
        log.append("forwardStopped:\(localPort)")
    }
}
