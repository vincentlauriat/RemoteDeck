import SwiftUI
import RemoteDeckCore

/// Library Window detail pane (DesignBrief › Library Window): name, host:port (mono), kind,
/// last connected, and a large Connect button.
struct MachineDetailView: View {
    @Environment(AppSettings.self) private var settings
    let machine: Machine
    let onConnect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: machine.kindValue.symbolName)
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(machine.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if machine.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("detail_address") {
                    Text(machine.displayAddress())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                row("detail_kind") { Text(settings.t(machine.kindValue.titleKey)) }
                if let username = machine.username, machine.kindValue != .anthropicVM {
                    row("detail_user") { Text(username).textSelection(.enabled) }
                }
                if let group = machine.group {
                    row("detail_group") { Text(group.name) }
                }
                row("detail_last_connected") {
                    if let date = machine.lastConnectedAt {
                        Text(date.formatted(.dateTime.locale(Locale(identifier: settings.localeIdentifier))))
                    } else {
                        Text(settings.t("detail_never")).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 13))

            HStack {
                Button(action: onConnect) {
                    Text(settings.t("connect")).frame(minWidth: 120)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!machine.canConnect)
                Button(settings.t("edit"), action: onEdit)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ key: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(settings.t(key))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }
}
