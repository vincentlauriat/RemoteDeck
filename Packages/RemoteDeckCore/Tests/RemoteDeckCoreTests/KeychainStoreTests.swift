import Foundation
import LocalAuthentication
import Security
import Testing
@testable import RemoteDeckCore

struct KeychainStoreTests {
    // MARK: Query building (no keychain access)

    @Test func accountNamesFollowSchema() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        #expect(KeychainAccount.machine(id).name == "machine.6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(KeychainAccount.anthropicAPIKey.name == "anthropic.apiKey")
    }

    @Test func defaultServiceIsAppService() {
        #expect(KeychainStore().service == "fr.vincentlauriat.remotedeck")
    }

    @Test func machinePasswordQueryIsSynchronizable() {
        let id = UUID()
        let query = KeychainStore().query(for: .machine(id))
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "fr.vincentlauriat.remotedeck")
        #expect(query[kSecAttrAccount as String] as? String == "machine.\(id.uuidString)")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
    }

    /// An automatic reconnect (T5.1) reads with no dialog allowed; a user's attempt as before.
    @Test func readWithoutInteractionCarriesANonInteractiveContext() {
        let store = KeychainStore()
        let quiet = store.readQuery(for: .machine(UUID()), synchronizable: true, allowsInteraction: false)
        let context = quiet[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context?.interactionNotAllowed == true)
        #expect(quiet[kSecReturnData as String] as? Bool == true)
        let normal = store.readQuery(for: .machine(UUID()), synchronizable: true, allowsInteraction: true)
        #expect(normal[kSecUseAuthenticationContext as String] == nil)
        #expect(normal[kSecReturnData as String] as? Bool == true)
    }

    @Test func apiKeyQueryIsLocalOnly() {
        let query = KeychainStore(service: "svc").query(for: .anthropicAPIKey)
        #expect(query[kSecAttrService as String] as? String == "svc")
        #expect(query[kSecAttrAccount as String] as? String == "anthropic.apiKey")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test(arguments: [KeychainAccount.machine(UUID()), .anthropicAPIKey])
    func deleteMatchesEitherSyncFlag(_ account: KeychainAccount) {
        let delete = KeychainStore().deleteQuery(for: account)
        #expect(delete[kSecAttrAccount as String] as? String == account.name)
        #expect(delete[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)
        // Read and save keep the exact flag.
        #expect(KeychainStore().query(for: account)[kSecAttrSynchronizable as String] as? Bool
            == account.isSynchronizable)
    }

    @Test(arguments: [KeychainAccount.machine(UUID()), .anthropicAPIKey])
    func addAndUpdateAttributesCarryAccessibilityAndIdentity(_ account: KeychainAccount) {
        let data = Data("secret".utf8)
        let store = KeychainStore()
        let add = store.addAttributes(for: account, data: data)
        #expect(add[kSecAttrService as String] as? String == "fr.vincentlauriat.remotedeck")
        #expect(add[kSecAttrAccount as String] as? String == account.name)
        #expect(add[kSecAttrSynchronizable as String] as? Bool == account.isSynchronizable)
        #expect(add[kSecValueData as String] as? Data == data)

        let update = store.updateAttributes(data: data, synchronizable: account.isSynchronizable)
        #expect(update[kSecValueData as String] as? Data == data)

        // T5.3 L2: synced items can leave the Mac; local ones (the API key) are this-device-only.
        let expected = account.isSynchronizable
            ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        for attributes in [add, update] {
            #expect(attributes[kSecAttrAccessible as String] as? String == expected as String)
        }
    }

    /// T5.3 L2: the machine-password local fallback is this-device-only too, the synced item never is
    /// (a ThisDeviceOnly class is refused on a synchronizable item).
    @Test func localFallbackItemsAreThisDeviceOnly() {
        let store = KeychainStore()
        let data = Data("pw".utf8)
        let local = store.addAttributes(for: .machine(UUID()), synchronizable: false, data: data)
        #expect(local[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(local[kSecAttrSynchronizable as String] as? Bool == false)
        let synced = store.addAttributes(for: .machine(UUID()), synchronizable: true, data: data)
        #expect(synced[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func errorCarriesStatus() {
        let error = KeychainError(status: errSecMissingEntitlement)
        #expect(error.status == -34018)
        #expect(error.description.contains("-34018"))
    }

    // MARK: Live round trip (non-synchronizable only, see KeychainStore)

    @Test func savesReadsOverwritesAndDeletesLocalItem() throws {
        let store = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        defer { try? store.delete(.anthropicAPIKey) }

        #expect(try store.read(.anthropicAPIKey) == nil)

        try store.save("sk-ant-first", for: .anthropicAPIKey)
        #expect(try store.read(.anthropicAPIKey) == "sk-ant-first")

        try store.save("sk-ant-second-é", for: .anthropicAPIKey)
        #expect(try store.read(.anthropicAPIKey) == "sk-ant-second-é")

        try store.delete(.anthropicAPIKey)
        #expect(try store.read(.anthropicAPIKey) == nil)

        // Deleting a missing item is not an error.
        try store.delete(.anthropicAPIKey)
    }

    @Test func explicitSyncFlagQueriesCarryThatFlag() {
        let id = UUID()
        let local = KeychainStore().query(for: .machine(id), synchronizable: false)
        #expect(local[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(local[kSecAttrAccount as String] as? String == "machine.\(id.uuidString)")
        let add = KeychainStore().addAttributes(for: .machine(id), synchronizable: false, data: Data())
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// The local fallback of a machine password: same service and account, not synchronizable.
    /// `delete(_:)` (any sync flag) removes it.
    @Test func localMachinePasswordRoundTripAndAnyFlagDelete() throws {
        let store = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        let account = KeychainAccount.machine(UUID())
        defer { try? store.delete(account) }

        try store.save("local-secret", for: account, synchronizable: false)
        #expect(try store.read(account, synchronizable: false) == "local-secret")

        try store.delete(account)
        #expect(try store.read(account, synchronizable: false) == nil)

        try store.save("again", for: account, synchronizable: false)
        try store.delete(account, synchronizable: false)
        #expect(try store.read(account, synchronizable: false) == nil)
    }

    // MARK: Data-protection keychain (T4.3)

    @Test func fileKeychainByDefault() {
        let store = KeychainStore()
        #expect(!store.usesDataProtectionKeychain)
        #expect(store.query(for: .anthropicAPIKey)[kSecUseDataProtectionKeychain as String] == nil)
        // `swift test` runs unsigned: no keychain access group, so the app's rule keeps the file keychain.
        #expect(!KeychainStore.processHasKeychainAccessGroup)
    }

    @Test(arguments: [KeychainAccount.machine(UUID()), .anthropicAPIKey])
    func dataProtectionStoreMarksEveryQuery(_ account: KeychainAccount) {
        let store = KeychainStore(usesDataProtectionKeychain: true)
        for synchronizable in [false, true] {
            #expect(store.query(for: account, synchronizable: synchronizable)[kSecUseDataProtectionKeychain as String] as? Bool == true)
            let read = store.readQuery(for: account, synchronizable: synchronizable, allowsInteraction: false)
            #expect(read[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(store.addAttributes(for: account, synchronizable: synchronizable, data: Data())[kSecUseDataProtectionKeychain as String] as? Bool == true)
        }
        #expect(store.deleteQuery(for: account)[kSecUseDataProtectionKeychain as String] as? Bool == true)
        // The copy an older build left in the file keychain: same identity, without the flag.
        let legacy = store.legacyQuery(for: account, synchronizable: false)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecAttrAccount as String] as? String == account.name)
        #expect(legacy[kSecAttrSynchronizable as String] as? Bool == false)
    }

    /// Without the data-protection keychain there is nothing to migrate (and nothing is touched).
    @Test func fileKeychainStoreHasNoLegacyItemToMigrate() throws {
        let store = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        defer { try? store.delete(.anthropicAPIKey) }
        try store.save("sk-ant-x", for: .anthropicAPIKey)
        #expect(try store.migrateLegacyItem(.anthropicAPIKey) == false)
        #expect(try store.read(.anthropicAPIKey) == "sk-ant-x")
    }

    /// Review M3: the file-keychain fallback read carries the non-interactive context too.
    @Test func legacyFallbackReadCanBeNonInteractive() {
        let store = KeychainStore(usesDataProtectionKeychain: true)
        let quiet = store.legacyReadQuery(for: .anthropicAPIKey, allowsInteraction: false)
        #expect((quiet[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(quiet[kSecUseDataProtectionKeychain as String] == nil)
        #expect(quiet[kSecReturnData as String] as? Bool == true)
        #expect(store.legacyReadQuery(for: .anthropicAPIKey, allowsInteraction: true)[kSecUseAuthenticationContext as String] == nil)
    }

    /// Review 6: Debug takes items from the shared service; the source copy goes only when asked.
    @Test func adoptCopiesThenRemovesTheSourceOnlyWhenAsked() throws {
        let source = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        let target = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString).dev")
        let machine = KeychainAccount.machine(UUID())
        defer {
            for store in [source, target] {
                try? store.delete(machine)
                try? store.delete(.anthropicAPIKey)
            }
        }
        try source.save("pw", for: machine, synchronizable: false)
        try source.save("sk-ant-k", for: .anthropicAPIKey)

        #expect(try target.adopt(machine, from: source, removingSource: true))
        #expect(try target.read(machine, synchronizable: false) == "pw")
        #expect(try source.read(machine, synchronizable: false) == nil)

        #expect(try target.adopt(.anthropicAPIKey, from: source, removingSource: false))
        #expect(try target.read(.anthropicAPIKey) == "sk-ant-k")
        #expect(try source.read(.anthropicAPIKey) == "sk-ant-k")

        // An item the target already has is never overwritten.
        try source.save("other", for: .anthropicAPIKey)
        #expect(try target.adopt(.anthropicAPIKey, from: source, removingSource: true) == false)
        #expect(try target.read(.anthropicAPIKey) == "sk-ant-k")
        #expect(try source.read(.anthropicAPIKey) == "other")
    }

    // MARK: Local → synced migration rules (shared by the app and its tests)

    @Test func migrationRules() {
        var local: [UUID: String] = [:]
        var synced: [UUID: String] = [:]
        var dropsWrites = false
        let moved = UUID(), kept = UUID(), already = UUID()
        local[moved] = "m"; local[kept] = "k"; local[already] = "old"; synced[already] = "new"
        func run(_ ids: [UUID]) -> [UUID] {
            LocalPasswordMigration.migrate(ids,
                readLocal: { local[$0] }, readSynced: { synced[$0] },
                writeSynced: { secret, id in if !dropsWrites { synced[id] = secret } },
                deleteLocal: { local[$0] = nil })
        }
        #expect(run([moved, already]) == [moved, already])
        #expect(synced[moved] == "m" && local[moved] == nil)
        #expect(synced[already] == "new" && local[already] == nil)
        dropsWrites = true
        #expect(run([kept]).isEmpty)
        #expect(local[kept] == "k")
    }

    /// Unentitled (`swift test`): the synced save fails, so nothing moves and the local item stays.
    @Test func liveMigrationKeepsLocalItemsWithoutTheEntitlement() throws {
        let store = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(.machine(id)) }
        try store.save("pw", for: .machine(id), synchronizable: false)
        #expect(store.migrateLocalMachinePasswordsToSynced([id]).isEmpty)
        #expect(try store.read(.machine(id), synchronizable: false) == "pw")
    }
}
