import ClaudeKit
import RFBKit
import SwiftUI

/// UI copy of the Claude Assistant: the models expose reasons, the views word them.
enum AssistantCopy {
    static func message(_ failure: AssistantFailure, _ t: (String) -> String) -> String {
        func with(_ key: String, _ value: String) -> String { t(key).replacingOccurrences(of: "%@", with: value) }
        switch failure {
        case .noAPIKey: return t("assistant_no_key")
        case .disconnected: return t("assistant_disconnected")
        case .api(let error):
            switch error {
            case .authentication: return t("assistant_error_auth")
            case .billing: return t("assistant_error_billing")
            case .permission: return t("assistant_error_permission")
            case .notFound: return t("assistant_error_not_found")
            case .requestTooLarge: return t("assistant_error_too_large")
            case .rateLimited: return t("assistant_error_rate_limited")
            case .overloaded: return t("assistant_error_overloaded")
            case .server(let status): return with("assistant_error_server", String(status))
            case .network(let reason): return with("assistant_error_network", reason)
            case .invalidRequest(let message): return with("assistant_error_invalid", message)
            case .unexpectedResponse: return t("assistant_error_unexpected")
            case .http(let status, _): return with("assistant_error_http", String(status))
            case .cancelled: return t("assistant_stopped")
            }
        }
    }

    static func point(_ location: PointerLocation) -> String { "(\(location.x), \(location.y))" }

    /// DesignBrief: "Click at (412, 230)" — remote pixels.
    static func describe(_ item: AssistantModel.ActionItem, _ t: (String) -> String) -> String {
        func with(_ key: String, _ value: String) -> String { t(key).replacingOccurrences(of: "%@", with: value) }
        func at(_ index: Int) -> String { item.targets.indices.contains(index) ? point(item.targets[index]) : t("action_at_cursor") }
        func modifiers(_ text: String) -> String { text.isEmpty ? "" : " " + with("action_with", text) }
        guard let action = item.action else { return item.name }
        switch action {
        case .screenshot: return t("action_screenshot")
        case .zoom: return t("action_zoom")
        case .cursorPosition: return t("action_cursor")
        case .click(let button, let count, _, let held):
            let key = switch (button, count) {
            case (.right, _): "action_right_click"
            case (.middle, _): "action_middle_click"
            case (_, 2): "action_double_click"
            case (_, 3...): "action_triple_click"
            default: "action_click"
            }
            return with(key, at(0)) + modifiers(held)
        case .drag(_, _, let held):
            return with("action_drag", "\(at(0)) → \(at(1))") + modifiers(held)
        case .mouseMove:
            return with("action_move", at(0))
        case .scroll(let direction, let amount, _, let held):
            let words = t("scroll_\(direction.rawValue)") + " ×\(amount) " + at(0)
            return with("action_scroll", words) + modifiers(held)
        case .type(let text):
            // T5.3 M2: never truncated. A long or multi-line text is in the block under the row
            // (`TypedTextBlock`); a short one is shown whole here, invisible scalars made visible.
            if AssistantModel.typeTextNeedsReveal(text) {
                return t("action_type_long").replacingOccurrences(of: "%d", with: String(text.unicodeScalars.count))
            }
            return with("action_type", DisplayText.revealingInvisibles(text))
        case .key(let text, let count):
            // Claude-controlled: escaped and bounded like a server string (T5.3).
            let keys = DisplayText.serverString(text)
            return with("action_key", count > 1 ? "\(keys) ×\(count)" : keys)
        case .holdKey(let text, let seconds):
            return with("action_hold_key", "\(DisplayText.serverString(text)) (\(seconds.formatted()) s)")
        case .wait(let seconds):
            return with("action_wait", seconds.formatted())
        }
    }

    static func symbol(_ item: AssistantModel.ActionItem) -> String {
        switch item.action {
        case .screenshot?, .zoom?: "camera.viewfinder"
        case .click?, .drag?, .mouseMove?, .cursorPosition?: "cursorarrow.click"
        case .scroll?: "scroll"
        case .type?, .key?, .holdKey?: "keyboard"
        case .wait?: "hourglass"
        case nil: "questionmark.circle"
        }
    }
}

/// Claude Assistant Panel (AppFlow › Claude Assistant Panel, DesignBrief): an inspector beside the
/// remote screen. Token counter top-right, transcript (prompts, progress notes, answers, actions with
/// Confirm/Skip), prompt field at the bottom. Typing in the field takes the keyboard from the remote
/// (the framebuffer view resigns first responder), so the panel's keys never reach the remote.
struct AssistantPanelView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: AssistantModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.hasAPIKey {
                transcript
                Divider()
                promptArea
            } else {
                noKey
            }
        }
        .onAppear { promptFocused = model.hasAPIKey }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(settings.t("assistant_title"), systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.purple)
            Spacer()
            Text(settings.t("assistant_tokens", model.usage.total.formatted()))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(settings.t("assistant_tokens_help") + "\n" + usageDetail)
            Button { model.clear() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase.isBusy || model.entries.isEmpty)
            .help(settings.t("assistant_clear"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var usageDetail: String {
        let usage = model.usage
        return [("usage_input", usage.inputTokens), ("usage_cache_read", usage.cacheReadInputTokens),
                ("usage_cache_write", usage.cacheCreationInputTokens), ("usage_output", usage.outputTokens)]
            .map { "\(settings.t($0.0)) \($0.1.formatted())" }
            .joined(separator: " · ")
    }

    /// AppFlow › Empty and blocked states: "No Anthropic API key".
    private var noKey: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key").font(.largeTitle).foregroundStyle(.secondary)
            Text(settings.t("assistant_no_key"))
                .multilineTextAlignment(.center)
            Button(settings.t("assistant_open_settings")) { openSettings() }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.entries.isEmpty {
                        Text(settings.t("assistant_empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    phaseRow.id("phase")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.entries) { proxy.scrollTo("phase", anchor: .bottom) }
            .onChange(of: model.phase) { proxy.scrollTo("phase", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ entry: AssistantModel.Entry) -> some View {
        switch entry.content {
        case .prompt(let text):
            Text(text)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
                .padding(.top, 4)
        case .progress(let text):
            Label(text, systemImage: "ellipsis.bubble")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .answer(let text):
            Text(text)
                .textSelection(.enabled)
        case .action(let item):
            actionRow(item)
        }
    }

    private func actionRow(_ item: AssistantModel.ActionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: AssistantCopy.symbol(item))
                    .foregroundStyle(item.status == .awaiting ? Color.purple : .secondary)
                Text(AssistantCopy.describe(item, settings.t))
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                statusBadge(item.status)
            }
            if case .type(let text)? = item.action {
                if AssistantModel.typeTextNeedsReveal(text) {
                    TypedTextBlock(text: text, item: item, model: model)
                }
                if DisplayText.hasHiddenScalars(text) {
                    Label(settings.t("action_type_invisible"), systemImage: "eye.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if item.status == .awaiting {
                if model.awaitingID == item.toolUseID, model.awaitingNeedsReveal, !model.awaitingRevealed {
                    Text(settings.t("action_type_reveal_first")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(settings.t("assistant_confirm")) {
                        model.confirm(item.toolUseID, isKeyRepeat: Self.currentEventIsKeyRepeat)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!model.confirmArmed || model.awaitingID != item.toolUseID)
                    Button(settings.t("assistant_skip")) { model.skip(item.toolUseID) }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(item.status == .awaiting ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.08)))
    }

    /// A held ⌘Return repeats: only its first key-down may confirm. (`isARepeat` may only be read on
    /// key events.)
    private static var currentEventIsKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    @ViewBuilder
    private func statusBadge(_ status: AssistantModel.ActionItem.Status) -> some View {
        switch status {
        case .queued, .awaiting:
            EmptyView()
        case .running:
            ProgressView().controlSize(.mini)
        case .done, .automatic:
            Image(systemName: "checkmark").foregroundStyle(.green).help(settings.t("action_status_done"))
        case .skipped:
            Text(settings.t("action_status_skipped")).font(.caption).foregroundStyle(.secondary)
        case .notExecuted:
            Text(settings.t("action_status_not_executed")).font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text(settings.t("action_status_cancelled")).font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Text(settings.t("action_status_failed")).font(.caption).foregroundStyle(.red).help(reason)
        }
    }

    @ViewBuilder
    private var phaseRow: some View {
        switch model.phase {
        case .idle, .done:
            EmptyView()
        case .sending:
            activity("assistant_looking")
        case .confirming:
            activity("assistant_waiting")
        case .running:
            activity("assistant_running")
        case .stopping:
            activity("assistant_stopping")
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                Label(settings.t("assistant_paused", AssistantModel.maxStepsWithoutAction), systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    Button(settings.t("assistant_continue")) { model.continueAfterPause() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    Button(settings.t("assistant_stop"), role: .cancel) { model.stop() }
                }
                .controlSize(.small)
            }
        case .stopped:
            Text(settings.t("assistant_stopped")).font(.callout).foregroundStyle(.secondary)
        case .cutOff:
            Text(settings.t("assistant_cut_off")).font(.callout).foregroundStyle(.orange)
        case .refused(_, let explanation):
            VStack(alignment: .leading, spacing: 4) {
                Label(settings.t("assistant_refused"), systemImage: "hand.raised")
                    .foregroundStyle(.orange)
                if let explanation { Text(explanation).font(.caption).foregroundStyle(.secondary) }
            }
            .font(.callout)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 6) {
                Label(AssistantCopy.message(failure, settings.t), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                if failure != .disconnected, failure != .noAPIKey {
                    Button(settings.t("assistant_retry")) { model.retry() }
                        .controlSize(.small)
                }
            }
        }
    }

    /// DesignBrief › Loading: pulsing purple dot for Claude.
    private func activity(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.purple)
                .symbolEffect(.pulse, options: .repeating)
            Text(settings.t(key)).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var promptArea: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField(settings.t("assistant_prompt_placeholder"), text: $model.prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
                .onSubmit { model.ask() }
                .disabled(model.phase.isBusy)
            HStack {
                if !model.sessionConnected {
                    Text(settings.t("assistant_not_connected")).font(.caption).foregroundStyle(.secondary)
                } else if model.trimmedPrompt.count > AssistantModel.maxPromptLength {
                    Text(settings.t("assistant_prompt_too_long")).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                if model.phase.isBusy {
                    Button(settings.t("assistant_stop"), role: .cancel) { model.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(settings.t("assistant_ask")) { model.ask() }
                        .disabled(!model.canAsk)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

/// A long or multi-line `type` text (T5.3 M2): closed at first, the whole text once opened, every
/// invisible scalar visible (⏎ ⇥ `\u{…}`). Opening it is what arms Confirm (`AssistantModel.reveal`).
private struct TypedTextBlock: View {
    @Environment(AppSettings.self) private var settings
    let text: String
    let item: AssistantModel.ActionItem
    let model: AssistantModel
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isOpen.toggle()
                if isOpen { model.reveal(item.toolUseID) }
            } label: {
                Label(isOpen ? settings.t("action_type_hide") : settings.t("action_type_show", text.unicodeScalars.count),
                      systemImage: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if isOpen {
                ScrollView {
                    Text(DisplayText.revealingInvisibles(text))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
            }
        }
        // Opened while it was still queued: it counts once it is the proposal.
        .onChange(of: model.awaitingID, initial: true) {
            if isOpen { model.reveal(item.toolUseID) }
        }
    }
}
