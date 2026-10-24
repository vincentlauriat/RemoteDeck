import Foundation
import Testing
import RemoteDeckCore
@testable import RemoteDeck

/// Counts the requests: the system prompt must only follow a click.
private actor FakeAuthorizer: NotificationAuthorizing {
    private(set) var calls = 0
    let answer: NotificationAuthorization

    init(answer: NotificationAuthorization = .granted) {
        self.answer = answer
    }

    func requestAuthorization() async -> NotificationAuthorization {
        calls += 1
        return answer
    }
}

/// Onboarding Sheet (AppFlow › First use): when it shows, how it ends, what it asks for.
@MainActor
struct OnboardingTests {
    let suiteName = "fr.vincentlauriat.remotedeck.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let keychain = InMemoryAPIKeyStore()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, apiKeys: keychain)
    }

    // MARK: When it shows

    @Test func neverUnderTestsOrDebugModes() {
        #expect(OnboardingLaunch.resolve(isRunningTests: false, demoMode: nil, framebufferDebugMode: nil) == .firstRun)
        #expect(OnboardingLaunch.resolve(isRunningTests: true, demoMode: nil, framebufferDebugMode: nil) == .off)
        #expect(OnboardingLaunch.resolve(isRunningTests: true, demoMode: "onboarding", framebufferDebugMode: nil) == .off)
        #expect(OnboardingLaunch.resolve(isRunningTests: false, demoMode: nil, framebufferDebugMode: "stream") == .off)
        #expect(OnboardingLaunch.resolve(isRunningTests: false, demoMode: "onboarding", framebufferDebugMode: "static") == .off)
        for mode in ["list", "editor", "session", "discovery", "empty", "store-error", "discovery-blocked"] {
            #expect(OnboardingLaunch.resolve(isRunningTests: false, demoMode: mode, framebufferDebugMode: nil) == .off)
        }
        #expect(OnboardingLaunch.resolve(isRunningTests: false, demoMode: "onboarding", framebufferDebugMode: nil) == .demo)
        #expect(!OnboardingLaunch.off.shouldPresent(completed: false))
        #expect(OnboardingLaunch.demo.shouldPresent(completed: true))
    }

    /// This process is the hosted test run: the app it hosts must not have shown the sheet.
    @Test func thisTestHostGetsNoOnboarding() {
        defer { cleanUp() }
        let launch = OnboardingLaunch.resolve(isRunningTests: LibraryStore.isRunningTests(),
                                              demoMode: nil, framebufferDebugMode: nil)
        #expect(launch == .off)
        #expect(launch.makeModel(settings: makeSettings(), authorizer: FakeAuthorizer()) == nil)
    }

    @Test func shownUntilSkippedThenNeverAgain() throws {
        defer { cleanUp() }
        let settings = makeSettings()
        let model = try #require(OnboardingLaunch.firstRun.makeModel(settings: settings, authorizer: FakeAuthorizer()))
        model.later()
        #expect(settings.onboardingCompleted)
        #expect(defaults.object(forKey: AppSettings.Key.onboardingCompleted) as? Bool == true)
        // Next launch reads the same domain.
        #expect(OnboardingLaunch.firstRun.makeModel(settings: makeSettings(), authorizer: FakeAuthorizer()) == nil)
    }

    @Test func finishingRecordsTheCompletionOnceAndOpensDiscovery() {
        var completions = 0
        let model = OnboardingModel(authorizer: FakeAuthorizer()) { completions += 1 }
        #expect(model.step == .welcome)
        model.next()
        #expect(model.step == .permissions)
        model.next()
        #expect(model.step == .sync)
        #expect(model.outcome == nil && completions == 0)
        model.next()   // "Not now" on the last page
        #expect(model.outcome == .finished)
        #expect(model.opensDiscovery)
        model.later()  // the sheet going away afterwards changes nothing
        #expect(model.outcome == .finished)
        #expect(completions == 1)
    }

    @Test func laterSkipsWithoutOpeningDiscovery() {
        var completions = 0
        let model = OnboardingModel(authorizer: FakeAuthorizer()) { completions += 1 }
        model.next()
        model.later()
        #expect(model.outcome == .skipped)
        #expect(!model.opensDiscovery)
        model.next()
        #expect(model.step == .permissions)
        #expect(completions == 1)
    }

    /// `-LibraryDemo onboarding` must never mark the real (.dev) domain as onboarded.
    @Test func demoShowsEveryTimeAndWritesNothing() throws {
        defer { cleanUp() }
        let settings = makeSettings()
        let model = try #require(OnboardingLaunch.demo.makeModel(settings: settings, authorizer: FakeAuthorizer()))
        model.finish()
        #expect(!settings.onboardingCompleted)
        #expect(defaults.object(forKey: AppSettings.Key.onboardingCompleted) == nil)
    }

    // MARK: What it asks for

    @Test func notificationsAreRequestedOnlyOnClick() async {
        let authorizer = FakeAuthorizer()
        let model = OnboardingModel(authorizer: authorizer) {}
        model.next()
        model.next()
        model.finish()
        #expect(await authorizer.calls == 0)

        let clicked = OnboardingModel(authorizer: authorizer) {}
        await clicked.requestNotifications()
        #expect(clicked.notificationStatus == .answered(.granted))
        await clicked.requestNotifications()   // already allowed: no second request
        #expect(await authorizer.calls == 1)
    }

    /// A "no" is final (macOS would not ask again); a failed request offers Retry.
    @Test func deniedIsNotAskedAgainButAFailureCanBeRetried() async {
        let denying = FakeAuthorizer(answer: .denied)
        let model = OnboardingModel(authorizer: denying) {}
        await model.requestNotifications()
        #expect(model.notificationStatus == .answered(.denied))
        await model.requestNotifications()
        #expect(await denying.calls == 1)

        let failing = FakeAuthorizer(answer: .failed)
        let retried = OnboardingModel(authorizer: failing) {}
        await retried.requestNotifications()
        #expect(retried.notificationStatus == .answered(.failed))
        await retried.requestNotifications()   // Retry
        #expect(await failing.calls == 2)
    }

    /// "Not now" on the iCloud page leaves iCloud Sync off.
    @Test func notNowLeavesICloudSyncOff() throws {
        defer { cleanUp() }
        let settings = makeSettings()
        let model = try #require(OnboardingLaunch.firstRun.makeModel(settings: settings, authorizer: FakeAuthorizer()))
        model.next()
        model.next()
        model.next()
        #expect(model.outcome == .finished)
        #expect(!settings.iCloudSyncEnabled)
        #expect(!model.enabledSync)
    }

    /// "Enable" (T4.3) turns iCloud Sync on, persisted, and finishes like "Not now".
    @Test func enableTurnsICloudSyncOnAndFinishes() throws {
        defer { cleanUp() }
        let settings = makeSettings()
        let model = try #require(OnboardingLaunch.firstRun.makeModel(settings: settings, authorizer: FakeAuthorizer()))
        model.enableSync()   // not on the iCloud page yet: nothing
        #expect(!settings.iCloudSyncEnabled && model.outcome == nil)
        model.next()
        model.next()
        model.enableSync()
        #expect(model.outcome == .finished)
        #expect(model.opensDiscovery)
        #expect(model.enabledSync)
        #expect(settings.iCloudSyncEnabled)
        #expect(settings.onboardingCompleted)
        #expect(AppSettings(defaults: defaults, apiKeys: keychain).iCloudSyncEnabled)
    }

    /// `-LibraryDemo onboarding` writes nothing, Enable included.
    @Test func demoEnableWritesNothing() throws {
        defer { cleanUp() }
        let settings = makeSettings()
        let model = try #require(OnboardingLaunch.demo.makeModel(settings: settings, authorizer: FakeAuthorizer()))
        model.next()
        model.next()
        model.enableSync()
        #expect(model.outcome == .finished)
        #expect(!settings.iCloudSyncEnabled)
        #expect(defaults.object(forKey: AppSettings.Key.iCloudSyncEnabled) == nil)
    }
}

/// AppFlow › Empty and blocked states › Library in memory: reached through `LibraryStore.open`.
@MainActor
struct LibraryStoreFallbackTests {
    struct DiskFailure: Error {}

    @Test func failingOnDiskStoreFallsBackToMemoryWithTheError() {
        let opened = LibraryStore.open(inMemory: false, onDisk: { _ in throw DiskFailure() })
        #expect(opened.isInMemory)
        #expect(opened.error is DiskFailure)
        #expect(!opened.syncsWithICloud)
        #expect(opened.container.configurations.map(\.isStoredInMemoryOnly) == [true, true])
        #expect(LibraryStore.passwordStore(isInMemory: opened.isInMemory) is InMemoryPasswordStore)
    }

    /// iCloud Sync (T4.3): a CloudKit store that fails to open falls back to the same files without
    /// CloudKit (not to the in-memory banner), and says why.
    @Test func failingCloudKitStoreOpensTheLocalStore() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckSyncOpen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String?] = []
        let opened = LibraryStore.open(inMemory: false, cloudKitContainer: "iCloud.example") { container in
            asked.append(container)
            if container != nil { throw DiskFailure() }
            return try RemoteDeckSchema.makeContainer(storeDirectory: directory)
        }
        #expect(asked == ["iCloud.example", nil])
        #expect(!opened.isInMemory && opened.error == nil)
        #expect(!opened.syncsWithICloud)
        #expect(opened.syncError is DiskFailure)
        #expect(opened.container.configurations.map(\.isStoredInMemoryOnly) == [false, false])
    }

    @Test func cloudKitStoreOpensWhenItCan() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckSyncOpen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked: [String?] = []
        // The stand-in opens a local store: this test process must never open a CloudKit one.
        let opened = LibraryStore.open(inMemory: false, cloudKitContainer: "iCloud.example") { container in
            asked.append(container)
            return try RemoteDeckSchema.makeContainer(storeDirectory: directory)
        }
        #expect(asked == ["iCloud.example"])
        #expect(opened.syncsWithICloud && opened.syncError == nil && !opened.isInMemory)
    }

    /// The store syncs only with the setting on, on disk, in a build signed with the container.
    @Test func cloudKitContainerNeedsTheSettingTheDiskAndTheEntitlement() {
        let id = RemoteDeckSchema.cloudKitContainerIdentifier
        #expect(LibraryStore.cloudKitContainer(syncEnabled: true, isInMemory: false, isEntitled: true) == id)
        #expect(LibraryStore.cloudKitContainer(syncEnabled: false, isInMemory: false, isEntitled: true) == nil)
        #expect(LibraryStore.cloudKitContainer(syncEnabled: true, isInMemory: true, isEntitled: true) == nil)
        #expect(LibraryStore.cloudKitContainer(syncEnabled: true, isInMemory: false, isEntitled: false) == nil)
    }

    /// The hosted tests run in memory, so the app they host never opened a CloudKit store.
    @Test func inMemoryNeverSyncs() {
        let opened = LibraryStore.open(inMemory: true, cloudKitContainer: RemoteDeckSchema.cloudKitContainerIdentifier,
                                       onDisk: { _ in Issue.record("on-disk store opened"); throw DiskFailure() })
        #expect(opened.isInMemory && !opened.syncsWithICloud && opened.error == nil)
    }
}
