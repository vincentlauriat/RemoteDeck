import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    let apiKeyChecker: any APIKeyChecking
    @State private var editor: APIKeyEditorModel?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(settings.t("settings_appearance")) {
                Picker(settings.t("settings_appearance"), selection: $settings.appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(settings.t(mode.titleKey)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(settings.t("settings_language")) {
                Picker(settings.t("settings_language"), selection: $settings.languageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang == .system ? settings.t("language_system") : lang.nativeName)
                            .tag(lang.rawValue)
                    }
                }
                .labelsHidden()
            }

            // Clé API Anthropic (Keychain, compte `anthropic.apiKey`) : un brouillon, enregistré seulement
            // par « Enregistrer » après le préfixe et la requête de test (APIKeyEditorModel).
            Section(settings.t("settings_claude")) {
                if let editor {
                    APIKeySection(editor: editor)
                }
                LabeledContent(settings.t("settings_model"), value: settings.claudeModel)
            }

            Section(settings.t("settings_about")) {
                Text(settings.t("settings_about_text"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if editor == nil { editor = APIKeyEditorModel(settings: settings, checker: apiKeyChecker) }
        }
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }
}

/// The API key rows: present or absent (never the key), the draft field, Save and Remove, the check's
/// outcome (AppFlow › Settings Window › Save API key).
private struct APIKeySection: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var editor: APIKeyEditorModel

    var body: some View {
        Label(settings.t(editor.hasStoredKey ? "apikey_present" : "apikey_absent"),
              systemImage: editor.hasStoredKey ? "key.fill" : "key")
            .font(.callout)
        HStack {
            SecureField(settings.t("apikey_placeholder"), text: $editor.draft)
                .onSubmit { editor.save() }
            Button(settings.t("apikey_save")) { editor.save() }
                .disabled(!editor.canSave)
        }
        status
        if editor.hasStoredKey {
            Button(settings.t("apikey_remove"), role: .destructive) { editor.remove() }
        }
        Text(settings.t("apikey_help"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var status: some View {
        switch editor.status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(settings.t("apikey_checking")).font(.caption)
            }
        case .saved:
            Label(settings.t("apikey_valid"), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .removed:
            Text(settings.t("apikey_removed")).font(.caption).foregroundStyle(.secondary)
        case .badPrefix:
            Text(settings.t("apikey_bad_prefix")).font(.caption).foregroundStyle(.red)
        case .rejected:
            Label(settings.t("apikey_invalid"), systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        case .uncheckable(let error):
            Text(settings.t("apikey_uncheckable", AssistantCopy.message(.api(error), settings.t)))
                .font(.caption).foregroundStyle(.red)
        case .keychain(let status):
            Text(settings.t("apikey_keychain_error", status)).font(.caption).foregroundStyle(.red)
        }
    }
}
