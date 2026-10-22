import SwiftUI
import RemoteDeckCore

extension MachineKind {
    /// SF Symbol per kind (DesignBrief › Sidebar rows).
    var symbolName: String {
        switch self {
        case .macARD: "desktopcomputer"
        case .vnc: "display"
        case .anthropicVM: "sparkles"
        }
    }

    var titleKey: String { "kind_\(rawValue)" }
}

extension Machine {
    /// `host:port`, with IPv6 literals in brackets (`[fe80::1%en0]:5901`). With
    /// `omittingDefaultPort`, port 5900 is left out (sidebar rows).
    func displayAddress(omittingDefaultPort: Bool = false) -> String {
        if omittingDefaultPort && port == 5900 { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// Sidebar row: kind symbol, name, host in SF Mono, star for favorites. The status dot arrives
/// with reachability monitoring (T4.5).
struct MachineRowView: View {
    @Environment(AppSettings.self) private var settings
    let machine: Machine

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: machine.kindValue.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel(settings.t(machine.kindValue.titleKey))
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if machine.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(settings.t("field_favorite"))
            }
        }
        .frame(minHeight: 28)
    }

    private var address: String { machine.displayAddress(omittingDefaultPort: true) }
}
