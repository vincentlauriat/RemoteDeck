import SwiftUI
import RemoteDeckCore

/// Discovery Panel (AppFlow › Discovery Panel, DesignBrief › Discovery Panel): a 420 × 360 sheet
/// listing the Macs and VNC servers advertised on the LAN; "Add" opens the Machine Editor
/// pre-filled, machines already in the library are greyed with "Added".
struct DiscoveryPanelView: View {
    /// System Settings › Privacy & Security › Local Network.
    static let localNetworkSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let model: DiscoveryService
    /// `normalizedKey` of every machine in the library (live, so a row flips to "Added" after Save).
    let libraryKeys: Set<String>
    let onAdd: (DiscoveredMachine) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(settings.t("discovery_title"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let problem = model.problemWithRows { problemNote(problem) }
                Spacer()
                Button(settings.t("discovery_close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 360)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .searching:
            VStack(spacing: 8) {
                ProgressView()
                Text(settings.t("discovery_searching")).foregroundStyle(.secondary)
            }
        case .found:
            List(model.machines) { machine in
                row(machine)
            }
            .listStyle(.inset)
        case .empty:
            ContentUnavailableView {
                Label(settings.t("discovery_empty_title"), systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(settings.t("discovery_empty_desc"))
            } actions: {
                Button(settings.t("discovery_retry")) { model.start() }
            }
        case .blocked:
            ContentUnavailableView {
                Label(settings.t("discovery_blocked_title"), systemImage: "lock.shield")
            } description: {
                Text(settings.t("discovery_blocked_desc"))
            } actions: {
                Button(settings.t("discovery_open_settings")) { openURL(Self.localNetworkSettings) }
            }
        case .failed(let code):
            ContentUnavailableView {
                Label(settings.t("discovery_failed_title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(settings.t("discovery_failed_desc"))
                Text(settings.t("discovery_error_code", code))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } actions: {
                Button(settings.t("discovery_retry")) { model.start() }
            }
        }
    }

    /// Rows are listed but a browser failed or was denied: some machines may be missing.
    @ViewBuilder
    private func problemNote(_ problem: BonjourProblem) -> some View {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        switch problem {
        case .permissionDenied:
            Text(settings.t("discovery_partial_blocked")).font(.system(size: 11)).lineLimit(2)
            Button(settings.t("discovery_open_settings")) { openURL(Self.localNetworkSettings) }
        case .error(let code):
            Text(settings.t("discovery_partial_failed", code)).font(.system(size: 11)).lineLimit(2)
            Button(settings.t("discovery_retry")) { model.start() }
        }
    }

    private func row(_ machine: DiscoveredMachine) -> some View {
        let added = machine.isInLibrary(libraryKeys)
        return HStack(spacing: 8) {
            Image(systemName: machine.kind.symbolName)
                .frame(width: 18)
                .accessibilityLabel(settings.t(machine.kind.titleKey))
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).font(.system(size: 13)).lineLimit(1)
                Text(machine.port == 5900 ? machine.host : "\(machine.host):\(machine.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(serviceLabel(machine))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if added {
                Text(settings.t("discovery_added"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button(settings.t("discovery_add")) { onAdd(machine) }
            }
        }
        .opacity(added ? 0.5 : 1)
        .padding(.vertical, 2)
    }

    private func serviceLabel(_ machine: DiscoveredMachine) -> String {
        BonjourServiceType.allCases
            .filter(machine.services.contains)
            .map { settings.t($0 == .rfb ? "discovery_service_rfb" : "discovery_service_ard") }
            .joined(separator: " · ")
    }
}

/// A request to open the Discovery Panel; the service lives as long as the sheet.
struct DiscoveryRequest: Identifiable {
    let id = UUID()
    let model: DiscoveryService
}
