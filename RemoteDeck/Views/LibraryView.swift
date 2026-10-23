import SwiftUI
import SwiftData
import RemoteDeckCore

/// A request to open the Machine Editor; the model is built once, when the request is made.
struct EditorRequest: Identifiable {
    let id = UUID()
    let model: MachineEditorModel
}

/// Library Window (AppFlow › Library Window): sidebar with Favorites, groups and ungrouped
/// machines, live search, detail pane, Machine Editor sheet.
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var sessions
    @Environment(ReachabilityMonitor.self) private var reachability
    @Environment(StatusNotificationRouter.self) private var notificationRouter
    @Environment(\.openWindow) private var openWindow
    @Query private var machines: [Machine]
    @Query private var groups: [MachineGroup]
    @Bindable var model: MachineLibraryModel
    let tester: any ConnectionTester
    /// Builds the Discovery Panel's service (live Bonjour, or the demo's fake one).
    let makeDiscovery: @MainActor () -> DiscoveryService
    /// Set when the on-disk store could not be opened (the library then runs in memory, and a
    /// persistent banner says so).
    let storeError: String?
    /// Whether this launch may show the Onboarding Sheet, and what answers its notification button.
    let onboardingLaunch: OnboardingLaunch
    let notificationAuthorizer: any NotificationAuthorizing

    @State private var editorRequest: EditorRequest?
    @State private var discoveryRequest: DiscoveryRequest?
    /// The row whose "Add" closed the Discovery Panel: the editor opens once the panel is gone.
    @State private var pendingDiscovered: DiscoveredMachine?
    @State private var onboarding: OnboardingModel?
    /// The model of the sheet on screen, kept until its dismissal (`onboarding` is nil by then).
    @State private var presentedOnboarding: OnboardingModel?
    @State private var pendingDelete: Machine?
    @State private var pendingGroupDelete: MachineGroup?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        // At the bottom of the window: at the top, the sidebar's search field was drawn over it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let storeError { storeBanner(storeError) }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: settings.t("search_placeholder"))
        .searchFocused($searchFocused)
        .toolbar { toolbar }
        .navigationTitle(settings.t("app_name"))
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $onboarding, onDismiss: onboardingDismissed) { model in
            OnboardingSheetView(model: model) { _ in
                onboarding = nil
            }
        }
        .sheet(item: $discoveryRequest, onDismiss: openPendingDiscovered) { request in
            DiscoveryPanelView(model: request.model, libraryKeys: Set(machines.map(\.normalizedKey))) { found in
                pendingDiscovered = found
                discoveryRequest = nil
            }
        }
        .sheet(item: $editorRequest) { request in
            MachineEditorView(model: request.model) { saved in
                model.selection = saved.id
            }
        }
        .confirmationDialog(
            settings.t("delete_confirm_title", pendingDelete?.name ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { machine in
            Button(settings.t("delete_button"), role: .destructive) { model.delete(machine) }
            Button(settings.t("cancel"), role: .cancel) {}
        } message: { _ in
            Text(settings.t("delete_confirm_message"))
        }
        .confirmationDialog(
            settings.t("delete_group_confirm_title", pendingGroupDelete?.name ?? ""),
            isPresented: Binding(get: { pendingGroupDelete != nil }, set: { if !$0 { pendingGroupDelete = nil } }),
            presenting: pendingGroupDelete
        ) { group in
            Button(settings.t("delete_button"), role: .destructive) { model.delete(group) }
            Button(settings.t("cancel"), role: .cancel) {}
        } message: { _ in
            Text(settings.t("delete_group_confirm_message"))
        }
        .alert(settings.t("error_title"), isPresented: alertBinding) {
            Button(settings.t("ok")) { dismissAlerts() }
        } message: {
            Text(alertMessage)
        }
        .focusedSceneValue(\.libraryActions, LibraryActions(
            newMachine: { openEditor(for: nil) },
            discover: { openDiscovery() },
            find: { searchFocused = true }
        ))
        // Status Notifications (T4.5): the watched machines reach the monitor from the store
        // (`WatchTargetFeed`), not from this window, which may be closed.
        .onChange(of: notificationRouter.pending, initial: true) { openFromNotification() }
        .onAppear {
            notificationRouter.openLibrary = { [openWindow] in openWindow(id: LibraryWindow.id) }
            // First launch (AppFlow › First use); never under tests or the other debug modes.
            if onboarding == nil {
                onboarding = onboardingLaunch.makeModel(settings: settings, authorizer: notificationAuthorizer)
                presentedOnboarding = onboarding
            }
            #if DEBUG
            if LibraryDemo.opensEditor { openEditor(for: machines.sorted { $0.name < $1.name }.first) }
            if LibraryDemo.opensDiscovery { openDiscovery() }
            if LibraryDemo.scriptsAssistant || LibraryDemo.showsHistory {
                connect(machines.first { $0.name == "Mac mini" })
            }
            if LibraryDemo.showsHistory { openWindow(id: HistoryWindow.id) }
            if LibraryDemo.opensSessions {
                LibraryDemo.sessionMachineNames.forEach { name in connect(machines.first { $0.name == name }) }
                // AC6: what ⌘2 does (the same call as the menu item), once the tabs are up.
                Task {
                    try? await Task.sleep(for: LibraryDemo.selectsSecondTabAfter)
                    SessionTabs.selectTab(at: 1)
                }
            }
            #endif
        }
    }

    // MARK: Sidebar

    private var sections: [LibrarySection] {
        MachineLibraryModel.sections(machines: machines, groups: groups, query: model.searchText, t: settings.t)
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.machines) { machine in
                        MachineRowView(machine: machine, isConnecting: sessions.isConnecting(machine.id),
                                       status: status(of: machine))
                            .tag(machine.id)
                    }
                } header: {
                    Text(section.title)
                        // The whole header row opens the menu, not just the title's glyphs.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if let group = section.group {
                                Button(settings.t("delete_group")) { pendingGroupDelete = group }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let machine = machine(ids.first), ids.count == 1 {
                Button(settings.t("edit")) { openEditor(for: machine) }
                Button(settings.t("delete"), role: .destructive) { pendingDelete = machine }
            }
        } primaryAction: { ids in
            // Double-click / Return: Connect (AppFlow).
            connect(machine(ids.first))
        }
        .onDeleteCommand {
            if let machine = machine(model.selection) { pendingDelete = machine }
        }
        .overlay {
            if !machines.isEmpty && sections.allSatisfy(\.machines.isEmpty) && !model.searchText.isEmpty {
                ContentUnavailableView(
                    settings.t("no_results_title"),
                    systemImage: "magnifyingglass",
                    description: Text(settings.t("no_results_desc", model.searchText))
                )
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if machines.isEmpty {
            ContentUnavailableView {
                Label(settings.t("empty_library_title"), systemImage: "desktopcomputer")
            } actions: {
                HStack {
                    Button(settings.t("empty_library_discover")) { openDiscovery() }
                    Button(settings.t("empty_library_add")) { openEditor(for: nil) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if let machine = machine(model.selection) {
            MachineDetailView(machine: machine, status: status(of: machine), onConnect: { connect(machine) }, onEdit: { openEditor(for: machine) })
        } else {
            ContentUnavailableView(
                settings.t("no_selection_title"),
                systemImage: "sidebar.left",
                description: Text(settings.t("no_selection_desc"))
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { openEditor(for: nil) } label: {
                Label(settings.t("add_machine"), systemImage: "plus")
            }
            .help(settings.t("add_machine"))
            Button { openDiscovery() } label: {
                Label(settings.t("discover"), systemImage: "antenna.radiowaves.left.and.right")
            }
            .help(settings.t("discover"))
            Button { connect(machine(model.selection)) } label: {
                Label(settings.t("connect"), systemImage: "play.fill")
            }
            .disabled(!canConnect(machine(model.selection)))
            .help(settings.t("connect"))
        }
    }

    // MARK: Actions

    private func machine(_ id: UUID?) -> Machine? {
        guard let id else { return nil }
        return machines.first { $0.id == id }
    }

    private func openEditor(for machine: Machine?, discovered: DiscoveredMachine? = nil) {
        guard onboarding == nil else { return }
        editorRequest = EditorRequest(model: MachineEditorModel(
            machine: machine, context: model.context, passwords: model.passwords,
            tester: tester, defaultSharedClipboard: settings.defaultSharedClipboard, discovered: discovered
        ))
    }

    /// AppFlow › Discover (⌘D, toolbar, empty library): opens the Discovery Panel.
    private func openDiscovery() {
        guard discoveryRequest == nil, editorRequest == nil, onboarding == nil else { return }
        discoveryRequest = DiscoveryRequest(model: makeDiscovery())
    }

    /// The Onboarding Sheet went away. Dismissed without a button (window closed) counts as Later;
    /// after the last page, the Discovery Panel opens (first-time main path). A quit never gets here,
    /// so quitting mid-onboarding shows the sheet again at the next launch.
    private func onboardingDismissed() {
        guard let model = presentedOnboarding else { return }
        presentedOnboarding = nil
        model.later()   // no-op once ended
        if model.opensDiscovery { openDiscovery() }
    }

    /// AppFlow › Discovery Panel › Add: Machine Editor pre-filled, after the panel has closed.
    private func openPendingDiscovered() {
        guard let found = pendingDiscovered else { return }
        pendingDiscovered = nil
        openEditor(for: nil, discovered: found)
    }

    /// Single entry point for Connect (double-click, Return, toolbar, detail pane): opens the
    /// machine's Session Window, or brings it forward if it is already open (AppFlow › Connect).
    private func connect(_ machine: Machine?) {
        SessionLauncher.connect(machine, sessions: sessions) { id in
            openWindow(id: SessionWindow.id, value: id)
        }
    }

    private func canConnect(_ machine: Machine?) -> Bool {
        machine?.canConnect ?? false
    }

    // MARK: Status Notifications

    private func status(of machine: Machine) -> StatusPresentation {
        reachability.presentation(machineID: machine.id, isWatched: machine.isWatched)
    }

    /// A clicked notification (AppFlow › Entry points): the machine is selected; "back online"
    /// also connects, through the same path as the Connect button. A machine deleted since is ignored.
    private func openFromNotification() {
        guard let request = notificationRouter.take(), let machine = machine(request.machineID) else { return }
        model.selection = machine.id
        if request.connects { connect(machine) }
    }

    // MARK: Banner and alerts

    /// DesignBrief › Banners: 32 pt, colored left bar. Stays as long as the library is in memory.
    private func storeBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.orange).frame(width: 3)
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.t("store_error_title")).font(.system(size: 12, weight: .semibold))
                Text(settings.t("store_banner")).font(.system(size: 11))
            }
            .help(error)
            Spacer()
        }
        .frame(minHeight: 32)
        .fixedSize(horizontal: false, vertical: true)   // the bar's height, not the window's
        .background(.orange.opacity(0.12))
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.deleteWarning != nil || model.deleteError != nil },
            set: { if !$0 { dismissAlerts() } }
        )
    }

    private var alertMessage: String {
        if let warning = model.deleteWarning {
            return settings.t("delete_keychain_warning", warning.description)
        }
        if let error = model.deleteError {
            return settings.t("delete_failed", error)
        }
        return ""
    }

    private func dismissAlerts() {
        model.deleteWarning = nil
        model.deleteError = nil
    }
}

// MARK: - Commands

/// Library actions exposed to the menu bar (⌘N, ⌘F) by the focused Library Window.
struct LibraryActions {
    let newMachine: () -> Void
    let discover: () -> Void
    let find: () -> Void
}

private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

extension FocusedValues {
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}

/// AppFlow shortcuts: ⌘N Add machine, ⌘F Search, ⌘D Discover, ⌘0 Library, ⌘Y Session History.
struct LibraryCommands: Commands {
    let settings: AppSettings
    @FocusedValue(\.libraryActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(settings.t("menu_new_machine")) { actions?.newMachine() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button(settings.t("menu_discover")) { actions?.discover() }
                .keyboardShortcut("d")
                .disabled(actions == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(settings.t("menu_find")) { actions?.find() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }
        CommandGroup(before: .windowList) {
            Button(settings.t("menu_library")) { openWindow(id: LibraryWindow.id) }
                .keyboardShortcut("0")
            Button(settings.t("menu_session_history")) { openWindow(id: HistoryWindow.id) }
                .keyboardShortcut("y")
            Divider()
        }
    }
}

enum LibraryWindow {
    static let id = "library"
}
