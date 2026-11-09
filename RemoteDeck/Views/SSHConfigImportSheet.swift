import SwiftUI
import SSHKit

/// SSH Config Import Sheet (AppFlow › Machine Editor › Import from ~/.ssh/config): the `Host` blocks
/// of `~/.ssh/config` with a single plain alias; Import pre-fills the Machine Editor with the chosen
/// one. A file without such a block, missing or unreadable, says so instead of the list.
struct SSHConfigImportSheet: View {
    @Environment(AppSettings.self) private var settings
    let state: ConfigImportState
    let onImport: (SSHConfigHost) -> Void
    let onCancel: () -> Void

    /// Index in the list: a file may repeat an alias.
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(settings.t("config_import_title"), systemImage: "terminal")
                .font(.headline)
            if let hosts = state.hosts {
                Text(settings.t("config_import_body"))
                    .fixedSize(horizontal: false, vertical: true)
                List(Array(hosts.enumerated()), id: \.offset, selection: $selection) { index, host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: host.alias).font(.body)
                        Text(verbatim: summary(host))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .tag(index)
                }
                .frame(minHeight: 160)
                .onAppear { if selection == nil, !hosts.isEmpty { selection = 0 } }
            } else {
                Text(settings.t(messageKey))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(settings.t("cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if state.hosts != nil {
                    Button(settings.t("config_import_choose"), action: importSelected)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedHost == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var selectedHost: SSHConfigHost? {
        guard let hosts = state.hosts, let selection, hosts.indices.contains(selection) else { return nil }
        return hosts[selection]
    }

    private func importSelected() {
        guard let host = selectedHost else { return }
        onImport(host)
    }

    private var messageKey: String {
        switch state {
        case .hosts, .empty: "config_import_empty"
        case .noFile: "config_import_no_file"
        case .unreadable: "config_import_unreadable"
        }
    }

    /// `user@host:port · key`, as the editor will fill it.
    private func summary(_ host: SSHConfigHost) -> String {
        let user = host.user.map { "\($0)@" } ?? ""
        let address = "\(user)\(host.hostName ?? host.alias):\(host.port ?? 22)"
        return host.identityFile.map { "\(address) · \($0)" } ?? address
    }
}
