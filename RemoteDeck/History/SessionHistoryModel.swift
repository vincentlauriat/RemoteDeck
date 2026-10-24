import AppKit
import Observation
import SwiftData
import UniformTypeIdentifiers
import RemoteDeckCore

// MARK: - Connect path

/// The Library's Connect, shared by the Menu Bar Extra and the Session History View's Reconnect: a
/// connectable machine gets its Session Window tab (a new one, or its open tab brought forward).
@MainActor
enum SessionLauncher {
    /// `true` when a new tab was requested through `openWindow`; `false` for a machine that is gone,
    /// cannot connect, or already has a tab (brought forward by `requestWindow`).
    @discardableResult
    static func connect(_ machine: Machine?, sessions: SessionManager, openWindow: (UUID) -> Void) -> Bool {
        guard let machine, machine.canConnect, sessions.requestWindow(for: machine.id) else { return false }
        openWindow(machine.id)
        return true
    }
}

extension SessionManager {
    /// The records of the sessions open now (connecting or connected): those rows are "in progress".
    /// A record without an end that is not in here was left by a killed run.
    var liveRecordIDs: Set<UUID> {
        Set(sessions.values.compactMap { session in
            switch session.phase {
            case .connecting, .connected: session.record?.id
            case .idle, .failed, .waiting, .closed: nil
            }
        })
    }
}

// MARK: - Menu Bar Extra

/// DesignBrief › Menu Bar Extra: the favorites, then the 5 most recent other machines (each machine
/// once in the menu, as in the Library), only machines that still exist.
enum MenuBarMenu {
    static let recentLimit = 5

    static func favorites(_ machines: [Machine]) -> [Machine] {
        machines.filter(\.isFavorite).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The newest records the menu reads (one fetch, bounded): plenty for 5 distinct machines.
    static var recordsDescriptor: FetchDescriptor<SessionRecord> {
        var descriptor = FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 200
        return descriptor
    }

    /// The line shown when the menu has no machine row: none in the library, or none favorite or recent.
    static func emptyKey(machines: [Machine], favorites: [Machine], recents: [Machine]) -> String? {
        guard favorites.isEmpty && recents.isEmpty else { return nil }
        return machines.isEmpty ? "empty_library_title" : "menubar_empty"
    }

    static func recents(_ machines: [Machine], entries: [HistoryEntry]) -> [Machine] {
        let byID = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = Set(machines.filter(\.isFavorite).map(\.id))
        return SessionHistory.recentMachineIDs(entries, existing: Set(byID.keys), excluded: favorites,
                                               limit: recentLimit)
            .compactMap { byID[$0] }
    }
}

// MARK: - CSV export

/// Where the CSV goes: the save panel and the file write in the app, fakes in tests (no panel, no file).
@MainActor
protocol HistoryExporting {
    /// The file the user picked, `nil` when the panel was cancelled.
    func chooseDestination(suggestedName: String) async -> URL?
    func write(_ data: Data, to url: URL) throws
}

/// NSSavePanel (the user-selected read-write sandbox entitlement), as a sheet on the key window (the
/// History window, whose Export… was clicked) when there is one, then an atomic write.
struct SavePanelExporter: HistoryExporting {
    func chooseDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            let done = { (response: NSApplication.ModalResponse) in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: done)
            } else {
                panel.begin(completionHandler: done)
            }
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Session History View

/// AppFlow › Session History View: search, machine and outcome filters, sort, Reconnect, Export CSV.
/// Views format the rows; this model only exposes values and enums.
@Observable
@MainActor
final class SessionHistoryModel {
    var searchText = ""
    var machineFilter: UUID?
    var outcomeFilter: HistoryOutcome?
    /// Newest first (AppFlow › Open).
    var sortOrder = [KeyPathComparator(\HistoryRow.startedAt, order: .reverse)]
    var selection: Set<UUID> = []
    /// Why a Reconnect did nothing: the machine was deleted since, or it has no valid address.
    enum ReconnectFailure: Equatable {
        case machineDeleted
        case cannotConnect
    }

    var reconnectFailure: ReconnectFailure?
    /// The CSV could not be written: the alert shows this error.
    var exportError: String?
    private(set) var isExporting = false

    @ObservationIgnored private let exporter: any HistoryExporting
    @ObservationIgnored private let now: () -> Date

    init(exporter: any HistoryExporting, now: @escaping () -> Date = { Date.now }) {
        self.exporter = exporter
        self.now = now
    }

    var isFiltering: Bool {
        machineFilter != nil || outcomeFilter != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func rows(_ entries: [HistoryEntry], liveRecordIDs: Set<UUID>) -> [HistoryRow] {
        SessionHistory.rows(entries, liveRecordIDs: liveRecordIDs, query: searchText,
                            machineID: machineFilter, outcome: outcomeFilter)
            .sorted(using: sortOrder)
    }

    /// Over every record, whatever the filters: the metric is global.
    func summary(_ entries: [HistoryEntry], liveRecordIDs: Set<UUID>) -> HistorySummary {
        HistorySummary(entries, now: now(), liveRecordIDs: liveRecordIDs)
    }

    /// Double-click a row: the Connect path, or an alert ("Machine deleted", "Cannot connect").
    func reconnect(_ row: HistoryRow, machines: [Machine], sessions: SessionManager, openWindow: (UUID) -> Void) {
        guard let machine = machines.first(where: { $0.id == row.entry.machineID }) else {
            reconnectFailure = .machineDeleted
            return
        }
        guard machine.canConnect else {
            reconnectFailure = .cannotConnect
            return
        }
        SessionLauncher.connect(machine, sessions: sessions, openWindow: openWindow)
    }

    /// `RemoteDeck History 2026-10-23.csv` (local date).
    func suggestedFileName() -> String {
        "RemoteDeck History \(now().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())).csv"
    }

    /// Export… : every record (not only the filtered rows), as CSV, to the file the user picks.
    func export(_ entries: [HistoryEntry], liveRecordIDs: Set<UUID> = []) async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        guard let url = await exporter.chooseDestination(suggestedName: suggestedFileName()) else { return }
        do {
            try exporter.write(Data(HistoryCSV.make(entries, liveRecordIDs: liveRecordIDs).utf8), to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
