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

/// The real Keychain, with a throwaway service: in this ad-hoc-signed test host the synced save is
/// refused with -34018, so the password must land in a local item; with the entitlement it is synced.
/// Either way it reads back, survives a migration attempt, and is gone after delete.
@MainActor
struct LiveKeychainFallbackTests {
    @Test func machinePasswordRoundTripThroughTheFallback() throws {
        let keychain = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? keychain.delete(.machine(id)) }

        let scope = try keychain.storePassword("live-secret", for: id)
        print("KEYCHAIN_FALLBACK_PROBE scope=\(scope)")
        let stored = try #require(try keychain.storedPassword(for: id))
        #expect(stored.password == "live-secret")
        #expect(stored.scope == scope)

        let migrated = keychain.migrateLocalPasswordsToSynced(machineIDs: [id])
        print("KEYCHAIN_FALLBACK_PROBE migrated=\(migrated.count)")
        #expect(try keychain.storedPassword(for: id)?.password == "live-secret")

        try keychain.deletePassword(for: id)
        #expect(try keychain.password(for: id, scope: .local) == nil)
        #expect(try keychain.storedPassword(for: id) == nil)
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
