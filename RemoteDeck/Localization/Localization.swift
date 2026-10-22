import SwiftUI
import Observation
import RemoteDeckCore

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
        static let claudeModel = "claudeModel"
        static let onboardingCompleted = "onboardingCompleted"
        static let historyRetentionDays = "historyRetentionDays"
    }

    static let defaultClaudeModel = "claude-sonnet-5-5"
    static let defaultHistoryRetentionDays = 365

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore

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
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Key.claudeModel) }
    }
    var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }
    var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays) }
    }

    /// Clé API Anthropic, stockée dans le Keychain (compte `anthropic.apiKey`, non synchronisé),
    /// jamais dans UserDefaults. Une chaîne vide supprime l'entrée.
    var anthropicAPIKey: String {
        didSet { persistAPIKey() }
    }

    /// Dernier échec Keychain (lecture ou écriture de la clé API), `nil` si tout va bien.
    private(set) var keychainError: KeychainError? = nil

    var apiKeyConfigured: Bool { !anthropicAPIKey.isEmpty }

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        appearanceRaw = defaults.string(forKey: Key.appearance) ?? AppearanceMode.system.rawValue
        languageRaw = defaults.string(forKey: Key.language) ?? AppLanguage.system.rawValue
        // `object(forKey:)`, pas `bool(forKey:)` : une clé absente doit donner le défaut, pas false/0.
        iCloudSyncEnabled = defaults.object(forKey: Key.iCloudSyncEnabled) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        defaultSharedClipboard = defaults.object(forKey: Key.defaultSharedClipboard) as? Bool ?? true
        claudeModel = defaults.string(forKey: Key.claudeModel) ?? Self.defaultClaudeModel
        onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
        historyRetentionDays = defaults.object(forKey: Key.historyRetentionDays) as? Int
            ?? Self.defaultHistoryRetentionDays
        do {
            anthropicAPIKey = try keychain.read(.anthropicAPIKey) ?? ""
        } catch {
            anthropicAPIKey = ""
            keychainError = error
        }
        AppLocale.identifier = localeIdentifier
    }

    private func persistAPIKey() {
        do {
            if anthropicAPIKey.isEmpty {
                try keychain.delete(.anthropicAPIKey)
            } else {
                try keychain.save(anthropicAPIKey, for: .anthropicAPIKey)
            }
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
