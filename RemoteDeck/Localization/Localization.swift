import SwiftUI
import Observation
import ClaudeKit
import RemoteDeckCore

// MARK: - Clé API

/// Where the Anthropic API key lives: the Keychain in the app (account `anthropic.apiKey`, local to
/// this Mac), in memory under XCTest and in the Debug demo, so neither reads nor writes the user's key.
protocol APIKeyStore {
    func readKey() throws(KeychainError) -> String?
    func saveKey(_ key: String) throws(KeychainError)
    func deleteKey() throws(KeychainError)
}

struct KeychainAPIKeyStore: APIKeyStore {
    var keychain = KeychainStore.app

    func readKey() throws(KeychainError) -> String? { try keychain.read(.anthropicAPIKey) }
    func saveKey(_ key: String) throws(KeychainError) { try keychain.save(key, for: .anthropicAPIKey) }
    func deleteKey() throws(KeychainError) { try keychain.delete(.anthropicAPIKey) }
}

final class InMemoryAPIKeyStore: APIKeyStore {
    var key: String?
    var saveError: KeychainError?
    /// Saves and deletes, for the tests ("no write per keystroke").
    private(set) var writes = 0

    init(key: String? = nil) {
        self.key = key
    }

    func readKey() throws(KeychainError) -> String? { key }

    func saveKey(_ key: String) throws(KeychainError) {
        writes += 1
        if let saveError { throw saveError }
        self.key = key
    }

    func deleteKey() throws(KeychainError) {
        writes += 1
        key = nil
    }
}

// MARK: - Apparence

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    var titleKey: String {
        switch self {
        case .system: return "appearance_system"
        case .light:  return "appearance_light"
        case .dark:   return "appearance_dark"
        }
    }
}

// MARK: - Langue

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, fr, en
    var id: String { rawValue }

    /// Libellé affiché dans le sélecteur (langues dans leur propre graphie).
    var nativeName: String {
        switch self {
        case .system: return ""          // remplacé par la chaîne localisée "language_system"
        case .fr:     return "Français"
        case .en:     return "English"
        }
    }
}

/// Identifiant de locale courant, lu par les modèles (formatage de dates)
/// sans dépendance directe à l'environnement SwiftUI.
@MainActor
enum AppLocale {
    static var identifier: String = "en_US"
}

// MARK: - Réglages observables

@Observable
@MainActor
final class AppSettings {
    /// Clés `UserDefaults` (BackendSchema › AppSettings).
    enum Key {
        static let appearance = "appearance"
        static let language = "language"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let defaultSharedClipboard = "defaultSharedClipboard"
        static let onboardingCompleted = "onboardingCompleted"
        static let historyRetentionDays = "historyRetentionDays"
    }

    /// The Claude Assistant's model (`ClaudeAPI.defaultModel`, Claude Opus 5.5).
    static let defaultClaudeModel = ClaudeAPI.defaultModel
    static let defaultHistoryRetentionDays = 365

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apiKeys: any APIKeyStore

    var appearanceRaw: String {
        didSet { defaults.set(appearanceRaw, forKey: Key.appearance) }
    }
    var languageRaw: String {
        didSet {
            defaults.set(languageRaw, forKey: Key.language)
            AppLocale.identifier = localeIdentifier
        }
    }

    var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSyncEnabled) }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    var defaultSharedClipboard: Bool {
        didSet { defaults.set(defaultSharedClipboard, forKey: Key.defaultSharedClipboard) }
    }
    /// The Claude Assistant's model: the one constant (`ClaudeAPI.defaultModel`), never read from
    /// UserDefaults, so a stale or unknown stored value cannot send another model the toolset.
    var claudeModel: String { Self.defaultClaudeModel }
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays) }
    }

    /// Clé API Anthropic, stockée dans le Keychain (compte `anthropic.apiKey`, non synchronisé),
    /// jamais dans UserDefaults. Changée seulement par `storeAPIKey` (après le contrôle du préfixe et
    /// la requête de test, `APIKeyEditorModel`) et `removeAPIKey`, jamais à chaque frappe.
    private(set) var anthropicAPIKey: String

    /// Dernier échec Keychain (lecture ou écriture de la clé API), `nil` si tout va bien.
    private(set) var keychainError: KeychainError? = nil

    var apiKeyConfigured: Bool { !anthropicAPIKey.isEmpty }

    init(defaults: UserDefaults = .standard, apiKeys: any APIKeyStore = KeychainAPIKeyStore()) {
        self.defaults = defaults
        self.apiKeys = apiKeys
        appearanceRaw = defaults.string(forKey: Key.appearance) ?? AppearanceMode.system.rawValue
        languageRaw = defaults.string(forKey: Key.language) ?? AppLanguage.system.rawValue
        // `object(forKey:)`, pas `bool(forKey:)` : une clé absente doit donner le défaut, pas false/0.
        iCloudSyncEnabled = defaults.object(forKey: Key.iCloudSyncEnabled) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        defaultSharedClipboard = defaults.object(forKey: Key.defaultSharedClipboard) as? Bool ?? true
        onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
        historyRetentionDays = defaults.object(forKey: Key.historyRetentionDays) as? Int
            ?? Self.defaultHistoryRetentionDays
        do {
            anthropicAPIKey = try apiKeys.readKey() ?? ""
        } catch {
            anthropicAPIKey = ""
            keychainError = error
        }
        AppLocale.identifier = localeIdentifier
    }

    /// Saves a checked key; on a Keychain error the previous key stays.
    func storeAPIKey(_ key: String) throws(KeychainError) {
        do {
            try apiKeys.saveKey(key)
        } catch {
            keychainError = error
            throw error
        }
        anthropicAPIKey = key
        keychainError = nil
    }

    func removeAPIKey() {
        do {
            try apiKeys.deleteKey()
            anthropicAPIKey = ""
            keychainError = nil
        } catch {
            keychainError = error
        }
    }

    var appearance: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }
    var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .system }

    /// Code langue effectif (résout `.system` via les préférences de l'OS).
    var effectiveLang: String {
        if language == .system {
            let pref = Locale.preferredLanguages.first ?? "en"
            if pref.hasPrefix("fr") { return "fr" }
            return "en"
        }
        return language.rawValue
    }

    var localeIdentifier: String {
        switch effectiveLang {
        case "fr": return "fr_FR"
        default:   return "en_US"
        }
    }

    // MARK: Traduction

    func t(_ key: String) -> String {
        let lang = effectiveLang
        return Strings.table[lang]?[key]
            ?? Strings.table["en"]?[key]
            ?? key
    }

    /// Traduction avec un argument : remplace le seul marqueur présent dans la chaîne (`%@`, sinon
    /// `%d`), une seule fois, pour ne jamais retoucher un `%d`/`%@` du texte inséré.
    func t(_ key: String, _ argument: some CustomStringConvertible) -> String {
        let template = t(key)
        let placeholder = template.contains("%@") ? "%@" : "%d"
        guard let range = template.range(of: placeholder) else { return template }
        return template.replacingCharacters(in: range, with: argument.description)
    }

    /// Compteur avec unité pluralisée : « 3 items », « 1 item »…
    func count(_ n: Int, _ oneKey: String, _ manyKey: String) -> String {
        let unit = t(n <= 1 ? oneKey : manyKey)
        return "\(n) \(unit)"
    }
}
