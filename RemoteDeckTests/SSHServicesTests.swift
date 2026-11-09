import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import SSHKit
@testable import RemoteDeck

/// App-side SSH services (plan Task 8): trusted host keys (own list + `known_hosts`), the `~/.ssh`
/// folder (read only), the SSH secret store and credential resolution, and the Library's delete and
/// merge of SSH secrets. Fakes only: never the real `~/.ssh`, Keychain, defaults or an open panel.
@MainActor
struct SSHServicesTests {
    private let host = "raspcorse"
    private var serverKey: SSHHostKey { SSHTestKeys.hostKey(SSHTestKeys.ed25519Public) }
    /// Another key of the same type (the server was reinstalled, or someone is in the middle).
    private var otherKey: SSHHostKey { SSHTestKeys.hostKey(SSHTestKeys.ed25519EncryptedPublic) }
    private var ecdsaKey: SSHHostKey { SSHTestKeys.hostKey(SSHTestKeys.ecdsaPublic) }

    /// Runs `body` on the UserDefaults store (a throwaway suite, removed after) and the in-memory one:
    /// both must take the same decisions.
    private func withTrustStores(_ folder: FakeSSHFolderAccess,
                                 _ body: (any TrustedHostKeys) throws -> Void) rethrows {
        let suite = "SSHServicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(UserDefaultsTrustedHostKeys(defaults: defaults, folder: folder))
        try body(InMemoryTrustedHostKeys(folder: folder))
    }

    private func knownHosts(_ lines: String...) -> [String: String] {
        ["known_hosts": lines.joined(separator: "\n") + "\n"]
    }

    // MARK: Trusted host keys

    @Test func testKnownHostsMatchIsTrustedWithoutAsking() {
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts(
            "\(host) \(serverKey.openSSHPublicKey)",
            "[\(host)]:2222 \(serverKey.openSSHPublicKey)"))
        withTrustStores(folder) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
            #expect(trust.decision(for: serverKey, host: "RaspCorse", port: 22) == .trusted)
            #expect(trust.decision(for: serverKey, host: host, port: 2222) == .trusted)
            #expect(trust.lastKnownHostsProblem == nil)
            // The match was pinned in RemoteDeck's own list: still trusted once the grant is lost.
            folder.granted = false
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
            folder.granted = true
        }
    }

    @Test func testKnownHostsMismatchIsChanged() {
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts("\(host) \(otherKey.openSSHPublicKey)"))
        withTrustStores(folder) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22)
                    == .changed(previousFingerprint: HostKeyDecision.knownHostsConflict))
            // known_hosts is asked first: RemoteDeck's own trust does not override its mismatch.
            trust.trust(serverKey, host: host, port: 22)
            #expect(trust.decision(for: serverKey, host: host, port: 22)
                    == .changed(previousFingerprint: HostKeyDecision.knownHostsConflict))
            // Known under another key type only: unknown (ask), never changed (TRD › Security).
            #expect(trust.decision(for: ecdsaKey, host: host, port: 22) == .unknown)
        }
        #expect(!HostKeyDecision.knownHostsConflict.hasPrefix("SHA256:"))
    }

    @Test func testOwnListTrustAfterAccept() {
        withTrustStores(FakeSSHFolderAccess()) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
            trust.trust(serverKey, host: host, port: 22)
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
            #expect(trust.decision(for: serverKey, host: " RASPCORSE ", port: 22) == .trusted)
            #expect(trust.decision(for: serverKey, host: host, port: 2222) == .unknown)
            #expect(trust.decision(for: serverKey, host: "other", port: 22) == .unknown)
        }
    }

    /// `rsa-sha2-256/512` (what a server signs with) and `ssh-rsa` (what the key is) are one key type.
    @Test func rsaSignatureAlgorithmsCompareAsSSHRSA() {
        let rsa = SSHTestKeys.hostKey(SSHTestKeys.rsaPublic)
        let signedWithSHA512 = SSHHostKey(algorithm: "rsa-sha2-512", blob: rsa.blob)
        let signedWithSHA256 = SSHHostKey(algorithm: "rsa-sha2-256", blob: rsa.blob)
        withTrustStores(FakeSSHFolderAccess()) { trust in
            trust.trust(signedWithSHA512, host: host, port: 22)
            #expect(trust.decision(for: rsa, host: host, port: 22) == .trusted)
            #expect(trust.decision(for: signedWithSHA256, host: host, port: 22) == .trusted)
        }
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts("\(host) \(rsa.openSSHPublicKey)"))
        withTrustStores(folder) { trust in
            #expect(trust.decision(for: signedWithSHA256, host: host, port: 22) == .trusted)
        }
    }

    /// A known_hosts match is pinned: after the grant is lost, another key of the same type is
    /// changed (against the pinned fingerprint), never unknown.
    @Test func knownHostsMatchIsPinnedAndALaterKeyChangeIsCaughtWithoutTheGrant() {
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts("\(host) \(serverKey.openSSHPublicKey)"))
        let trust = InMemoryTrustedHostKeys(folder: folder)
        #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
        #expect(trust.entries == ["raspcorse:22": ["ssh-ed25519": serverKey.fingerprintSHA256]])

        folder.granted = false
        folder.accessLost = true
        #expect(trust.decision(for: otherKey, host: host, port: 22)
                == .changed(previousFingerprint: serverKey.fingerprintSHA256))
        #expect(trust.lastKnownHostsProblem == .accessLost)
    }

    /// "~/.ssh access lost" and an unreadable known_hosts are reported; no grant or no file is not a
    /// problem. The decision then comes from the own list.
    @Test func knownHostsProblemsAreReported() {
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts("\(host) \(serverKey.openSSHPublicKey)"))
        folder.unreadable = ["known_hosts"]
        withTrustStores(folder) { trust in
            trust.trust(otherKey, host: host, port: 22)
            #expect(trust.decision(for: otherKey, host: host, port: 22) == .trusted)
            #expect(trust.lastKnownHostsProblem == .unreadable)
        }
        folder.granted = false
        folder.accessLost = true
        withTrustStores(folder) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
            #expect(trust.lastKnownHostsProblem == .accessLost)
        }
        folder.accessLost = false
        withTrustStores(folder) { trust in
            _ = trust.decision(for: serverKey, host: host, port: 22)
            #expect(trust.lastKnownHostsProblem == nil)
        }
        let noFile = FakeSSHFolderAccess(granted: true)
        withTrustStores(noFile) { trust in
            _ = trust.decision(for: serverKey, host: host, port: 22)
            #expect(trust.lastKnownHostsProblem == nil)
        }
    }

    /// One malformed value in the stored list is dropped alone.
    @Test func malformedTrustedEntriesAreSkippedOneByOne() {
        let suite = "SSHServicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "raspcorse:22": ["ssh-ed25519": serverKey.fingerprintSHA256],
            "bad:22": 42,
            "half:22": ["ssh-ed25519": 7, "ecdsa-sha2-nistp256": ecdsaKey.fingerprintSHA256],
        ] as [String: Any], forKey: "trustedHostKeys")
        let trust = UserDefaultsTrustedHostKeys(defaults: defaults, folder: FakeSSHFolderAccess())
        #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
        #expect(trust.decision(for: ecdsaKey, host: "half", port: 22) == .trusted)
        #expect(trust.decision(for: serverKey, host: "half", port: 22) == .unknown)
        #expect(trust.decision(for: serverKey, host: "bad", port: 22) == .unknown)
    }

    @Test func onlyAFolderNamedSSHIsAccepted() {
        #expect(SSHFolderPath.isSSHFolder(URL(filePath: "/home/someone/.ssh", directoryHint: .isDirectory)))
        #expect(SSHFolderPath.isSSHFolder(URL(filePath: "/tmp/x/.ssh/", directoryHint: .isDirectory)))
        #expect(!SSHFolderPath.isSSHFolder(URL(filePath: "/tmp/x/Documents", directoryHint: .isDirectory)))
        #expect(!SSHFolderPath.isSSHFolder(URL(filePath: "/tmp/x/ssh", directoryHint: .isDirectory)))
    }

    @Test func testOwnListChangedKeyIsChanged() {
        withTrustStores(FakeSSHFolderAccess()) { trust in
            trust.trust(serverKey, host: host, port: 22)
            #expect(trust.decision(for: otherKey, host: host, port: 22)
                    == .changed(previousFingerprint: serverKey.fingerprintSHA256))
            // Another key type the server also has: unknown, not changed.
            #expect(trust.decision(for: ecdsaKey, host: host, port: 22) == .unknown)
            trust.forget(host: host, port: 22)
            #expect(trust.decision(for: otherKey, host: host, port: 22) == .unknown)
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
        }
    }

    @Test func testNoFolderGrantUsesOwnListOnly() {
        let folder = FakeSSHFolderAccess(granted: false, files: knownHosts("\(host) \(serverKey.openSSHPublicKey)"))
        withTrustStores(folder) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
            trust.trust(otherKey, host: host, port: 22)
            #expect(trust.decision(for: otherKey, host: host, port: 22) == .trusted)
        }
        #expect(!folder.calls.contains { $0.hasPrefix("readFile") })
        // A granted folder without a known_hosts file: the own list alone, no error.
        let empty = FakeSSHFolderAccess(granted: true)
        withTrustStores(empty) { trust in
            #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
        }
    }

    /// The UserDefaults shape (BackendSchema › AppSettings): `trustedHostKeys` =
    /// `["host:port": ["key type": "SHA256:…"]]`, host lowercased.
    @Test func trustedKeysAreStoredByHostPortAndKeyType() {
        let suite = "SSHServicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = UserDefaultsTrustedHostKeys(defaults: defaults, folder: FakeSSHFolderAccess())
        trust.trust(serverKey, host: "RaspCorse", port: 22)
        trust.trust(ecdsaKey, host: "raspcorse", port: 22)
        trust.trust(serverKey, host: "nas", port: 2222)
        let stored = defaults.dictionary(forKey: "trustedHostKeys") as? [String: [String: String]]
        #expect(stored == [
            "raspcorse:22": ["ssh-ed25519": serverKey.fingerprintSHA256,
                             "ecdsa-sha2-nistp256": ecdsaKey.fingerprintSHA256],
            "nas:2222": ["ssh-ed25519": serverKey.fingerprintSHA256],
        ])
        trust.forget(host: "RASPCORSE", port: 22)
        #expect(defaults.dictionary(forKey: "trustedHostKeys") as? [String: [String: String]]
                == ["nas:2222": ["ssh-ed25519": serverKey.fingerprintSHA256]])
        // A new store over the same defaults reads what was saved.
        let reopened = UserDefaultsTrustedHostKeys(defaults: defaults, folder: FakeSSHFolderAccess())
        #expect(reopened.decision(for: serverKey, host: "nas", port: 2222) == .trusted)
    }

    // MARK: ~/.ssh

    @Test func testNeverWritesSSHFolder() async {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: true, files: knownHosts("\(host) \(serverKey.openSSHPublicKey)"))
        folder.files["id_ed25519"] = SSHTestKeys.ed25519
        let trust = InMemoryTrustedHostKeys(folder: folder)
        _ = trust.decision(for: otherKey, host: host, port: 22)
        trust.trust(otherKey, host: "other", port: 22)
        trust.forget(host: "other", port: 22)
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: FakeSSHSecrets(), folder: folder)
        _ = resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519"),
                             passphrase: nil, allowsInteraction: true)

        // The folder API has no write: only reads happened, of known_hosts and the key.
        #expect(folder.calls.allSatisfy { $0 == "isGranted" || $0.hasPrefix("readFile(") })
        #expect(Set(folder.calls.filter { $0.hasPrefix("readFile(") })
                == ["readFile(known_hosts)", "readFile(id_ed25519)"])
    }

    /// The real folder access without a bookmark: not granted, and nothing is read (no `~/.ssh`
    /// access in the tests). Paths that would leave the folder are refused before any access.
    @Test func realFolderAccessWithoutBookmarkIsNotGranted() {
        let suite = "SSHServicesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = SSHFolderAccess(defaults: defaults)
        #expect(!access.isGranted)
        #expect(throws: SSHFolderError.notGranted) { try access.readFile("id_ed25519") }
        #expect(throws: SSHFolderError.invalidPath("../.zshrc")) { try access.readFile("../.zshrc") }
        // A bookmark that does not resolve reads as not granted.
        defaults.set(Data("not a bookmark".utf8), forKey: SSHFolderAccess.bookmarkKey)
        #expect(!access.isGranted)
    }

    @Test(arguments: ["id_ed25519", "keys/id_work", "id..old"])
    func relativeKeyPathsInsideTheFolderAreAccepted(_ path: String) {
        #expect(SSHFolderPath.isValid(path))
    }

    @Test(arguments: ["", "/etc/ssh/ssh_host_ed25519_key", "~/.ssh/id_ed25519", "../id", "a/../../id", "..", "a/.."])
    func pathsLeavingTheFolderAreRefused(_ path: String) {
        #expect(!SSHFolderPath.isValid(path))
    }

    // MARK: Credential resolution

    private func target(id: UUID = UUID(), auth: SSHAuthMethod, keyFile: String? = nil,
                        forwards: [PortForward] = []) -> SessionTarget {
        SessionTarget(Machine(id: id, name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent",
                              sshAuthMethod: auth, sshKeyFileName: keyFile, portForwards: forwards))
    }

    @Test func passwordMethodReadsTheMachinePassword() {
        let passwords = FakePasswordStore()
        let id = UUID()
        let resolver = SSHCredentialResolver(passwords: passwords, secrets: FakeSSHSecrets(), folder: FakeSSHFolderAccess())
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .password), passphrase: nil,
                                         allowsInteraction: true)) == "failed(passwordMissing)")
        passwords.items[id] = "s3cret"
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .password), passphrase: nil,
                                         allowsInteraction: true)) == "password(vincent, s3cret)")
        // An automatic attempt never shows a dialog: the read fails, the password is missing.
        passwords.interactionRequiredError = .interactionNotAllowed
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .password), passphrase: nil,
                                         allowsInteraction: false)) == "failed(passwordMissing)")
        #expect(passwords.log.last == "read.synced.noUI")
    }

    @Test func testKeyInFolderWithoutGrantNeedsFolderAccess() {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: false, files: ["id_ed25519": SSHTestKeys.ed25519])
        let secrets = FakeSSHSecrets()
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: secrets, folder: folder)
        let machine = target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519")

        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: true)) == "needsFolderAccess")
        #expect(!folder.calls.contains { $0.hasPrefix("readFile") })

        folder.granted = true
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: true))
                == "key(vincent, ssh-ed25519)")
        // An unencrypted key never needs the Keychain.
        #expect(secrets.reads.isEmpty)
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_gone"),
                                         passphrase: nil, allowsInteraction: true)) == #"failed(keyFileMissing("id_gone"))"#)
        folder.files["id_bad"] = "not a key"
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_bad"),
                                         passphrase: nil, allowsInteraction: true)) == "failed(keyUnreadable)")
    }

    @Test func testEncryptedKeyWithoutPassphraseNeedsPassphrase() {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: true, files: ["id_ed25519": SSHTestKeys.ed25519Encrypted])
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: FakeSSHSecrets(), folder: folder)
        let machine = target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519")

        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: true)) == "needsPassphrase")
        #expect(summary(resolver.resolve(machine: machine, passphrase: "", allowsInteraction: true)) == "needsPassphrase")
        // An automatic attempt never gets a prompt: nobody can answer it.
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: false))
                == "failed(passphraseUnavailable)")
        // A wrong passphrase asks again when someone can answer, else nobody can: "Connection lost".
        #expect(summary(resolver.resolve(machine: machine, passphrase: "nope", allowsInteraction: true)) == "needsPassphrase")
        #expect(summary(resolver.resolve(machine: machine, passphrase: "nope", allowsInteraction: false))
                == "failed(passphraseUnavailable)")
        #expect(summary(resolver.resolve(machine: machine, passphrase: SSHTestKeys.passphrase, allowsInteraction: true))
                == "key(vincent, ssh-ed25519)")
    }

    @Test func testRememberedLocalPassphraseIsUsedNonInteractively() {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: true, files: ["id_ed25519": SSHTestKeys.ed25519Encrypted])
        let secrets = FakeSSHSecrets()
        secrets.items[.sshLocalKeyPassphrase(id)] = SSHTestKeys.passphrase
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: secrets, folder: folder)

        let result = resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519"),
                                      passphrase: nil, allowsInteraction: false)

        #expect(summary(result) == "key(vincent, ssh-ed25519)")
        #expect(secrets.reads == [.init(account: .sshLocalKeyPassphrase(id), allowsInteraction: false)])

        // A remembered passphrase that no longer opens the key (the key was re-encrypted).
        secrets.items[.sshLocalKeyPassphrase(id)] = "old"
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519"),
                                         passphrase: nil, allowsInteraction: false)) == "failed(passphraseUnavailable)")
        #expect(summary(resolver.resolve(machine: target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519"),
                                         passphrase: nil, allowsInteraction: true)) == "rememberedPassphraseRejected")
    }

    /// A remembered passphrase whose read would need a Keychain dialog, during an automatic attempt:
    /// unavailable, never a prompt; a manual Connect reads it.
    @Test func rememberedPassphraseNeedingADialogIsUnavailableToAutomaticAttempts() {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: true, files: ["id_ed25519": SSHTestKeys.ed25519Encrypted])
        let secrets = FakeSSHSecrets()
        secrets.items[.sshLocalKeyPassphrase(id)] = SSHTestKeys.passphrase
        secrets.needsInteraction = [.sshLocalKeyPassphrase(id)]
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: secrets, folder: folder)
        let machine = target(id: id, auth: .keyInSSHFolder, keyFile: "id_ed25519")

        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: false))
                == "failed(passphraseUnavailable)")
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: true))
                == "key(vincent, ssh-ed25519)")
    }

    @Test func testImportedKeyReadsSyncedItems() {
        let id = UUID()
        let folder = FakeSSHFolderAccess(granted: true)
        let secrets = FakeSSHSecrets()
        let resolver = SSHCredentialResolver(passwords: FakePasswordStore(), secrets: secrets, folder: folder)
        let machine = target(id: id, auth: .importedKey)

        // Not on this Mac (yet): the key cannot be read.
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: true)) == "failed(keyUnreadable)")

        secrets.items[.sshPrivateKey(id)] = SSHTestKeys.ed25519Encrypted
        secrets.items[.sshKeyPassphrase(id)] = SSHTestKeys.passphrase
        secrets.items[.sshLocalKeyPassphrase(id)] = "never read for an imported key"
        let before = secrets.reads.count
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: false))
                == "key(vincent, ssh-ed25519)")
        #expect(Array(secrets.reads.dropFirst(before)) == [
            .init(account: .sshPrivateKey(id), allowsInteraction: false),
            .init(account: .sshKeyPassphrase(id), allowsInteraction: false),
        ])
        #expect(folder.calls.isEmpty)

        // A key read that needs a dialog during an automatic attempt.
        secrets.needsInteraction = [.sshPrivateKey(id)]
        #expect(summary(resolver.resolve(machine: machine, passphrase: nil, allowsInteraction: false)) == "failed(keyUnreadable)")
    }

    @Test func sessionTargetCarriesTheSSHFields() {
        let forward = PortForward(localPort: 8080, remotePort: 80)
        let machine = target(auth: .keyInSSHFolder, keyFile: "id_ed25519", forwards: [forward])
        #expect(machine.sshAuth == .keyInSSHFolder)
        #expect(machine.sshKeyFileName == "id_ed25519")
        #expect(machine.portForwards == [forward])
        let vnc = SessionTarget(Machine(name: "Mini", kind: .vnc, host: "mini.local"))
        #expect(vnc.sshAuth == .password)
        #expect(vnc.sshKeyFileName == nil)
        #expect(vnc.portForwards.isEmpty)
    }

    // MARK: Secret store

    /// Synced SSH items fall back to local items on -34018, like machine passwords; the local-only
    /// passphrase of a key in `~/.ssh` is always local.
    @Test func syncedSecretsFallBackToLocalItemsWithoutTheEntitlement() throws {
        let id = UUID()
        let keychain = FakeScopedKeychain()
        let store = KeychainSSHSecretStore(keychain: keychain)
        keychain.refusesSynced = true
        try store.setSecret("key text", for: .sshPrivateKey(id))
        #expect(keychain.items == [.init(account: .sshPrivateKey(id), synchronizable: false): "key text"])
        #expect(try store.secret(.sshPrivateKey(id), allowsInteraction: false) == "key text")

        // Entitled: the synced save wins and the stale local copy goes.
        keychain.refusesSynced = false
        try store.setSecret("key text 2", for: .sshPrivateKey(id))
        #expect(keychain.items == [.init(account: .sshPrivateKey(id), synchronizable: true): "key text 2"])

        try store.setSecret("pass", for: .sshLocalKeyPassphrase(id))
        #expect(keychain.items[.init(account: .sshLocalKeyPassphrase(id), synchronizable: false)] == "pass")
        #expect(keychain.items[.init(account: .sshLocalKeyPassphrase(id), synchronizable: true)] == nil)

        try store.deleteSecret(.sshPrivateKey(id))
        try store.deleteSecret(.sshLocalKeyPassphrase(id))
        #expect(keychain.items.isEmpty)
    }

    /// The launch migration moves `sshKey.<id>` and `sshPassphrase.<id>` from local to synced items
    /// (read back before delete); `sshLocalPassphrase.<id>` stays local.
    @Test func launchMigrationMovesLocalSSHSecretsToSynced() {
        let id = UUID()
        let keychain = FakeScopedKeychain()
        keychain.items = [
            .init(account: .sshPrivateKey(id), synchronizable: false): "key",
            .init(account: .sshKeyPassphrase(id), synchronizable: false): "pass",
            .init(account: .sshLocalKeyPassphrase(id), synchronizable: false): "local",
        ]
        let moved = SSHSecretMigration.migrateLocalToSynced(machineIDs: [id], keychain: keychain)
        #expect(Set(moved) == [.sshPrivateKey(id), .sshKeyPassphrase(id)])
        #expect(keychain.items == [
            .init(account: .sshPrivateKey(id), synchronizable: true): "key",
            .init(account: .sshKeyPassphrase(id), synchronizable: true): "pass",
            .init(account: .sshLocalKeyPassphrase(id), synchronizable: false): "local",
        ])
        // Unentitled: nothing moves, nothing is lost.
        let unentitled = FakeScopedKeychain()
        unentitled.items = [.init(account: .sshPrivateKey(id), synchronizable: false): "key"]
        unentitled.refusesSynced = true
        #expect(SSHSecretMigration.migrateLocalToSynced(machineIDs: [id], keychain: unentitled).isEmpty)
        #expect(unentitled.items == [.init(account: .sshPrivateKey(id), synchronizable: false): "key"])
    }

    // MARK: Library delete and merge

    @Test func testDeleteMachineRemovesSSHSecretsAndTrust() throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent",
                              sshAuthMethod: .importedKey)
        let other = Machine(name: "NAS", kind: .ssh, host: "nas", port: 22, username: "vincent")
        context.insert(machine)
        context.insert(other)
        try context.save()
        let secrets = FakeSSHSecrets()
        for account in [KeychainAccount.sshPrivateKey(machine.id), .sshKeyPassphrase(machine.id),
                        .sshLocalKeyPassphrase(machine.id), .sshPrivateKey(other.id)] {
            secrets.items[account] = "secret"
        }
        let trust = InMemoryTrustedHostKeys(folder: FakeSSHFolderAccess())
        trust.trust(serverKey, host: host, port: 22)
        trust.trust(serverKey, host: "nas", port: 22)
        let library = MachineLibraryModel(context: context, passwords: FakePasswordStore(),
                                          ssh: SSHServices(folder: FakeSSHFolderAccess(), trustedHostKeys: trust,
                                                           secrets: secrets))

        library.delete(machine)

        #expect(try context.fetch(FetchDescriptor<Machine>()).map(\.id) == [other.id])
        #expect(secrets.items == [.sshPrivateKey(other.id): "secret"])
        #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
        #expect(trust.decision(for: serverKey, host: "nas", port: 22) == .trusted)
        #expect(library.deleteWarning == nil)
    }

    /// A synced duplicate not merged yet shares the normalized host:port: its trust stays until the
    /// last such machine is deleted.
    @Test func deleteKeepsTrustStillUsedByAnotherMachine() throws {
        let context = try makeTestContext()
        let first = Machine(name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent")
        let duplicate = Machine(name: "Pi (other Mac)", kind: .ssh, host: " RASPCORSE", port: 22, username: "vincent")
        context.insert(first)
        context.insert(duplicate)
        try context.save()
        let trust = InMemoryTrustedHostKeys(folder: FakeSSHFolderAccess())
        trust.trust(serverKey, host: host, port: 22)
        let library = MachineLibraryModel(context: context, passwords: FakePasswordStore(),
                                          ssh: SSHServices(folder: FakeSSHFolderAccess(), trustedHostKeys: trust,
                                                           secrets: FakeSSHSecrets()))
        library.delete(first)
        #expect(trust.decision(for: serverKey, host: host, port: 22) == .trusted)
        library.delete(duplicate)
        #expect(trust.decision(for: serverKey, host: host, port: 22) == .unknown)
    }

    @Test func testMergeCopiesImportedKeyToSurvivor() throws {
        let context = try makeTestContext()
        let survivor = Machine(name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent",
                               createdAt: Date(timeIntervalSince1970: 1), sshAuthMethod: .importedKey)
        let dropped = Machine(name: "Pi (other Mac)", kind: .ssh, host: host.uppercased(), port: 22,
                              username: "vincent", createdAt: Date(timeIntervalSince1970: 2),
                              sshAuthMethod: .importedKey)
        context.insert(survivor)
        context.insert(dropped)
        try context.save()
        let secrets = FakeSSHSecrets()
        secrets.items[.sshPrivateKey(dropped.id)] = SSHTestKeys.ed25519Encrypted
        secrets.items[.sshKeyPassphrase(dropped.id)] = SSHTestKeys.passphrase
        secrets.items[.sshLocalKeyPassphrase(dropped.id)] = "this Mac only"

        let removed = LibraryMerger(context: context, passwords: FakePasswordStore(), sshSecrets: secrets).mergeDuplicates()

        #expect(removed == [dropped.id])
        #expect(secrets.items == [
            .sshPrivateKey(survivor.id): SSHTestKeys.ed25519Encrypted,
            .sshKeyPassphrase(survivor.id): SSHTestKeys.passphrase,
        ])
        // Every read of the merge is non-interactive.
        #expect(secrets.reads.allSatisfy { !$0.allowsInteraction })
    }

    /// A survivor with its own key keeps its pair: the dropped copy's passphrase never pairs with it.
    /// A dropped key that cannot be read without a dialog keeps the duplicate for a later merge.
    @Test func mergeKeepsTheSurvivorsOwnKeyAndWaitsForUnreadableOnes() throws {
        let context = try makeTestContext()
        let survivor = Machine(name: "Pi", kind: .ssh, host: host, port: 22, username: "vincent",
                               createdAt: Date(timeIntervalSince1970: 1), sshAuthMethod: .importedKey)
        let dropped = Machine(name: "Pi 2", kind: .ssh, host: host, port: 22, username: "vincent",
                              createdAt: Date(timeIntervalSince1970: 2), sshAuthMethod: .importedKey)
        context.insert(survivor)
        context.insert(dropped)
        try context.save()
        let secrets = FakeSSHSecrets()
        secrets.items[.sshPrivateKey(survivor.id)] = "survivor key"
        secrets.items[.sshPrivateKey(dropped.id)] = "dropped key"
        secrets.items[.sshKeyPassphrase(dropped.id)] = "dropped pass"
        secrets.needsInteraction = [.sshPrivateKey(survivor.id)]
        let merger = LibraryMerger(context: context, passwords: FakePasswordStore(), sshSecrets: secrets)

        #expect(merger.mergeDuplicates().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 2)

        secrets.needsInteraction = []
        #expect(merger.mergeDuplicates() == [dropped.id])
        #expect(secrets.items == [.sshPrivateKey(survivor.id): "survivor key"])
    }
}

/// One line per resolution, for `#expect` (`SSHCredentials` is not Equatable and holds the key).
@MainActor
private func summary(_ resolution: CredentialResolution) -> String {
    switch resolution {
    case .ready(.password(let user, let password)): "password(\(user), \(password))"
    case .ready(.key(let user, let key)): "key(\(user), \(key.algorithm))"
    case .needsPassphrase: "needsPassphrase"
    case .rememberedPassphraseRejected: "rememberedPassphraseRejected"
    case .needsFolderAccess: "needsFolderAccess"
    case .failed(let failure): "failed(\(failure))"
    }
}
