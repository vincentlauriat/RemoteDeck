import AppKit
import SwiftUI

/// UI copy of the terminal assistant's rows (the model exposes actions, the view words them).
enum TerminalAssistantCopy {
    /// The bytes that will be typed, before the Return: shown whole, never shortened or reformatted.
    static func commandText(_ item: TerminalAssistantModel.ActionItem) -> String? {
        if case .runCommand(let command)? = item.action { return command }
        return nil
    }

    static func title(_ item: TerminalAssistantModel.ActionItem, _ t: (String) -> String) -> String {
        func with(_ key: String, _ value: String) -> String { t(key).replacingOccurrences(of: "%@", with: value) }
        switch item.action {
        case .runCommand?: return t("assistant_terminal_type_return")
        case .sendKeys(let keys)?: return with("assistant_terminal_keys", keys.map(\.displayName).joined(separator: ", "))
        case .waitForOutput(let seconds)?:
            return t("assistant_terminal_wait").replacingOccurrences(of: "%d", with: String(seconds))
        case nil: return t("assistant_terminal_unreadable")
        }
    }

    static func symbol(_ item: TerminalAssistantModel.ActionItem) -> String {
        switch item.action {
        case .runCommand?: "return"
        case .sendKeys?: "keyboard"
        case .waitForOutput?: "hourglass"
        case nil: "questionmark.circle"
        }
    }
}

/// The Assistant Panel of a terminal tab (spec 2026-11-12 › UI): the screen panel's layout (header,
/// transcript, prompt), with rows for commands and keys. A proposed command shows exactly the text
/// that will be typed, the prompt line it lands on, and notes; Confirm (⌘Return, armed after 400 ms),
/// Skip, Stop (⌘.).
struct TerminalAssistantPanelView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: TerminalAssistantModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isReady {
                transcript
                Divider()
                promptArea
            } else {
                notReady
            }
        }
        .onAppear {
            model.syncProvider()
            promptFocused = model.isReady
        }
        .onChange(of: settings.assistantProvider) { model.syncProvider() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(settings.t(model.provider == .claude ? "assistant_title" : "assistant_title_apple"),
                  systemImage: model.provider == .claude ? "sparkles" : "laptopcomputer")
                .font(.headline)
                .foregroundStyle(.purple)
            Spacer()
            if model.provider == .claude {
                Text(settings.t("assistant_tokens", model.usage.total.formatted()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(settings.t("assistant_tokens_help"))
            } else {
                Text(settings.t("assistant_on_device"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(settings.t("assistant_on_device_help"))
            }
            Button { model.newConversation() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(model.phase.isBusy || (model.entries.isEmpty && !model.isNewShell))
            .help(settings.t("assistant_clear"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var notReady: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: model.provider == .claude ? "key" : "laptopcomputer")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(AssistantCopy.message(model.engine.notReadyReason ?? .noAPIKey, settings.t))
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
                        Text(settings.t("assistant_terminal_empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.entries) { entry in
                        row(entry).id(entry.id)
                    }
                    if model.isNewShell {
                        Label(settings.t("assistant_terminal_new_shell"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                            .foregroundStyle(.orange)
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
    private func row(_ entry: TerminalAssistantModel.Entry) -> some View {
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

    private func actionRow(_ item: TerminalAssistantModel.ActionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: TerminalAssistantCopy.symbol(item))
                    .foregroundStyle(item.status == .awaiting ? Color.purple : .secondary)
                Text(TerminalAssistantCopy.title(item, settings.t))
                    .font(.callout)
                Spacer(minLength: 4)
                statusBadge(item.status)
            }
            if let command = TerminalAssistantCopy.commandText(item) {
                if let line = item.promptLine, item.status == .awaiting {
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                // Verbatim: every byte that will be typed, wrapped, selectable.
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    .accessibilityLabel(command)
                if TerminalCommandValidator.looksDestructive(command) {
                    Label(settings.t("assistant_terminal_destructive"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help(settings.t("assistant_terminal_destructive_help"))
                }
                if item.commandLineNotEmpty, item.status == .awaiting {
                    Label(settings.t("assistant_terminal_line_not_empty"), systemImage: "text.cursor")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let reason = item.reason, !reason.isEmpty {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if item.status == .awaiting {
                HStack {
                    Button(settings.t("assistant_confirm")) {
                        model.confirm(id: item.id, isKeyRepeat: Self.currentEventIsKeyRepeat)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!model.confirmArmed || model.awaitingID != item.id)
                    Button(settings.t("assistant_skip")) { model.skip(id: item.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(item.status == .awaiting ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.08)))
    }

    private static var currentEventIsKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    @ViewBuilder
    private func statusBadge(_ status: TerminalAssistantModel.ActionItem.Status) -> some View {
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
        case .idle, .finished:
            EmptyView()
        case .running:
            activity(model.provider == .claude ? "assistant_looking" : "assistant_looking_apple")
        case .awaitingDecision:
            activity("assistant_waiting")
        case .stopping:
            activity("assistant_stopping")
        case .waitingForUser(.password):
            VStack(alignment: .leading, spacing: 6) {
                Label(settings.t("assistant_terminal_password_wait"), systemImage: "key.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                HStack {
                    Button(settings.t("assistant_continue")) { model.continueAfterUser() }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    Button(settings.t("assistant_stop"), role: .cancel) { model.stop() }
                }
                .controlSize(.small)
            }
        case .paused:
            VStack(alignment: .leading, spacing: 6) {
                Label(settings.t("assistant_paused", AssistantDecisionGate.maxStepsWithoutAction), systemImage: "pause.circle")
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
                if !failure.isPermanent {
                    Button(settings.t("assistant_retry")) { model.retry() }
                        .controlSize(.small)
                }
            }
        }
    }

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
                } else if model.trimmedPrompt.count > TerminalAssistantModel.maxPromptLength {
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
