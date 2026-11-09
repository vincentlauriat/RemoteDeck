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

/// Read-only access to the user's `~/.ssh` folder (TRD › Security › `~/.ssh`): granted once per Mac
/// through an open panel, kept as an app-scoped security-scoped bookmark. Nothing in the folder is
/// ever written: the API has no write, and the bookmark itself is read-only.
@MainActor
protocol SSHFolderAccessing: AnyObject {
    /// A grant exists and its bookmark resolves (a stale bookmark reads as not granted).
    var isGranted: Bool { get }
    /// Shows the open panel on `~/.ssh` (directories only); true once the folder is granted.
    func requestAccess() async -> Bool
    /// The UTF-8 contents of a file of the folder (`id_ed25519`, `known_hosts`). Throws `SSHFolderError`.
    func readFile(_ relativePath: String) throws -> String
}

/// Paths relative to `~/.ssh` (BackendSchema › Machine.sshKeyFileName): never absolute, never `~`,
/// no `..` component, so a read never leaves the granted folder.
enum SSHFolderPath {
    nonisolated static func isValid(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        return !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

/// The real folder access. The bookmark (UserDefaults `sshFolderBookmark`, per Mac, never synced) is
/// made with `securityScopeAllowOnlyReadAccess`, and the security scope is held only for the
/// duration of each read.
@MainActor
final class SSHFolderAccess: SSHFolderAccessing {
    static let bookmarkKey = "sshFolderBookmark"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isGranted: Bool { grantedFolder() != nil }

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
        guard response == .OK, let url = panel.url else { return isGranted }
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return isGranted
    }

    func readFile(_ relativePath: String) throws -> String {
        guard SSHFolderPath.isValid(relativePath) else { throw SSHFolderError.invalidPath(relativePath) }
        guard let folder = grantedFolder() else { throw SSHFolderError.notGranted }
        let file = folder.appending(path: relativePath, directoryHint: .notDirectory)
        guard folder.startAccessingSecurityScopedResource() else { throw SSHFolderError.notGranted }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw SSHFolderError.fileMissing(relativePath)
        } catch {
            throw SSHFolderError.unreadable(relativePath)
        }
    }

    /// The bookmarked folder, or nil without a bookmark, or when it no longer resolves or is stale
    /// (the folder moved or was replaced: the user grants it again).
    private func grantedFolder() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale else { return nil }
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

    func requestAccess() async -> Bool { isGranted }

    func readFile(_ relativePath: String) throws -> String {
        guard SSHFolderPath.isValid(relativePath) else { throw SSHFolderError.invalidPath(relativePath) }
        guard let files else { throw SSHFolderError.notGranted }
        guard let text = files[relativePath] else { throw SSHFolderError.fileMissing(relativePath) }
        return text
    }
}
