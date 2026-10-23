import SwiftUI

/// Onboarding Sheet (AppFlow › First use, DesignBrief › Onboarding Sheet): 3 pages of 520 × 400 pt,
/// a large SF Symbol, one sentence and one primary button per page; "Later" (Esc) skips it.
struct OnboardingSheetView: View {
    @Environment(AppSettings.self) private var settings
    let model: OnboardingModel
    /// Called once the sheet has ended (finished or skipped); the caller closes it.
    let onEnd: (OnboardingModel.Outcome) -> Void

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            pageDots
                .padding(.bottom, 12)
            Divider()
            buttons
                .padding(20)
        }
        .frame(width: 520, height: 400)
        // Esc is "Later" on the first two pages. The last page has no cancel action: Esc does
        // nothing there, the user picks "Not now". Closing the sheet otherwise counts as Later
        // (LibraryView's onDismiss); quitting the app before the end shows it again next launch.
        .interactiveDismissDisabled(model.step == .sync)
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome:
            header(symbol: "desktopcomputer", title: "onboarding_welcome_title", text: "onboarding_welcome_text")
        case .permissions:
            VStack(spacing: 16) {
                header(symbol: "lock.shield", title: "onboarding_permissions_title", text: "onboarding_permissions_text")
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(symbol: "antenna.radiowaves.left.and.right",
                                  title: "onboarding_local_network_title", text: "onboarding_local_network_text")
                    permissionRow(symbol: "bell", title: "onboarding_notifications_title",
                                  text: "onboarding_notifications_text") {
                        notificationControl
                    }
                }
                .frame(maxWidth: 440)
            }
        case .sync:
            VStack(spacing: 16) {
                header(symbol: "icloud", title: "onboarding_sync_title", text: "onboarding_sync_text")
                // iCloud Sync is T4.3: offered, but not available yet.
                Button(settings.t("onboarding_sync_enable")) {}
                    .disabled(true)
                Text(settings.t("onboarding_sync_unavailable"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }

    private func header(symbol: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(settings.t(title))
                .font(.title2.weight(.semibold))
            Text(settings.t(text))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
    }

    private func permissionRow(symbol: String, title: String, text: String,
                               @ViewBuilder control: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.t(title)).font(.system(size: 13, weight: .semibold))
                Text(settings.t(text))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                control()
            }
        }
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch model.notificationStatus {
        case .notAsked:
            Button(settings.t("onboarding_notifications_allow")) { Task { await model.requestNotifications() } }
        case .asking:
            ProgressView().controlSize(.small)
        case .answered(.granted):
            Label(settings.t("onboarding_notifications_granted"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .answered(.denied):
            Text(settings.t("onboarding_notifications_denied"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .answered(.failed):
            HStack(spacing: 8) {
                Text(settings.t("onboarding_notifications_failed"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Button(settings.t("onboarding_notifications_retry")) { Task { await model.requestNotifications() } }
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if model.step != .sync {
                Button(settings.t("onboarding_later")) { end { model.later() } }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if model.step == .sync {
                Button(settings.t("onboarding_sync_not_now")) { end { model.finish() } }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(settings.t("onboarding_continue")) { model.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func end(_ action: () -> Void) {
        action()
        if let outcome = model.outcome { onEnd(outcome) }
    }
}
