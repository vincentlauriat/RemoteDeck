import SwiftUI

extension StatusPresentation {
    /// DesignBrief › Colors: green online, red offline, grey otherwise (unknown, network down, not watched).
    var color: Color {
        switch self {
        case .online: Color(nsColor: .systemGreen)
        case .offline: Color(nsColor: .systemRed)
        case .checking, .networkUnavailable, .localNetworkDenied, .notWatched: Color(nsColor: .systemGray)
        }
    }

    var labelKey: String {
        switch self {
        case .notWatched: "status_not_watched"
        case .checking: "status_checking"
        case .online: "status_online"
        case .offline: "status_offline"
        case .networkUnavailable: "status_network_unavailable"
        case .localNetworkDenied: "status_local_network_denied"
        }
    }

    /// The sidebar draws no dot for a machine that is not watched (review L4); the detail pane's
    /// status line still says so.
    var showsSidebarDot: Bool { self != .notWatched }
}

/// The 8 pt status dot (DesignBrief › Sidebar rows); never color alone: VoiceOver label and tooltip.
struct StatusDotView: View {
    @Environment(AppSettings.self) private var settings
    let presentation: StatusPresentation
    /// Next to a text saying the same (detail pane): hidden from VoiceOver, so it is read once.
    var isDecorative = false

    var body: some View {
        let dot = Circle()
            .fill(presentation.color)
            .frame(width: 8, height: 8)
            .help(settings.t(presentation.labelKey))
        if isDecorative {
            dot.accessibilityHidden(true)
        } else {
            dot.accessibilityElement()
                .accessibilityLabel(settings.t(presentation.labelKey))
        }
    }
}

/// What the notification permission means for Status Notifications, with the one action it allows:
/// "Allow notifications" (the system prompt, on that click only) or Retry. `showsAuthorized`: the
/// Settings Window also says when everything is on; the Machine Editor stays quiet then.
struct NotificationPermissionNotice: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationPermissionModel.self) private var permission
    var showsAuthorized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !settings.notificationsEnabled {
                caption("notif_app_off")
            } else {
                switch permission.state {
                case .unknown:
                    EmptyView()
                case .authorized:
                    if showsAuthorized {
                        Label(settings.t("onboarding_notifications_granted"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                case .notDetermined:
                    caption("notif_not_allowed")
                    Button(settings.t("onboarding_notifications_allow")) { Task { await permission.request() } }
                        .controlSize(.small)
                case .requesting:
                    ProgressView().controlSize(.small)
                case .denied:
                    caption("notif_denied")
                case .failed:
                    caption("onboarding_notifications_failed")
                    Button(settings.t("onboarding_notifications_retry")) { Task { await permission.request() } }
                        .controlSize(.small)
                }
            }
        }
        .task { await permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permission.refresh() }
        }
    }

    private func caption(_ key: String) -> some View {
        Text(settings.t(key))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
