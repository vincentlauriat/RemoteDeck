import SwiftUI
import SwiftData
import RemoteDeckCore
import RFBKit

/// The Session Window scene id. One window (a tab of the Session Window, `SessionTabs`) per machine,
/// keyed by `Machine.id`.
enum SessionWindow {
    static let id = "session"
}

/// A session window with no machine: the tab bar's "+" (AppKit shows it for every tab group, and
/// SwiftUI answers it with a window without a value). There is no session to show, so it closes one
/// main-queue turn after it appears (not inside AppKit's own handling of the "+") and brings the
/// Library Window forward, where the next machine is picked. Hiding the "+" would need a custom
/// `NSWindow` class or swizzling `newWindowForTab:` out of SwiftUI's responder chain, which is not a
/// clean option for a SwiftUI-owned window.
struct EmptySessionWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            // One turn later: not while AppKit is still inserting the new tab that asked for it.
            Task { @MainActor in
                dismissWindow()
                openWindow(id: LibraryWindow.id)
            }
        }
    }
}

/// Session Window (AppFlow › Session Window, DesignBrief › Session Window): the remote screen, the
/// connecting overlay with Cancel, the error banner with its action, and a compact toolbar (keyboard
/// capture pill, Accessibility notice, scaling, Disconnect). It is one tab of the Session Window
/// (`SessionTabs`). Closing the tab or window (close button, ⌘W with the keyboard released), Cancel and
/// Disconnect all close this `NSWindow`, whose `willClose` (`SessionWindowAccessor`) runs
/// `SessionManager.close`, which tears this session down in order; the other tabs are untouched.
struct SessionWindowView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionManager.self) private var manager
    @Environment(\.dismissWindow) private var dismissWindow
    let machineID: UUID

    @State private var session: SessionModel?
    @State private var missing = false
    /// Another window already shows this machine: this one closes and leaves the session alone.
    @State private var duplicate = false
    @State private var editorRequest: EditorRequest?
    /// Claude Assistant Panel shown (toolbar sparkles, ⌘K with the keyboard released).
    @State private var showsAssistant = false

    var body: some View {
        Group {
            if let session {
                content(session)
            } else if missing {
                ContentUnavailableView(settings.t("session_machine_missing"), systemImage: "questionmark.circle")
            } else {
                Color.black
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            // SwiftUI may run this again for the same window (its tab shown again): it already holds
            // its session, and must not take itself for a duplicate.
            guard session == nil, !duplicate else { return }
            guard let found = manager.session(for: machineID) else {
                missing = true
                return
            }
            if found.hasWindow {
                duplicate = true
                found.bringWindowForward?()
                dismissWindow()
                return
            }
            found.hasWindow = true
            session = found
            #if DEBUG
            if LibraryDemo.scriptsAssistant { showsAssistant = true }
            #endif
        }
    }

    @ViewBuilder
    private func content(_ session: SessionModel) -> some View {
        ZStack {
            FramebufferViewRepresentable(
                renderer: session.display?.renderer,
                scalingMode: session.scalingMode,
                modifierProfile: session.target.modifierProfile,
                onInput: { [weak session] messages in session?.sendInput(messages) },
                highlight: session.assistant?.highlight ?? [],
                onCreate: { view in
                    Task { @MainActor in attach(view, to: session) }   // not during the view update
                }
            )
            if session.phase != .connected || session.overlay != nil {
                // Takes the clicks, so the view cannot capture the keyboard before the first frame.
                Color.black.opacity(session.overlay != nil ? 0.6 : 0.35)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            if let overlay = session.overlay { connectingOverlay(overlay, session: session) }
            if session.clipboardTooLarge { clipboardToast }
        }
        .background(.black)
        .background {
            // The tab joins the Session Window; only a real window close ends the session.
            SessionWindowAccessor(onAttach: { [order = session.openOrder] window in
                SessionTabs.prepare(window)   // a session tab from the start
                Task { @MainActor in SessionTabs.adopt(window, order: order) }   // once SwiftUI has set it up
            }, onClose: { [machineID, manager] window in
                SessionTabs.forget(window)   // no new tab joins a closing window
                manager.close(machineID)
            })
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure = session.failure { banner(failure, session: session) }
        }
        .toolbar { toolbar(session) }
        .inspector(isPresented: $showsAssistant) {
            Group {
                if let assistant = session.assistant { AssistantPanelView(model: assistant) }
            }
            .inspectorColumnWidth(320)
        }
        .navigationTitle(session.target.name)
        .sheet(item: $editorRequest) { request in
            MachineEditorView(model: request.model) { _ in session.connect() }
        }
    }

    /// Wires the view's capture and Accessibility state to the session. Capture stays off until the
    /// first frame (`SessionSurface.startCapture`).
    private func attach(_ view: FramebufferView, to session: SessionModel) {
        session.surface = view
        session.bringWindowForward = { [weak view] in
            if let window = view?.window { SessionTabs.select(window) }   // its tab, in its group
        }
        view.releaseCapture()
        let update: () -> Void = { [weak session, weak view] in
            guard let view else { return }
            session?.inputStateChanged(capturing: view.input.isCapturing,
                                       systemShortcutsAvailable: view.systemShortcutsAvailable)
        }
        view.onCaptureChange = { _ in update() }
        view.onLocalShortcut = { shortcut in
            if case .switchTab(let number) = shortcut { SessionTabs.selectTab(at: number - 1) }
        }
        view.onWindowKeyChange = { [weak session] key in session?.windowKeyChanged(key) }
        session.windowKeyChanged(view.window?.isKeyWindow == true)
        view.systemShortcuts.onAvailabilityChange = { _ in update() }
        if session.phase == .connected { view.startCapture() }
    }

    // MARK: Overlay and banner

    /// DesignBrief: 15 pt medium, white on 60 % black; Esc cancels (closes the tab). Also over the
    /// last frame while the session reconnects or waits for the network (T5.1).
    private func connectingOverlay(_ overlay: SessionModel.Overlay, session: SessionModel) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text(overlayText(overlay, session: session))
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

    private func overlayText(_ overlay: SessionModel.Overlay, session: SessionModel) -> String {
        switch overlay {
        case .connecting: settings.t("session_connecting", session.target.name)
        case .reconnecting: settings.t("session_reconnecting", session.target.name)
        case .waitingForNetwork: settings.t("session_waiting_network")
        }
    }

    /// DesignBrief › Toasts: bottom-center, 2 s (the model clears it).
    private var clipboardToast: some View {
        VStack {
            Spacer()
            Label(settings.t("session_clipboard_too_large"), systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// DesignBrief › Banners: 32 pt, colored left bar, one action button.
    private func banner(_ failure: SessionFailure, session: SessionModel) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red).frame(width: 3)
            Image(systemName: failure.isAuthentication ? "lock.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(failure.message(settings.t))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
            Spacer()
            switch failure.action {
            case .editCredentials:
                Button(settings.t("session_edit_credentials")) { editCredentials(session) }
            case .retry:
                Button(settings.t("session_retry")) { session.connect() }
            case .reconnect:
                Button(settings.t("session_reconnect")) { session.connect() }
            }
        }
        .padding(.trailing, 12)
        .frame(minHeight: 32)
        .fixedSize(horizontal: false, vertical: true)   // the bar's height, not the window's
        .background(.red.opacity(0.12))
        .background(.background)
    }

    /// AppFlow: "Edit credentials" opens the Machine Editor; saving retries.
    private func editCredentials(_ session: SessionModel) {
        guard let machine = try? manager.context.fetch(FetchDescriptor<Machine>(
            predicate: #Predicate { $0.id == machineID })).first else { return }
        editorRequest = EditorRequest(model: MachineEditorModel(
            machine: machine, context: manager.context, passwords: manager.passwords,
            tester: manager.tester, defaultSharedClipboard: settings.defaultSharedClipboard))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ session: SessionModel) -> some ToolbarContent {
        ToolbarItemGroup {
            if session.isCapturing {
                Label(settings.t("session_captured"), systemImage: "keyboard")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .help(settings.t("session_captured"))
                if !session.systemShortcutsAvailable {
                    // AppFlow › Keyboard capture: opens Privacy & Security › Accessibility.
                    Button(settings.t("session_ax_notice")) { SystemShortcutTap.openAccessibilitySettings() }
                        .font(.system(size: 11))
                        .help(settings.t("session_ax_notice"))
                }
            }
            Button { session.scalingMode = session.scalingMode == .fit ? .actual : .fit } label: {
                Label(settings.t(session.scalingMode == .fit ? "scaling_actual" : "scaling_fit"),
                      systemImage: session.scalingMode == .fit
                          ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .help(settings.t(session.scalingMode == .fit ? "session_scaling_to_actual" : "session_scaling_to_fit"))
            Toggle(isOn: Binding(get: { session.clipboardSharing }, set: { session.clipboardSharing = $0 })) {
                Label(settings.t("session_clipboard"), systemImage: "doc.on.clipboard")
            }
            .help(settings.t(session.clipboardSharing ? "session_clipboard_on" : "session_clipboard_off"))
            if session.assistant != nil {
                Toggle(isOn: $showsAssistant) {
                    Label(settings.t("assistant_toggle"), systemImage: "sparkles")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(settings.t("assistant_toggle_help"))
            }
            Button { dismissWindow() } label: {
                Label(settings.t("session_disconnect"), systemImage: "xmark.circle")
            }
            .help(settings.t("session_disconnect"))
        }
    }
}
