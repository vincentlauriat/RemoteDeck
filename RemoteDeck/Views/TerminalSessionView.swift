import SwiftUI
import SwiftData
import RemoteDeckCore

/// Terminal tab (AppFlow › Session Window › Terminal tab, DesignBrief › Terminal tab): an SSH
/// machine's shell in a tab of the Session Window. The terminal fills the content area on its
/// palette's background; the connecting overlay, the banners and the dimming of the last output are
/// those of the screen session. Closing the tab (close button, ⌘W, Cancel, Disconnect) closes this
/// `NSWindow`, whose `willClose` runs `SessionManager.close`.
struct TerminalSessionView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var manager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme
    let terminal: TerminalSessionModel
    let machineID: UUID

    @State private var surface: GhosttyTerminalSurface?
    @State private var editorRequest: EditorRequest?
    /// Files hover over the terminal and would be taken (Task 12).
    @State private var isDropTargeted = false

    private var appearance: TerminalAppearance {
        TerminalAppearance(isDark: colorScheme == .dark, fontSize: CGFloat(settings.terminalFontSize),
                           optionAsMeta: settings.terminalOptionAsMeta)
    }

    var body: some View {
        ZStack {
            if let surface {
                TerminalSurfaceRepresentable(surface: surface)
                    .accessibilityLabel(settings.t("terminal_accessibility_label"))
            }
            if let _ = terminal.overlay {
                // Connecting, reconnecting, waiting for the network: the overlay takes the clicks.
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            } else if terminal.phase != .connected {
                // A banner or "The remote shell ended": the last output stays dimmed but can still be
                // selected, copied and scrolled back (nothing is sent: the shell is not up).
                Color.black.opacity(0.35)
                    .allowsHitTesting(false)
            }
            if let overlay = terminal.overlay { connectingOverlay(overlay) }
            if isDropTargeted { dropHighlight }
        }
        .background(Color(nsColor: TerminalTheme.forAppearance(isDark: colorScheme == .dark).background.nsColor))
        .background {
            // The tab joins the Session Window; only a real window close ends the session.
            SessionWindowAccessor(onAttach: { [terminal] window in
                terminal.bringWindowForward = { [weak window] in
                    if let window { SessionTabs.select(window) }
                }
                SessionTabs.prepare(window)
                Task { @MainActor in SessionTabs.adopt(window, order: terminal.openOrder) }
            }, onClose: { [machineID, manager] window in
                SessionTabs.forget(window)
                manager.close(machineID)
            })
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure = terminal.failure {
                banner(failure)
            } else if terminal.phase == .ended {
                endedBar
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !terminal.target.portForwards.isEmpty { forwardsMenu }
                Button { dismissWindow() } label: {
                    Label(settings.t("session_disconnect"), systemImage: "xmark.circle")
                }
                .help(settings.t("session_disconnect"))
            }
        }
        .navigationTitle(terminal.target.name)
        .focusedSceneValue(\.terminalFileActions, TerminalFileActions(
            canTransfer: terminal.canTransferFiles,
            upload: { [terminal] in Task { await terminal.chooseFilesToUpload() } },
            download: { [terminal] in terminal.beginDownload() }
        ))
        .onAppear(perform: attachSurface)
        .onChange(of: appearance) { _, new in surface?.apply(new) }
        .onChange(of: terminal.phase) { _, phase in focusIfConnected(phase) }
        .sheet(item: $editorRequest) { request in
            MachineEditorView(model: request.model) { _ in terminal.connect() }
        }
        .background {
            // One sheet per anchor: the two prompts never show at once, but SwiftUI wants them apart.
            Color.clear.sheet(isPresented: Binding(get: { terminal.hostKeyPrompt != nil }, set: { _ in })) {
                if let prompt = terminal.hostKeyPrompt {
                    HostKeySheet(prompt: prompt, onTrust: { terminal.trustHostKey() },
                                 onCancel: { terminal.rejectHostKey() })
                }
            }
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { terminal.fileTransfer != nil }, set: { _ in })) {
                if let transfer = terminal.fileTransfer {
                    FileTransferSheet(model: transfer, machineName: terminal.target.name,
                                      onEnd: { terminal.endFileTransfer() })
                }
            }
        }
        .background {
            Color.clear.sheet(isPresented: Binding(get: { terminal.needsPassphrase }, set: { _ in })) {
                PassphraseSheet(machineName: terminal.target.name, rejected: terminal.passphraseRejected,
                                onConnect: { passphrase, remember in
                                    terminal.providePassphrase(passphrase, remember: remember)
                                },
                                onCancel: {
                                    terminal.cancelPassphrase()
                                    dismissWindow()
                                })
            }
        }
    }

    /// DesignBrief › Terminal tab: the `network` menu, one section per saved forward (label or
    /// `localhost:8080 → localhost:80`), its state (a symbol per state, as menu images render as
    /// templates, and its word or error), Open in Browser (only while active) and Retry for a failed
    /// one. Hidden when the machine has no forwards.
    private var forwardsMenu: some View {
        Menu {
            ForEach(terminal.target.portForwards) { forward in
                let state = terminal.forwardStates[forward.id] ?? .stopped
                Section(forward.displayTitle) {
                    Label(state.message(settings.t), systemImage: forwardSymbol(state))
                        .disabled(true)
                    Button(settings.t("forward_open_in_browser")) { terminal.openInBrowser(forward.id) }
                        .disabled(!state.isActive)
                    if state.isFailed {
                        Button(settings.t("session_retry")) { terminal.retryForward(forward.id) }
                    }
                }
            }
        } label: {
            Label(settings.t("editor_section_forwards"), systemImage: "network")
        }
        .help(settings.t("editor_section_forwards"))
    }

    private func forwardSymbol(_ state: ForwardState) -> String {
        switch state {
        case .active: "checkmark.circle"
        case .starting: "circle.dotted"
        case .failed: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        }
    }

    /// One engine adapter per terminal session, kept by the model (a tab shown again reuses it).
    private func attachSurface() {
        guard surface == nil else { return }
        let engine = (terminal.surface as? GhosttyTerminalSurface) ?? GhosttyTerminalSurface()
        engine.apply(appearance)
        engine.accessibilityLabel = settings.t("terminal_accessibility_label")
        engine.onFontSizeStep = { [settings] step in settings.stepTerminalFontSize(step) }
        engine.onSelectTab = { index in _ = SessionTabs.selectTab(at: index) }
        let targeted = $isDropTargeted
        engine.acceptsFileDrop = { [terminal] in terminal.canTransferFiles }
        engine.onDropTargeted = { targeted.wrappedValue = $0 }
        engine.onDropFiles = { [terminal] urls in terminal.beginUpload(urls) }
        terminal.fileTransferPanels = AppPanels.fileTransferPanels()
        terminal.separatorText = { [settings] in settings.t("terminal_reconnected_separator") }
        if terminal.surface !== engine { terminal.attach(engine) }
        surface = engine
        focusIfConnected(terminal.phase)
    }

    /// The terminal takes the keyboard once the shell is up (AppFlow: "Terminal shown and focused").
    private func focusIfConnected(_ phase: TerminalSessionModel.Phase) {
        guard phase == .connected, let view = surface?.view else { return }
        Task { @MainActor in
            if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
        }
    }

    /// Files hovering over the terminal: an accent frame and where they go.
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            .overlay {
                Label(settings.t("transfer_drop_hint", terminal.target.name), systemImage: "arrow.up.doc")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(4)
            .allowsHitTesting(false)
    }

    // MARK: Overlay and banners

    /// DesignBrief: 15 pt medium, white on 60 % black; Esc cancels (closes the tab).
    private func connectingOverlay(_ overlay: SessionModel.Overlay) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text(overlayText(overlay))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            if overlay == .waitingForNetwork {
                Text(settings.t("session_waiting_network_detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Button(settings.t("cancel")) { dismissWindow() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private func overlayText(_ overlay: SessionModel.Overlay) -> String {
        switch overlay {
        case .connecting: settings.t("session_connecting", terminal.target.name)
        case .reconnecting: settings.t("session_reconnecting", terminal.target.name)
        case .waitingForNetwork: settings.t("session_waiting_network")
        }
    }

    /// DesignBrief › Banners: 32 pt, red left bar, the failure's action. The changed-key banner shows
    /// both fingerprints in SF Mono and has Close only: nothing in it continues the connection.
    private func banner(_ failure: TerminalFailure) -> some View {
        let lines = failure.message(settings.t).components(separatedBy: "\n")
        return HStack(spacing: 8) {
            Rectangle().fill(.red).frame(width: 3)
            Image(systemName: failure.isAuthentication ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(lines.first ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, lines.count > 1 ? 6 : 0)
            Spacer()
            switch failure.action {
            case .editCredentials:
                Button(settings.t("session_edit_credentials")) { editCredentials() }
            case .grantSSHFolder:
                Button(settings.t("terminal_grant_access")) { grantSSHFolder() }
                Button(settings.t("session_retry")) { terminal.connect() }
            case .retry:
                Button(settings.t("session_retry")) { terminal.connect() }
            case .reconnect:
                Button(settings.t("session_reconnect")) { terminal.connect() }
            case .close:
                Button(settings.t("terminal_close")) { dismissWindow() }
            }
        }
        .padding(.trailing, 12)
        .frame(minHeight: 32)
        .fixedSize(horizontal: false, vertical: true)
        .background(.red.opacity(0.12))
        .background(.background)
    }

    /// "The remote shell ended": no error, the last output kept; Reconnect opens a new shell.
    private var endedBar: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.secondary).frame(width: 3)
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(settings.t("terminal_shell_ended"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(settings.t("session_reconnect")) { terminal.connect() }
        }
        .padding(.trailing, 12)
        .frame(minHeight: 32)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
    }

    /// AppFlow: "Edit credentials" opens the Machine Editor; saving retries.
    private func editCredentials() {
        guard let machine = try? manager.context.fetch(FetchDescriptor<Machine>(
            predicate: #Predicate { $0.id == machineID })).first else { return }
        editorRequest = EditorRequest(model: MachineEditorModel(
            machine: machine, context: manager.context, passwords: manager.passwords,
            tester: manager.tester, defaultSharedClipboard: settings.defaultSharedClipboard,
            publicConsents: manager.publicConsents, ssh: manager.ssh, sshTester: manager.sshTester,
            keyPicker: AppPanels.keyFilePicker()))
    }

    /// The open panel on `~/.ssh`; granted, the attempt starts again; refused, the banner stays.
    private func grantSSHFolder() {
        Task { @MainActor in
            if await manager.ssh.folder.requestAccess() { terminal.connect() }
        }
    }
}

/// Hosts the engine adapter's view. The adapter (and its view) belong to the session model, so a
/// tab shown again gets the same view, with its scrollback.
private struct TerminalSurfaceRepresentable: NSViewRepresentable {
    let surface: GhosttyTerminalSurface

    func makeNSView(context: Context) -> NSView { surface.view }
    func updateNSView(_ view: NSView, context: Context) {}
}
