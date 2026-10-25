import Foundation
import Testing
@testable import RemoteDeck

/// Sparkle (T6.3): the updater never starts under the hosted tests, a Debug build or a debug mode.
@MainActor
struct AppUpdaterTests {
    @Test func startsOnlyInTheReleasedApp() {
        #expect(UpdaterLaunch.resolve(isRunningTests: false, isDebugBuild: false,
                                      demoMode: nil, framebufferDebugMode: nil) == .on)
        #expect(UpdaterLaunch.resolve(isRunningTests: true, isDebugBuild: false,
                                      demoMode: nil, framebufferDebugMode: nil) == .off)
        #expect(UpdaterLaunch.resolve(isRunningTests: false, isDebugBuild: true,
                                      demoMode: nil, framebufferDebugMode: nil) == .off)
        #expect(UpdaterLaunch.resolve(isRunningTests: false, isDebugBuild: false,
                                      demoMode: nil, framebufferDebugMode: "stream") == .off)
        for mode in ["list", "session", "assistant", "onboarding", "watch", "public", "resilience"] {
            #expect(UpdaterLaunch.resolve(isRunningTests: false, isDebugBuild: false,
                                          demoMode: mode, framebufferDebugMode: nil) == .off)
        }
    }

    /// This process is the hosted test run. Even as a Release build (`isDebugBuild: false`), XCTest
    /// alone keeps the updater off; and the app hosting these tests started none.
    @Test func thisTestHostStartsNoUpdater() {
        let launch = UpdaterLaunch.resolve(isRunningTests: LibraryStore.isRunningTests(), isDebugBuild: false,
                                           demoMode: nil, framebufferDebugMode: nil)
        #expect(launch == .off)
        // Never `.on` here: that would start a real updater in the test process.
        if launch == .off { #expect(!AppUpdater(launch: launch).isStarted) }
        #expect(AppUpdater.startedCount == 0)
    }

    @Test func checkingWhileOffDoesNothing() {
        let updater = AppUpdater(launch: .off)
        updater.checkForUpdates()
        #expect(!updater.isStarted)
        #expect(!updater.canCheckForUpdates)   // the menu item stays disabled
        #expect(AppUpdater.startedCount == 0)
    }
}
