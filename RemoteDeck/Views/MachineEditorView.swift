import SwiftUI
import RemoteDeckCore
import SSHKit

/// Machine Editor sheet (AppFlow › Machine Editor, DesignBrief › Machine Editor): kind first,
/// inline red errors under the fields, Test next to Save, Esc cancels, ⌘S saves. SSH machines
/// (DesignBrief › Machine Editor, SSH) show the authentication method and the port forwards instead of
/// the screen settings.
struct MachineEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: MachineEditorModel
    let onSave: (Machine) -> Void

    @State private var confirmsTrustRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            Text(settings.t(model.isNew ? "editor_new_title" : "editor_edit_title"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 20)
            Form {
                Section(settings.t("editor_section_connection")) {
                    Picker(settings.t("field_kind"), selection: $model.kind) {
                        ForEach(MachineKind.editorKinds, id: \.self) { kind in
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
                        if model.kind == .ssh {
                            Button(settings.t("editor_import_config")) {
                                Task { await model.openConfigImport() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            folderProblemText
                        }
                        if model.hostIsPublicAddress {
                            // T5.3 H1: a public IP literal; the session asks again at connect time.
                            Label(settings.t("editor_public_host"), systemImage: "exclamationmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: .systemOrange))
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                    if model.kind == .ssh {
                        sshAuthentication
                    }
                    if model.showsPasswordField {
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField(settings.t("field_password"), text: $model.password,
                                        prompt: model.passwordIsOptional ? Text(settings.t("optional_placeholder")) : nil)
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
                            } else if model.kind == .anthropicVM {
                                Text(settings.t("anthropic_vm_password_note"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if model.kind == .ssh, model.hasTrustedHostKey {
                        Button(settings.t("editor_remove_trust")) { confirmsTrustRemoval = true }
                            .controlSize(.small)
                    }
                }

                if model.kind == .ssh {
                    forwardsSection
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
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(settings.t("field_watch"), isOn: $model.isWatched)
                        // Notifications not allowed (or off in Settings): said here, the dot works anyway.
                        if model.isWatched { NotificationPermissionNotice() }
                    }
                }

                if model.showsScreenSettings {
                    Section(settings.t("editor_section_session")) {
                        Picker(settings.t("field_scaling"), selection: $model.scalingMode) {
                            ForEach(ScalingMode.allCases, id: \.self) { mode in
                                Text(settings.t("scaling_\(mode.rawValue)")).tag(mode)
                            }
                        }
                        Toggle(settings.t("field_shared_clipboard"), isOn: $model.sharedClipboard)
                    }
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
        .sheet(item: sheetBinding) { sheet in
            sheetView(sheet)
        }
        .confirmationDialog(settings.t("editor_remove_trust_title", trustedAddress), isPresented: $confirmsTrustRemoval) {
            Button(settings.t("editor_remove_trust_action"), role: .destructive) { model.removeTrustedKeys() }
            Button(settings.t("cancel"), role: .cancel) {}
        } message: {
            Text(settings.t("editor_remove_trust_body"))
        }
    }

    // MARK: SSH

    /// Authentication method and its control (AppFlow › Choose the authentication method).
    @ViewBuilder
    private var sshAuthentication: some View {
        Picker(settings.t("editor_ssh_auth"), selection: $model.sshAuth) {
            ForEach(SSHAuthMethod.allCases, id: \.self) { method in
                Text(settings.t("ssh_auth_\(method.rawValue)")).tag(method)
            }
        }
        switch model.sshAuth {
        case .password:
            EmptyView()   // the password field below
        case .keyInSSHFolder:
            field(.sshKeyFileName) {
                if model.sshFolderGranted {
                    if model.sshKeyChoices.isEmpty {
                        LabeledContent(settings.t("editor_ssh_key_file")) {
                            Text(settings.t("editor_ssh_no_keys")).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker(settings.t("editor_ssh_key_file"), selection: $model.sshKeyFileName) {
                            ForEach(model.sshKeyChoices, id: \.self) { name in
                                Text(verbatim: name).font(.system(size: 12, design: .monospaced)).tag(name)
                            }
                        }
                    }
                } else {
                    Button(settings.t("editor_ssh_grant")) {
                        Task { await model.grantSSHFolder() }
                    }
                }
                folderProblemText
                note(settings.t("editor_ssh_folder_note"))
            }
        case .importedKey:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button(settings.t("editor_import_key")) {
                        Task { await model.chooseKeyToImport() }
                    }
                    if let key = model.importedKey {
                        Text(verbatim: "\(key.algorithm)  \(key.fingerprint)")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if model.importedKey?.isEncrypted == true {
                    note(settings.t("editor_imported_key_encrypted"))
                } else if model.importedKey == nil, model.hasStoredImportedKey {
                    note(settings.t("editor_imported_key_stored"))
                }
                if let problem = model.keyProblem {
                    errorText(problem.message(settings.t))
                }
                if let failure = model.keyFailure {
                    errorText(settings.t("key_save_failed", String(failure.status)))
                }
                note(settings.t("editor_imported_key_note"))
            }
        }
    }

    /// Port forwards (AppFlow › Edit port forwards): label, local port → remote host : remote port.
    private var forwardsSection: some View {
        Section(settings.t("editor_section_forwards")) {
            if model.portForwards.isEmpty {
                Text(settings.t("forwards_empty")).foregroundStyle(.secondary)
            }
            ForEach($model.portForwards) { $forward in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField(settings.t("forward_label"), text: Binding(
                            get: { forward.label ?? "" }, set: { forward.label = $0 }),
                                  prompt: Text(settings.t("forward_label")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button {
                            model.removeForward(forward.id)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .help(settings.t("forward_remove"))
                        .accessibilityLabel(settings.t("forward_remove"))
                    }
                    HStack(spacing: 4) {
                        TextField(settings.t("forward_local_port"), value: $forward.localPort, format: .number.grouping(.never),
                                  prompt: Text(settings.t("forward_local_port")))
                            .labelsHidden()
                            .frame(width: 64)
                            .help(settings.t("forward_local_port"))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField(settings.t("forward_remote_host"), text: $forward.remoteHost,
                                  prompt: Text(verbatim: "localhost"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                            .help(settings.t("forward_remote_host"))
                        Text(verbatim: ":").foregroundStyle(.secondary)
                        TextField(settings.t("forward_remote_port"), value: $forward.remotePort, format: .number.grouping(.never),
                                  prompt: Text(settings.t("forward_remote_port")))
                            .labelsHidden()
                            .frame(width: 64)
                            .help(settings.t("forward_remote_port"))
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    if let reason = model.forwardIssue(for: forward.id) {
                        errorText(reason.message(for: .portForwards, settings.t))
                    }
                }
                .onChange(of: forward) { model.clearForwardIssue(for: forward.id) }
            }
            Button {
                model.addForward()
            } label: {
                Label(settings.t("forward_add"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var folderProblemText: some View {
        switch model.sshFolderProblem {
        case .notSSHFolder(let name): errorText(settings.t("editor_ssh_not_ssh_folder", name))
        case .bookmarkFailed: errorText(settings.t("editor_ssh_bookmark_failed"))
        case nil: EmptyView()
        }
    }

    /// `host:port` of the saved machine, as the trusted keys are kept.
    private var trustedAddress: String {
        let host = model.savedHost ?? ""
        let port = model.savedPort ?? 22
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private var sheetBinding: Binding<EditorSheet?> {
        Binding(get: { model.sheet }, set: { if $0 == nil { model.dismissSheet() } })
    }

    @ViewBuilder
    private func sheetView(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case .hostKey(let prompt):
            HostKeySheet(prompt: prompt, onTrust: model.trustHostKey, onCancel: model.rejectHostKey)
        case .testPassphrase(let rejected):
            PassphraseSheet(machineName: model.name, rejected: rejected, message: settings.t("passphrase_test_body"),
                            showsRemember: false, actionKey: "test",
                            onConnect: { passphrase, _ in model.provideTestPassphrase(passphrase) },
                            onCancel: model.cancelTestPassphrase)
        case .savePassphrase(let rejected):
            PassphraseSheet(machineName: model.name, rejected: rejected, message: settings.t("passphrase_save_body"),
                            actionKey: "save",
                            onConnect: { passphrase, remember in
                                Task {
                                    if let machine = await model.submitSavePassphrase(passphrase, remember: remember) {
                                        onSave(machine)
                                        dismiss()
                                    }
                                }
                            },
                            onCancel: model.cancelSavePassphrase)
        case .configImport:
            SSHConfigImportSheet(state: model.configImport ?? .empty, onImport: model.chooseConfigHost,
                                 onCancel: model.dismissConfigImport)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        case .sshKeyFileName: model.sshKeyFileName
        // Forward rows clear their own error (`clearForwardIssue`).
        case .portForwards: ""
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
