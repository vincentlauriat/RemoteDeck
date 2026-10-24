import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - Posting

/// macOS's notification setting for the app. Reading it never shows the system prompt.
enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

/// Posts Status Notifications. Injectable: the hosted tests and the demo never post a real one.
@MainActor
protocol NotificationPosting: Sendable {
    func authorizationStatus() async -> NotificationPermission
    func post(_ change: StatusChange) async
    /// Removes the machine's delivered Status Notification, if any (unwatched or deleted).
    func removeDelivered(_ machineID: UUID) async
}

/// The text of a Status Notification (AppFlow › Status Notifications): the machine's name and what
/// happened. No host, user name or password.
struct StatusNotificationContent: Equatable, Sendable {
    let title: String
    let body: String

    init(_ change: StatusChange, _ t: (String) -> String) {
        let (titleKey, bodyKey) = switch change.transition {
        case .wentOffline: ("notif_offline_title", "notif_offline_body")
        case .backOnline: ("notif_online_title", "notif_online_body")
        }
        title = t(titleKey).replacingOccurrences(of: "%@", with: change.machineName)
        body = t(bodyKey)
    }
}

/// What a notification carries back to the app when clicked.
enum StatusNotificationPayload {
    static let machineIDKey = "machineID"
    static let transitionKey = "transition"

    static func userInfo(_ change: StatusChange) -> [String: String] {
        [machineIDKey: change.machineID.uuidString, transitionKey: change.transition.rawValue]
    }

    static func request(from userInfo: [AnyHashable: Any]) -> StatusNotificationRouter.Request? {
        guard let id = (userInfo[machineIDKey] as? String).flatMap(UUID.init(uuidString:)),
              let transition = (userInfo[transitionKey] as? String).flatMap(StatusTransition.init(rawValue:))
        else { return nil }
        return StatusNotificationRouter.Request(machineID: id, transition: transition)
    }

    /// One notification per machine: "back online" replaces "offline" in Notification Center.
    static func identifier(_ machineID: UUID) -> String { "status.\(machineID.uuidString)" }
}

/// The real poster (UserNotifications).
@MainActor
final class UserNotificationPoster: NotificationPosting {
    private let t: @MainActor (String) -> String

    init(t: @escaping @MainActor (String) -> String) {
        self.t = t
    }

    func authorizationStatus() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func post(_ change: StatusChange) async {
        let text = StatusNotificationContent(change) { t($0) }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = "status"
        content.userInfo = StatusNotificationPayload.userInfo(change)
        let request = UNNotificationRequest(identifier: StatusNotificationPayload.identifier(change.machineID),
                                            content: content, trigger: nil)
        // A refused post (permission withdrawn meanwhile) changes nothing: the dot still shows the status.
        try? await UNUserNotificationCenter.current().add(request)
    }

    func removeDelivered(_ machineID: UUID) async {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [StatusNotificationPayload.identifier(machineID)])
    }
}

/// Never posts, never reads the system setting: the hosted tests.
struct SilentNotificationPoster: NotificationPosting {
    func authorizationStatus() async -> NotificationPermission { .notDetermined }
    func post(_ change: StatusChange) async {}
    func removeDelivered(_ machineID: UUID) async {}
}

// MARK: - Click

/// A clicked Status Notification, handed to the Library Window, which selects the machine (AppFlow ›
/// Entry points). "Back online" no longer connects (T5.3): a notification click must not open a
/// connection, and send credentials, without a Connect from the user.
@Observable
@MainActor
final class StatusNotificationRouter {
    struct Request: Equatable, Sendable {
        let machineID: UUID
        let transition: StatusTransition

        enum Action: Equatable, Sendable {
            /// Select the machine in the Library Window.
            case select
        }

        /// What the Library Window does with the click: `.select` for both transitions.
        var action: Action { .select }
    }

    private(set) var pending: Request?
    /// Set by the Library Window: opens it (or brings it forward), so a click also works when it was closed.
    @ObservationIgnored var openLibrary: (@MainActor () -> Void)?
    @ObservationIgnored private let activate: @MainActor () -> Void

    init(activate: @escaping @MainActor () -> Void = { NSApplication.shared.activate() }) {
        self.activate = activate
    }

    func open(_ request: Request) {
        activate()
        pending = request
        openLibrary?()
    }

    /// The request, once: the Library Window consumes it.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// `UNUserNotificationCenter`'s delegate (set in `RemoteDeckApp.init`, before launch ends, so a click
/// that launches the app is not lost). The center keeps it weakly: the app holds it.
final class StatusNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let router: StatusNotificationRouter

    init(router: StatusNotificationRouter) {
        self.router = router
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let request = StatusNotificationPayload.request(from: response.notification.request.content.userInfo)
        else { return }
        await router.open(request)
    }

    /// Shown even while the app is frontmost: a watched server dropping matters during a session too.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

// MARK: - Permission (Settings, Machine Editor)

/// The notification permission as the Settings Window and the Machine Editor show it. The system
/// prompt only follows a click on "Allow notifications" (`request`), as in the onboarding.
@Observable
@MainActor
final class NotificationPermissionModel {
    enum State: Equatable {
        case unknown
        case notDetermined
        case requesting
        case authorized
        case denied
        /// The request itself failed: Retry.
        case failed
    }

    private(set) var state: State = .unknown

    @ObservationIgnored private let poster: any NotificationPosting
    @ObservationIgnored private let authorizer: any NotificationAuthorizing

    init(poster: any NotificationPosting, authorizer: any NotificationAuthorizing) {
        self.poster = poster
        self.authorizer = authorizer
    }

    /// Reads the current setting (e.g. back from System Settings). Never prompts.
    func refresh() async {
        let status = await poster.authorizationStatus()
        guard state != .requesting else { return }
        switch status {
        case .authorized: state = .authorized
        case .denied: state = .denied
        case .notDetermined where state != .failed: state = .notDetermined
        case .notDetermined: break
        }
    }

    func request() async {
        guard state == .notDetermined || state == .failed else { return }
        state = .requesting
        state = switch await authorizer.requestAuthorization() {
        case .granted: .authorized
        case .denied: .denied
        case .failed: .failed
        }
    }
}
