import Foundation
import SwiftData

// Session History (T4.6, AppFlow › Session History View): pure computations over value snapshots of
// SessionRecord, so the summary, the list, the CSV export and the Menu Bar Extra recents are tested
// without a SwiftData context.

/// A value snapshot of one SessionRecord.
public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var machineID: UUID
    public var machineName: String
    public var startedAt: Date
    public var connectMillis: Int?
    public var endedAt: Date?
    public var outcome: SessionOutcome
    public var bytesReceived: Int64
    public var assistantTokens: Int

    public init(id: UUID = UUID(), machineID: UUID, machineName: String, startedAt: Date,
                connectMillis: Int? = nil, endedAt: Date? = nil, outcome: SessionOutcome,
                bytesReceived: Int64 = 0, assistantTokens: Int = 0) {
        self.id = id
        self.machineID = machineID
        self.machineName = machineName
        self.startedAt = startedAt
        self.connectMillis = connectMillis
        self.endedAt = endedAt
        self.outcome = outcome
        self.bytesReceived = bytesReceived
        self.assistantTokens = assistantTokens
    }

    public init(_ record: SessionRecord) {
        self.init(id: record.id, machineID: record.machineID, machineName: record.machineName,
                  startedAt: record.startedAt, connectMillis: record.connectMillis, endedAt: record.endedAt,
                  outcome: record.outcomeValue, bytesReceived: record.bytesReceived,
                  assistantTokens: record.assistantTokens)
    }

    /// `endedAt − startedAt` (BackendSchema › SessionRecord), `nil` while the record has no end.
    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// The first frame came (`connected`, or `dropped` after it).
    public var reachedFirstFrame: Bool { connectMillis != nil }
}

/// What the Outcome column shows and filters on. A record without an end and without a first frame
/// still holds the `cancelled` it was created with (SessionModel inserts it so): it is presented as
/// `connecting` while its session is open, else `interrupted` (the run was killed while connecting),
/// never as a cancellation. Every other record shows its stored outcome.
public enum HistoryOutcome: String, CaseIterable, Sendable {
    case connected, authFailed, unreachable, cancelled, dropped, connecting, interrupted

    public init(_ entry: HistoryEntry, liveRecordIDs: Set<UUID>) {
        if entry.endedAt == nil && entry.connectMillis == nil {
            self = liveRecordIDs.contains(entry.id) ? .connecting : .interrupted
        } else {
            self = HistoryOutcome(rawValue: entry.outcome.rawValue) ?? .cancelled
        }
    }
}

/// What the Duration column shows.
public enum HistoryDuration: Sendable, Equatable {
    case ended(TimeInterval)
    /// No end yet, and the session is open in this run.
    case inProgress
    /// No end and no live session: the run was killed or crashed. The end is never guessed.
    case unknown

    /// `liveRecordIDs`: the records of the sessions open right now (connecting or connected).
    public init(_ entry: HistoryEntry, liveRecordIDs: Set<UUID>) {
        if let duration = entry.duration {
            self = .ended(duration)
        } else {
            self = liveRecordIDs.contains(entry.id) ? .inProgress : .unknown
        }
    }
}

/// One row of the Session History table, with non-optional sort keys for `KeyPathComparator`.
public struct HistoryRow: Sendable, Equatable, Identifiable {
    public let entry: HistoryEntry
    public let duration: HistoryDuration
    public let outcome: HistoryOutcome

    public init(_ entry: HistoryEntry, liveRecordIDs: Set<UUID>) {
        self.entry = entry
        duration = HistoryDuration(entry, liveRecordIDs: liveRecordIDs)
        outcome = HistoryOutcome(entry, liveRecordIDs: liveRecordIDs)
    }

    public var id: UUID { entry.id }
    public var machineName: String { entry.machineName }
    public var startedAt: Date { entry.startedAt }
    public var outcomeKey: String { outcome.rawValue }
    public var bytesReceived: Int64 { entry.bytesReceived }
    public var assistantTokens: Int { entry.assistantTokens }
    /// No first frame sorts after every measured one.
    public var connectSortKey: Int { entry.connectMillis ?? .max }
    /// In progress after every ended row, unknown last.
    public var durationSortKey: Double {
        switch duration {
        case .ended(let seconds): seconds
        case .inProgress: .greatestFiniteMagnitude / 2
        case .unknown: .greatestFiniteMagnitude
        }
    }
}

public enum SessionHistory {
    /// Rows newest first, filtered by machine (`machineID`), outcome and a search on the machine name
    /// (case- and diacritic-insensitive, as the Library's search).
    public static func rows(_ entries: [HistoryEntry], liveRecordIDs: Set<UUID>, query: String = "",
                            machineID: UUID? = nil, outcome: HistoryOutcome? = nil) -> [HistoryRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries
            .filter { entry in
                (machineID == nil || entry.machineID == machineID)
                    && (query.isEmpty || entry.machineName.range(
                        of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            }
            .sorted { $0.startedAt > $1.startedAt }
            .map { HistoryRow($0, liveRecordIDs: liveRecordIDs) }
            .filter { outcome == nil || $0.outcome == outcome }
    }

    /// The machines of the machine filter: one per `machineID`, with its newest name snapshot (a
    /// renamed or deleted machine keeps one entry), sorted by that name.
    public static func machines(_ entries: [HistoryEntry]) -> [(id: UUID, name: String)] {
        var newest: [UUID: HistoryEntry] = [:]
        for entry in entries where (newest[entry.machineID]?.startedAt ?? .distantPast) <= entry.startedAt {
            newest[entry.machineID] = entry
        }
        return newest.values
            .map { (id: $0.machineID, name: $0.machineName) }
            .sorted { byName($0.name, $0.id, $1.name, $1.id) }
    }

    /// Menu Bar Extra recents: distinct machines, most recent attempt first, only machines that still
    /// exist and are not in `excluded` (the favorites, listed above them), at most `limit`.
    public static func recentMachineIDs(_ entries: [HistoryEntry], existing: Set<UUID>,
                                        excluded: Set<UUID> = [], limit: Int = 5) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for entry in entries.sorted(by: { $0.startedAt > $1.startedAt }) where result.count < limit {
            let id = entry.machineID
            guard existing.contains(id), !excluded.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}

/// Finder order on the name, then the id, so equal names keep a stable order.
func byName(_ lhs: String, _ lhsID: UUID, _ rhs: String, _ rhsID: UUID) -> Bool {
    let order = lhs.localizedStandardCompare(rhs)
    return order == .orderedSame ? lhsID.uuidString < rhsID.uuidString : order == .orderedAscending
}

// MARK: - 30-day summary

/// The Session History summary (PRD › Success metric, AppFlow › Session History View).
///
/// Window: records whose `startedAt` is in `[now − 30 × 86 400 s, now]`, an absolute interval (no
/// calendar days, so time zones and DST change nothing). Inside it:
/// - **sessions**: attempts that reached a first frame (`connectMillis` set: `connected`, or `dropped`
///   after it), including one whose run was killed later (its duration is unknown);
/// - **slow failures**: attempts that ended without a first frame more than 5 s after they started
///   (`endedAt − startedAt > 5000 ms`: an unreachable host or timeout, a cancel or a drop after a long
///   wait); the user waited longer than the target, so they count as slow;
/// - **fast share**: sessions with `connectMillis ≤ 5000`, over sessions + slow failures (`nil` when
///   both are 0). Attempts that ended without a first frame within 5 s (refused, authentication failed,
///   a quick cancel; exactly 5000 ms included) and records without an end (in progress, interrupted)
///   are not in it;
/// - **p50 / p90**: nearest-rank percentiles of the sessions' `connectMillis`;
/// - **connected time**: the sum of `endedAt − startedAt` over sessions with an end (in progress and
///   unknown ones are counted, not added);
/// - **failures**: attempts per outcome `authFailed`, `unreachable`, `dropped`; `cancelled` apart (the
///   user's choice, not a failure); `interrupted` (no end, no first frame, no open session) apart too.
///   Outcomes are the presented ones (`HistoryOutcome`), as in the table.
public struct HistorySummary: Sendable, Equatable {
    public static let window: TimeInterval = 30 * 86_400
    public static let fastThresholdMillis = 5_000

    public struct Machine: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// Newest name snapshot in the window.
        public let name: String
        public let attempts: Int
        public let sessions: Int
        public let connectedTime: TimeInterval
    }

    public let attempts: Int
    public let sessions: Int
    public let fastSessions: Int
    public let slowFailures: Int
    public let p50Millis: Int?
    public let p90Millis: Int?
    public let connectedTime: TimeInterval
    /// Records without an end, as the Duration column: open now (connecting or connected), or left by
    /// a killed run (unknown; `interrupted` are those of them that had no first frame).
    public let inProgress: Int
    public let unknownDuration: Int
    public let interrupted: Int
    public let authFailed: Int
    public let unreachable: Int
    public let dropped: Int
    public let cancelled: Int
    /// Most sessions first, then by name.
    public let machines: [Machine]

    /// `fastSessions / (sessions + slowFailures)`, `nil` when both are 0.
    public var fastShare: Double? {
        let measured = sessions + slowFailures
        return measured == 0 ? nil : Double(fastSessions) / Double(measured)
    }

    /// The share for display, floored to 0.1 %: 89.96 % reads 89.9 %, never a rounded-up 90 %.
    public static func displayShare(_ share: Double) -> Double {
        (share * 1000).rounded(.down) / 1000
    }

    public init(_ entries: [HistoryEntry], now: Date, liveRecordIDs: Set<UUID> = []) {
        let start = now.addingTimeInterval(-Self.window)
        let inWindow = entries.filter { $0.startedAt >= start && $0.startedAt <= now }
        let sessions = inWindow.filter(\.reachedFirstFrame)
        let millis = sessions.compactMap(\.connectMillis).sorted()
        attempts = inWindow.count
        self.sessions = sessions.count
        fastSessions = millis.filter { $0 <= Self.fastThresholdMillis }.count
        slowFailures = inWindow.filter { entry in
            guard !entry.reachedFirstFrame, let duration = entry.duration else { return false }
            return duration * 1000 > Double(Self.fastThresholdMillis)
        }.count
        p50Millis = Self.percentile(0.5, of: millis)
        p90Millis = Self.percentile(0.9, of: millis)
        connectedTime = sessions.compactMap(\.duration).reduce(0, +)
        let open = inWindow.filter { $0.endedAt == nil }
        inProgress = open.filter { liveRecordIDs.contains($0.id) }.count
        unknownDuration = open.count - inProgress
        let outcomes = inWindow.map { HistoryOutcome($0, liveRecordIDs: liveRecordIDs) }
        func count(_ outcome: HistoryOutcome) -> Int { outcomes.filter { $0 == outcome }.count }
        interrupted = count(.interrupted)
        authFailed = count(.authFailed)
        unreachable = count(.unreachable)
        dropped = count(.dropped)
        cancelled = count(.cancelled)
        machines = Dictionary(grouping: inWindow, by: \.machineID)
            .map { id, entries in
                let newest = entries.max { $0.startedAt < $1.startedAt }
                let sessions = entries.filter(\.reachedFirstFrame)
                return Machine(id: id, name: newest?.machineName ?? "", attempts: entries.count,
                               sessions: sessions.count, connectedTime: sessions.compactMap(\.duration).reduce(0, +))
            }
            .sorted { lhs, rhs in
                lhs.sessions != rhs.sessions ? lhs.sessions > rhs.sessions : byName(lhs.name, lhs.id, rhs.name, rhs.id)
            }
    }

    /// Nearest rank: the smallest value with at least `q` of the values at or below it.
    static func percentile(_ q: Double, of sorted: [Int]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

// MARK: - CSV export

/// Session History as CSV (RFC 4180): a header row, CRLF line ends, a field quoted when it holds a
/// comma, a quote, CR or LF (quotes doubled). Dates in ISO 8601 UTC, numbers unformatted, an empty
/// field when there is no value (no first frame, no end). The outcome is the stored one, except for a
/// record without an end nor a first frame: `connecting` (its session is open) or `interrupted`
/// (`HistoryOutcome`), never its placeholder `cancelled`. The machine name, which may come from a
/// Bonjour service name, is escaped against spreadsheet formulas (OWASP: a leading `'` before `=`, `+`,
/// `-`, `@`, tab or CR). The machine's host is not exported (SessionRecord does not hold it;
/// BackendSchema › Retention and deletion).
public enum HistoryCSV {
    public static let header = [
        "machine_name", "machine_id", "started_at", "ended_at", "connect_ms", "duration_ms",
        "outcome", "bytes_received", "assistant_tokens",
    ]

    /// Oldest first, as a log reads.
    public static func make(_ entries: [HistoryEntry], liveRecordIDs: Set<UUID> = []) -> String {
        var lines = [header.joined(separator: ",")]
        for entry in entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            let fields = [
                neutralized(entry.machineName),
                entry.machineID.uuidString,
                timestamp(entry.startedAt),
                entry.endedAt.map(timestamp) ?? "",
                entry.connectMillis.map(String.init) ?? "",
                entry.duration.map { String(Int(($0 * 1000).rounded())) } ?? "",
                HistoryOutcome(entry, liveRecordIDs: liveRecordIDs).rawValue,
                String(entry.bytesReceived),
                String(entry.assistantTokens),
            ]
            lines.append(fields.map(quoted).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// `2026-10-23T08:15:30.250Z`: UTC, milliseconds.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    /// A text field a spreadsheet would read as a formula gets a leading `'`.
    static func neutralized(_ field: String) -> String {
        guard let first = field.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) else { return field }
        return "'" + field
    }

    static func quoted(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Retention

/// BackendSchema › Retention and deletion: SessionRecord older than `historyRetentionDays` and
/// AssistantAction older than 30 days are deleted at launch. A record (or action) exactly at the
/// cutoff is kept. Deleting a SessionRecord also deletes its actions (`.cascade`); records are
/// fetched and deleted one by one so the cascade rule applies.
public enum HistoryRetention {
    public static let assistantActionDays = 30
    public static let day: TimeInterval = 86_400

    /// Rows deleted: records past the history cutoff, then actions past theirs (not counting the
    /// actions that went with their record).
    public struct Result: Sendable, Equatable {
        public let records: Int
        public let actions: Int
    }

    /// `historyDays` below 1 (a broken setting) is read as 1: the history is never wiped whole.
    @MainActor
    @discardableResult
    /// On a failed save the context is rolled back before the error is rethrown, so the pending deletes
    /// do not ride along with the next save of a session record. `save` is injectable for tests.
    public static func purge(_ context: ModelContext, now: Date, historyDays: Int,
                             actionDays: Int = assistantActionDays,
                             save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Result {
        do {
            return try purgeRecordsAndActions(context, now: now, historyDays: historyDays,
                                              actionDays: actionDays, save: save)
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    private static func purgeRecordsAndActions(_ context: ModelContext, now: Date, historyDays: Int,
                                               actionDays: Int, save: (ModelContext) throws -> Void) throws -> Result {
        let recordCutoff = now.addingTimeInterval(-Double(max(historyDays, 1)) * day)
        let actionCutoff = now.addingTimeInterval(-Double(max(actionDays, 1)) * day)
        let records = try context.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.startedAt < recordCutoff }))
        records.forEach(context.delete)
        try save(context)   // the cascade runs here, before the actions are fetched
        let actions = try context.fetch(FetchDescriptor<AssistantAction>(
            predicate: #Predicate { $0.createdAt < actionCutoff }))
        actions.forEach(context.delete)
        try save(context)
        return Result(records: records.count, actions: actions.count)
    }
}
