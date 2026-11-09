import AppKit
import Foundation
import SSHKit
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 9 (AppFlow › Terminal tab, TRD › Architecture › SSH): the terminal session over fakes
// only (`FakeSSHSessionConnection`, `FakeTerminalSurface`, in-memory trust, folder and secrets).

let serverKey = try! SSHHostKey(openSSHPublicKey: SSHTestKeys.ed25519Public)
/// Same key type as `serverKey`, another key: a changed host key.
let otherServerKey = try! SSHHostKey(openSSHPublicKey: SSHTestKeys.ed25519EncryptedPublic)

/// The machine, its stores and a terminal session whose attempts use the given fakes in order.
@MainActor
final class TerminalHarness {
    let context: ModelContext
    let machine: Machine
    let passwords = FakePasswordStore()
    let secrets = FakeSSHSecrets()
    let folder: FakeSSHFolderAccess
    let trust: InMemoryTrustedHostKeys
    let log = SessionLog()
    let clock = FakeClock()
    let reconnectClock = FakeReachabilityClock()
    let surface = FakeTerminalSurface()
    private(set) var fakes: [FakeSSHSessionConnection] = []
    /// The fake of attempt n (0-based); by default one that presents `serverKey` and connects.
    var makeFake: (Int, SessionLog) -> FakeSSHSessionConnection = { _, log in
        FakeSSHSessionConnection(log: log, hostKey: serverKey)
    }

    init(auth: SSHAuthMethod = .password, keyFile: String? = nil, host: String = "pi.local",
         folderFiles: [String: String] = [:]) throws {
        context = try makeTestContext()
        machine = Machine(name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent",
                          sshAuthMethod: auth, sshKeyFileName: keyFile)
        context.insert(machine)
        try context.save()
        passwords.items[machine.id] = "pw"
        folder = FakeSSHFolderAccess(granted: true, files: folderFiles)
        trust = InMemoryTrustedHostKeys(folder: folder)
    }

    var made: Int { fakes.count }
    var last: FakeSSHSessionConnection? { fakes.last }

    func model(attaching: Bool = true) -> TerminalSessionModel {
        let model = TerminalSessionModel(
            machine: machine, context: context,
            resolver: SSHCredentialResolver(passwords: passwords, secrets: secrets, folder: folder),
            trust: trust, secrets: secrets, clock: clock.clock, reconnectClock: reconnectClock
        ) { [unowned self] _ in
            let fake = makeFake(fakes.count, log)
            fakes.append(fake)
            return fake
        }
        if attaching { model.attach(surface) }
        return model
    }

    func trustServerKey(_ key: SSHHostKey = serverKey) {
        trust.trust(key, host: machine.host, port: machine.port)
    }

    func records() throws -> [SessionRecord] {
        try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    /// Waits for the shell of the current attempt and the connected phase.
    func connected(_ model: TerminalSessionModel) async throws {
        #expect(await waitUntil { model.phase == .connected })
        let fake = try #require(last)
        #expect(await waitUntilAsync { await fake.hasShell })
    }
}

@MainActor
final class Heartbeat {
    var ticking = true
    var longestGap: Duration = .zero
}

@MainActor
struct TerminalSessionModelTests {
    // MARK: Host keys

    @Test func testConnectUnknownHostKeyShowsPromptThenTrustConnects() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(model.phase == .connecting)
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        let prompt = try #require(model.hostKeyPrompt)
        #expect(prompt == .init(host: "pi.local", port: 22, key: serverKey))
        let fake = try #require(harness.last)
        #expect(await fake.credentials == nil)   // stopped before any authentication

        model.trustHostKey()
        #expect(model.hostKeyPrompt == nil)
        try await harness.connected(model)
        #expect(harness.trust.decision(for: serverKey, host: "pi.local", port: 22) == .trusted)
        guard case .password(let user, let password)? = await fake.credentials else {
            Issue.record("no password sent")
            return
        }
        #expect(user == "vincent" && password == "pw")
        await model.close()
    }

    @Test func testRejectHostKeyEndsFailedWithoutAuth() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        model.rejectHostKey()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .connect(.hostKeyRejected(serverKey)))
        #expect(model.hostKeyPrompt == nil)
        let fake = try #require(harness.last)
        #expect(await fake.credentials == nil)
        #expect(!harness.log.all.contains("auth"))
        #expect(harness.trust.decision(for: serverKey, host: "pi.local", port: 22) == .unknown)   // nothing remembered
    }

    @Test func testChangedHostKeyBlocksWithFingerprints() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey(serverKey)
        harness.makeFake = { _, log in FakeSSHSessionConnection(log: log, hostKey: otherServerKey) }
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        let expected = TerminalFailure.hostKeyChanged(previousFingerprint: serverKey.fingerprintSHA256,
                                                      newFingerprint: otherServerKey.fingerprintSHA256)
        #expect(model.failure == expected)
        #expect(model.hostKeyPrompt == nil)
        #expect(model.failure?.action == .close)   // nothing in the banner continues
        #expect(await harness.last?.credentials == nil)
        let message = try #require(model.failure?.message(english))
        #expect(message.contains("The identity of this server has changed"))
        #expect(message.contains(serverKey.fingerprintSHA256) && message.contains(otherServerKey.fingerprintSHA256))

        // No trust path: Trust without a prompt does nothing, and Retry blocks again.
        model.trustHostKey()
        #expect(harness.trust.decision(for: otherServerKey, host: "pi.local", port: 22)
            == .changed(previousFingerprint: serverKey.fingerprintSHA256))
        model.connect()
        #expect(await waitUntil { harness.made == 2 && model.failure == expected })
        #expect(model.hostKeyPrompt == nil)
    }

    /// `open` ends while the Host Key Sheet is up (the connection died): the sheet goes away.
    @Test func connectionDyingUnderThePromptDismissesIt() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        await harness.last?.dieDuringValidation()
        #expect(await waitUntil { model.hostKeyPrompt == nil && model.failure != nil })
        #expect(model.failure == .connect(.connectionClosed))
        #expect(model.failure?.action == .retry)
    }

    /// A re-key that presents another key ends the connection: blocked as a changed key, no reconnect.
    @Test func rekeyWithAnotherKeyBlocks() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        await harness.last?.rekeyRejected(otherServerKey)
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .hostKeyChanged(previousFingerprint: serverKey.fingerprintSHA256,
                                                 newFingerprint: otherServerKey.fingerprintSHA256))
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.reconnectClock.pendingCount == 0)
        #expect(try harness.records().map(\.outcomeValue) == [.hostKeyRejected])
    }

    /// A re-key to a key type no list holds: the banner never names known_hosts or a previous key it
    /// does not know.
    @Test func rekeyToAnotherTypeUsesTheGenericWording() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        let ecdsa = try SSHHostKey(openSSHPublicKey: SSHTestKeys.ecdsaPublic)
        await harness.last?.rekeyRejected(ecdsa)
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .hostKeyChanged(previousFingerprint: "", newFingerprint: ecdsa.fingerprintSHA256))
        let message = try #require(model.failure?.message(english))
        #expect(!message.contains("known_hosts") && !message.contains("Trusted key"))
        #expect(message.hasPrefix("The identity of this server has changed"))
        #expect(message.contains(ecdsa.fingerprintSHA256))
    }

    /// Closing the tab while the Host Key Sheet is up: the sheet goes, the validator is answered
    /// (nothing left waiting), nothing authenticates, the record ends `cancelled`.
    @Test func closeWhileTheHostKeySheetIsUpResumesTheValidator() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        let fake = try #require(harness.last)
        await model.close()
        #expect(model.hostKeyPrompt == nil)
        #expect(model.phase == .closed)
        #expect(await waitUntilAsync { await fake.validationEnded })
        #expect(await fake.credentials == nil)
        let record = try #require(try harness.records().first)
        #expect(record.outcomeValue == .cancelled)
        #expect(record.endedAt != nil)
        #expect(harness.trust.decision(for: serverKey, host: "pi.local", port: 22) == .unknown)
    }

    /// A shell that never opens fails as an open timeout, and the connection is closed.
    @Test func shellThatNeverOpensTimesOut() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        harness.makeFake = { _, log in FakeSSHSessionConnection(log: log, hostKey: serverKey, shellHangs: true) }
        let model = harness.model()
        model.shellTimeout = .milliseconds(100)
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .connect(.timedOut))
        #expect(model.failure?.message(english) == "Unreachable — no answer within 10 s")
        #expect(await waitUntil { harness.log.all.last == "close" })
        #expect(try harness.records().map(\.outcomeValue) == [.unreachable])
    }

    // MARK: Passphrase

    @Test func testPassphrasePromptThenRememberStoresLocalItem() async throws {
        let harness = try TerminalHarness(auth: .keyInSSHFolder, keyFile: "id_enc",
                                          folderFiles: ["id_enc": SSHTestKeys.ed25519Encrypted])
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.needsPassphrase })
        #expect(!model.passphraseRejected)
        #expect(harness.made == 0)   // nothing connects before the key is open

        model.providePassphrase("wrong", remember: true)
        #expect(await waitUntil(timeout: .seconds(10)) { model.needsPassphrase && model.passphraseRejected })
        model.providePassphrase(SSHTestKeys.passphrase, remember: true)
        try await harness.connected(model)
        #expect(!model.passphraseRejected)
        let id = harness.machine.id
        #expect(harness.secrets.items[.sshLocalKeyPassphrase(id)] == SSHTestKeys.passphrase)
        #expect(harness.secrets.items[.sshKeyPassphrase(id)] == nil)   // a key in ~/.ssh: local item only
        guard case .key(let user, _)? = await harness.last?.credentials else {
            Issue.record("no key sent")
            return
        }
        #expect(user == "vincent")
        await model.close()
    }

    /// A remembered passphrase that no longer opens the key (re-encrypted): the sheet says it was
    /// wrong, and the stale item goes once a typed one works, even without Remember.
    @Test func staleRememberedPassphraseAsksAndIsDeletedOnSuccess() async throws {
        let harness = try TerminalHarness(auth: .keyInSSHFolder, keyFile: "id_enc",
                                          folderFiles: ["id_enc": SSHTestKeys.ed25519Encrypted])
        harness.trustServerKey()
        let id = harness.machine.id
        harness.secrets.items[.sshLocalKeyPassphrase(id)] = "old"
        let model = harness.model()
        model.connect()
        #expect(await waitUntil(timeout: .seconds(10)) { model.needsPassphrase })
        #expect(model.passphraseRejected)
        model.providePassphrase(SSHTestKeys.passphrase, remember: false)
        try await harness.connected(model)
        #expect(harness.secrets.items[.sshLocalKeyPassphrase(id)] == nil)
        #expect(harness.secrets.deleted == [.sshLocalKeyPassphrase(id)])
        await model.close()
    }

    @Test func testCancelPassphraseIsCancelledOutcome() async throws {
        let harness = try TerminalHarness(auth: .keyInSSHFolder, keyFile: "id_enc",
                                          folderFiles: ["id_enc": SSHTestKeys.ed25519Encrypted])
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.needsPassphrase })
        model.cancelPassphrase()
        #expect(await waitUntil { model.phase == .idle })
        #expect(!model.needsPassphrase)
        #expect(model.failure == nil)
        let records = try harness.records()
        #expect(records.map(\.outcomeValue) == [.cancelled])
        #expect(records.first?.endedAt != nil)
        #expect(harness.made == 0)
        #expect(harness.secrets.items.isEmpty)
    }

    /// "Key in ~/.ssh" without the grant: a banner the view turns into "Grant access to ~/.ssh…".
    @Test func keyInSSHFolderWithoutGrantAsksForTheFolder() async throws {
        let harness = try TerminalHarness(auth: .keyInSSHFolder, keyFile: "id_ed25519")
        harness.folder.granted = false
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .sshFolderAccessNeeded)
        #expect(model.failure?.action == .grantSSHFolder)
        #expect(model.failure?.message(english) == "Access to ~/.ssh is needed to read this key")
        #expect(harness.made == 0)
    }

    // MARK: Shell

    @Test func testShellOutputIsFedAndInputIsWritten() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        harness.surface.type("early")   // before the shell: dropped
        model.connect()
        try await harness.connected(model)
        let fake = try #require(harness.last)
        #expect(await fake.shellRequest?.term == "xterm-256color")

        fake.shell.emit("hello ")
        fake.shell.emit("world")
        #expect(await waitUntil { harness.surface.fedText == "hello world" })
        harness.surface.type("l")
        harness.surface.type("s\n")
        #expect(await waitUntil { fake.shell.written == Data("ls\n".utf8) })
        await model.close()
    }

    /// The attempt starts before the window attaches its surface: what the shell printed meanwhile
    /// (banner, prompt) is fed on attach, byte for byte, before anything newer.
    @Test func outputBeforeAttachIsFedOnAttach() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model(attaching: false)
        model.connect()
        try await harness.connected(model)
        let shell = try #require(harness.last).shell
        let banner = Data((0..<3000).map { UInt8($0 % 251) })
        shell.emit(banner)
        shell.emit("$ ")
        #expect(await waitUntil { model.pendingOutputCount == banner.count + 2 })
        #expect(harness.surface.feeds == 0)
        model.attach(harness.surface)
        #expect(harness.surface.fed == banner + Data("$ ".utf8))
        #expect(model.pendingOutputCount == 0)
        shell.emit("ls")
        #expect(await waitUntil { harness.surface.fedText.hasSuffix("$ ls") })
        await model.close()
    }

    @Test func testResizeForwardsToShell() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        harness.surface.onResize(120, 40)   // the engine reports its grid at attach
        model.connect()
        try await harness.connected(model)
        let fake = try #require(harness.last)
        let request = try #require(await fake.shellRequest)
        #expect(request.columns == 120 && request.rows == 40)

        harness.surface.onResize(100, 30)
        #expect(await waitUntil { fake.shell.resizes == [[100, 30]] })
        harness.surface.onResize(100, 30)   // unchanged: nothing sent
        try await Task.sleep(for: .milliseconds(30))
        #expect(fake.shell.resizes == [[100, 30]])
        await model.close()
    }

    /// The remote shell exits: no drop, no automatic attempt; the record keeps `connected`.
    @Test func remoteExitEndsWithoutReconnecting() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        harness.last?.shell.emit("logout\r\n")
        harness.last?.shell.finish()
        #expect(await waitUntil { model.phase == .ended })
        #expect(harness.surface.fedText == "logout\r\n")   // the last bytes came first
        #expect(await waitUntil { harness.log.all.last == "close" })
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.reconnectClock.pendingCount == 0)
        #expect(try harness.records().map(\.outcomeValue) == [.connected])
        model.connect()   // Reconnect from the view
        #expect(await waitUntil { harness.made == 2 })
    }

    // MARK: Records

    @Test func testRecordWrittenWithOutcomeAndDuration() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        harness.clock.now += 30
        await model.close()
        let record = try #require(try harness.records().first)
        #expect(record.outcomeValue == .connected)
        #expect(record.endedAt == record.startedAt.addingTimeInterval(30))
        #expect(model.phase == .closed)
        // Close order: the shell (end of its output), then the connection.
        let order = harness.log.all.filter { $0 == "shellClosed" || $0 == "close" }
        #expect(order == ["shellClosed", "close"])
    }

    @Test func testHostKeyRejectionRecordsHostKeyRejectedOutcome() async throws {
        // A declined unknown key.
        let declined = try TerminalHarness()
        let first = declined.model()
        first.connect()
        #expect(await waitUntil { first.hostKeyPrompt != nil })
        first.rejectHostKey()
        #expect(await waitUntil { first.failure != nil })
        #expect(try declined.records().map(\.outcomeValue) == [.hostKeyRejected])
        #expect(first.failure?.outcome == .hostKeyRejected)

        // A changed key.
        let changed = try TerminalHarness()
        changed.trustServerKey(otherServerKey)
        let second = changed.model()
        second.connect()
        #expect(await waitUntil { second.failure != nil })
        #expect(try changed.records().map(\.outcomeValue) == [.hostKeyRejected])
        #expect(try changed.records().first?.endedAt != nil)
    }

    @Test func testDeclinedKeyShowsRetryBannerTabStaysOpen() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        model.rejectHostKey()
        #expect(await waitUntil { model.failure != nil })
        #expect(model.phase != .closed)
        #expect(model.failure?.action == .retry)
        #expect(model.failure?.message(english) == "Host key not trusted: nothing was sent to the server")

        model.connect()   // Retry: asks again
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        model.trustHostKey()
        try await harness.connected(model)
        #expect(try harness.records().map(\.outcomeValue) == [.hostKeyRejected, .connected])
        await model.close()
    }

    @Test func testConnectMillisIsClickToShellOpen() async throws {
        let harness = try TerminalHarness()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.hostKeyPrompt != nil })
        harness.clock.uptime += 2.5   // the user reads the fingerprint
        model.trustHostKey()
        try await harness.connected(model)
        let fake = try #require(harness.last)
        fake.shell.emit(Data(count: 1000))
        fake.shell.emit(Data(count: 234))
        #expect(await waitUntil { harness.surface.fedBytes == 1234 })
        await model.close()
        let record = try #require(try harness.records().first)
        #expect(record.connectMillis == 2500)
        #expect(record.bytesReceived == 1234)
    }

    // MARK: SessionManager

    @Test func testSecondConnectBringsExistingTabForward() async throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Pi", kind: .ssh, host: "pi.local", port: 22, username: "vincent")
        context.insert(machine)
        try context.save()
        let log = SessionLog()
        var made = 0
        let passwords = FakePasswordStore()
        passwords.items[machine.id] = "pw"
        let manager = SessionManager(context: context, passwords: passwords, tester: FakeConnectionTester(),
                                     makeConnection: { _ in
                                         Issue.record("an SSH machine never gets an RFB connection")
                                         return FakeSessionConnection(log: log, hangs: true)
                                     }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard(),
                                     makeSSHConnection: { _ in
                                         made += 1
                                         return FakeSSHSessionConnection(log: log, hostKey: serverKey,
                                                                         hangsAfterValidation: true)
                                     })
        #expect(manager.requestWindow(for: machine.id))
        let terminal = try #require(manager.terminals[machine.id])
        #expect(manager.sessions.isEmpty)
        #expect(manager.session(for: machine.id) == nil)   // never a screen session
        #expect(manager.isConnecting(machine.id))
        #expect(manager.watchedState(machine.id) == .connecting)
        #expect(manager.openSessionCount == 1)
        var broughtForward = 0
        terminal.bringWindowForward = { broughtForward += 1 }
        #expect(!manager.requestWindow(for: machine.id))
        #expect(broughtForward == 1)
        #expect(await waitUntil { made == 1 })   // the attempt reaches `open` after the credentials
        #expect(manager.terminals.count == 1)

        manager.close(machine.id)
        #expect(manager.terminals.isEmpty)
        #expect(await waitUntil { terminal.phase == .closed })
        #expect(try context.fetch(FetchDescriptor<SessionRecord>()).first?.outcomeValue == .cancelled)
    }

    // MARK: Flood (Review Focus 2)

    @Test func testOutputFloodIsCoalesced() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        harness.surface.keepsBytes = false
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        let shell = try #require(harness.last).shell

        let chunk = Data(repeating: 0x79, count: 64 * 1024)
        let chunks = 800   // 50 MB (52 428 800 bytes)
        let total = chunk.count * chunks
        // Main-actor heartbeat: the longest gap between ticks is the longest block.
        let beat = Heartbeat()
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while beat.ticking {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ContinuousClock.now
                beat.longestGap = max(beat.longestGap, now - last)
                last = now
            }
        }
        let start = ContinuousClock.now
        let producer = Task.detached {
            for _ in 0..<chunks { shell.emit(chunk) }
        }
        #expect(await waitUntil(timeout: .seconds(30)) { harness.surface.fedBytes == total })
        let elapsed = ContinuousClock.now - start
        beat.ticking = false
        await heartbeat.value
        let longestGap = beat.longestGap
        await producer.value

        let frames = Int((elapsed / .milliseconds(16)).rounded(.up))
        #expect(harness.surface.fedBytes == total)
        #expect(harness.surface.feeds <= frames + 1, "\(harness.surface.feeds) feeds in \(elapsed)")
        #expect(longestGap < .milliseconds(50), "main actor blocked \(longestGap)")
        await model.close()
        #expect(try harness.records().first?.bytesReceived == Int64(total))
    }
}
