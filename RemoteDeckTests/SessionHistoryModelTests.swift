import AppKit
import Foundation
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

/// Never a save panel nor a file: records what would be written.
@MainActor
final class FakeHistoryExporter: HistoryExporting {
    var destination: URL? = URL(fileURLWithPath: "/nonexistent/history.csv")
    var writeError: (any Error)?
    private(set) var suggestedNames: [String] = []
    private(set) var written: [(data: Data, url: URL)] = []

    func chooseDestination(suggestedName: String) async -> URL? {
        suggestedNames.append(suggestedName)
        return destination
    }

    func write(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        written.append((data, url))
    }
}

@MainActor
private func makeManager(_ context: ModelContext) -> SessionManager {
    SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                   makeConnection: { _ in FakeSessionConnection(log: SessionLog(), hangs: true) },
                   makeDisplay: { nil }, pasteboard: InMemoryPasteboard())
}

@MainActor
private func entries(_ context: ModelContext) throws -> [HistoryEntry] {
    try context.fetch(FetchDescriptor<SessionRecord>()).map(HistoryEntry.init)
}

private let fixedNow = Date(timeIntervalSince1970: 1_793_000_000)

@MainActor
struct SessionHistoryModelTests {
    /// The live session's record is "in progress"; an open record of the same machine left by a killed
    /// run is "unknown"; once the window closes, the live one gets its end.
    @Test func inProgressOnlyForTheLiveRecord() async throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(machine)
        let crashed = SessionRecord(machineID: machine.id, machineName: "Mini",
                                    startedAt: .now.addingTimeInterval(-86_400), connectMillis: 900, outcome: .connected)
        context.insert(crashed)
        try context.save()
        let manager = makeManager(context)
        let session = try #require(manager.session(for: machine.id))
        let live = try #require(session.record)
        #expect(manager.liveRecordIDs == [live.id])

        let model = SessionHistoryModel(exporter: FakeHistoryExporter())
        var rows = model.rows(try entries(context), liveRecordIDs: manager.liveRecordIDs)
        #expect(rows.map(\.id) == [live.id, crashed.id])
        #expect(rows.map(\.duration) == [.inProgress, .unknown])

        manager.close(machine.id)
        #expect(manager.liveRecordIDs.isEmpty)
        rows = model.rows(try entries(context), liveRecordIDs: manager.liveRecordIDs)
        guard case .ended = rows[0].duration else {
            Issue.record("closed session should have an end: \(rows[0].duration)")
            return
        }
        #expect(rows[1].duration == .unknown)
        #expect(await waitUntil { session.phase == .closed })
    }

    /// A failed attempt is not live: its record has its end.
    @Test func failedSessionIsNotLive() async throws {
        let context = try makeTestContext()
        let machine = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(machine)
        try context.save()
        let manager = SessionManager(context: context, passwords: FakePasswordStore(), tester: FakeConnectionTester(),
                                     makeConnection: { _ in
                                         FakeSessionConnection(log: SessionLog(), connectResult: .failure(.authFailed(reason: nil)))
                                     }, makeDisplay: { nil }, pasteboard: InMemoryPasteboard())
        let session = try #require(manager.session(for: machine.id))
        #expect(await waitUntil { session.failure != nil })
        #expect(manager.liveRecordIDs.isEmpty)
        manager.close(machine.id)
    }

    /// Filters, search and sort go through the model; the default order is newest first.
    @Test func filterAndSort() throws {
        let mini = UUID(), nas = UUID()
        let list = [
            HistoryEntry(machineID: mini, machineName: "Mac mini", startedAt: fixedNow.addingTimeInterval(-10),
                         connectMillis: 3000, endedAt: fixedNow, outcome: .connected),
            HistoryEntry(machineID: nas, machineName: "NAS", startedAt: fixedNow.addingTimeInterval(-20),
                         endedAt: fixedNow, outcome: .unreachable),
            HistoryEntry(machineID: mini, machineName: "Mac mini", startedAt: fixedNow.addingTimeInterval(-30),
                         connectMillis: 500, endedAt: fixedNow, outcome: .connected),
        ]
        let model = SessionHistoryModel(exporter: FakeHistoryExporter(), now: { fixedNow })
        #expect(model.rows(list, liveRecordIDs: []).map(\.id) == list.map(\.id))
        model.sortOrder = [KeyPathComparator(\HistoryRow.connectSortKey)]
        #expect(model.rows(list, liveRecordIDs: []).map(\.id) == [list[2].id, list[0].id, list[1].id])
        model.machineFilter = mini
        #expect(model.rows(list, liveRecordIDs: []).count == 2)
        #expect(model.isFiltering)
        model.machineFilter = nil
        model.outcomeFilter = .unreachable
        #expect(model.rows(list, liveRecordIDs: []).map(\.machineName) == ["NAS"])
        model.outcomeFilter = nil
        model.searchText = "mini"
        #expect(model.rows(list, liveRecordIDs: []).count == 2)
        // The summary ignores the filters.
        #expect(model.summary(list, liveRecordIDs: []).attempts == 3)
    }

    /// A deleted machine keeps its name in the history; Reconnect on it says "Machine deleted" and
    /// opens nothing. On an existing machine it takes the Connect path.
    @Test func deletedMachineKeepsItsNameAndCannotReconnect() async throws {
        let context = try makeTestContext()
        let gone = Machine(name: "Old iMac", host: "imac.local", username: "vincent")
        let mini = Machine(name: "Mini", host: "mini.local", username: "vincent")
        context.insert(gone)
        context.insert(mini)
        context.insert(SessionRecord(machineID: gone.id, machineName: "Old iMac", startedAt: fixedNow,
                                     connectMillis: 800, endedAt: fixedNow.addingTimeInterval(60), outcome: .connected))
        context.insert(SessionRecord(machineID: mini.id, machineName: "Mini", startedAt: fixedNow.addingTimeInterval(-60),
                                     connectMillis: 800, endedAt: fixedNow, outcome: .connected))
        try context.save()
        let library = MachineLibraryModel(context: context, passwords: FakePasswordStore())
        library.delete(gone)
        let machines = try context.fetch(FetchDescriptor<Machine>())
        #expect(machines.map(\.name) == ["Mini"])

        let model = SessionHistoryModel(exporter: FakeHistoryExporter())
        let rows = model.rows(try entries(context), liveRecordIDs: [])
        #expect(rows.map(\.machineName) == ["Old iMac", "Mini"])
        let manager = makeManager(context)
        var opened: [UUID] = []
        model.reconnect(rows[0], machines: machines, sessions: manager) { opened.append($0) }
        #expect(model.reconnectFailure == .machineDeleted)
        #expect(opened.isEmpty)
        #expect(manager.sessions.isEmpty)

        model.reconnectFailure = nil
        model.reconnect(rows[1], machines: machines, sessions: manager) { opened.append($0) }
        #expect(model.reconnectFailure == nil)
        #expect(opened == [mini.id])
        #expect(manager.sessions[mini.id] != nil)
        manager.close(mini.id)
    }

    /// A machine without a valid address (synced or edited badly): "Cannot connect", nothing opened.
    @Test func reconnectOnAnUnconnectableMachineSaysSo() throws {
        let context = try makeTestContext()
        let broken = Machine(name: "Broken", host: " ", username: "vincent")
        context.insert(broken)
        context.insert(SessionRecord(machineID: broken.id, machineName: "Broken", startedAt: fixedNow,
                                     endedAt: fixedNow.addingTimeInterval(1), outcome: .unreachable))
        try context.save()
        let model = SessionHistoryModel(exporter: FakeHistoryExporter())
        let manager = makeManager(context)
        var opened: [UUID] = []
        let row = try #require(model.rows(try entries(context), liveRecordIDs: []).first)
        model.reconnect(row, machines: [broken], sessions: manager) { opened.append($0) }
        #expect(model.reconnectFailure == .cannotConnect)
        #expect(opened.isEmpty)
        #expect(manager.sessions.isEmpty)
    }

    // MARK: Export

    @Test func exportWritesEveryRecordAsCSV() async throws {
        let exporter = FakeHistoryExporter()
        let model = SessionHistoryModel(exporter: exporter, now: { fixedNow })
        let list = [HistoryEntry(machineID: UUID(), machineName: "A, B", startedAt: fixedNow, outcome: .cancelled)]
        await model.export(list)
        #expect(exporter.suggestedNames.count == 1)
        #expect(exporter.suggestedNames[0].hasPrefix("RemoteDeck History 2026-10-2"))
        #expect(exporter.suggestedNames[0].hasSuffix(".csv"))
        let written = try #require(exporter.written.first)
        #expect(String(decoding: written.data, as: UTF8.self) == HistoryCSV.make(list))
        #expect(model.exportError == nil)
        #expect(!model.isExporting)
    }

    @Test func cancelledPanelWritesNothing() async {
        let exporter = FakeHistoryExporter()
        exporter.destination = nil
        let model = SessionHistoryModel(exporter: exporter)
        await model.export([])
        #expect(exporter.written.isEmpty)
        #expect(model.exportError == nil)
    }

    @Test func writeErrorIsShown() async {
        let exporter = FakeHistoryExporter()
        exporter.writeError = CocoaError(.fileWriteNoPermission)
        let model = SessionHistoryModel(exporter: exporter)
        await model.export([])
        #expect(model.exportError != nil)
        #expect(exporter.written.isEmpty)
    }
}

// MARK: - Menu Bar Extra

@MainActor
struct MenuBarMenuTests {
    /// Favorites by name; recents distinct, newest first, at most 5, without favorites and without
    /// machines deleted since.
    @Test func favoritesThenRecents() throws {
        let context = try makeTestContext()
        let names = ["M0", "M1", "M2", "M3", "M4", "M5", "M6"]
        let machines = names.map { Machine(name: $0, host: "\($0.lowercased()).local", username: "v") }
        machines[6].isFavorite = true
        let zeta = Machine(name: "Zeta", host: "zeta.local", username: "v", isFavorite: true)
        let alpha = Machine(name: "alpha", host: "alpha.local", username: "v", isFavorite: true)
        (machines + [zeta, alpha]).forEach(context.insert)
        var list = machines.enumerated().map { index, machine in
            HistoryEntry(machineID: machine.id, machineName: machine.name,
                         startedAt: fixedNow.addingTimeInterval(-Double(index + 1) * 60), outcome: .connected)
        }
        list.append(HistoryEntry(machineID: machines[4].id, machineName: "M4", startedAt: fixedNow, outcome: .unreachable))
        list.append(HistoryEntry(machineID: alpha.id, machineName: "alpha", startedAt: fixedNow.addingTimeInterval(0.5),
                                 outcome: .connected))   // a favorite used last: listed under Favorites only
        list.append(HistoryEntry(machineID: UUID(), machineName: "Gone", startedAt: fixedNow.addingTimeInterval(1),
                                 outcome: .connected))
        try context.save()
        let all = try context.fetch(FetchDescriptor<Machine>())

        #expect(MenuBarMenu.favorites(all).map(\.name) == ["alpha", "M6", "Zeta"])
        #expect(MenuBarMenu.recents(all, entries: list).map(\.name) == ["M4", "M0", "M1", "M2", "M3"])
        #expect(MenuBarMenu.recents(all, entries: []).isEmpty)
    }

    /// No machine row: "No machines yet" for an empty library, else "No favorites or recent machines yet".
    @Test func emptyMenuLine() {
        let machine = Machine(name: "Mini", host: "mini.local", username: "v")
        #expect(MenuBarMenu.emptyKey(machines: [], favorites: [], recents: []) == "empty_library_title")
        #expect(MenuBarMenu.emptyKey(machines: [machine], favorites: [], recents: []) == "menubar_empty")
        #expect(MenuBarMenu.emptyKey(machines: [machine], favorites: [], recents: [machine]) == nil)
        #expect(MenuBarMenu.emptyKey(machines: [machine], favorites: [machine], recents: []) == nil)
    }

    /// The menu reads a bounded, newest-first slice of the history.
    @Test func recordsFetchIsBoundedNewestFirst() throws {
        let context = try makeTestContext()
        for index in 0..<250 {
            context.insert(SessionRecord(machineID: UUID(), machineName: "M\(index)",
                                         startedAt: fixedNow.addingTimeInterval(Double(index)), outcome: .connected))
        }
        try context.save()
        let records = try context.fetch(MenuBarMenu.recordsDescriptor)
        #expect(records.count == 200)
        #expect(records.first?.machineName == "M249")
    }

    /// A click takes the Library's Connect path: a tab for that machine, then (already open) the tab
    /// is brought forward with no second window.
    @Test func clickConnectsTheRightMachine() throws {
        let context = try makeTestContext()
        let mini = Machine(name: "Mini", host: "mini.local", username: "vincent")
        let nas = Machine(name: "NAS", host: "nas.local", username: "vincent")
        let broken = Machine(name: "Broken", host: " ", username: "vincent")
        [mini, nas, broken].forEach(context.insert)
        try context.save()
        let manager = makeManager(context)
        var opened: [UUID] = []

        #expect(SessionLauncher.connect(nas, sessions: manager) { opened.append($0) })
        #expect(opened == [nas.id])
        #expect(Set(manager.sessions.keys) == [nas.id])
        var broughtForward = 0
        manager.sessions[nas.id]?.bringWindowForward = { broughtForward += 1 }
        #expect(!SessionLauncher.connect(nas, sessions: manager) { opened.append($0) })
        #expect(opened == [nas.id])
        #expect(broughtForward == 1)
        #expect(!SessionLauncher.connect(broken, sessions: manager) { opened.append($0) })
        #expect(!SessionLauncher.connect(nil, sessions: manager) { opened.append($0) })
        #expect(opened == [nas.id])
        manager.close(nas.id)
    }
}
