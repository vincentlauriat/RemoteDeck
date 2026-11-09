import SwiftUI

/// Passphrase Sheet (AppFlow › Terminal tab › Ask a passphrase): the machine's key is encrypted and no
/// passphrase is remembered (a user's Connect only; automatic attempts never ask). A secure field,
/// "Remember in Keychain", "Wrong passphrase" after a rejected one (typed or remembered), Connect and
/// Cancel (Esc), which ends the attempt and closes the tab.
struct PassphraseSheet: View {
    @Environment(AppSettings.self) private var settings
    let machineName: String
    let rejected: Bool
    /// The text under the title; nil: the session's ("The key of “name” is encrypted…").
    var message: String? = nil
    /// "Remember in Keychain": off for the Machine Editor's Test, which never remembers.
    var showsRemember = true
    /// The prominent button's string key.
    var actionKey = "connect"
    let onConnect: (_ passphrase: String, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""
    @State private var remember = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(settings.t("passphrase_title"), systemImage: "lock")
                .font(.headline)
            Text(message ?? settings.t("passphrase_body", machineName))
                .fixedSize(horizontal: false, vertical: true)
            SecureField(settings.t("passphrase_placeholder"), text: $passphrase)
                .textContentType(.password)
                .focused($fieldFocused)
                .onSubmit(connect)
            if rejected {
                Label(settings.t("passphrase_wrong"), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            if showsRemember {
                Toggle(settings.t("passphrase_remember"), isOn: $remember)
            }
            HStack {
                Spacer()
                Button(settings.t("cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(settings.t(actionKey), action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
        .onAppear { fieldFocused = true }
    }

    private func connect() {
        guard !passphrase.isEmpty else { return }
        let typed = passphrase
        passphrase = ""   // not kept in the view once handed over
        onConnect(typed, showsRemember && remember)
    }
}
