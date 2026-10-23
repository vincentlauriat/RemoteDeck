import SwiftUI
import SwiftData
import RemoteDeckCore

enum HistoryWindow {
    static let id = "history"
}

extension HistoryOutcome {
    var titleKey: String { "outcome_\(rawValue)" }
    var isFailure: Bool { self == .authFailed || self == .unreachable || self == .dropped || self == .interrupted }
}

/// Session History View (AppFlow › Session History View, DesignBrief): the 30-day summary strip above
/// a sortable table of every attempt, with search, machine and outcome filters, Reconnect on
/// double-click and Export….
struct SessionHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SessionRecord.startedAt, order: .reverse) private var records: [SessionRecord]
    @Query private var machines: [Machine]
    @Bindable var model: SessionHistoryModel
    @State private var showsMachines = false

    private var entries: [HistoryEntry] { records.map(HistoryEntry.init) }
    /// The app's language, which may differ from the system's.
    private var locale: Locale { Locale(identifier: settings.localeIdentifier) }

    var body: some View {
        let entries = self.entries
        let live = sessions.liveRecordIDs
        let rows = model.rows(entries, liveRecordIDs: live)
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView(settings.t("history_empty"), systemImage: "clock.arrow.circlepath")
            } else {
                summaryStrip(model.summary(entries, liveRecordIDs: live))
                Divider()
                table(rows)
                    .overlay {
                        if rows.isEmpty {
                            ContentUnavailableView(settings.t("no_results_title"), systemImage: "magnifyingglass")
                        }
                    }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: settings.t("history_search"))
        .toolbar { toolbar(entries) }
        .navigationTitle(settings.t("history_title"))
        .frame(minWidth: 760, minHeight: 420)
        .alert(settings.t(model.reconnectFailure == .cannotConnect ? "history_cannot_connect" : "history_machine_deleted"),
               isPresented: Binding(get: { model.reconnectFailure != nil },
                                    set: { if !$0 { model.reconnectFailure = nil } })) {
            Button(settings.t("ok")) { model.reconnectFailure = nil }
        } message: {
            Text(settings.t(model.reconnectFailure == .cannotConnect ? "history_cannot_connect_desc"
                                                                     : "history_machine_deleted_desc"))
        }
        .alert(settings.t("error_title"), isPresented: Binding(
            get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })) {
            Button(settings.t("ok")) { model.exportError = nil }
        } message: {
            Text(settings.t("history_export_failed", model.exportError ?? ""))
        }
    }

    // MARK: Table

    private func table(_ rows: [HistoryRow]) -> some View {
        Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(settings.t("history_col_machine"), value: \.machineName) { row in
                Text(row.machineName)
            }
            .width(min: 120, ideal: 180)
            TableColumn(settings.t("history_col_started"), value: \.startedAt) { row in
                Text(row.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)))
            }
            .width(min: 140, ideal: 170)
            TableColumn(settings.t("history_col_connect"), value: \.connectSortKey) { row in
                Text(row.entry.connectMillis.map(String.init) ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 130)
            TableColumn(settings.t("history_col_duration"), value: \.durationSortKey) { row in
                durationCell(row.duration)
            }
            .width(min: 80, ideal: 100)
            TableColumn(settings.t("history_col_outcome"), value: \.outcomeKey) { row in
                Text(settings.t(row.outcome.titleKey))
                    .foregroundStyle(row.outcome.isFailure ? Color.red : Color.primary)
            }
            .width(min: 110, ideal: 150)
            TableColumn(settings.t("history_col_bytes"), value: \.bytesReceived) { row in
                Text(row.bytesReceived > 0 ? row.bytesReceived.formatted(.byteCount(style: .file).locale(locale)) : "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn(settings.t("history_col_tokens"), value: \.assistantTokens) { row in
                Text(row.assistantTokens > 0 ? row.assistantTokens.formatted(.number.locale(locale)) : "")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let row = rows.first(where: { ids.count == 1 && ids.contains($0.id) }) {
                Button(settings.t("history_reconnect")) { reconnect(row) }
            }
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.count == 1 && ids.contains($0.id) }) { reconnect(row) }
        }
    }

    @ViewBuilder
    private func durationCell(_ duration: HistoryDuration) -> some View {
        switch duration {
        case .ended(let seconds):
            Text(Self.format(seconds)).monospacedDigit()
        case .inProgress:
            Text(settings.t("history_in_progress")).foregroundStyle(.green)
        case .unknown:
            Text(settings.t("history_unknown"))
                .foregroundStyle(.secondary)
                .help(settings.t("history_unknown_help"))
        }
    }

    /// `1:02:03`, or `0:42` under an hour.
    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// Totals: `8 h 5 min` (minutes are enough over 30 days).
    private func total(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
    }

    private func reconnect(_ row: HistoryRow) {
        model.reconnect(row, machines: machines, sessions: sessions) { id in
            openWindow(id: SessionWindow.id, value: id)
        }
    }

    // MARK: Summary

    private func summaryStrip(_ summary: HistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(settings.t("summary_title")).font(.system(size: 13, weight: .semibold))
                metric(settings.t("summary_sessions"), "\(summary.sessions)",
                       help: settings.t("summary_sessions_help", summary.attempts))
                metric(settings.t("summary_fast"), summary.fastShare.map { HistorySummary.displayShare($0).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)) } ?? "—",
                       help: settings.t("summary_fast_help"),
                       warn: (summary.fastShare ?? 1) < 0.9)
                metric(settings.t("summary_p50"), summary.p50Millis.map { "\($0) ms" } ?? "—")
                metric(settings.t("summary_p90"), summary.p90Millis.map { "\($0) ms" } ?? "—")
                metric(settings.t("summary_connected_time"), total(summary.connectedTime))
                Spacer()
                Button(settings.t("summary_by_machine")) { showsMachines.toggle() }
                    .disabled(summary.machines.isEmpty)
                    .popover(isPresented: $showsMachines, arrowEdge: .bottom) { machineBreakdown(summary) }
            }
            HStack(spacing: 16) {
                Text(failures(summary))
                if summary.inProgress > 0 { Text(settings.t("summary_in_progress", summary.inProgress)) }
                if summary.unknownDuration > 0 { Text(settings.t("summary_unknown", summary.unknownDuration)) }
                Spacer()
                Text(settings.t("summary_ard_note"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metric(_ title: String, _ value: String, help: String? = nil, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
    }

    private func failures(_ summary: HistorySummary) -> String {
        let parts = [(HistoryOutcome.authFailed, summary.authFailed), (.unreachable, summary.unreachable),
                     (.dropped, summary.dropped), (.interrupted, summary.interrupted), (.cancelled, summary.cancelled)]
            .map { "\(settings.t($0.0.titleKey)) \($0.1)" }
        return parts.joined(separator: " · ")
    }

    private func machineBreakdown(_ summary: HistorySummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text(settings.t("history_col_machine"))
                Text(settings.t("summary_sessions"))
                Text(settings.t("summary_attempts"))
                Text(settings.t("summary_connected_time"))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(summary.machines) { machine in
                GridRow {
                    Text(machine.name)
                    Text("\(machine.sessions)").monospacedDigit().gridColumnAlignment(.trailing)
                    Text("\(machine.attempts)").monospacedDigit().gridColumnAlignment(.trailing)
                    Text(total(machine.connectedTime)).monospacedDigit().gridColumnAlignment(.trailing)
                }
            }
        }
        .padding(16)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ entries: [HistoryEntry]) -> some ToolbarContent {
        ToolbarItemGroup {
            Picker(settings.t("history_filter_machine"), selection: $model.machineFilter) {
                Text(settings.t("history_all_machines")).tag(UUID?.none)
                ForEach(SessionHistory.machines(entries), id: \.id) { machine in
                    Text(machine.name).tag(UUID?.some(machine.id))
                }
            }
            .help(settings.t("history_filter_machine"))
            Picker(settings.t("history_filter_outcome"), selection: $model.outcomeFilter) {
                Text(settings.t("history_all_outcomes")).tag(HistoryOutcome?.none)
                ForEach(HistoryOutcome.allCases, id: \.self) { outcome in
                    Text(settings.t(outcome.titleKey)).tag(HistoryOutcome?.some(outcome))
                }
            }
            .help(settings.t("history_filter_outcome"))
            Button {
                Task { await model.export(entries, liveRecordIDs: sessions.liveRecordIDs) }
            } label: {
                Label(settings.t("history_export"), systemImage: "square.and.arrow.up")
            }
            .disabled(entries.isEmpty || model.isExporting)
            .help(settings.t("history_export"))
        }
    }
}
