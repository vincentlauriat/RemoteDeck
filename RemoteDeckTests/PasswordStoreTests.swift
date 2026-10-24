import Foundation
import Security
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

/// Fallback and migration rules of `MachinePasswordStore` (Vincent, 2026-10-22).
@MainActor
struct PasswordStoreRulesTests {
    let store = FakePasswordStore()
    let id = UUID()

    @Test func storeGoesToSyncedAndDropsAStaleLocalCopy() throws {
        store.localItems[id] = "old"
        #expect(try store.storePassword("new", for: id) == .synced)
        #expect(store.items[id] == "new")
        #expect(store.localItems[id] == nil)
    }

    @Test func missingEntitlementFallsBackToLocal() throws {
        store.syncedSaveError = .missingEntitlement
        #expect(try store.storePassword("pw", for: id) == .local)
        #expect(store.items[id] == nil)
        #expect(store.localItems[id] == "pw")
    }

    @Test func otherSyncedErrorsAreNotHiddenByTheFallback() {
        store.syncedSaveError = .interactionNotAllowed
        #expect(throws: KeychainError.interactionNotAllowed) { try store.storePassword("pw", for: id) }
        #expect(store.localItems[id] == nil)
    }

    @Test func readPrefersSyncedThenLocal() throws {
        store.localItems[id] = "local"
        #expect(try store.storedPassword(for: id)?.password == "local")
        #expect(try store.storedPassword(for: id)?.scope == .local)
        store.items[id] = "synced"
        #expect(try store.storedPassword(for: id)?.password == "synced")
        #expect(try store.storedPassword(for: id)?.scope == .synced)
        #expect(try store.storedPassword(for: UUID()) == nil)
    }

    @Test func syncedReadRefusedWithMissingEntitlementStillFindsLocal() throws {
        store.syncedReadError = .missingEntitlement
        store.localItems[id] = "local"
        #expect(try store.storedPassword(for: id)?.password == "local")

        store.syncedReadError = .interactionNotAllowed
        #expect(throws: KeychainError.interactionNotAllowed) { try store.storedPassword(for: id) }
    }

    @Test func deleteRemovesBothScopes() throws {
        store.items[id] = "a"
        store.localItems[id] = "b"
        try store.deletePassword(for: id)
        #expect(store.items[id] == nil && store.localItems[id] == nil)
    }

    @Test func migrationMovesLocalPasswordsToSynced() {
        let other = UUID()
        let none = UUID()
        store.localItems[id] = "one"
        store.localItems[other] = "two"

        let migrated = store.migrateLocalPasswordsToSynced(machineIDs: [id, other, none])

        #expect(Set(migrated) == [id, other])
        #expect(store.items[id] == "one" && store.items[other] == "two")
        #expect(store.localItems.isEmpty)
    }

    @Test func migrationKeepsLocalPasswordsWhileSyncIsRefused() {
        store.localItems[id] = "one"
        store.syncedSaveError = .missingEntitlement
        #expect(store.migrateLocalPasswordsToSynced(machineIDs: [id]).isEmpty)
        #expect(store.localItems[id] == "one")
        #expect(store.items[id] == nil)
    }

    /// T4.3: the local item goes only once its synced copy reads back equal.
    @Test func migrationKeepsTheLocalPasswordWhenTheCopyDoesNotReadBack() {
        store.localItems[id] = "one"
        store.dropsSyncedWrites = true
        #expect(store.migrateLocalPasswordsToSynced(machineIDs: [id]).isEmpty)
        #expect(store.localItems[id] == "one")
    }

    /// A synced password already there (maybe newer, from another Mac) is kept; the local copy goes.
    @Test func migrationNeverOverwritesAnExistingSyncedPassword() {
        store.localItems[id] = "old-local"
        store.items[id] = "newer-synced"
        #expect(store.migrateLocalPasswordsToSynced(machineIDs: [id]) == [id])
        #expect(store.items[id] == "newer-synced")
        #expect(store.localItems[id] == nil)
        #expect(!store.writes.contains("save.synced"))
    }

    @Test func migrationKeepsTheLocalPasswordWhenTheSyncedReadFails() {
        store.localItems[id] = "one"
        store.syncedReadError = .missingEntitlement
        #expect(store.migrateLocalPasswordsToSynced(machineIDs: [id]).isEmpty)
        #expect(store.localItems[id] == "one")
        #expect(store.writes.isEmpty)
    }

    @Test func inMemoryStoreKeepsScopesApart() throws {
        let memory = InMemoryPasswordStore()
        try memory.setPassword("s", for: id, scope: .synced)
        try memory.setPassword("l", for: id, scope: .local)
        #expect(try memory.password(for: id, scope: .local) == "l")
        #expect(try memory.storedPassword(for: id)?.password == "s")
        try memory.deletePassword(for: id)
        #expect(try memory.storedPassword(for: id) == nil)
    }
}

/// The real Keychain, with a throwaway service, as the app builds it (`KeychainStore` in the
/// data-protection keychain when the signature has a keychain access group). The test host is the
/// Debug app signed with the team's Development profile (T4.3), so the synced save succeeds; a build
/// without the entitlement (ad-hoc, `CODE_SIGNING_ALLOWED=NO`) gets -34018 and the local item.
/// Either way it reads back, survives a migration attempt, and is gone after delete.
@MainActor
struct LiveKeychainFallbackTests {
    let service = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    var entitled: Bool { KeychainStore.processHasKeychainAccessGroup }

    @Test func machinePasswordRoundTripThroughTheFallback() throws {
        let keychain = KeychainStore(service: service, usesDataProtectionKeychain: entitled)
        let id = UUID()
        defer { try? keychain.delete(.machine(id)) }

        let scope = try keychain.storePassword("live-secret", for: id)
        print("KEYCHAIN_FALLBACK_PROBE scope=\(scope) entitled=\(entitled)")
        // M4 (T4.3 review): gated on the entitlement, the item is really synchronizable.
        #expect(scope == (entitled ? .synced : .local))
        let stored = try #require(try keychain.storedPassword(for: id))
        #expect(stored.password == "live-secret")
        #expect(stored.scope == scope)
        if entitled {
            let attributes = try #require(try itemAttributes(service: service, account: .machine(id), synchronizable: true))
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool == true)
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
            #expect(attributes[kSecAttrAccessGroup as String] as? String == "KFLACS69T9.fr.vincentlauriat.remotedeck")
        }

        let migrated = keychain.migrateLocalPasswordsToSynced(machineIDs: [id])
        print("KEYCHAIN_FALLBACK_PROBE migrated=\(migrated.count)")
        #expect(try keychain.storedPassword(for: id)?.password == "live-secret")

        try keychain.deletePassword(for: id)
        #expect(try keychain.password(for: id, scope: .local) == nil)
        #expect(try keychain.storedPassword(for: id) == nil)
    }
}

extension LiveKeychainFallbackTests {
    /// M3 (T4.3 review): a local item of the entitled app lives in the data-protection keychain, where
    /// `ThisDeviceOnly` applies; an item an older build left in the file keychain moves there (read
    /// back first) and leaves the file keychain.
    @Test(.enabled(if: KeychainStore.processHasKeychainAccessGroup))
    func localItemsMoveToTheDataProtectionKeychain() throws {
        let legacy = KeychainStore(service: service)
        let current = KeychainStore(service: service, usesDataProtectionKeychain: true)
        defer {
            try? current.delete(.anthropicAPIKey)
            try? legacy.delete(.anthropicAPIKey)
        }
        try legacy.save("sk-ant-legacy", for: .anthropicAPIKey)
        // Readable before the move (fallback to the file keychain).
        #expect(try current.read(.anthropicAPIKey) == "sk-ant-legacy")

        #expect(try current.migrateLegacyItem(.anthropicAPIKey))
        #expect(try legacy.read(.anthropicAPIKey) == nil)
        #expect(try current.read(.anthropicAPIKey) == "sk-ant-legacy")
        let attributes = try #require(try itemAttributes(service: service, account: .anthropicAPIKey,
                                                     synchronizable: false, dataProtection: true))
        #expect(attributes[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(try current.migrateLegacyItem(.anthropicAPIKey) == false)   // nothing left to move

        try current.delete(.anthropicAPIKey)
        #expect(try current.read(.anthropicAPIKey) == nil)
    }

    /// A local machine password of an unentitled build (file keychain) migrates to iCloud Keychain.
    @Test(.enabled(if: KeychainStore.processHasKeychainAccessGroup))
    func legacyLocalMachinePasswordMigratesToSynced() throws {
        let legacy = KeychainStore(service: service)
        let current = KeychainStore(service: service, usesDataProtectionKeychain: true)
        let id = UUID()
        defer {
            try? current.delete(.machine(id))
            try? legacy.delete(.machine(id))
        }
        try legacy.save("old-local", for: .machine(id), synchronizable: false)

        #expect(current.migrateLocalPasswordsToSynced(machineIDs: [id]) == [id])
        #expect(try current.storedPassword(for: id)?.scope == .synced)
        #expect(try current.storedPassword(for: id)?.password == "old-local")
        #expect(try legacy.read(.machine(id), synchronizable: false) == nil)
    }

    func itemAttributes(service: String, account: KeychainAccount, synchronizable: Bool,
                        dataProtection: Bool = false) throws -> [String: Any]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.name,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? [String: Any]
    }
}

/// The password never reaches the SwiftData files on disk.
@MainActor
struct PasswordNotInStoreTests {
    @Test func savedPasswordIsAbsentFromTheStoreFiles() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckSecretTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try RemoteDeckSchema.makeContainer(storeDirectory: directory)
        let context = ModelContext(container)
        let secret = "Secret-\(UUID().uuidString)"
        let passwords = FakePasswordStore()

        let model = MachineEditorModel(machine: nil, context: context, passwords: passwords,
                                       tester: FakeConnectionTester(), defaultSharedClipboard: true)
        model.name = "Mini"
        model.host = "mini.local"
        model.username = "vincent"
        model.password = secret
        let saved = try #require(model.save())
        #expect(passwords.items[saved.id] == secret)

        // The machine itself did reach the files (so the search below looks at real data).
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(RemoteDeckSchema.syncedStoreFileName) }
        #expect(files.contains(RemoteDeckSchema.syncedStoreFileName))
        var bytes = Data()
        for file in files { bytes += try Data(contentsOf: directory.appending(path: file)) }
        #expect(bytes.range(of: Data("mini.local".utf8)) != nil)
        #expect(bytes.range(of: Data(secret.utf8)) == nil)
    }
}

/// Review 6: the Debug build (this test host) has its own Keychain service, so it never touches the
/// Release app's items in the shared access group.
@MainActor
struct KeychainServiceTests {
    @Test func debugBuildUsesItsOwnService() {
        #expect(KeychainStore.appService == "fr.vincentlauriat.remotedeck.dev")
        #expect(KeychainStore.app.service == KeychainStore.appService)
        #expect(KeychainStore.appService != KeychainStore.defaultService)
    }
}

@MainActor
struct DisplayAndLocalizationTests {
    @Test func addressesBracketIPv6() {
        #expect(Machine(host: "mini.local").displayAddress() == "mini.local:5900")
        #expect(Machine(host: "mini.local").displayAddress(omittingDefaultPort: true) == "mini.local")
        #expect(Machine(host: "10.0.0.2", port: 5901).displayAddress(omittingDefaultPort: true) == "10.0.0.2:5901")
        #expect(Machine(host: "fe80::1%en0", port: 5901).displayAddress() == "[fe80::1%en0]:5901")
        #expect(Machine(host: "::1", port: 5901).displayAddress(omittingDefaultPort: true) == "[::1]:5901")
    }

    @Test func substitutionLeavesPercentSequencesInTheArgumentAlone() throws {
        let suite = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, apiKeys: InMemoryAPIKeyStore())
        settings.languageRaw = AppLanguage.en.rawValue

        #expect(settings.t("no_results_desc", "100%done") == "No machine matches “100%done”.")
        #expect(settings.t("no_results_desc", "a%db") == "No machine matches “a%db”.")
        #expect(settings.t("delete_confirm_title", "%@") == "Delete “%@”?")
        #expect(settings.t("err_name_too_long", 64) == "Use at most 64 characters.")
    }
}
