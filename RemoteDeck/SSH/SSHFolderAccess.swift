import AppKit
import Foundation

/// Why a file of the `~/.ssh` folder could not be read.
enum SSHFolderError: Error, Equatable {
    /// No folder grant on this Mac, or its bookmark no longer resolves.
    case notGranted
    /// The path would leave the folder (absolute, `~`, or a `..` component), or is empty.
    case invalidPath(String)
    case fileMissing(String)
    /// Exists but could not be read (permissions, not UTF-8).
    case unreadable(String)
}

/// Why the last `requestAccess` granted nothing (a Cancel in the panel is not a problem).
enum SSHFolderRequestProblem: Equatable, Sendable {
    /// The chosen folder is not named `.ssh` (its name, for the message).
    case notSSHFolder(String)
    /// The bookmark could not be made.
    case bookmarkFailed
}

/// Read-only access to the user's `~/.ssh` folder (TRD › Security › `~/.ssh`): granted once per Mac
/// through an open panel, kept as an app-scoped security-scoped bookmark. Nothing in the folder is
/// ever written: the API has no write, and the bookmark itself is read-only.
@MainActor
protocol SSHFolderAccessing: AnyObject {
    /// A grant exists and its bookmark resolves (a stale one is re-created from the URL it resolved
    /// to, and stays granted).
    var isGranted: Bool { get }
    /// A grant was made on this Mac but its bookmark no longer resolves: "~/.ssh access lost", as
    /// opposed to never granted. Never true while `isGranted`.
    var accessLost: Bool { get }
    /// Shows the open panel on `~/.ssh` (directories only); true once the folder is granted. Only a
    /// folder named `.ssh` is accepted.
    func requestAccess() async -> Bool
    /// Why the last `requestAccess` granted nothing; nil after a grant or a Cancel.
    var lastRequestProblem: SSHFolderRequestProblem? { get }
    /// The UTF-8 contents of a file of the folder (`id_ed25519`, `known_hosts`), at most
    /// `SSHFolderAccess.maxFileSize` bytes (larger: unreadable). Throws `SSHFolderError`.
    func readFile(_ relativePath: String) throws -> String
    /// The names of the regular files at the top of the folder (no contents read, no subfolder,
    /// sockets and links left out), for the Machine Editor's key picker. Throws `SSHFolderError`.
    func listFiles() throws -> [String]
}

/// Paths relative to `~/.ssh` (BackendSchema › Machine.sshKeyFileName): never absolute, never `~`,
/// no `..` component, so a read never leaves the granted folder.
enum SSHFolderPath {
    nonisolated static func isValid(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        return !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// A file of `~/.ssh` that may be a private key, by name only (the editor never reads a key
    /// to list it): not hidden, not a public key (`*.pub`), not `known_hosts*`, `config`,
    /// `authorized_keys*` or `environment`.
    nonisolated static func isKeyCandidate(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasSuffix(".pub") else { return false }
        if name.hasPrefix("known_hosts") || name.hasPrefix("authorized_keys") { return false }
        return !["config", "environment", "rc"].contains(name)
    }

    /// The folder the user picked must be a `.ssh` folder: key file names are relative to it.
    nonisolated static func isSSHFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == ".ssh"
    }
}

/// The security-scoped bookmark calls of `SSHFolderAccess`, injectable so the stale-bookmark refresh
/// and the capped read are tested without a real grant (the hosted tests never touch `~/.ssh`).
@MainActor
protocol SecurityScopedBookmarks {
    /// The URL the bookmark resolves to and whether it is stale; nil when it does not resolve.
    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)?
    /// A read-only security-scoped bookmark of `url`; nil when it cannot be made.
    func makeBookmark(for url: URL) -> Data?
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// The system's calls (`URL(resolvingBookmarkData:…)`, `bookmarkData`, the security scope).
struct SystemSecurityScopedBookmarks: SecurityScopedBookmarks {
    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        return (url, isStale)
    }

    func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// The real folder access. The bookmark (UserDefaults `sshFolderBookmark`, per Mac, never synced) is
/// made with `securityScopeAllowOnlyReadAccess`, and the security scope is held only for the
/// duration of each read (or of the re-creation of a stale bookmark).
@MainActor
final class SSHFolderAccess: SSHFolderAccessing {
    static let bookmarkKey = "sshFolderBookmark"
    /// A read stops here (a private key is a few KiB, a big `known_hosts` a few hundred): anything
    /// larger is reported unreadable rather than read whole on the main actor at every attempt.
    nonisolated static let maxFileSize = 4 * 1024 * 1024

    private let defaults: UserDefaults
    private let bookmarks: any SecurityScopedBookmarks
    private(set) var lastRequestProblem: SSHFolderRequestProblem?

    init(defaults: UserDefaults = .standard, bookmarks: any SecurityScopedBookmarks = SystemSecurityScopedBookmarks()) {
        self.defaults = defaults
        self.bookmarks = bookmarks
    }

    var isGranted: Bool { grantedFolder() != nil }

    var accessLost: Bool { defaults.data(forKey: Self.bookmarkKey) != nil && !isGranted }

    /// The user's real `~/.ssh`: in the sandbox, `NSHomeDirectory()` is the app's container, so the
    /// home folder comes from the password database.
    nonisolated static var userSSHFolder: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(filePath: home, directoryHint: .isDirectory).appending(path: ".ssh", directoryHint: .isDirectory)
    }

    func requestAccess() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.userSSHFolder
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        lastRequestProblem = nil
        guard response == .OK, let url = panel.url else { return isGranted }
        guard SSHFolderPath.isSSHFolder(url) else {
            lastRequestProblem = .notSSHFolder(url.lastPathComponent)
            return isGranted
        }
        guard let bookmark = bookmarks.makeBookmark(for: url) else {
            lastRequestProblem = .bookmarkFailed
            return isGranted
        }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return isGranted
    }

    func readFile(_ relativePath: String) throws -> String {
        guard SSHFolderPath.isValid(relativePath) else { throw SSHFolderError.invalidPath(relativePath) }
        guard let folder = grantedFolder() else { throw SSHFolderError.notGranted }
        let file = folder.appending(path: relativePath, directoryHint: .notDirectory)
        guard bookmarks.startAccessing(folder) else { throw SSHFolderError.notGranted }
        defer { bookmarks.stopAccessing(folder) }
        return try Self.readText(file, relativePath: relativePath)
    }

    /// The UTF-8 text of `file`, reading at most `limit` + 1 bytes (one bounded read, no size check
    /// then read): more than `limit` bytes, or not UTF-8, is unreadable.
    nonisolated static func readText(_ file: URL, relativePath: String,
                                     limit: Int = maxFileSize) throws(SSHFolderError) -> String {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw .fileMissing(relativePath)
        } catch {
            throw .unreadable(relativePath)
        }
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw .unreadable(relativePath)
        }
        return text
    }

    func listFiles() throws -> [String] {
        guard let folder = grantedFolder() else { throw SSHFolderError.notGranted }
        guard bookmarks.startAccessing(folder) else { throw SSHFolderError.notGranted }
        defer { bookmarks.stopAccessing(folder) }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [])
        } catch {
            throw SSHFolderError.unreadable(".")
        }
        // `isRegularFile` is false for a symbolic link, a socket (ControlMaster) or a folder.
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// The bookmarked folder, or nil without a bookmark or when it no longer resolves (the user
    /// grants it again). A stale bookmark still resolves: per Apple's documentation of
    /// `URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:`, "your app
    /// should create a new bookmark using the returned URL and use it in place of any stored copies
    /// of the existing bookmark". It is re-created inside the security scope and stored; if that
    /// fails, the old one is kept (it resolved) and the next resolution tries again.
    private func grantedFolder() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
              let (url, isStale) = bookmarks.resolve(bookmark) else { return nil }
        if isStale, bookmarks.startAccessing(url) {
            defer { bookmarks.stopAccessing(url) }
            if let fresh = bookmarks.makeBookmark(for: url) { defaults.set(fresh, forKey: Self.bookmarkKey) }
        }
        return url
    }
}

/// The hosted tests, the demo modes and an in-memory library: never a panel, never the user's
/// `~/.ssh`. Not granted unless built with files.
@MainActor
final class InMemorySSHFolderAccess: SSHFolderAccessing {
    private let files: [String: String]?

    /// `files` nil: no grant.
    init(files: [String: String]? = nil) {
        self.files = files
    }

    var isGranted: Bool { files != nil }
    var accessLost: Bool { false }
    var lastRequestProblem: SSHFolderRequestProblem? { nil }

    func requestAccess() async -> Bool { isGranted }

    func readFile(_ relativePath: String) throws -> String {
        guard SSHFolderPath.isValid(relativePath) else { throw SSHFolderError.invalidPath(relativePath) }
        guard let files else { throw SSHFolderError.notGranted }
        guard let text = files[relativePath] else { throw SSHFolderError.fileMissing(relativePath) }
        return text
    }

    func listFiles() throws -> [String] {
        guard let files else { throw SSHFolderError.notGranted }
        return files.keys.filter { !$0.contains("/") }.sorted()
    }
}

// MARK: - Key import

/// The open panel of the Machine Editor's "Import Key…": one file the user picks. Injectable, so the
/// hosted tests never show a panel.
@MainActor
protocol KeyFilePicking {
    /// The chosen file, nil on Cancel.
    func chooseKeyFile() async -> URL?
}

/// `NSOpenPanel` on `~/.ssh` (hidden files shown, one file). The sandbox grants read access to the
/// chosen file only.
struct OpenPanelKeyFilePicker: KeyFilePicking {
    func chooseKeyFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = SSHFolderAccess.userSSHFolder
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}

/// The default of models built without the app's picker: never a panel.
struct NoKeyFilePicker: KeyFilePicking {
    func chooseKeyFile() async -> URL? { nil }
}

// MARK: - Panels of the app

/// The panels SSH machines show (Import Key…, Upload File…, Download File…) and the browser a
/// forward opens: the real ones, except in a Debug `-LibraryDemo` mode, which never shows a real
/// panel nor opens a URL (`LibraryDemo.FileTransferPanels`, `LibraryDemo.URLOpener`, no key picker).
@MainActor
enum AppPanels {
    static var isDemo: Bool {
        #if DEBUG
        LibraryDemo.isEnabled
        #else
        false
        #endif
    }

    static func keyFilePicker(demo: Bool = isDemo) -> any KeyFilePicking {
        demo ? NoKeyFilePicker() : OpenPanelKeyFilePicker()
    }

    /// Open in Browser of a forward: the default browser, or in a demo mode a line on stderr.
    static func urlOpener(demo: Bool = isDemo) -> any URLOpening {
        #if DEBUG
        if demo { return LibraryDemo.URLOpener() }
        #endif
        return WorkspaceURLOpener()
    }

    static func fileTransferPanels(demo: Bool = isDemo) -> any FileTransferPanels {
        #if DEBUG
        if demo { return LibraryDemo.FileTransferPanels() }
        #endif
        return SystemFileTransferPanels()
    }
}
