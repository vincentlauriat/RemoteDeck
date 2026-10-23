import SwiftUI
import SwiftData
import RemoteDeckCore

/// Menu Bar Extra (AppFlow › Entry points, DesignBrief › Menu Bar Extra): favorites, a separator, the
/// 5 most recent other machines, then Open Library…, Session History… and Quit. A click connects
/// through the Library's Connect path.
struct MenuBarContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Query private var machines: [Machine]
    @Query(MenuBarMenu.recordsDescriptor) private var records: [SessionRecord]

    var body: some View {
        let favorites = MenuBarMenu.favorites(machines)
        let recents = MenuBarMenu.recents(machines, entries: records.map(HistoryEntry.init))
        if let key = MenuBarMenu.emptyKey(machines: machines, favorites: favorites, recents: recents) {
            Text(settings.t(key))
        }
        if !favorites.isEmpty {
            Section(settings.t("section_favorites")) {
                ForEach(favorites) { item($0) }
            }
        }
        if !recents.isEmpty {
            Section(settings.t("menubar_recents")) {
                ForEach(recents) { item($0) }
            }
        }
        Divider()
        Button(settings.t("menubar_open_library")) { open(id: LibraryWindow.id) }
        Button(settings.t("menubar_history")) { open(id: HistoryWindow.id) }
        Divider()
        Button(settings.t("menubar_quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func item(_ machine: Machine) -> some View {
        Button {
            NSApp.activate()
            SessionLauncher.connect(machine, sessions: sessions) { id in
                openWindow(id: SessionWindow.id, value: id)
            }
        } label: {
            Label(machine.name, systemImage: machine.kindValue.symbolName)
        }
        .disabled(!machine.canConnect)
    }

    private func open(id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}
