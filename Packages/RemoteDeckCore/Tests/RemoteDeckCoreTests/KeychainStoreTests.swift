import Foundation
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

        let update = store.updateAttributes(data: data)
        #expect(update[kSecValueData as String] as? Data == data)

        for attributes in [add, update] {
            #expect(attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlock as String)
        }
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
}
