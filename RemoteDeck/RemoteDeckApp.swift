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
    @State private var sync: LibrarySync
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
    private let sshTester: any SSHTester
    private let makeDiscovery: @MainActor () -> DiscoveryService
    private let apiKeyChecker: any APIKeyChecking
    /// The Apple model's availability (Settings › Assistant); fixed under XCTest and the demo.
    private let appleStatus: AppleModelStatus
    /// Sparkle (T6.3): started only in a Release build outside XCTest and the debug modes.
    private let updater: AppUpdater
    /// Help (⌘?) and What's New… (AppFlow › Help and What's New): fetched from GitHub only when their
    /// window appears; never under XCTest (`HelpSource.disabled`) nor in a debug mode (sample pages).
    @State private var help: HelpModel
    @State private var whatsNew: HelpModel

    init() {
        // The hosted RemoteDeckTests run inside this app: never open the user's on-disk store then.
        var inMemory = LibraryStore.isRunningTests()
        #if DEBUG
        inMemory = inMemory || LibraryDemo.isEnabled
        #endif
        // iCloud Sync (T4.3): the Library store mirrors to CloudKit when the setting was on at launch
        // (a change applies at the next launch), only in a build signed with the container.
        let isEntitled = CloudSyncEntitlement.isPresent
        let syncContainer = LibraryStore.cloudKitContainer(
            syncEnabled: UserDefaults.standard.bool(forKey: AppSettings.Key.iCloudSyncEnabled),
            isInMemory: inMemory, isEntitled: isEntitled)
        let opened = LibraryStore.open(inMemory: inMemory, cloudKitContainer: syncContainer)
        let container = opened.container
        let isInMemory = opened.isInMemory
        self.container = container
        var storeError = opened.error.map { String(describing: $0) }
        var demoMode: String?
        var framebufferDebugMode: String?
        #if DEBUG
        demoMode = LibraryDemo.mode
        framebufferDebugMode = FramebufferDebug.mode
        #endif
        onboardingLaunch = OnboardingLaunch.resolve(isRunningTests: LibraryStore.isRunningTests(),
                                                    demoMode: demoMode, framebufferDebugMode: framebufferDebugMode)
        updater = AppUpdater(launch: UpdaterLaunch.resolve(isRunningTests: LibraryStore.isRunningTests(),
                                                           isDebugBuild: UpdaterLaunch.isDebugBuild,
                                                           demoMode: demoMode,
                                                           framebufferDebugMode: framebufferDebugMode))
        let helpTransport = HelpSource.appTransport(for: HelpSource.resolve(
            isRunningTests: LibraryStore.isRunningTests(), demoMode: demoMode, framebufferDebugMode: framebufferDebugMode))
        _help = State(initialValue: HelpModel(page: .help, transport: helpTransport))
        _whatsNew = State(initialValue: HelpModel(page: .whatsNew, transport: helpTransport))
        // The hosted tests and the demo never read or write the user's API key.
        var apiKeys: any APIKeyStore = inMemory ? InMemoryAPIKeyStore() : KeychainAPIKeyStore()
        var claudeClient = MessagesClient()
        // Apple (on device): the hosted tests and every demo mode never touch the real model, only a
        // fixed "available" answer; the real one is read in a normal launch.
        let appleStatus = AppleModelStatus(checker: inMemory ? FixedAppleModelChecker(reason: nil)
                                                             : SystemAppleModelChecker() as any AppleModelChecking)
        var makeAppleEngine: @MainActor @Sendable () -> any AssistantEngine = { AppleAssistant.makeEngine(status: appleStatus) }
        if inMemory { makeAppleEngine = { AppleAssistant.inertEngine() } }
        // The terminal assistant's Apple provider: the same rule (never the real model under the hosted
        // tests or in a demo mode).
        var makeAppleTerminalEngine: @MainActor @Sendable () -> any TerminalAssistantEngine = {
            AppleAssistant.makeTerminalEngine(status: appleStatus)
        }
        if inMemory { makeAppleTerminalEngine = { AppleAssistant.inertTerminalEngine() } }
        // `-LibraryDemo assistant-apple` shows the Apple provider without changing the stored setting.
        #if DEBUG
        let forcedProvider: AssistantProvider? = LibraryDemo.scriptsAppleAssistant ? .appleOnDevice : nil
        #else
        let forcedProvider: AssistantProvider? = nil
        #endif
        var notificationAuthorizer: any NotificationAuthorizing = UserNotificationAuthorizer()
        let passwords = LibraryStore.passwordStore(isInMemory: isInMemory)
        // "Connect anyway" over the Internet (T5.3 H1): the user's defaults, except under the hosted
        // tests and the demo, which never write them.
        let publicConsents: any PublicAddressConsents = inMemory
            ? InMemoryPublicAddressConsents() : UserDefaultsPublicAddressConsents()
        // SSH machines: `~/.ssh` access, trusted host keys and secrets, in memory under the hosted
        // tests and the demo (no panel, no `~/.ssh`, no defaults), secrets following the library.
        var ssh = SSHServices.app(usesUserState: !inMemory, isInMemory: isInMemory)
        #if DEBUG
        // The demo's `~/.ssh` (a demo key and `config`), in memory like the rest (`-LibraryDemo ssh`).
        if LibraryDemo.isEnabled { ssh = LibraryDemo.sshServices() }
        #endif
        _library = State(initialValue: MachineLibraryModel(context: container.mainContext, passwords: passwords,
                                                           publicConsents: publicConsents, ssh: ssh))
        var tester: any ConnectionTester = RFBConnectionTester()
        var sshTester: any SSHTester = SSHConnectionTester()
        var makeConnection: @MainActor (SessionTarget) -> any SessionConnection = SessionManager.rfbConnection
        var makeSSHConnection: @MainActor (SessionTarget) -> any SSHSessionConnection = SessionManager.sshConnection
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
            sshTester = LibraryDemo.SSHTester()
            makeConnection = LibraryDemo.connection   // never the network: the sample hosts are not real
            makeSSHConnection = LibraryDemo.sshConnection   // `SSHDemoConnection`: never a socket
            pasteboard = InMemoryPasteboard()         // nor the user's clipboard
            makeDiscovery = LibraryDemo.discovery
            LibraryDemo.suppressAccessibilityPrompt()
            if LibraryDemo.scriptsAssistant {
                apiKeys = InMemoryAPIKeyStore(key: LibraryDemo.assistantKey)
                claudeClient = LibraryDemo.assistantClient()   // scripted answers: never the API
            }
            if LibraryDemo.scriptsAppleAssistant {
                // Scripted steps and OCR: never the model; the stored provider is left as it is.
                makeAppleEngine = { LibraryDemo.appleEngine() }
            }
        }
        #endif
        var settingsDefaults = UserDefaults.standard
        #if DEBUG
        if LibraryDemo.showsSync { settingsDefaults = LibraryDemo.syncDefaults() }
        #endif
        let settings = AppSettings(defaults: settingsDefaults, apiKeys: apiKeys)
        _settings = State(initialValue: settings)
        // Retention (BackendSchema › Retention and deletion): only the on-disk store, so never under the
        // hosted tests or a demo mode (both in memory). Best effort: a failure leaves the rows for next time.
        if !isInMemory {
            _ = try? HistoryRetention.purge(container.mainContext, now: .now, historyDays: settings.historyRetentionDays)
        }
        apiKeyChecker = claudeClient
        self.appleStatus = appleStatus
        self.tester = tester
        self.sshTester = sshTester
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
                                      makeAssistant: { [claudeClient, makeAppleEngine, forcedProvider] session in
            // The provider read when a conversation starts (Settings › Assistant).
            AssistantModel(port: session, provider: { forcedProvider ?? settings.assistantProvider }) { provider in
                switch provider {
                case .claude: ClaudeEngine(client: claudeClient, apiKey: { settings.anthropicAPIKey })
                case .appleOnDevice, .applePrivateCloud: makeAppleEngine()
                }
            }
        }, path: sessionPath, workspaceCenter: powerCenter, publicConsents: publicConsents,
                                      ssh: ssh, makeSSHConnection: makeSSHConnection, sshTester: sshTester,
                                      makeTerminalAssistant: { [claudeClient, makeAppleTerminalEngine, forcedProvider, pasteboard] terminal in
            #if DEBUG
            // `-LibraryDemo ssh-assistant`: a scripted engine, never a request or the Apple model.
            if LibraryDemo.scriptsTerminalAssistant {
                return TerminalAssistantModel(port: terminal, provider: { .claude },
                                              makeEngine: { _ in LibraryDemo.terminalAssistantEngine() },
                                              pasteboard: pasteboard)
            }
            #endif
            // Terminal tabs (SSH): the same provider setting, read between conversations.
            return TerminalAssistantModel(port: terminal, provider: { forcedProvider ?? settings.assistantProvider },
                                          makeEngine: { provider in
                switch provider {
                case .claude: TerminalClaudeEngine(client: claudeClient, apiKey: { settings.anthropicAPIKey })
                case .appleOnDevice, .applePrivateCloud: makeAppleTerminalEngine()
                }
            }, pasteboard: pasteboard)
        })
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
            sessionState: { [sessions] id in sessions.watchedState(id) })
        _reachability = State(initialValue: reachability)
        let watchFeed = WatchTargetFeed(context: container.mainContext, monitor: reachability)
        self.watchFeed = watchFeed

        // The account status only for the real on-disk app (never a `CKContainer` under the hosted
        // tests, in a demo mode or in an unentitled build); the merge only while the store syncs.
        var statusProvider: (any CloudAccountStatusProviding)? = !isInMemory && isEntitled
            ? CloudKitAccountStatusProvider(containerIdentifier: RemoteDeckSchema.cloudKitContainerIdentifier) : nil
        var syncActive = opened.syncsWithICloud
        var syncEntitled = isEntitled
        #if DEBUG
        if LibraryDemo.showsSync {
            statusProvider = LibraryDemo.accountStatus
            syncActive = LibraryDemo.syncsInDemo
            syncEntitled = true
        }
        #endif
        let merger = opened.syncsWithICloud
            ? LibraryMerger(context: container.mainContext, passwords: passwords, sshSecrets: ssh.secrets,
                            trustedHostKeys: ssh.trustedHostKeys,
                            hasSession: { [sessions] id in sessions.hasSession(id) })
            : nil
        let sync = LibrarySync(isActive: syncActive, isEntitled: syncEntitled,
                               openError: opened.syncError.map { String(describing: $0) },
                               statusProvider: statusProvider, merger: merger,
                               onRemoteChange: { [watchFeed] in watchFeed.refresh() })
        _sync = State(initialValue: sync)
        if !isRunningTests { sync.start() }
        #if DEBUG
        if LibraryDemo.showsSync { LibraryDemo.simulateSync(sync) }
        #endif
        // Keychain (T4.3): once the build has a keychain access group, items an older build left in
        // the file keychain move to the data-protection keychain, local passwords to iCloud Keychain.
        // Detached: a file-keychain item that asks for its keychain password never holds the main actor.
        if !isInMemory {
            let machines = (try? container.mainContext.fetch(FetchDescriptor<Machine>())) ?? []
            let ids = machines.map(\.id)
            let sshIDs = machines.filter { $0.kindValue == .ssh }.map(\.id)
            let keychain = KeychainStore.app
            Task.detached(priority: .utility) { keychain.migrateAtLaunch(machineIDs: ids, sshMachineIDs: sshIDs) }
        }
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
            LibraryView(model: library, tester: tester, sshTester: sshTester, makeDiscovery: makeDiscovery, storeError: storeError,
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
        // Window › Library (⌘0) opens it: no second, automatic entry in the Window menu. Before
        // `.commands`, so only the scene's own menu item goes, not the commands added below.
        .commandsRemoved()
        .commands {
            UpdateCommands(settings: settings, updater: updater)
            LibraryCommands(settings: settings)
            SessionTabCommands(settings: settings, sessions: sessions)
            FileTransferCommands(settings: settings)
            TerminalAssistantCommands(settings: settings)
            HelpCommands(settings: settings)
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
        // Window › Session History (⌘Y) and the Library toolbar open it; no duplicate entry.
        .commandsRemoved()

        // Help and What's New (AppFlow › Help and What's New): never opened nor restored at launch,
        // so nothing is fetched until the user asks.
        Window(settings.t("help_window_title"), id: HelpWindow.helpID) {
            HelpWindowView(model: help)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 720)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // Help › RemoteDeck Help opens it: not listed again in the Window menu.
        .commandsRemoved()
        Window(settings.t("whats_new_window_title"), id: HelpWindow.whatsNewID) {
            HelpWindowView(model: whatsNew)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 760, height: 620)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

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
            SettingsView(apiKeyChecker: apiKeyChecker, appleStatus: appleStatus)
                .environment(settings)
                .environment(notificationPermission)
                .environment(sync)
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
