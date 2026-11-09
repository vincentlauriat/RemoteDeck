import AppKit
import Foundation
import SSHKit
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

// Plan Task 9, resilience (TRD › Architecture › Session resilience, applied to terminals): every
// timer runs on `FakeReachabilityClock` (wait for `pending(...)` before `fire`); 2 s is the
// reconnect delay, 5 s the wake grace, 3 s the path-loss grace.

private let reconnectDelay: Duration = .seconds(2)
private let wakeGrace: Duration = .seconds(5)
private let pathLossGrace: Duration = .seconds(3)

@MainActor
struct TerminalSessionResilienceTests {
    /// Drops the current connection and runs the automatic attempt.
    private func dropAndFire(_ harness: TerminalHarness, _ model: TerminalSessionModel) async throws {
        let count = harness.made
        try await #require(harness.last).drop()
        #expect(await waitUntil { model.phase == .waiting(.retryDelay) && harness.reconnectClock.pending(reconnectDelay) == 1 })
        #expect(model.overlay == .reconnecting)
        #expect(model.failure == nil)
        #expect(harness.made == count)   // nothing before the delay
        harness.reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { harness.made == count + 1 })
        #expect(model.isAutomaticAttempt)
    }

    @Test func testDropAfterConnectedReconnectsOnceAfterDelayAndShowsSeparator() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        #expect(harness.surface.separators.isEmpty)   // the first shell has none

        try await dropAndFire(harness, model)
        try await harness.connected(model)
        #expect(harness.surface.separators == ["Reconnected: the previous shell session ended"])
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .connected])
        // The automatic attempt read the password without any Keychain dialog.
        #expect(harness.passwords.log.last == "read.synced.noUI")
        #expect(harness.reconnectClock.pendingCount == 0)

        // The separator follows the app's language when the view sets it.
        model.separatorText = { "— reconnecté —" }
        harness.clock.uptime += 61   // held long enough: re-armed
        try await dropAndFire(harness, model)
        try await harness.connected(model)
        #expect(harness.surface.separators.last == "— reconnecté —")
        await model.close()
    }

    /// The automatic attempt connects but drops again at once: no second automatic attempt.
    @Test func testSecondDropWithin60sIsConnectionLost() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        try await dropAndFire(harness, model)
        try await harness.connected(model)

        harness.clock.uptime += 5   // drops again 5 s after its shell opened
        try await #require(harness.last).drop()
        #expect(await waitUntil { model.failure == .connectionLost })
        #expect(model.failure?.action == .reconnect)
        #expect(model.failure?.message(english) == "Connection lost")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.reconnectClock.pendingCount == 0)
        #expect(harness.made == 2)
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .dropped])

        model.connect()   // Reconnect: a user's attempt again
        try await harness.connected(model)
        #expect(!model.isAutomaticAttempt)
        await model.close()
    }

    @Test func testSleepSuspendsAndWakeResumesAfterGrace() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let power = NotificationCenter()
        let quit = NotificationCenter()
        var fakes: [FakeSSHSessionConnection] = []
        let manager = SessionManager(context: harness.context, passwords: harness.passwords,
                                     tester: FakeConnectionTester(), makeDisplay: { nil },
                                     pasteboard: InMemoryPasteboard(), notificationCenter: quit,
                                     reconnectClock: harness.reconnectClock, workspaceCenter: power,
                                     ssh: SSHServices(folder: harness.folder, trustedHostKeys: harness.trust,
                                                      secrets: harness.secrets),
                                     makeSSHConnection: { [log = harness.log] _ in
                                         let fake = FakeSSHSessionConnection(log: log, hostKey: serverKey)
                                         fakes.append(fake)
                                         return fake
                                     })
        defer { manager.stop() }
        #expect(manager.requestWindow(for: harness.machine.id))
        let terminal = try #require(manager.terminals[harness.machine.id])
        #expect(await waitUntil { terminal.phase == .connected })

        power.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(terminal.phase == .waiting(.asleep))
        #expect(await waitUntil { harness.log.all.last == "close" })
        #expect(harness.log.all.contains("shellClosed"))
        #expect(manager.liveRecordIDs.isEmpty)
        #expect(try harness.records().map(\.outcomeValue) == [.connected])

        power.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { harness.reconnectClock.pending(wakeGrace) == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(fakes.count == 1)   // the grace is respected
        harness.reconnectClock.fire(wakeGrace)
        #expect(await waitUntil { fakes.count == 2 })
        #expect(terminal.isAutomaticAttempt)
        #expect(await waitUntil { terminal.phase == .connected })
        #expect(try harness.records().map(\.outcomeValue) == [.connected, .connected])
        #expect(manager.liveRecordIDs == Set([try #require(terminal.record?.id)]))
        manager.close(harness.machine.id)
    }

    /// The network goes past the 3 s grace: closed, nothing tried offline, one attempt when back.
    @Test func pathLossClosesAfterGraceAndReconnectsWhenBack() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let path = FakeNetworkPath()
        var fakes = 0
        let manager = SessionManager(context: harness.context, passwords: harness.passwords,
                                     tester: FakeConnectionTester(), makeDisplay: { nil },
                                     pasteboard: InMemoryPasteboard(), notificationCenter: NotificationCenter(),
                                     reconnectClock: harness.reconnectClock, path: path,
                                     ssh: SSHServices(folder: harness.folder, trustedHostKeys: harness.trust,
                                                      secrets: harness.secrets),
                                     makeSSHConnection: { [log = harness.log] _ in
                                         fakes += 1
                                         return FakeSSHSessionConnection(log: log, hostKey: serverKey)
                                     })
        defer { manager.stop() }
        #expect(manager.requestWindow(for: harness.machine.id))
        let terminal = try #require(manager.terminals[harness.machine.id])
        #expect(await waitUntil { terminal.phase == .connected })

        path.send(false)
        #expect(terminal.overlay == .waitingForNetwork)
        #expect(await waitUntil { harness.reconnectClock.pending(pathLossGrace) == 1 })
        harness.reconnectClock.fire(pathLossGrace)
        #expect(await waitUntil { terminal.phase == .waiting(.network) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.reconnectClock.pendingCount == 0)

        path.send(true)
        #expect(await waitUntil { harness.reconnectClock.pending(reconnectDelay) == 1 })
        harness.reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { fakes == 2 && terminal.phase == .connected })
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .connected])
        manager.close(harness.machine.id)
    }

    /// Review Focus 5: an automatic attempt never asks for a passphrase.
    @Test func testAutomaticAttemptNeedingPassphraseEndsConnectionLostWithoutPrompt() async throws {
        let harness = try TerminalHarness(auth: .keyInSSHFolder, keyFile: "id_enc",
                                          folderFiles: ["id_enc": SSHTestKeys.ed25519Encrypted])
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        #expect(await waitUntil { model.needsPassphrase })
        model.providePassphrase(SSHTestKeys.passphrase, remember: false)   // not remembered
        #expect(await waitUntil(timeout: .seconds(10)) { model.phase == .connected })
        #expect(harness.secrets.items.isEmpty)

        try await #require(harness.last).drop()
        #expect(await waitUntil { harness.reconnectClock.pending(reconnectDelay) == 1 })
        harness.reconnectClock.fire(reconnectDelay)
        #expect(await waitUntil { model.failure != nil })
        #expect(!model.needsPassphrase)
        #expect(model.failure == .connectionLost)
        #expect(model.failure?.action == .reconnect)
        #expect(harness.made == 1)   // nothing reached the server
        let reads = harness.secrets.reads.filter { $0.account == .sshLocalKeyPassphrase(harness.machine.id) }
        #expect(reads.last?.allowsInteraction == false)
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .authFailed])

        model.connect()   // Reconnect: the user's attempt asks again
        #expect(await waitUntil { model.needsPassphrase })
        model.cancelPassphrase()
    }

    /// Review Focus 5: a key that changed while the session was away blocks the automatic attempt
    /// with the changed-key banner, never "Connection lost", never a prompt.
    @Test func testAutomaticAttemptWithChangedHostKeyBlocks() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        harness.makeFake = { attempt, log in
            FakeSSHSessionConnection(log: log, hostKey: attempt == 0 ? serverKey : otherServerKey)
        }
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        try await dropAndFire(harness, model)
        #expect(await waitUntil { model.failure != nil })
        #expect(model.failure == .hostKeyChanged(previousFingerprint: serverKey.fingerprintSHA256,
                                                 newFingerprint: otherServerKey.fingerprintSHA256))
        #expect(model.hostKeyPrompt == nil)
        #expect(await harness.last?.credentials == nil)
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .hostKeyRejected])
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.reconnectClock.pendingCount == 0)
    }

    /// An unknown key on an automatic attempt (trust removed meanwhile): no prompt, "Connection lost".
    @Test func automaticAttemptWithUnknownKeyNeverPrompts() async throws {
        let harness = try TerminalHarness()
        harness.trustServerKey()
        let model = harness.model()
        model.connect()
        try await harness.connected(model)
        harness.trust.forget(host: "pi.local", port: 22)
        try await dropAndFire(harness, model)
        #expect(await waitUntil { model.failure != nil })
        #expect(model.hostKeyPrompt == nil)
        #expect(model.failure == .connectionLost)
        #expect(try harness.records().map(\.outcomeValue) == [.dropped, .hostKeyRejected])
    }

    /// SSH is encrypted: a public address connects with no "Unencrypted connection over the Internet"
    /// sheet and no screen session at all.
    @Test func testNoPublicInternetSheetForSSH() async throws {
        let harness = try TerminalHarness(host: "203.0.113.10")
        harness.trust.trust(serverKey, host: "203.0.113.10", port: 22)
        let consents = InMemoryPublicAddressConsents()
        var made: [FakeSSHSessionConnection] = []
        let manager = SessionManager(context: harness.context, passwords: harness.passwords,
                                     tester: FakeConnectionTester(), makeDisplay: { nil },
                                     pasteboard: InMemoryPasteboard(), notificationCenter: NotificationCenter(),
                                     publicConsents: consents,
                                     ssh: SSHServices(folder: harness.folder, trustedHostKeys: harness.trust,
                                                      secrets: harness.secrets),
                                     makeSSHConnection: { [log = harness.log] _ in
                                         let fake = FakeSSHSessionConnection(log: log, hostKey: serverKey)
                                         made.append(fake)
                                         return fake
                                     })
        #expect(manager.requestWindow(for: harness.machine.id))
        let terminal = try #require(manager.terminals[harness.machine.id])
        #expect(await waitUntil { terminal.phase == .connected })
        #expect(manager.sessions.isEmpty)
        #expect(!consents.hasConfirmed(harness.machine.id, host: "203.0.113.10"))   // never asked
        #expect(harness.log.all.contains("auth"))
        manager.close(harness.machine.id)
    }
}
