import SwiftUI
import SwiftData
import RemoteDeckCore

@main
struct RemoteDeckApp: App {
    @State private var settings = AppSettings()
    @State private var library: MachineLibraryModel
    @State private var sessions: SessionManager
    private let container: ModelContainer
    private let storeError: String?
    private let tester: any ConnectionTester
    private let makeDiscovery: @MainActor () -> DiscoveryService

    init() {
        // The hosted RemoteDeckTests run inside this app: never open the user's on-disk store then.
        var inMemory = LibraryStore.isRunningTests()
        #if DEBUG
        inMemory = inMemory || LibraryDemo.isEnabled
        #endif
        let (container, isInMemory, error) = LibraryStore.open(inMemory: inMemory)
        self.container = container
        storeError = error.map { String(describing: $0) }
        let passwords = LibraryStore.passwordStore(isInMemory: isInMemory)
        _library = State(initialValue: MachineLibraryModel(context: container.mainContext, passwords: passwords))
        var tester: any ConnectionTester = RFBConnectionTester()
        var makeConnection: @MainActor (SessionTarget) -> any SessionConnection = SessionManager.rfbConnection
        // Built when the Discovery Panel opens: nothing browses the network before that.
        var makeDiscovery: @MainActor () -> DiscoveryService = {
            DiscoveryService(browsers: NWBonjourBrowserFactory(), resolver: DNSSDResolver(),
                             excludedHosts: LocalHost.bonjourNames)
        }
        #if DEBUG
        if LibraryDemo.isEnabled {
            LibraryDemo.seed(container.mainContext)
            tester = LibraryDemo.Tester()
            makeConnection = LibraryDemo.connection   // never the network: the sample hosts are not real
            makeDiscovery = LibraryDemo.discovery
            LibraryDemo.suppressAccessibilityPrompt()
        }
        #endif
        self.tester = tester
        self.makeDiscovery = makeDiscovery
        _sessions = State(initialValue: SessionManager(context: container.mainContext, passwords: passwords,
                                                       tester: tester, makeConnection: makeConnection))
    }

    var body: some Scene {
        Window(settings.t("app_name"), id: LibraryWindow.id) {
            LibraryView(model: library, tester: tester, makeDiscovery: makeDiscovery, storeError: storeError)
                .environment(settings)
                .environment(sessions)
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
        }

        // One Session Window per machine; opening a machine that has one brings it forward.
        WindowGroup(id: SessionWindow.id, for: UUID.self) { $machineID in
            if let machineID {
                SessionWindowView(machineID: machineID)
                    .environment(settings)
                    .environment(sessions)
                    .preferredColorScheme(settings.appearance.colorScheme)
            }
        }
        .modelContainer(container)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1280, height: 800)
        // Never reopened at launch: that would reconnect to a host (and could show the
        // Accessibility prompt) without the user asking.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        // Réglages via la scène native macOS (⌘,).
        Settings {
            SettingsView()
                .environment(settings)
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
