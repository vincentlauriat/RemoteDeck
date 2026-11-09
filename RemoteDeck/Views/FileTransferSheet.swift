import SwiftUI
import SSHKit

/// File Transfer Sheet (AppFlow › Terminal tab › Upload File… / Download File…, DesignBrief ›
/// Terminal tab): 420 pt wide, 20 pt padding; the file names, the remote folder (or file) field in
/// SF Mono 12 pt pre-filled with the remote home, a progress bar with bytes done and total, Cancel,
/// and Upload or Download as the single prominent button. "Replace <name>?" is a confirmation row
/// inside the sheet. Cancel and Done go through `onEnd` (`TerminalSessionModel.endFileTransfer`).
struct FileTransferSheet: View {
    @Environment(AppSettings.self) private var settings
    let model: FileTransferModel
    let machineName: String
    let onEnd: () -> Void

    /// Names shown before "+ n more".
    private static let listedFiles = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.t(model.kind == .upload ? "transfer_upload_title" : "transfer_download_title", machineName))
                .font(.headline)
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.step {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(settings.t("transfer_preparing")).foregroundStyle(.secondary)
            }
        case .chooseDestination(let files, let directory):
            fileList(files)
            refusedNotice
            if !files.isEmpty {
                pathField("transfer_remote_folder", directory) { model.setDirectory($0) }
            }
        case .confirmOverwrite(let names):
            replaceRow(names)
        case .chooseRemoteFile(let path):
            pathField("transfer_remote_file", path) { model.setRemotePath($0) }
        case .noSuchFile(let path):
            pathField("transfer_remote_file", path) { model.setRemotePath($0) }
            failureRow(settings.t("transfer_no_such_file"), detail: nil)
        case .transferring(let done, let total):
            progress(done: done, total: total)
        case .finished:
            Label(settings.t("transfer_finished"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let error):
            failureRow(FileTransferModel.message(for: error, settings.t), detail: detail(of: error))
        }
    }

    private func fileList(_ files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files.prefix(Self.listedFiles), id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if files.count > Self.listedFiles {
                Text("+ \(files.count - Self.listedFiles)").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var refusedNotice: some View {
        if !model.refusedFolders.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label(settings.t("transfer_folders_refused"), systemImage: "folder.badge.minus")
                    .foregroundStyle(.secondary)
                Text(model.refusedFolders.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func pathField(_ labelKey: String, _ value: String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(settings.t(labelKey)).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(settings.t(labelKey), text: Binding(get: { value }, set: set))
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .disabled(model.isChecking)
                .onSubmit(primaryAction)
        }
    }

    private func replaceRow(_ names: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(settings.t("transfer_replace", names.joined(separator: ", ")))
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private func progress(done: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if total > 0 {
                ProgressView(value: Double(min(done, total)), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(settings.t("transfer_progress", bytes(done)).replacingOccurrences(of: "%@", with: bytes(total)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func failureRow(_ message: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
    }

    /// The path or the server's words, under the message.
    private func detail(of error: SSHError) -> String? {
        switch error {
        case .noSuchDirectory(let path), .fileExists(let path): path
        case .remote(let text): text
        default: nil
        }
    }

    /// In the app's language (Settings › Language), as Session History does, not the system's.
    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(Locale(identifier: settings.localeIdentifier)))
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        switch model.step {
        case .finished, .failed:
            Button(settings.t("transfer_done"), action: onEnd)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        default:
            Button(settings.t("cancel"), action: onEnd)
                .keyboardShortcut(.cancelAction)
            if let title = primaryTitle {
                Button(title, action: primaryAction)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!primaryEnabled)
            }
        }
    }

    private var primaryTitle: String? {
        switch model.step {
        case .preparing, .chooseDestination:
            model.kind == .upload ? settings.t("transfer_upload") : settings.t("transfer_download")
        case .transferring: nil   // Cancel only while bytes move
        case .confirmOverwrite: settings.t("transfer_replace_button")
        case .chooseRemoteFile, .noSuchFile: settings.t("transfer_download")
        case .finished, .failed: nil
        }
    }

    private var primaryEnabled: Bool {
        guard !model.isChecking else { return false }
        switch model.step {
        case .chooseDestination(let files, _): return !files.isEmpty
        case .confirmOverwrite: return true
        case .chooseRemoteFile, .noSuchFile: return model.canChooseDownloadLocation
        default: return false
        }
    }

    private func primaryAction() {
        guard primaryEnabled else { return }
        switch model.step {
        case .chooseDestination: model.start()
        case .confirmOverwrite: model.confirmOverwrite()
        case .chooseRemoteFile, .noSuchFile: model.chooseDownloadLocation()
        default: break
        }
    }
}

// MARK: - Menu

/// What the File menu's transfer items act on: the focused terminal tab.
struct TerminalFileActions {
    let canTransfer: Bool
    let upload: () -> Void
    let download: () -> Void
}

private struct TerminalFileActionsKey: FocusedValueKey {
    typealias Value = TerminalFileActions
}

extension FocusedValues {
    var terminalFileActions: TerminalFileActions? {
        get { self[TerminalFileActionsKey.self] }
        set { self[TerminalFileActionsKey.self] = newValue }
    }
}

/// File › Upload File… (⌘U) and Download File… (⇧⌘D), AppFlow › Shortcuts: enabled only in a
/// terminal tab whose shell is up and that shows no transfer sheet.
struct FileTransferCommands: Commands {
    let settings: AppSettings
    @FocusedValue(\.terminalFileActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(settings.t("menu_upload_file")) { actions?.upload() }
                .keyboardShortcut("u")
                .disabled(actions?.canTransfer != true)
            Button(settings.t("menu_download_file")) { actions?.download() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions?.canTransfer != true)
        }
    }
}
