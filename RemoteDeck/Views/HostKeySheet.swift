import SwiftUI

/// Host Key Sheet (AppFlow › Terminal tab › Trust a host key, DesignBrief › Host key sheet): the first
/// connection to a `host:port` whose key RemoteDeck does not know. 420 pt, 20 pt padding, the
/// fingerprint in SF Mono 12 pt (selectable, to compare with `ssh-keygen -lf`), Cancel (Esc) and Trust
/// (the one prominent button). Nothing is sent to the server before Trust.
struct HostKeySheet: View {
    @Environment(AppSettings.self) private var settings
    let prompt: TerminalSessionModel.HostKeyPrompt
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(settings.t("host_key_title"), systemImage: "key.horizontal")
                .font(.headline)
            Text(settings.t("host_key_body"))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(settings.t("host_key_server")).foregroundStyle(.secondary)
                    Text(verbatim: hostAndPort).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text(settings.t("host_key_algorithm")).foregroundStyle(.secondary)
                    Text(verbatim: prompt.key.algorithm).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text(settings.t("host_key_fingerprint")).foregroundStyle(.secondary)
                    Text(verbatim: prompt.key.fingerprintSHA256)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            Text(settings.t("host_key_remembered"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(settings.t("cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(settings.t("host_key_trust"), action: onTrust)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    /// `host:port`, with an IPv6 literal in brackets.
    private var hostAndPort: String {
        prompt.host.contains(":") ? "[\(prompt.host)]:\(prompt.port)" : "\(prompt.host):\(prompt.port)"
    }
}
