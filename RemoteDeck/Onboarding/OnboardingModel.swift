import Foundation
import Observation
import UserNotifications

// MARK: - Notification permission

/// The user's answer to the notification permission request.
enum NotificationAuthorization: Equatable, Sendable {
    case granted
    case denied
    /// The request itself failed (not an answer).
    case failed
}

/// Asks for the notification permission. Injectable, so tests and the demo never show the system
/// prompt; the app calls it only from the onboarding's "Allow notifications" button.
protocol NotificationAuthorizing: Sendable {
    func requestAuthorization() async -> NotificationAuthorization
}

/// The real request (UserNotifications). Also behind "Allow notifications" in the Settings Window and
/// the Machine Editor (`NotificationPermissionModel`); Status Notifications post through
/// `UserNotificationPoster`.
struct UserNotificationAuthorizer: NotificationAuthorizing {
    func requestAuthorization() async -> NotificationAuthorization {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                ? .granted : .denied
        } catch {
            return .failed
        }
    }
}

// MARK: - When the sheet shows

/// Whether this launch shows the Onboarding Sheet (AppFlow › First use).
enum OnboardingLaunch: Equatable {
    /// Never: hosted tests, `-FramebufferDebug`, and every `-LibraryDemo` mode but `onboarding`.
    case off
    /// The real app: shown until completed or skipped (`AppSettings.onboardingCompleted`).
    case firstRun
    /// `-LibraryDemo onboarding`: always shown, and finishing it writes nothing.
    case demo

    static let demoMode = "onboarding"

    static func resolve(isRunningTests: Bool, demoMode: String?, framebufferDebugMode: String?) -> OnboardingLaunch {
        if isRunningTests || framebufferDebugMode != nil { return .off }
        if let demoMode { return demoMode == Self.demoMode ? .demo : .off }
        return .firstRun
    }

    func shouldPresent(completed: Bool) -> Bool {
        switch self {
        case .off: false
        case .firstRun: !completed
        case .demo: true
        }
    }

    /// The sheet's model, or `nil` when it must not show. Only `.firstRun` records the completion.
    @MainActor
    func makeModel(settings: AppSettings, authorizer: any NotificationAuthorizing) -> OnboardingModel? {
        guard shouldPresent(completed: settings.onboardingCompleted) else { return nil }
        let persists = self == .firstRun
        return OnboardingModel(authorizer: authorizer) {
            if persists { settings.onboardingCompleted = true }
        }
    }
}

// MARK: - Model

/// Onboarding Sheet state (AppFlow › First use): welcome, permissions, iCloud Sync offer. Ending
/// it (the last page, "Later", Esc, the sheet dismissed) records the completion once; quitting the
/// app before that leaves it unrecorded, so the sheet shows again at the next launch.
/// Nothing is requested on its own: the notification prompt only follows a click, and the Local
/// Network prompt comes from the Discovery Panel, which opens after the last page.
@Observable
@MainActor
final class OnboardingModel: Identifiable {
    enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case sync
    }

    enum Outcome: Equatable {
        /// "Later" (or the sheet closed early): permissions are asked when first needed.
        case skipped
        /// Last page done: the Discovery Panel opens next.
        case finished
    }

    enum NotificationStatus: Equatable {
        case notAsked
        case asking
        case answered(NotificationAuthorization)
    }

    let id = UUID()
    private(set) var step: Step = .welcome
    private(set) var notificationStatus: NotificationStatus = .notAsked
    private(set) var outcome: Outcome?

    @ObservationIgnored private let authorizer: any NotificationAuthorizing
    @ObservationIgnored private let markCompleted: @MainActor () -> Void

    init(authorizer: any NotificationAuthorizing, markCompleted: @escaping @MainActor () -> Void) {
        self.authorizer = authorizer
        self.markCompleted = markCompleted
    }

    /// The Discovery Panel opens once the sheet is gone (first-time main path).
    var opensDiscovery: Bool { outcome == .finished }

    /// Next page; on the last page, finishes.
    func next() {
        guard outcome == nil else { return }
        if let following = Step(rawValue: step.rawValue + 1) {
            step = following
        } else {
            finish()
        }
    }

    func later() { end(.skipped) }

    func finish() { end(.finished) }

    /// "Allow notifications" (or Retry after a failed request): one request per click. Never while
    /// one is pending, nor after an answer (macOS would not ask again after a no).
    func requestNotifications() async {
        switch notificationStatus {
        case .notAsked, .answered(.failed): break
        case .asking, .answered(.granted), .answered(.denied): return
        }
        notificationStatus = .asking
        notificationStatus = .answered(await authorizer.requestAuthorization())
    }

    private func end(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        markCompleted()
    }
}
