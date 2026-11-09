import Foundation
import Synchronization
import Testing
@testable import SSHKit

/// SSHConnection against the in-process `TestSSHServer` (and a silent TCP listener) on 127.0.0.1.
/// Every wait is bounded: a broken client fails its test, it never hangs the run.
@Suite(.timeLimit(.minutes(1)))
struct SSHConnectionLoopbackTests {
    private let user = "tester"
    private let password = "s3cret"
    private static let acceptAll: @Sendable (SSHHostKey) async -> Bool = { _ in true }

    // MARK: Authentication

    @Test func passwordAuthOpensEchoShell() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let transcript = try await Transcript(try await openShell(connection))
        try await transcript.shell.write(Data("hi\n".utf8))
        #expect(await transcript.waitFor { $0.contains("hi") })
        // Positive control for `rejectedHostKeyStopsBeforeAuth`: the recorder does see requests.
        #expect(server.record.userauthRequests == ["password"])
        await connection.close()
        await server.stop()
    }

    @Test func hostNameWithSeveralAddressesConnects() async throws {
        // `localhost` resolves to ::1 and 127.0.0.1; the server listens on 127.0.0.1 only, so the
        // first (refused) connection attempt must not end the one that succeeds.
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "localhost", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let transcript = try await Transcript(try await openShell(connection))
        try await transcript.shell.write(Data("hi\n".utf8))
        #expect(await transcript.waitFor { $0.contains("hi") })
        await connection.close()
        await server.stop()
    }

    @Test func ed25519KeyAuth() async throws {
        let server = try await TestSSHServer.start(.init(password: nil, authorizedKeys: [try publicKey("id_ed25519.pub")]))
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .key(user: user, key: try privateKey("id_ed25519")))
        #expect(server.record.acceptedKeyAlgorithms == ["ssh-ed25519"])
        await connection.close()
        await server.stop()
    }

    @Test func ecdsaKeyAuth() async throws {
        let server = try await TestSSHServer.start(.init(password: nil, authorizedKeys: [try publicKey("id_ecdsa.pub")]))
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .key(user: user, key: try privateKey("id_ecdsa")))
        #expect(server.record.acceptedKeyAlgorithms == ["ecdsa-sha2-nistp256"])
        await connection.close()
        await server.stop()
    }

    @Test func rsaKeyAuthUsesSHA2() async throws {
        // The server refuses `ssh-rsa` (SHA-1) signatures, as OpenSSH does by default.
        let server = try await TestSSHServer.start(.init(password: nil, authorizedKeys: [try publicKey("id_rsa.pub")]))
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .key(user: user, key: try privateKey("id_rsa")))
        #expect(server.record.acceptedKeyAlgorithms == ["rsa-sha2-512"])
        #expect(!server.record.userauthRequests.contains("publickey ssh-rsa"))
        await connection.close()
        await server.stop()
    }

    @Test func wrongPasswordIsAuthFailed() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let error = await openError(connection, .password(user: user, password: "nope"))
        #expect(error == .authFailed)
        await server.stop()
    }

    @Test func unauthorizedKeyIsAuthFailed() async throws {
        let server = try await TestSSHServer.start(.init(password: nil, authorizedKeys: [try publicKey("id_ed25519.pub")]))
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let error = await openError(connection, .key(user: user, key: try privateKey("id_rsa")))
        #expect(error == .authFailed)
        // Both SHA-2 algorithms were offered, never SHA-1.
        #expect(server.record.userauthRequests == ["publickey rsa-sha2-512", "publickey rsa-sha2-256"])
        await server.stop()
    }

    // MARK: Host keys

    @Test func rejectedHostKeyStopsBeforeAuth() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let error = await openError(connection, .password(user: user, password: password)) { _ in false }
        #expect(error == .hostKeyRejected(server.hostKey))
        #expect(server.record.userauthRequests.isEmpty)
        await server.stop()
    }

    @Test func validatorReceivesServerKey() async throws {
        let server = try await TestSSHServer.start()
        let seen = try await validatedKey(server)
        #expect(seen?.fingerprintSHA256 == (try publicKey("host_ed25519.pub")).fingerprintSHA256)
        await server.stop()
    }

    @Test func rsaHostKeyArrivesAsSSHRSA() async throws {
        let server = try await TestSSHServer.start(.init(hostKey: .rsa))
        let seen = try await validatedKey(server)
        let expected = try publicKey("id_rsa.pub")
        #expect(seen?.algorithm == "ssh-rsa")
        #expect(seen == expected)
        #expect(seen?.fingerprintSHA256 == expected.fingerprintSHA256)
        await server.stop()
    }

    @Test func ecdsaHostKey() async throws {
        let server = try await TestSSHServer.start(.init(hostKey: .ecdsa))
        let seen = try await validatedKey(server)
        #expect(seen == (try publicKey("id_ecdsa.pub")))
        await server.stop()
    }

    // MARK: Shell

    @Test func resizeSendsWindowChange() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let transcript = try await Transcript(try await openShell(connection))
        await transcript.shell.resize(columns: 120, rows: 40)
        #expect(await transcript.waitFor { $0.contains("[size 120 40]") })
        await connection.close()
        await server.stop()
    }

    @Test func termIsSentAsGiven() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        _ = try await openShell(connection, term: "xterm-256color")
        #expect(server.record.ptyTerms == ["xterm-256color"])
        await connection.close()
        await server.stop()
    }

    @Test func remoteExitEndsOutputNormally() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let transcript = try await Transcript(try await openShell(connection))
        try await transcript.shell.write(Data("exit\n".utf8))
        #expect(await transcript.waitForEnd() == .finished)
        await connection.close()
        await server.stop()
    }

    // MARK: Network failures

    @Test func closedPortIsUnreachable() async throws {
        let port = try await closedLoopbackPort()
        let connection = SSHConnection(host: "127.0.0.1", port: port)
        let error = await openError(connection, .password(user: user, password: password))
        #expect(error == .unreachable)
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await SilentTCPServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let start = ContinuousClock.now
        let error = await openError(connection, .password(user: user, password: password), timeout: .milliseconds(500))
        #expect(error == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
        await server.stop()
    }

    // MARK: Keepalive and closing

    @Test func keepaliveMissesEndConnection() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port, keepalive: .init(interval: .milliseconds(100), maxMissed: 2))
        try await open(connection, .password(user: user, password: password))
        let closed = Ending(await connection.closed)
        server.stopAnswering()
        #expect(await closed.value(within: .seconds(5)) == .some(.connectionClosed))
        await server.stop()
    }

    @Test func answeredKeepalivesKeepConnectionOpen() async throws {
        // Positive control: the same settings against a server that answers (with
        // SSH_MSG_REQUEST_FAILURE, as servers do for keepalive@openssh.com) never close.
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port, keepalive: .init(interval: .milliseconds(100), maxMissed: 2))
        try await open(connection, .password(user: user, password: password))
        let closed = Ending(await connection.closed)
        #expect(await closed.value(within: .seconds(1)) == nil)
        let transcript = try await Transcript(try await openShell(connection))
        try await transcript.shell.write(Data("still here\n".utf8))
        #expect(await transcript.waitFor { $0.contains("still here") })
        await connection.close()
        #expect(await closed.value(within: .seconds(5)) == .some(nil))
        await server.stop()
    }

    @Test func localCloseYieldsNilOnceAndIsIdempotent() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let closed = Ending(await connection.closed)
        await connection.close()
        await connection.close()
        #expect(await closed.value(within: .seconds(5)) == .some(nil))
        #expect(await closed.finished(within: .seconds(5)))
        #expect(closed.count == 1)
        await server.stop()
    }

    @Test func serverGoingAwayYieldsConnectionClosed() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let closed = Ending(await connection.closed)
        let transcript = try await Transcript(try await openShell(connection))
        await server.stop()
        #expect(await closed.value(within: .seconds(5)) == .some(.connectionClosed))
        #expect(await transcript.waitForEnd() == .failed(.connectionClosed))
    }

    // MARK: Aborting open, timeouts

    @Test func closeWhileHandshakeIsPendingThrowsConnectionClosed() async throws {
        let server = try await SilentTCPServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let closed = Ending(await connection.closed)
        let opening = Task { await openError(connection, .password(user: user, password: password), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        await connection.close()
        #expect(try await bounded(.seconds(2)) { await opening.value } == .connectionClosed)
        #expect(await closed.value(within: .seconds(5)) == .some(nil))
        #expect(await closed.finished(within: .seconds(5)))
        #expect(closed.count == 1)
        await server.stop()
    }

    @Test func closeWhileTCPConnectIsPendingThrowsConnectionClosed() async throws {
        let server = try await StalledTCPServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let closed = Ending(await connection.closed)
        let opening = Task { await openError(connection, .password(user: user, password: password), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await connection.close()
        #expect(try await bounded(.seconds(5)) { await opening.value } == .connectionClosed)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await closed.value(within: .seconds(5)) == .some(nil))
        #expect(closed.count == 1)
        await server.stop()
    }

    @Test func closeWhileValidatorIsPendingCancelsIt() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let closed = Ending(await connection.closed)
        let validator = Locked<(started: Bool, cancelled: Bool)>((false, false))
        let opening = Task {
            await openError(connection, .password(user: user, password: password)) { _ in
                validator.withLock { $0.started = true }
                do {
                    try await Task.sleep(for: .seconds(30))
                    return true
                } catch {
                    validator.withLock { $0.cancelled = true }
                    return true  // ignored: the connection is gone
                }
            }
        }
        #expect(await poll(within: .seconds(5)) { validator.withLock { $0.started } })
        await connection.close()
        #expect(try await bounded(.seconds(2)) { await opening.value } == .connectionClosed)
        #expect(await poll(within: .seconds(2)) { validator.withLock { $0.cancelled } })
        #expect(await closed.value(within: .seconds(5)) == .some(nil))
        #expect(closed.count == 1)
        #expect(server.record.userauthRequests.isEmpty)
        await server.stop()
    }

    @Test func cancellingOpenClosesPromptly() async throws {
        let server = try await SilentTCPServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        let opening = Task { () -> SSHError? in
            do {
                try await connection.open(credentials: .password(user: user, password: password), timeout: .seconds(30)) { _ in true }
                return nil
            } catch let error as SSHError {
                return error
            } catch {
                return .remote("untyped \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        opening.cancel()
        #expect(try await bounded(.seconds(2)) { await opening.value } == .connectionClosed)
        #expect(ContinuousClock.now - start < .milliseconds(200))
        await server.stop()
    }

    @Test func validatorTimeDoesNotCountTowardsTimeout() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password), timeout: .milliseconds(500)) { _ in
            try? await Task.sleep(for: .seconds(1))
            return true
        }
        await connection.close()
        await server.stop()
    }

    // MARK: Re-key

    @Test func rekeyWithTheSameHostKeyKeepsTheSession() async throws {
        let server = try await TestSSHServer.start(.init(hostKey: .rsa))
        let calls = Locked(0)
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password)) { _ in
            calls.withLock { $0 += 1 }
            return true
        }
        let closed = Ending(await connection.closed)
        let transcript = try await Transcript(try await openShell(connection))
        let signed = server.record.hostKeySignatures
        // The server holds the client's bytes: once some are held, the client has answered the
        // server's KEXINIT with its own and stays mid re-key until they are released.
        try await server.rekeyHoldingClientBytes()
        #expect(await pollAsync(within: .seconds(5)) { (try? await server.heldBytes()) ?? 0 > 0 })
        let shell = transcript.shell
        let write = Task { try await shell.write(Data("during rekey\n".utf8)) }
        let written = Locked(false)
        Task { _ = await write.result; written.withLock { $0 = true } }
        // The write waits in the client's handler (it is not refused, and not sent).
        #expect(await pollAsync(within: .seconds(5)) {
            (try? await deferredSSHMessageCount(connection)) == 1 || written.withLock { $0 }
        })
        #expect(try await deferredSSHMessageCount(connection) == 1)
        #expect(!written.withLock { $0 })
        try await server.releaseHeldBytes()
        try await bounded(.seconds(5)) { try await write.value }
        #expect(await transcript.waitFor { $0.contains("during rekey") })
        #expect(server.record.hostKeySignatures > signed)
        try await transcript.shell.write(Data("after rekey\n".utf8))
        #expect(await transcript.waitFor { $0.contains("after rekey") })
        #expect(calls.withLock { $0 } == 1)
        #expect(await closed.value(within: .milliseconds(200)) == nil)
        await connection.close()
        await server.stop()
    }

    @Test func rekeyWithAnotherHostKeyEndsWithHostKeyRejected() async throws {
        let server = try await TestSSHServer.start(.init(hostKey: .rsa))
        let calls = Locked(0)
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password)) { _ in
            calls.withLock { $0 += 1 }
            return true
        }
        let closed = Ending(await connection.closed)
        let newKey = try server.rotateRSAHostKey()
        #expect(newKey != server.hostKey)
        try await server.rekey()
        #expect(await closed.value(within: .seconds(5)) == .some(.hostKeyRejected(newKey)))
        #expect(calls.withLock { $0 } == 1)
        await server.stop()
    }

    @Test func localCloseEndsShellOutputNormally() async throws {
        let server = try await TestSSHServer.start()
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password))
        let transcript = try await Transcript(try await openShell(connection))
        await connection.close()
        #expect(await transcript.waitForEnd() == .finished)
        await server.stop()
    }

    // MARK: Helpers

    private func publicKey(_ name: String) throws -> SSHHostKey {
        try SSHHostKey(openSSHPublicKey: fixture(name))
    }

    private func privateKey(_ name: String) throws -> SSHPrivateKey {
        try SSHPrivateKey.parse(openSSH: fixture(name), passphrase: nil)
    }

    private func open(
        _ connection: SSHConnection, _ credentials: SSHCredentials, timeout: Duration = .seconds(5),
        validate: @escaping @Sendable (SSHHostKey) async -> Bool = Self.acceptAll
    ) async throws {
        try await bounded {
            try await connection.open(credentials: credentials, timeout: timeout, validateHostKey: validate)
        }
    }

    private func openError(
        _ connection: SSHConnection, _ credentials: SSHCredentials, timeout: Duration = .seconds(5),
        validate: @escaping @Sendable (SSHHostKey) async -> Bool = Self.acceptAll
    ) async -> SSHError? {
        do {
            try await open(connection, credentials, timeout: timeout, validate: validate)
            Issue.record("open succeeded")
            return nil
        } catch let error as SSHError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    private func openShell(_ connection: SSHConnection, term: String = "xterm-256color") async throws -> SSHShell {
        try await bounded { try await connection.openShell(term: term, columns: 80, rows: 24) }
    }

    /// Connects with a validator that records the key it is shown and accepts it.
    private func validatedKey(_ server: TestSSHServer) async throws -> SSHHostKey? {
        let seen = Mutex<SSHHostKey?>(nil)
        let connection = SSHConnection(host: "127.0.0.1", port: server.port)
        try await open(connection, .password(user: user, password: password)) { key in
            seen.withLock { $0 = key }
            return true
        }
        await connection.close()
        return seen.withLock { $0 }
    }
}

struct BoundedWaitExpired: Error {}

/// Runs `operation`, failing with `BoundedWaitExpired` if it takes longer than `limit`.
func bounded<T: Sendable>(_ limit: Duration = .seconds(10), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw BoundedWaitExpired()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Reads a shell's output in the background, so a test can wait for text with a deadline.
final class Transcript: Sendable {
    enum End: Equatable, Sendable {
        case finished
        case failed(SSHError?)
    }

    let shell: SSHShell
    private let state = Locked<(text: String, end: End?)>(("", nil))
    private let reader: Task<Void, Never>

    init(_ shell: SSHShell) async throws {
        self.shell = shell
        let state = self.state
        reader = Task {
            do {
                for try await chunk in shell.output {
                    state.withLock { $0.text += String(decoding: chunk, as: UTF8.self) }
                }
                state.withLock { $0.end = .finished }
            } catch {
                state.withLock { $0.end = .failed(error as? SSHError) }
            }
        }
    }

    deinit { reader.cancel() }

    func waitFor(within limit: Duration = .seconds(5), _ predicate: (String) -> Bool) async -> Bool {
        await poll(within: limit) { predicate(self.state.withLock { $0.text }) }
    }

    func waitForEnd(within limit: Duration = .seconds(5)) async -> End? {
        _ = await poll(within: limit) { self.state.withLock { $0.end } != nil }
        return state.withLock { $0.end }
    }
}

/// Collects what a `closed` stream yields, so a test can wait for it with a deadline.
final class Ending: Sendable {
    private let state = Locked<(values: [SSHError?], finished: Bool)>(([], false))
    private let reader: Task<Void, Never>

    init(_ stream: AsyncStream<SSHError?>) {
        let state = self.state
        reader = Task {
            for await value in stream {
                state.withLock { $0.values.append(value) }
            }
            state.withLock { $0.finished = true }
        }
    }

    deinit { reader.cancel() }

    var count: Int { state.withLock { $0.values.count } }

    /// The first value, or nil (no `.some`) if none came within `limit`.
    func value(within limit: Duration) async -> SSHError?? {
        _ = await poll(within: limit) { !self.state.withLock { $0.values.isEmpty } }
        return state.withLock { $0.values.first }
    }

    func finished(within limit: Duration) async -> Bool {
        await poll(within: limit) { self.state.withLock { $0.finished } }
    }
}

/// A value behind a lock, shareable between tasks (a `Mutex` cannot be captured).
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        mutex.withLock { body(&$0) }
    }
}

/// Checks `condition` every 20 ms until it holds or `limit` passes.
func poll(within limit: Duration, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
