import AppKit
import SwiftUI
import SwiftData
import UserNotifications
import ClaudeKit
import RemoteDeckCore

@main
struct RemoteDeckApp: App {
    @State private var settings: AppSettings
    @State private var library: MachineLibraryModel
    @State private var sessions: SessionManager
    @State private var reachability: ReachabilityMonitor
    @State private var notificationRouter: StatusNotificationRouter
    @State private var notificationPermission: NotificationPermissionModel
    @State private var history = SessionHistoryModel(exporter: SavePanelExporter())
    /// The Menu Bar Extra; never inserted while the hosted tests run.
    @State private var showsMenuBarExtra = !LibraryStore.isRunningTests()
    /// `UNUserNotificationCenter` keeps its delegate weakly.
    private let notificationDelegate: StatusNotificationDelegate?
    private let watchFeed: WatchTargetFeed
    private let container: ModelContainer
    private let storeError: String?
    private let onboardingLaunch: OnboardingLaunch
    private let notificationAuthorizer: any NotificationAuthorizing
    private let tester: any ConnectionTester
    private let makeDiscovery: @MainActor () -> DiscoveryService
    private let apiKeyChecker: any APIKeyChecking

    init() {
        // The hosted RemoteDeckTests run inside this app: never open the user's on-disk store then.
        var inMemory = LibraryStore.isRunningTests()
        #if DEBUG
        inMemory = inMemory || LibraryDemo.isEnabled
        #endif
        let (container, isInMemory, error) = LibraryStore.open(inMemory: inMemory)
        self.container = container
        var storeError = error.map { String(describing: $0) }
        var demoMode: String?
        var framebufferDebugMode: String?
        #if DEBUG
        demoMode = LibraryDemo.mode
        framebufferDebugMode = FramebufferDebug.mode
        #endif
        onboardingLaunch = OnboardingLaunch.resolve(isRunningTests: LibraryStore.isRunningTests(),
                                                    demoMode: demoMode, framebufferDebugMode: framebufferDebugMode)
        // The hosted tests and the demo never read or write the user's API key.
        var apiKeys: any APIKeyStore = inMemory ? InMemoryAPIKeyStore() : KeychainAPIKeyStore()
        var claudeClient = MessagesClient()
        var notificationAuthorizer: any NotificationAuthorizing = UserNotificationAuthorizer()
        let passwords = LibraryStore.passwordStore(isInMemory: isInMemory)
        _library = State(initialValue: MachineLibraryModel(context: container.mainContext, passwords: passwords))
        var tester: any ConnectionTester = RFBConnectionTester()
        var makeConnection: @MainActor (SessionTarget) -> any SessionConnection = SessionManager.rfbConnection
        // The hosted tests never touch the real pasteboard.
        var pasteboard: any ClipboardPasteboard = LibraryStore.isRunningTests() ? InMemoryPasteboard() : SystemPasteboard()
        // Built when the Discovery Panel opens: nothing browses the network before that.
        var makeDiscovery: @MainActor () -> DiscoveryService = {
            DiscoveryService(browsers: NWBonjourBrowserFactory(), resolver: DNSSDResolver(),
                             excludedHosts: LocalHost.bonjourNames)
        }
        #if DEBUG
        if LibraryDemo.isEnabled {
            if LibraryDemo.seedsLibrary { LibraryDemo.seed(container.mainContext) }
            if LibraryDemo.showsHistory { LibraryDemo.seedHistory(container.mainContext, now: .now) }
            if LibraryDemo.simulatesStoreError { storeError = LibraryDemo.storeError }
            notificationAuthorizer = LibraryDemo.NotificationAuthorizer()   // never the system prompt
            tester = LibraryDemo.Tester()
            makeConnection = LibraryDemo.connection   // never the network: the sample hosts are not real
            pasteboard = InMemoryPasteboard()         // nor the user's clipboard
            makeDiscovery = LibraryDemo.discovery
            LibraryDemo.suppressAccessibilityPrompt()
            if LibraryDemo.scriptsAssistant {
                apiKeys = InMemoryAPIKeyStore(key: LibraryDemo.assistantKey)
                claudeClient = LibraryDemo.assistantClient()   // scripted answers: never the API
            }
        }
        #endif
        let settings = AppSettings(apiKeys: apiKeys)
        _settings = State(initialValue: settings)
        // Retention (BackendSchema › Retention and deletion): only the on-disk store, so never under the
        // hosted tests or a demo mode (both in memory). Best effort: a failure leaves the rows for next time.
        if !isInMemory {
            _ = try? HistoryRetention.purge(container.mainContext, now: .now, historyDays: settings.historyRetentionDays)
        }
        apiKeyChecker = claudeClient
        self.tester = tester
        self.makeDiscovery = makeDiscovery
        self.storeError = storeError
        self.notificationAuthorizer = notificationAuthorizer
        // Resilience (T5.1): the hosted tests never watch the network path or sleep and wake; demo
        // modes see the network as always there and ignore sleep, except `resilience`, which keeps
        // the real path and the real sleep and wake.
        var sessionPath: (any NetworkPathMonitoring)? = LibraryStore.isRunningTests() ? nil : NWNetworkPathMonitor(countsRequiresConnection: true)
        var powerCenter: NotificationCenter? = LibraryStore.isRunningTests() ? nil : NSWorkspace.shared.notificationCenter
        #if DEBUG
        if LibraryDemo.isEnabled && !LibraryDemo.simulatesDrops {
            sessionPath = LibraryDemo.AlwaysOnlinePath()
            powerCenter = nil
        }
        #endif
        let sessions = SessionManager(context: container.mainContext, passwords: passwords,
                                      tester: tester, makeConnection: makeConnection,
                                      pasteboard: pasteboard,
                                      makeAssistant: { [claudeClient] session in
            AssistantModel(port: session, client: claudeClient, apiKey: { settings.anthropicAPIKey })
        }, path: sessionPath, workspaceCenter: powerCenter)
        _sessions = State(initialValue: sessions)

        // Status Notifications (T4.5). The hosted tests never probe, post or read the notification
        // setting; demo modes never touch the network or Notification Center (`-LibraryDemo watch` fakes both).
        let isRunningTests = LibraryStore.isRunningTests()
        var monitorsReachability = !isRunningTests
        var usesNotificationCenter = !isRunningTests
        var poster: any NotificationPosting = isRunningTests
            ? SilentNotificationPoster() : UserNotificationPoster(t: { settings.t($0) })
        var probe: any ReachabilityProbe = TCPReachabilityProbe()
        var path: any NetworkPathMonitoring = NWNetworkPathMonitor()
        var configuration = ReachabilityMonitor.Configuration()
        #if DEBUG
        if LibraryDemo.isEnabled {
            monitorsReachability = LibraryDemo.watchesMachines
            usesNotificationCenter = false
            // Only `watch` pretends notifications are allowed; the other modes never post.
            poster = LibraryDemo.watchesMachines ? LibraryDemo.WatchPoster(t: { settings.t($0) })
                                                 : SilentNotificationPoster()
            probe = LibraryDemo.WatchProbe()
            path = LibraryDemo.AlwaysOnlinePath()
            configuration = LibraryDemo.watchConfiguration
        }
        #endif
        let reachability = ReachabilityMonitor(
            probe: probe, path: path, poster: poster, configuration: configuration,
            notificationsEnabled: { settings.notificationsEnabled },
            sessionState: { [sessions] id in sessions.sessions[id]?.phase.watchedState ?? .noSession })
        _reachability = State(initialValue: reachability)
        watchFeed = WatchTargetFeed(context: container.mainContext, monitor: reachability)
        let router = StatusNotificationRouter()
        _notificationRouter = State(initialValue: router)
        _notificationPermission = State(initialValue: NotificationPermissionModel(poster: poster,
                                                                                  authorizer: notificationAuthorizer))
        if usesNotificationCenter {
            // Before launch ends, so a click that launches the app reaches the router.
            let delegate = StatusNotificationDelegate(router: router)
            UNUserNotificationCenter.current().delegate = delegate
            notificationDelegate = delegate
        } else {
            notificationDelegate = nil
        }
        if monitorsReachability { reachability.start() }
    }

    var body: some Scene {
        Window(settings.t("app_name"), id: LibraryWindow.id) {
            LibraryView(model: library, tester: tester, makeDiscovery: makeDiscovery, storeError: storeError,
                        onboardingLaunch: onboardingLaunch, notificationAuthorizer: notificationAuthorizer)
                .environment(settings)
                .environment(sessions)
                .environment(reachability)
                .environment(notificationRouter)
                .environment(notificationPermission)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .modelContainer(container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        // At every launch, even when state restoration has no window to bring back (after a
        // killed run, or when only session windows were open: those are never restored).
        .defaultLaunchBehavior(.presented)
        .commands {
            LibraryCommands(settings: settings)
            SessionTabCommands(settings: settings, sessions: sessions)
        }

        // One window per machine, each a native tab of the Session Window (`SessionTabs`); opening a
        // machine that has one selects its tab.
        WindowGroup(id: SessionWindow.id, for: UUID.self) { $machineID in
            if let machineID {
                SessionWindowView(machineID: machineID)
                    .environment(settings)
                    .environment(sessions)
                    // Edit credentials opens the Machine Editor, whose Watch note reads it.
                    .environment(notificationPermission)
                    .preferredColorScheme(settings.appearance.colorScheme)
            } else {
                EmptySessionWindowView()
            }
        }
        .modelContainer(container)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
        // Never reopened at launch: that would reconnect to a host (and could show the
        // Accessibility prompt) without the user asking.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Session History View (T4.6): Window › Session History (⌘Y), or the Menu Bar Extra.
        Window(settings.t("history_title"), id: HistoryWindow.id) {
            SessionHistoryView(model: history)
                .environment(settings)
                .environment(sessions)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .modelContainer(container)
        .defaultSize(width: 1000, height: 600)
        // `-LibraryDemo history` opens it from the Library Window.
        .defaultLaunchBehavior(.suppressed)

        // Menu Bar Extra (T4.6): favorites and recent machines, Open Library, Session History, Quit.
        MenuBarExtra(settings.t("app_name"), systemImage: "display.2", isInserted: $showsMenuBarExtra) {
            MenuBarContentView()
                .environment(settings)
                .environment(sessions)
                .modelContainer(container)
        }
        .menuBarExtraStyle(.menu)

        // Réglages via la scène native macOS (⌘,).
        Settings {
            SettingsView(apiKeyChecker: apiKeyChecker)
                .environment(settings)
                .environment(notificationPermission)
        }

        #if DEBUG
        Window("Framebuffer Debug", id: "framebuffer-debug") {
            FramebufferDebugView()
        }
        .defaultSize(width: 1280, height: 760)
        .defaultLaunchBehavior(FramebufferDebug.mode == nil ? .suppressed : .presented)
        #endif
    }
}
