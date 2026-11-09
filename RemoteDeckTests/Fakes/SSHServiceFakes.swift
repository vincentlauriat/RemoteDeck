import Foundation
import Security
import RemoteDeckCore
@testable import RemoteDeck

/// A `~/.ssh` folder in memory that records every call. Its API (as `SSHFolderAccessing`) has no
/// write: `calls` shows the only things the code under test did with the folder.
@MainActor
final class FakeSSHFolderAccess: SSHFolderAccessing {
    var granted: Bool
    /// Relative path → contents.
    var files: [String: String]
    /// `requestAccess` grants the folder (the user picked it in the panel).
    var grantsOnRequest = false
    var accessLost = false
    var lastRequestProblem: SSHFolderRequestProblem?
    /// Files that exist but cannot be read.
    var unreadable: Set<String> = []
    private(set) var calls: [String] = []

    init(granted: Bool = false, files: [String: String] = [:]) {
        self.granted = granted
        self.files = files
    }

    var isGranted: Bool {
        calls.append("isGranted")
        return granted
    }

    func requestAccess() async -> Bool {
        calls.append("requestAccess")
        if grantsOnRequest {
            granted = true
            accessLost = false
        }
        return granted
    }

    func readFile(_ relativePath: String) throws -> String {
        calls.append("readFile(\(relativePath))")
        guard granted else { throw SSHFolderError.notGranted }
        if unreadable.contains(relativePath) { throw SSHFolderError.unreadable(relativePath) }
        guard let text = files[relativePath] else { throw SSHFolderError.fileMissing(relativePath) }
        return text
    }

    func listFiles() throws -> [String] {
        calls.append("listFiles")
        guard granted else { throw SSHFolderError.notGranted }
        return files.keys.filter { !$0.contains("/") }.sorted()
    }
}

/// The bookmark calls of `SSHFolderAccess` over a temporary folder: never a real grant, never `~/.ssh`.
@MainActor
final class FakeSecurityScopedBookmarks: SecurityScopedBookmarks {
    /// What every bookmark resolves to; nil: nothing resolves.
    let folder: URL?
    /// Bookmarks that resolve as stale.
    var stale: Set<Data> = []
    /// What `makeBookmark` returns; nil: it fails.
    var made: Data?
    private(set) var log: [String] = []
    private var open = 0

    init(folder: URL?) {
        self.folder = folder
    }

    /// Every `start` was followed by its `stop`.
    var balanced: Bool { open == 0 }

    func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        log.append("resolve(\(String(decoding: bookmark, as: UTF8.self)))")
        guard let folder else { return nil }
        return (folder, stale.contains(bookmark))
    }

    func makeBookmark(for url: URL) -> Data? {
        log.append("make")
        return made
    }

    func startAccessing(_ url: URL) -> Bool {
        log.append("start")
        open += 1
        return true
    }

    func stopAccessing(_ url: URL) {
        log.append("stop")
        open -= 1
    }
}

/// SSH secrets in memory, recording each read with its `allowsInteraction`, with injectable failures.
@MainActor
final class FakeSSHSecrets: SSHSecretStore {
    struct Read: Equatable {
        let account: KeychainAccount
        let allowsInteraction: Bool
    }

    var items: [KeychainAccount: String] = [:]
    /// Reads of these accounts fail when they may not show a dialog (errSecInteractionNotAllowed).
    var needsInteraction: Set<KeychainAccount> = []
    var saveError: KeychainError?
    /// Every read fails with it (an interactive read refused, a damaged item).
    var readError: KeychainError?
    private(set) var reads: [Read] = []
    private(set) var deleted: [KeychainAccount] = []

    func secret(_ account: KeychainAccount, allowsInteraction: Bool) throws(KeychainError) -> String? {
        reads.append(Read(account: account, allowsInteraction: allowsInteraction))
        if !allowsInteraction, needsInteraction.contains(account) { throw .interactionNotAllowed }
        if let readError { throw readError }
        return items[account]
    }

    func setSecret(_ value: String, for account: KeychainAccount) throws(KeychainError) {
        if let saveError { throw saveError }
        items[account] = value
    }

    func deleteSecret(_ account: KeychainAccount) throws(KeychainError) {
        deleted.append(account)
        items[account] = nil
    }

    /// Listing the local passphrases fails with it.
    var listError: KeychainError?

    func localPassphraseMachineIDs() throws(KeychainError) -> [UUID] {
        if let listError { throw listError }
        return items.keys.compactMap { account in
            if case .sshLocalKeyPassphrase(let id) = account { return id }
            return nil
        }
    }
}

/// The Keychain's per-scope primitives in memory (`ScopedSecretKeychain`), to drive the -34018
/// fallback and the launch migration without the real Keychain.
final class FakeScopedKeychain: ScopedSecretKeychain, @unchecked Sendable {
    struct Item: Hashable {
        let account: KeychainAccount
        let synchronizable: Bool
    }

    var items: [Item: String] = [:]
    /// Synced reads and saves fail with -34018, as in an unentitled build.
    var refusesSynced = false

    func read(_ account: KeychainAccount, synchronizable: Bool, allowsInteraction: Bool) throws(KeychainError) -> String? {
        if synchronizable, refusesSynced { throw .missingEntitlement }
        return items[Item(account: account, synchronizable: synchronizable)]
    }

    func save(_ secret: String, for account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        if synchronizable, refusesSynced { throw .missingEntitlement }
        items[Item(account: account, synchronizable: synchronizable)] = secret
    }

    func delete(_ account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        items[Item(account: account, synchronizable: synchronizable)] = nil
    }

    func delete(_ account: KeychainAccount) throws(KeychainError) {
        items[Item(account: account, synchronizable: true)] = nil
        items[Item(account: account, synchronizable: false)] = nil
    }

    func localAccountNames() throws(KeychainError) -> [String] {
        items.keys.filter { !$0.synchronizable }.map(\.account.name).sorted()
    }
}
