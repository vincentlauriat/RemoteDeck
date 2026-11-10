import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    let apiKeyChecker: any APIKeyChecking
    @State private var editor: APIKeyEditorModel?
    @State private var showsNotices = false

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

            // iCloud Sync (T4.3, AppFlow › Settings Window › Toggle iCloud Sync): turning it on needs a
            // signed-in account; the store takes the change at the next launch.
            Section(settings.t("settings_icloud")) {
                Toggle(settings.t("settings_icloud_sync"), isOn: $settings.iCloudSyncEnabled)
                    .disabled(!settings.iCloudSyncEnabled && !sync.canTurnOn)
                SyncStatusText(line: sync.statusLine(enabled: settings.iCloudSyncEnabled))
                Text(settings.t("settings_icloud_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { sync.refreshAccountStatus() }

            // Clé API Anthropic (Keychain, compte `anthropic.apiKey`) : un brouillon, enregistré seulement
            // par « Enregistrer » après le préfixe et la requête de test (APIKeyEditorModel).
            Section(settings.t("settings_claude")) {
                if let editor {
                    APIKeySection(editor: editor)
                }
                LabeledContent(settings.t("settings_model"), value: settings.claudeModel)
            }

            // Status Notifications (T4.5, AppFlow › Settings Window › Toggle notifications).
            Section(settings.t("settings_notifications")) {
                Toggle(settings.t("settings_status_notifications"), isOn: $settings.notificationsEnabled)
                Text(settings.t("settings_status_notifications_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NotificationPermissionNotice(showsAuthorized: true)
            }

            // Terminal (SSH machines, AppFlow › Settings Window › Terminal options): ⌥ as Meta, font,
            // size, theme and colours; applies to open terminals at once, kept per Mac (UserDefaults).
            Section(settings.t("settings_terminal")) {
                Toggle(settings.t("settings_option_as_meta"), isOn: $settings.terminalOptionAsMeta)
                Text(settings.t("settings_option_as_meta_help"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TerminalAppearanceSettings()
            }

            Section(settings.t("settings_about")) {
                Text(settings.t("settings_about_text"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(settings.t("settings_notices")) { showsNotices = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsNotices) { ThirdPartyNoticesView() }
        .onAppear {
            if editor == nil { editor = APIKeyEditorModel(settings: settings, checker: apiKeyChecker) }
        }
        #if os(macOS)
        .frame(width: 480, height: 680)
        #endif
    }
}

/// The licences of the bundled third-party software (`ThirdPartyNotices.txt`: libghostty-vt and the
/// libraries it links, JetBrains Mono, the SSH stack, Sparkle).
private struct ThirdPartyNoticesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private static let text: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.t("notices_title")).font(.headline)
            ScrollView {
                Text(verbatim: Self.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary)
            HStack {
                Spacer()
                Button(settings.t("ok")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

/// The status line under the iCloud Sync switch.
private struct SyncStatusText: View {
    @Environment(AppSettings.self) private var settings
    let line: LibrarySync.StatusLine

    var body: some View {
        switch line {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(settings.t("sync_checking")).font(.caption)
            }
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(settings.t("sync_syncing")).font(.caption)
            }
        case .synced(let date):
            Label(settings.t("sync_last_synced",
                             date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                .locale(Locale(identifier: settings.localeIdentifier)))),
                  systemImage: "checkmark.icloud")
                .font(.caption).foregroundStyle(.secondary)
        case .on:
            Label(settings.t("sync_on"), systemImage: "icloud").font(.caption).foregroundStyle(.secondary)
        case .off:
            Text(settings.t("sync_off")).font(.caption).foregroundStyle(.secondary)
        case .signedOut:
            Label(settings.t("sync_signed_out"), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
        case .restricted:
            Label(settings.t("sync_restricted"), systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
        case .unavailable:
            Label(settings.t("sync_unavailable"), systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
        case .notEntitled:
            Label(settings.t("sync_not_entitled"), systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
        case .openFailed(let reason):
            Label(settings.t("sync_open_failed", reason), systemImage: "exclamationmark.icloud")
                .font(.caption).foregroundStyle(.red)
        case .failed(let reason):
            Label(settings.t("sync_failed", reason), systemImage: "exclamationmark.icloud")
                .font(.caption).foregroundStyle(.red)
        case .restartToTurnOn:
            Label(settings.t("sync_restart_on"), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
        case .restartToTurnOff:
            Label(settings.t("sync_restart_off"), systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
        }
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
