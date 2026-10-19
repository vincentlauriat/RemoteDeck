import Foundation
import Testing
import RemoteDeckCore
@testable import RemoteDeck

@MainActor
struct AppSettingsTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let keychain = KeychainStore(service: "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? keychain.delete(.anthropicAPIKey)
    }

    @Test func defaultsMatchBackendSchema() {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        #expect(settings.iCloudSyncEnabled == false)
        #expect(settings.notificationsEnabled == true)
        #expect(settings.defaultSharedClipboard == true)
        #expect(settings.claudeModel == "claude-sonnet-5-5")
        #expect(settings.onboardingCompleted == false)
        #expect(settings.historyRetentionDays == 365)
        #expect(settings.appearance == .system)
        #expect(settings.language == .system)
        #expect(settings.anthropicAPIKey.isEmpty)
        #expect(settings.keychainError == nil)
    }

    @Test func persistsChangesToInjectedDefaults() {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.iCloudSyncEnabled = true
        settings.notificationsEnabled = false
        settings.defaultSharedClipboard = false
        settings.claudeModel = "claude-opus-5-5"
        settings.onboardingCompleted = true
        settings.historyRetentionDays = 30
        settings.appearanceRaw = AppearanceMode.dark.rawValue

        #expect(defaults.bool(forKey: "iCloudSyncEnabled") == true)
        #expect(defaults.object(forKey: "notificationsEnabled") as? Bool == false)

        let reloaded = AppSettings(defaults: defaults, keychain: keychain)
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
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.claudeModel = "probe-\(suiteName)"
        #expect(UserDefaults.standard.string(forKey: "claudeModel") != settings.claudeModel)
    }

    @Test func storesAPIKeyInKeychainAndDeletesWhenEmptied() throws {
        defer { cleanUp() }
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.anthropicAPIKey = "sk-ant-test"
        #expect(settings.keychainError == nil)
        #expect(try keychain.read(.anthropicAPIKey) == "sk-ant-test")
        #expect(defaults.dictionaryRepresentation().values.contains { $0 as? String == "sk-ant-test" } == false)
        #expect(AppSettings(defaults: defaults, keychain: keychain).anthropicAPIKey == "sk-ant-test")

        settings.anthropicAPIKey = ""
        #expect(try keychain.read(.anthropicAPIKey) == nil)
    }
}
