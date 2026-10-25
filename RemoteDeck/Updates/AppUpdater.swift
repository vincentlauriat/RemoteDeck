import Foundation
import Sparkle
import SwiftUI

/// Whether Sparkle's updater starts at launch (T6.3, TRD › Environments and release › Updates).
enum UpdaterLaunch: Equatable {
    /// Never checks, never downloads: hosted tests, Debug builds, `-FramebufferDebug` and every
    /// `-LibraryDemo` mode. "Check for Updates…" is disabled.
    case off
    /// The released app: scheduled checks (`SUEnableAutomaticChecks`) and the menu item.
    case on

    /// A Debug build is "RemoteDeck Dev": an update from the release feed would replace it with
    /// "RemoteDeck", so it never starts there either.
    static func resolve(isRunningTests: Bool, isDebugBuild: Bool,
                        demoMode: String?, framebufferDebugMode: String?) -> UpdaterLaunch {
        if isRunningTests || isDebugBuild || demoMode != nil || framebufferDebugMode != nil { return .off }
        return .on
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Owns Sparkle's standard updater. The controller is built only for `.on`: under `.off` no Sparkle
/// object exists, so nothing reads the feed or schedules a check.
@MainActor
@Observable
final class AppUpdater {
    /// How many updaters this process started (hosted tests check it stays 0).
    private(set) static var startedCount = 0

    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check runs, and when off): drives
    /// "Check for Updates…".
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(launch: UpdaterLaunch) {
        guard launch == .on else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        Self.startedCount += 1
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            // Sparkle changes it on the main thread; hop explicitly in case a future version does not.
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    var isStarted: Bool { controller != nil }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}

/// RemoteDeck › Check for Updates…, enabled only while Sparkle can start a check.
struct UpdateCommands: Commands {
    let settings: AppSettings
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(settings.t("menu_check_for_updates")) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
