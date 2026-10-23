import Foundation
import SwiftData
import Testing
@testable import RemoteDeckCore

private let now = Date(timeIntervalSince1970: 1_793_000_000)   // a fixed "now"; no wall clock
private let mini = UUID()
private let nas = UUID()
private let studio = UUID()

private func entry(_ machine: UUID = mini, _ name: String = "Mac mini", ago: TimeInterval,
                   connect: Int? = nil, lasts: TimeInterval? = nil, outcome: SessionOutcome = .connected,
                   bytes: Int64 = 0, tokens: Int = 0) -> HistoryEntry {
    let start = now.addingTimeInterval(-ago)
    return HistoryEntry(machineID: machine, machineName: name, startedAt: start, connectMillis: connect,
                        endedAt: lasts.map { start.addingTimeInterval($0) }, outcome: outcome,
                        bytesReceived: bytes, assistantTokens: tokens)
}

// MARK: - Summary

struct HistorySummaryTests {
    /// First frames count, fast when ≤ 5000 ms; an attempt that ended without a first frame counts as
    /// slow only after more than 5 s (exactly 5 s stays out); quick failures and open records stay out.
    @Test func fastShareCountsFirstFramesAndSlowFailures() throws {
        let entries = [
            entry(ago: 100, connect: 1200, lasts: 60),
            entry(ago: 200, connect: 5000, lasts: 60),
            entry(ago: 300, connect: 5001, lasts: 60),
            entry(nas, "NAS", ago: 400, connect: 800, lasts: 10, outcome: .dropped),   // dropped after a frame
            entry(ago: 500, outcome: .cancelled),                                      // interrupted: out
            entry(studio, "Studio", ago: 600, lasts: 2, outcome: .authFailed),         // fast failure: out
            entry(nas, "NAS", ago: 700, lasts: 10, outcome: .unreachable),             // slow: in
            entry(nas, "NAS", ago: 800, lasts: 3, outcome: .dropped),                  // before a frame, fast: out
            entry(ago: 900, lasts: 5, outcome: .unreachable),                          // exactly 5 s: out
            entry(ago: 950, lasts: 5.001, outcome: .unreachable),                      // just over: in
            entry(ago: 990, lasts: 8, outcome: .cancelled),                            // cancelled after 8 s: in
        ]
        let summary = HistorySummary(entries, now: now)
        #expect(summary.attempts == 11)
        #expect(summary.sessions == 4)
        #expect(summary.slowFailures == 3)
        #expect(summary.fastSessions == 3)
        #expect(try #require(summary.fastShare) == 3.0 / 7.0)
        #expect(summary.authFailed == 1)
        #expect(summary.unreachable == 3)
        #expect(summary.dropped == 2)
        #expect(summary.cancelled == 1)       // the 8 s cancel; the open record is interrupted
        #expect(summary.interrupted == 1)
    }

    /// Floored to 0.1 %: 89.96 % never shows as 90 %.
    @Test func displayedShareIsFloored() {
        #expect(HistorySummary.displayShare(0.8996) == 0.899)
        #expect(HistorySummary.displayShare(0.9) == 0.9)
        #expect(HistorySummary.displayShare(1) == 1)
    }

    @Test func noSessionHasNoShareNorPercentiles() {
        let summary = HistorySummary([entry(ago: 10, outcome: .cancelled)], now: now)
        #expect(summary.sessions == 0)
        #expect(summary.fastShare == nil)
        #expect(summary.p50Millis == nil)
        #expect(summary.p90Millis == nil)
        #expect(HistorySummary([], now: now).attempts == 0)
    }

    /// Nearest rank over the sessions' connect times.
    @Test func percentilesAreNearestRank() {
        let millis = [900, 100, 500, 700, 300, 200, 400, 1000, 600, 800]   // 100…1000, shuffled
        let summary = HistorySummary(millis.enumerated().map { entry(ago: Double($0.offset + 1), connect: $0.element, lasts: 1) },
                                     now: now)
        #expect(summary.p50Millis == 500)
        #expect(summary.p90Millis == 900)
        #expect(HistorySummary.percentile(0.9, of: [42]) == 42)
        #expect(HistorySummary.percentile(0.5, of: [1, 2, 3]) == 2)
        #expect(HistorySummary.percentile(0.9, of: [1, 2, 3]) == 3)
    }

    /// Exactly 30 × 24 h ago is inside; one second more is outside; a record after `now` is outside.
    @Test func windowEdgesAreAbsoluteIntervals() {
        let window = HistorySummary.window
        let entries = [
            entry(ago: window, connect: 100, lasts: 10),
            entry(ago: window + 1, connect: 100, lasts: 10),
            entry(ago: -1, connect: 100, lasts: 10),
            entry(ago: 0, connect: 100, lasts: 10),
        ]
        #expect(HistorySummary(entries, now: now).attempts == 2)
        // Across a DST change (Europe/Paris, 2026-10-25 03:00 → 02:00) the window stays 720 h: no calendar.
        let paris = TimeZone(identifier: "Europe/Paris")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let afterDST = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        let edge = HistoryEntry(machineID: mini, machineName: "Mac mini", startedAt: afterDST.addingTimeInterval(-window),
                                connectMillis: 100, endedAt: afterDST, outcome: .connected)
        let outside = HistoryEntry(machineID: mini, machineName: "Mac mini",
                                   startedAt: afterDST.addingTimeInterval(-window - 0.001),
                                   connectMillis: 100, endedAt: afterDST, outcome: .connected)
        #expect(HistorySummary([edge, outside], now: afterDST).attempts == 1)
    }

    /// Durations add only the sessions with an end; a killed one counts as a session (and toward the
    /// ≤ 5 s share) with an unknown duration; a live one is in progress.
    @Test func totalsExcludeOpenRecords() {
        let live = entry(ago: 50, connect: 900)
        let crashed = entry(ago: 5000, connect: 1100)
        let entries = [entry(ago: 100, connect: 1000, lasts: 60), entry(ago: 900, connect: 2000, lasts: 120.5),
                       live, crashed, entry(ago: 300, lasts: 40, outcome: .unreachable)]
        let summary = HistorySummary(entries, now: now, liveRecordIDs: [live.id])
        #expect(summary.sessions == 4)
        #expect(summary.fastSessions == 4)
        #expect(summary.connectedTime == 180.5)
        #expect(summary.inProgress == 1)
        #expect(summary.unknownDuration == 1)
        #expect(summary.interrupted == 0)
    }

    /// Grouped by machine id: a renamed machine is one row with its newest name.
    @Test func perMachineBreakdown() throws {
        let entries = [
            entry(mini, "Old mini", ago: 900, connect: 1000, lasts: 100),
            entry(mini, "Mac mini", ago: 100, connect: 1000, lasts: 50),
            entry(mini, "Mac mini", ago: 200, outcome: .cancelled),
            entry(nas, "NAS", ago: 300, connect: 3000, lasts: 10),
            entry(studio, "Studio", ago: 400, lasts: 1, outcome: .authFailed),
            entry(nas, "NAS", ago: HistorySummary.window + 10, connect: 3000, lasts: 1000),   // outside
        ]
        let machines = HistorySummary(entries, now: now).machines
        #expect(machines.map(\.name) == ["Mac mini", "NAS", "Studio"])
        let first = try #require(machines.first)
        #expect(first.id == mini)
        #expect(first.attempts == 3)
        #expect(first.sessions == 2)
        #expect(first.connectedTime == 150)
        #expect(machines[1].connectedTime == 10)
        #expect(machines[2].sessions == 0)
    }
}

// MARK: - List

struct HistoryListTests {
    /// No end: in progress only if that very record is live; an older open record of the same machine
    /// (a killed run) is unknown, never given an end.
    @Test func inProgressVersusCrashed() {
        let crashed = entry(ago: 90_000, connect: 900)
        let live = entry(ago: 30, connect: 800)
        let ended = entry(ago: 500, connect: 700, lasts: 42)
        let rows = SessionHistory.rows([crashed, live, ended], liveRecordIDs: [live.id])
        #expect(rows.map(\.id) == [live.id, ended.id, crashed.id])   // newest first
        #expect(rows.map(\.duration) == [.inProgress, .ended(42), .unknown])
        #expect(HistoryDuration(crashed, liveRecordIDs: []) == .unknown)
    }

    /// A record without an end nor a first frame (stored `cancelled` at insertion) is "connecting" while
    /// its session is open, else "interrupted": never shown, filtered or counted as cancelled.
    @Test func openRecordWithoutFrameIsConnectingOrInterrupted() {
        let connecting = entry(ago: 5, outcome: .cancelled)
        let interrupted = entry(ago: 50_000, outcome: .cancelled)
        let cancelled = entry(ago: 60, lasts: 1, outcome: .cancelled)
        let all = [connecting, interrupted, cancelled]
        let rows = SessionHistory.rows(all, liveRecordIDs: [connecting.id])
        #expect(rows.map(\.outcome) == [.connecting, .cancelled, .interrupted])
        #expect(rows.map(\.duration) == [.inProgress, .ended(1), .unknown])
        #expect(SessionHistory.rows(all, liveRecordIDs: [connecting.id], outcome: .cancelled).map(\.id) == [cancelled.id])
        #expect(SessionHistory.rows(all, liveRecordIDs: [], outcome: .interrupted).count == 2)
        let summary = HistorySummary(all, now: now, liveRecordIDs: [connecting.id])
        #expect(summary.cancelled == 1)
        #expect(summary.interrupted == 1)
        #expect(summary.inProgress == 1)
        #expect(summary.unknownDuration == 1)
        // An open record with a first frame keeps its stored outcome (the duration is what is unknown).
        #expect(HistoryOutcome(entry(ago: 10, connect: 900), liveRecordIDs: []) == .connected)
    }

    @Test func filtersBySearchMachineAndOutcome() {
        let entries = [
            entry(mini, "Mac mini", ago: 10, connect: 100, lasts: 1),
            entry(nas, "NAS Équipe", ago: 20, lasts: 1, outcome: .unreachable),
            entry(nas, "NAS Équipe", ago: 30, connect: 100, lasts: 1),
            entry(studio, "Studio", ago: 40, lasts: 1, outcome: .authFailed),
        ]
        #expect(SessionHistory.rows(entries, liveRecordIDs: [], query: " equipe ").count == 2)   // case, accents
        #expect(SessionHistory.rows(entries, liveRecordIDs: [], machineID: nas).count == 2)
        #expect(SessionHistory.rows(entries, liveRecordIDs: [], outcome: .connected).map(\.machineName)
                == ["Mac mini", "NAS Équipe"])
        #expect(SessionHistory.rows(entries, liveRecordIDs: [], machineID: nas, outcome: .unreachable).count == 1)
        #expect(SessionHistory.rows(entries, liveRecordIDs: [], query: "zzz").isEmpty)
    }

    /// Sort keys: no first frame after every measured one; in progress after ended, unknown last.
    @Test func sortKeys() {
        let live = entry(ago: 5, connect: 300)
        let entries = [entry(ago: 10, connect: 2000, lasts: 5), entry(ago: 20, lasts: 1, outcome: .unreachable),
                       live, entry(ago: 40, connect: 100), entry(ago: 50, connect: 400, lasts: 500)]
        let rows = SessionHistory.rows(entries, liveRecordIDs: [live.id])
        #expect(rows.sorted(using: KeyPathComparator(\.connectSortKey)).map(\.entry.connectMillis)
                == [100, 300, 400, 2000, nil])
        #expect(rows.sorted(using: KeyPathComparator(\.durationSortKey)).map(\.duration)
                == [.ended(1), .ended(5), .ended(500), .inProgress, .unknown])
        #expect(rows.sorted(using: KeyPathComparator(\.startedAt, order: .forward)).first?.startedAt
                == entries[4].startedAt)
    }

    /// The machine filter: one item per id, its newest name (a deleted machine keeps its snapshot).
    @Test func machineFilterUsesNewestName() {
        let entries = [entry(mini, "Old mini", ago: 900), entry(mini, "Mac mini", ago: 100), entry(nas, "NAS", ago: 50)]
        let machines = SessionHistory.machines(entries)
        #expect(machines.map(\.name) == ["Mac mini", "NAS"])
        #expect(machines.map(\.id) == [mini, nas])
    }
}

// MARK: - Menu Bar Extra recents

struct RecentMachinesTests {
    @Test func distinctNewestFirstLimitedAndExisting() {
        let ids = (0..<8).map { _ in UUID() }
        var entries = ids.enumerated().map { entry($0.element, "M\($0.offset)", ago: Double($0.offset + 1) * 100) }
        entries.append(entry(ids[3], "M3", ago: 1))          // M3 used again, most recently
        entries.append(entry(ids[0], "M0", ago: 2))          // a second M0: listed once
        let deleted = UUID()
        entries.append(entry(deleted, "Gone", ago: 0))       // deleted machine: not listed
        let recents = SessionHistory.recentMachineIDs(entries, existing: Set(ids), excluded: [ids[1]], limit: 5)
        #expect(recents == [ids[3], ids[0], ids[2], ids[4], ids[5]])
        #expect(SessionHistory.recentMachineIDs([], existing: Set(ids)).isEmpty)
        #expect(SessionHistory.recentMachineIDs(entries, existing: Set(ids)).count == 5)   // default limit
    }
}

// MARK: - CSV

struct HistoryCSVTests {
    @Test func emptyListIsTheHeaderOnly() {
        #expect(HistoryCSV.make([]) ==
                "machine_name,machine_id,started_at,ended_at,connect_ms,duration_ms,outcome,bytes_received,assistant_tokens\r\n")
    }

    @Test func rowsAreQuotedAndUnformatted() {
        let id = UUID(uuidString: "6B1D3C4E-0000-4000-8000-000000000001")!
        let start = Date(timeIntervalSince1970: 1_793_000_000.25)   // 2026-10-26T07:33:20.250Z
        let rows = [
            HistoryEntry(machineID: id, machineName: "Lab, \"rack 2\"\nnorth", startedAt: start, connectMillis: 1234,
                         endedAt: start.addingTimeInterval(3723.5), outcome: .connected,
                         bytesReceived: 12_345_678, assistantTokens: 6044),
            HistoryEntry(machineID: id, machineName: "Plain", startedAt: start.addingTimeInterval(-60),
                         outcome: .cancelled),   // killed: no end, no duration
        ]
        let lines = HistoryCSV.make(rows).components(separatedBy: "\r\n")
        #expect(lines.count == 4)        // header, two rows, the empty string after the last CRLF
        #expect(lines[3] == "")
        #expect(lines[1] == "Plain,6B1D3C4E-0000-4000-8000-000000000001,2026-10-26T07:32:20.250Z,,,,interrupted,0,0")
        #expect(lines[2] == "\"Lab, \"\"rack 2\"\"\nnorth\",6B1D3C4E-0000-4000-8000-000000000001,"
                + "2026-10-26T07:33:20.250Z,2026-10-26T08:35:23.750Z,1234,3723500,connected,12345678,6044")
    }

    @Test func quotingRules() {
        #expect(HistoryCSV.quoted("plain") == "plain")
        #expect(HistoryCSV.quoted("a,b") == "\"a,b\"")
        #expect(HistoryCSV.quoted("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.quoted("line\rbreak") == "\"line\rbreak\"")
        #expect(HistoryCSV.quoted("two\nlines") == "\"two\nlines\"")
        #expect(HistoryCSV.quoted("") == "")
    }

    /// A live open record exports as `connecting`; an ended cancel keeps `cancelled`.
    @Test func openRecordsExportUnambiguously() {
        let open = entry(ago: 5, outcome: .cancelled)
        let ended = entry(ago: 100, lasts: 1, outcome: .cancelled)
        let lines = HistoryCSV.make([open, ended], liveRecordIDs: [open.id]).components(separatedBy: "\r\n")
        #expect(lines[1].contains(",cancelled,"))
        #expect(lines[2].contains(",connecting,"))
    }

    /// OWASP CSV injection: a name that a spreadsheet would run as a formula gets a leading quote mark.
    @Test func formulaNamesAreNeutralized() {
        for name in ["=HYPERLINK(\"x\")", "+1", "-2+3", "@SUM(A1)", "\tTab", "\rCR"] {
            #expect(HistoryCSV.neutralized(name) == "'" + name)
        }
        #expect(HistoryCSV.neutralized("Mac mini") == "Mac mini")
        #expect(HistoryCSV.neutralized("") == "")
        #expect(HistoryCSV.neutralized("a=b") == "a=b")
        let line = HistoryCSV.make([entry(mini, "=1+2,x", ago: 1, lasts: 1)]).components(separatedBy: "\r\n")[1]
        #expect(line.hasPrefix("\"'=1+2,x\","))
    }

    /// UTC whatever the process time zone.
    @Test func timestampsAreUTC() {
        #expect(HistoryCSV.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }
}

// MARK: - Retention

@MainActor
struct HistoryRetentionTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try RemoteDeckSchema.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    private func record(daysAgo: Double, plus seconds: TimeInterval = 0) -> SessionRecord {
        let record = SessionRecord(machineID: mini, machineName: "Mac mini",
                                   startedAt: now.addingTimeInterval(-daysAgo * 86_400 + seconds), outcome: .connected)
        context.insert(record)
        return record
    }

    private func action(_ session: SessionRecord, daysAgo: Double, plus seconds: TimeInterval = 0) {
        context.insert(AssistantAction(session: session, createdAt: now.addingTimeInterval(-daysAgo * 86_400 + seconds),
                                       kind: .click))
    }

    @Test func purgeKeepsTheBoundary() throws {
        let atCutoff = record(daysAgo: 365)
        let justBefore = record(daysAgo: 365, plus: -1)
        let recent = record(daysAgo: 1)
        action(justBefore, daysAgo: 365)          // goes with its record
        action(recent, daysAgo: 30)               // exactly 30 days: kept
        action(recent, daysAgo: 30, plus: -1)     // older: purged
        action(atCutoff, daysAgo: 31)             // old action of a kept record: purged, the record stays
        try context.save()

        let result = try HistoryRetention.purge(context, now: now, historyDays: 365)
        #expect(result == HistoryRetention.Result(records: 1, actions: 2))
        let records = try context.fetch(FetchDescriptor<SessionRecord>())
        #expect(Set(records.map(\.id)) == [atCutoff.id, recent.id])
        let actions = try context.fetch(FetchDescriptor<AssistantAction>())
        #expect(actions.count == 1)
        #expect(actions.first?.session?.id == recent.id)
        #expect(atCutoff.actions?.isEmpty ?? true)
    }

    /// A failed save rolls the deletes back, so the next save (a session record) does not replay them.
    @Test func failedSaveRollsBack() throws {
        _ = record(daysAgo: 400)
        _ = record(daysAgo: 1)
        try context.save()
        struct SaveFailed: Error {}
        #expect(throws: SaveFailed.self) {
            try HistoryRetention.purge(context, now: now, historyDays: 365, save: { _ in throw SaveFailed() })
        }
        #expect(!context.hasChanges)
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<SessionRecord>()) == 2)
    }

    @Test func purgeFollowsTheSettingAndNeverWipesAll() throws {
        _ = record(daysAgo: 10)
        _ = record(daysAgo: 0.5)
        try context.save()
        #expect(try HistoryRetention.purge(context, now: now, historyDays: 7).records == 1)
        #expect(try HistoryRetention.purge(context, now: now, historyDays: 0).records == 0)   // read as 1 day
        #expect(try context.fetchCount(FetchDescriptor<SessionRecord>()) == 1)
    }
}
