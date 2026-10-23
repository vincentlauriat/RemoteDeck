import Foundation
import Testing
import RemoteDeckCore
@testable import RemoteDeck

@MainActor
struct AppSettingsTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    /// Never the Keychain: the API key goes through an in-memory store.
    let keychain = InMemoryAPIKeyStore()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func defaultsMatchBackendSchema() {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, apiKeys: keychain)
        #expect(settings.iCloudSyncEnabled == false)
        #expect(settings.notificationsEnabled == true)
        #expect(settings.defaultSharedClipboard == true)
        #expect(settings.claudeModel == "claude-opus-5-5")
        #expect(settings.onboardingCompleted == false)
        #expect(settings.historyRetentionDays == 365)
        #expect(settings.appearance == .system)
        #expect(settings.language == .system)
        #expect(settings.anthropicAPIKey.isEmpty)
        #expect(settings.keychainError == nil)
    }

    @Test func persistsChangesToInjectedDefaults() {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, apiKeys: keychain)
        settings.iCloudSyncEnabled = true
        settings.notificationsEnabled = false
        settings.defaultSharedClipboard = false
        settings.onboardingCompleted = true
        settings.historyRetentionDays = 30
        settings.appearanceRaw = AppearanceMode.dark.rawValue

        #expect(defaults.bool(forKey: "iCloudSyncEnabled") == true)
        #expect(defaults.object(forKey: "notificationsEnabled") as? Bool == false)

        let reloaded = AppSettings(defaults: defaults, apiKeys: keychain)
        #expect(reloaded.iCloudSyncEnabled == true)
        #expect(reloaded.notificationsEnabled == false)
        #expect(reloaded.defaultSharedClipboard == false)
        #expect(reloaded.claudeModel == "claude-opus-5-5")
        #expect(reloaded.onboardingCompleted == true)
        #expect(reloaded.historyRetentionDays == 30)
        #expect(reloaded.appearance == .dark)
    }

    @Test func doesNotWriteToStandardDefaults() {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, apiKeys: keychain)
        settings.languageRaw = "probe-\(suiteName)"
        #expect(UserDefaults.standard.string(forKey: "language") != settings.languageRaw)
    }

    /// The model is the constant: a value left in UserDefaults (an older default) is never used.
    @Test func storedModelValueIsIgnored() {
        defer { cleanUp() }
        defaults.set("claude-sonnet-5-5", forKey: "claudeModel")
        #expect(AppSettings(defaults: defaults, apiKeys: keychain).claudeModel == "claude-opus-5-5")
    }

    @Test func storesAPIKeyOnlyThroughStoreAndRemove() throws {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, apiKeys: keychain)
        try settings.storeAPIKey("sk-ant-test")
        #expect(settings.keychainError == nil)
        #expect(keychain.key == "sk-ant-test")
        #expect(defaults.dictionaryRepresentation().values.contains { $0 as? String == "sk-ant-test" } == false)
        #expect(AppSettings(defaults: defaults, apiKeys: keychain).anthropicAPIKey == "sk-ant-test")

        settings.removeAPIKey()
        #expect(keychain.key == nil)
        #expect(settings.anthropicAPIKey.isEmpty)
        #expect(keychain.writes == 2)
    }

    @Test func refusedSaveKeepsThePreviousKey() throws {
        defer { cleanUp() }
        keychain.key = "sk-ant-old"
        let settings = AppSettings(defaults: defaults, apiKeys: keychain)
        keychain.saveError = .interactionNotAllowed
        #expect(throws: KeychainError.self) { try settings.storeAPIKey("sk-ant-new") }
        #expect(settings.anthropicAPIKey == "sk-ant-old")
        #expect(settings.keychainError == .interactionNotAllowed)
    }
}
