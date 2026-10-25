import AppKit
import SwiftUI

enum HelpWindow {
    static let helpID = "help"
    static let whatsNewID = "whats-new"

    static func id(for page: HelpPage) -> String {
        page == .help ? helpID : whatsNewID
    }
}

/// Help › RemoteDeck Help (⌘?) and What's New… (AppFlow › Help and What's New).
struct HelpCommands: Commands {
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(settings.t("menu_help")) { openWindow(id: HelpWindow.helpID) }
                .keyboardShortcut("?", modifiers: .command)
            Button(settings.t("menu_whats_new")) { openWindow(id: HelpWindow.whatsNewID) }
        }
    }
}

/// The Help or What's New window: the page from GitHub, rendered natively block by block (no web view,
/// no HTML, no image loaded), with Reload and "View on GitHub" at the bottom.
struct HelpWindowView: View {
    let model: HelpModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(settings.t("help_reload")) { Task { await model.load() } }
                    .disabled(model.isLoading)
                Spacer()
                Button(settings.t("help_open_github")) { NSWorkspace.shared.open(model.page.webURL) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(minWidth: 560, minHeight: 440)
        .task { await model.loadIfNeeded() }
        // Second layer (the model already dropped other links): http(s) to the browser, nothing else.
        .environment(\.openURL, OpenURLAction { url in
            HelpLinkPolicy.allows(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView(settings.t(model.page == .help ? "help_loading" : "whats_new_loading"))
        case .empty:
            ContentUnavailableView(settings.t("whats_new_empty"), systemImage: "shippingbox",
                                   description: Text(settings.t("whats_new_empty_desc")))
        case .failed(let failure):
            ContentUnavailableView {
                Label(settings.t(model.page == .help ? "help_failed_title" : "whats_new_failed_title"),
                      systemImage: failure == .offline ? "wifi.slash" : "exclamationmark.triangle")
            } description: {
                Text(message(for: failure))
            } actions: {
                if failure != .disabled {
                    Button(settings.t("help_retry")) { Task { await model.load() } }
                }
            }
        case .loaded(.document(let page)):
            ScrollView {
                HelpBlocksView(blocks: page.blocks)
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        case .loaded(.releases(let entries)):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        releaseView(entry)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func releaseView(_ entry: ReleaseEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title).font(.title2.bold())
                if entry.isPrerelease {
                    Text(settings.t("whats_new_prerelease"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }
            if let date = entry.date {
                Text(date).font(.callout).foregroundStyle(.secondary)
            }
            if entry.notes.blocks.isEmpty {
                Text(settings.t("whats_new_no_notes")).foregroundStyle(.secondary).italic()
            } else {
                HelpBlocksView(blocks: entry.notes.blocks)
            }
            Divider()
        }
    }

    private func message(for failure: HelpFailure) -> String {
        switch failure {
        case .offline: settings.t("help_offline")
        case .notPublished: settings.t("help_not_published")
        case .rateLimited: settings.t("help_rate_limited")
        case .http(let status): settings.t("help_http", status)
        case .network(let code): settings.t("help_network", code)
        case .invalidResponse: settings.t("help_invalid")
        case .tooLarge: settings.t("help_too_large")
        case .disabled: settings.t("help_disabled")
        }
    }
}

/// The blocks of one page, each as native text, already parsed by the model (`HelpRendered`): the
/// view never parses Markdown in `body`, and only the visible blocks are laid out.
struct HelpBlocksView: View {
    let blocks: [HelpRenderedBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                view(for: blocks[index])
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: HelpRenderedBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.marker(items[index].marker))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(items[index].text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(items[index].depth) * 18)
                }
            }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                Text(text).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let header {
                    GridRow {
                        ForEach(header.indices, id: \.self) { index in
                            Text(header[index]).bold()
                        }
                    }
                    Divider()
                }
                ForEach(rows.indices, id: \.self) { row in
                    GridRow(alignment: .firstTextBaseline) {
                        ForEach(rows[row].indices, id: \.self) { column in
                            Text(rows[row][column])
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title2.bold()
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }

    static func marker(_ marker: HelpListItem.Marker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let n): "\(n)."
        case .task(let done): done ? "☑︎" : "☐"
        }
    }
}
