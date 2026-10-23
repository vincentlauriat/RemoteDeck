import SwiftUI
import SwiftData
import RemoteDeckCore
import RFBKit

/// The Session Window scene id. One window per machine, keyed by `Machine.id`.
enum SessionWindow {
    static let id = "session"
}

/// Session Window (AppFlow › Session Window, DesignBrief › Session Window): the remote screen, the
/// connecting overlay with Cancel, the error banner with its action, and a compact toolbar (keyboard
/// capture pill, Accessibility notice, scaling, Disconnect). Closing the window, Cancel and Disconnect
/// all go through `SessionManager.close`, which tears the session down in order.
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
        }
        .onDisappear {
            if !duplicate { manager.close(machineID) }
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
                onCreate: { view in
                    Task { @MainActor in attach(view, to: session) }   // not during the view update
                }
            )
            if session.phase != .connected {
                // Takes the clicks, so the view cannot capture the keyboard before the first frame.
                Color.black.opacity(session.isConnecting ? 0.6 : 0.35)
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            if session.isConnecting { connectingOverlay(session) }
            if session.clipboardTooLarge { clipboardToast }
        }
        .background(.black)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure = session.failure { banner(failure, session: session) }
        }
        .toolbar { toolbar(session) }
        .navigationTitle(session.target.name)
        .sheet(item: $editorRequest) { request in
            MachineEditorView(model: request.model) { _ in session.connect() }
        }
    }

    /// Wires the view's capture and Accessibility state to the session. Capture stays off until the
    /// first frame (`SessionSurface.startCapture`).
    private func attach(_ view: FramebufferView, to session: SessionModel) {
        session.surface = view
        session.bringWindowForward = { [weak view] in view?.window?.makeKeyAndOrderFront(nil) }
        view.releaseCapture()
        let update: () -> Void = { [weak session, weak view] in
            guard let view else { return }
            session?.inputStateChanged(capturing: view.input.isCapturing,
                                       systemShortcutsAvailable: view.systemShortcutsAvailable)
        }
        view.onCaptureChange = { _ in update() }
        view.onWindowKeyChange = { [weak session] key in session?.windowKeyChanged(key) }
        session.windowKeyChanged(view.window?.isKeyWindow == true)
        view.systemShortcuts.onAvailabilityChange = { _ in update() }
        if session.phase == .connected { view.startCapture() }
    }

    // MARK: Overlay and banner

    /// DesignBrief: 15 pt medium, white on 60 % black; Esc cancels.
    private func connectingOverlay(_ session: SessionModel) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text(settings.t("session_connecting", session.target.name))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Button(settings.t("cancel")) { dismissWindow() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
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
            Button { dismissWindow() } label: {
                Label(settings.t("session_disconnect"), systemImage: "xmark.circle")
            }
            .help(settings.t("session_disconnect"))
        }
    }
}
