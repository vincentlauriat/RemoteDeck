import SwiftUI
import RemoteDeckCore

/// Machine Editor sheet (AppFlow › Machine Editor, DesignBrief › Machine Editor): kind first,
/// inline red errors under the fields, Test next to Save, Esc cancels, ⌘S saves.
struct MachineEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MachineEditorModel
    let onSave: (Machine) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(settings.t(model.isNew ? "editor_new_title" : "editor_edit_title"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 20)
            Form {
                Section(settings.t("editor_section_connection")) {
                    Picker(settings.t("field_kind"), selection: $model.kind) {
                        ForEach(MachineKind.allCases, id: \.self) { kind in
                            Label(settings.t(kind.titleKey), systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .onChange(of: model.kind) { model.clearIssue(for: .username) }

                    field(.name) {
                        TextField(settings.t("field_name"), text: $model.name)
                    }
                    field(.host) {
                        // SF Mono for the value only: the label keeps the body font.
                        TextField(text: $model.host, prompt: Text(settings.t("host_placeholder"))) {
                            Text(settings.t("field_host")).font(.body)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                    }
                    field(.port) {
                        TextField(text: $model.portText) {
                            Text(settings.t("field_port")).font(.body)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                    if model.showsUsername {
                        field(.username) {
                            TextField(settings.t("field_username"), text: $model.username,
                                      prompt: model.requiresUsername ? nil : Text(settings.t("optional_placeholder")))
                                .autocorrectionDisabled()
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(settings.t("field_password"), text: $model.password)
                            .onChange(of: model.password) { model.clearPasswordError() }
                        if let failure = model.passwordFailure {
                            errorText(failure.error.passwordMessage(deleting: failure.deleting, settings.t))
                        } else if let error = model.passwordReadError {
                            errorText(settings.t("password_unreadable", String(error.status)))
                        } else if model.passwordScope == .local {
                            Text(settings.t("password_local_note"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section(settings.t("editor_section_library")) {
                    Picker(settings.t("field_group"), selection: $model.groupChoice) {
                        Text(settings.t("group_none")).tag(MachineEditorModel.GroupChoice.none)
                        ForEach(model.groups) { group in
                            Text(group.name).tag(MachineEditorModel.GroupChoice.existing(group.id))
                        }
                        Divider()
                        Text(settings.t("group_new")).tag(MachineEditorModel.GroupChoice.new)
                    }
                    if model.groupChoice == .new {
                        field(.groupName) {
                            TextField(settings.t("field_new_group_name"), text: $model.newGroupName)
                        }
                    }
                    Toggle(settings.t("field_favorite"), isOn: $model.isFavorite)
                    Toggle(settings.t("field_watch"), isOn: $model.isWatched)
                }

                Section(settings.t("editor_section_session")) {
                    Picker(settings.t("field_scaling"), selection: $model.scalingMode) {
                        ForEach(ScalingMode.allCases, id: \.self) { mode in
                            Text(settings.t("scaling_\(mode.rawValue)")).tag(mode)
                        }
                    }
                    Toggle(settings.t("field_shared_clipboard"), isOn: $model.sharedClipboard)
                }

                if let error = model.saveError {
                    errorText(settings.t("save_failed", error))
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
                .padding(20)
        }
        .frame(width: 460)
        .onDisappear { model.cancelTest() }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(settings.t("test")) { model.testConnection() }
                .disabled(model.testState == .testing)
            testStatus
            Spacer(minLength: 8)
            Button(settings.t("cancel")) {
                model.cancelTest()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(settings.t("save")) {
                if let machine = model.save() {
                    onSave(machine)
                    dismiss()
                }
            }
            .keyboardShortcut("s")
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch model.testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
            Text(settings.t("test_testing")).font(.system(size: 11)).foregroundStyle(.secondary)
        case .succeeded:
            Label(settings.t("test_success"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let failure):
            Label(failure.message(settings.t), systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Fields

    /// A field with its inline validation error (11 pt red, DesignBrief › Forms).
    private func field(_ field: MachineValidator.Field, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let reason = model.issue(for: field) {
                errorText(reason.message(for: field, settings.t))
            }
        }
        .onChange(of: fieldValue(field)) { model.clearIssue(for: field) }
    }

    private func fieldValue(_ field: MachineValidator.Field) -> String {
        switch field {
        case .name: model.name
        case .host: model.host
        case .port: model.portText
        case .username: model.username
        case .groupName: model.newGroupName
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
