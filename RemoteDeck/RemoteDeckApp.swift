import SwiftUI
import SwiftData
import RemoteDeckCore

@main
struct RemoteDeckApp: App {
    @State private var settings = AppSettings()
    @State private var library: MachineLibraryModel
    private let container: ModelContainer
    private let storeError: String?
    private let tester: any ConnectionTester

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
        #if DEBUG
        if LibraryDemo.isEnabled {
            LibraryDemo.seed(container.mainContext)
            tester = LibraryDemo.Tester()
        }
        #endif
        self.tester = tester
    }

    var body: some Scene {
        Window(settings.t("app_name"), id: LibraryWindow.id) {
            LibraryView(model: library, tester: tester, storeError: storeError)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .modelContainer(container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .commands {
            LibraryCommands(settings: settings)
        }

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
