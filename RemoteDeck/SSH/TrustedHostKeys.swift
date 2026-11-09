import Foundation
import SSHKit

/// What to do with a server's host key (TRD › Security › Host keys).
enum HostKeyDecision: Equatable, Sendable {
    /// Known with this key: connect without asking.
    case trusted
    /// Never seen for this `host:port` under this key type: ask (Trust / Cancel).
    case unknown
    /// Known with another key of the same type: block, with both fingerprints. No override.
    case changed(previousFingerprint: String)

    /// `previousFingerprint` when the conflict comes from `~/.ssh/known_hosts`: SSHKit's `KnownHosts`
    /// answers `.mismatch` without the conflicting key, so its fingerprint is not known. Never looks
    /// like a fingerprint (those start with `SHA256:`), so the UI can tell it apart and say "the key
    /// in ~/.ssh/known_hosts" instead.
    static let knownHostsConflict = "~/.ssh/known_hosts"
}

/// RemoteDeck's own trusted host keys, local to this Mac (never synced: trust is a per-Mac
/// judgement, as `PublicAddressConsents`), plus a read-only look at `~/.ssh/known_hosts` when the
/// folder is granted.
@MainActor
protocol TrustedHostKeys: AnyObject {
    func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision
    /// The user accepted an unknown key (never called for a changed one).
    func trust(_ key: SSHHostKey, host: String, port: Int)
    /// The machine was deleted, or "Remove from RemoteDeck's trusted keys…".
    func forget(host: String, port: Int)
}

/// The decision rules, shared by both stores (pure).
enum HostKeyTrust {
    /// `[key type: fingerprint]` per `host:port`.
    typealias Entries = [String: [String: String]]

    /// `host:port`, host trimmed and lowercased (DNS names compare case-insensitively).
    nonisolated static func entryKey(host: String, port: Int) -> String {
        "\(normalized(host)):\(port)"
    }

    nonisolated static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A server signing with `rsa-sha2-256/512` has an `ssh-rsa` key: one key type.
    nonisolated static func keyType(_ algorithm: String) -> String {
        algorithm == "rsa-sha2-256" || algorithm == "rsa-sha2-512" ? "ssh-rsa" : algorithm
    }

    /// `known_hosts` first (when given): a match is trusted, a mismatch (or a revoked key) is changed;
    /// not found there, the own list: same type and fingerprint → trusted, same type and another
    /// fingerprint → changed, otherwise unknown (a host known only under another key type asks).
    nonisolated static func decide(key: SSHHostKey, host: String, port: Int, knownHosts: KnownHosts?,
                                   trusted: [String: String]?) -> HostKeyDecision {
        if let knownHosts {
            switch knownHosts.lookup(host: normalized(host), port: port, key: key) {
            case .match: return .trusted
            case .mismatch: return .changed(previousFingerprint: HostKeyDecision.knownHostsConflict)
            case .notFound: break
            }
        }
        guard let fingerprint = trusted?[keyType(key.algorithm)] else { return .unknown }
        return fingerprint == key.fingerprintSHA256 ? .trusted : .changed(previousFingerprint: fingerprint)
    }

    /// `~/.ssh/known_hosts` when the folder is granted; a missing or unreadable file is no file.
    @MainActor
    static func knownHosts(in folder: any SSHFolderAccessing) -> KnownHosts? {
        guard folder.isGranted, let text = try? folder.readFile("known_hosts") else { return nil }
        return KnownHosts(parsing: text)
    }

    nonisolated static func adding(_ key: SSHHostKey, host: String, port: Int, to entries: Entries) -> Entries {
        var entries = entries
        entries[entryKey(host: host, port: port), default: [:]][keyType(key.algorithm)] = key.fingerprintSHA256
        return entries
    }
}

/// The app's store: UserDefaults `trustedHostKeys` = `["host:port": ["key type": "SHA256:…"]]`
/// (BackendSchema › AppSettings).
@MainActor
final class UserDefaultsTrustedHostKeys: TrustedHostKeys {
    static let key = "trustedHostKeys"

    private let defaults: UserDefaults
    private let folder: any SSHFolderAccessing

    init(defaults: UserDefaults = .standard, folder: any SSHFolderAccessing) {
        self.defaults = defaults
        self.folder = folder
    }

    private var entries: HostKeyTrust.Entries {
        get { defaults.dictionary(forKey: Self.key) as? HostKeyTrust.Entries ?? [:] }
        set { newValue.isEmpty ? defaults.removeObject(forKey: Self.key) : defaults.set(newValue, forKey: Self.key) }
    }

    func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision {
        HostKeyTrust.decide(key: key, host: host, port: port, knownHosts: HostKeyTrust.knownHosts(in: folder),
                            trusted: entries[HostKeyTrust.entryKey(host: host, port: port)])
    }

    func trust(_ key: SSHHostKey, host: String, port: Int) {
        entries = HostKeyTrust.adding(key, host: host, port: port, to: entries)
    }

    func forget(host: String, port: Int) {
        entries[HostKeyTrust.entryKey(host: host, port: port)] = nil
    }
}

/// The hosted tests and the demo modes: nothing is written to the user's defaults.
@MainActor
final class InMemoryTrustedHostKeys: TrustedHostKeys {
    private(set) var entries: HostKeyTrust.Entries = [:]
    private let folder: any SSHFolderAccessing

    init(folder: any SSHFolderAccessing) {
        self.folder = folder
    }

    func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision {
        HostKeyTrust.decide(key: key, host: host, port: port, knownHosts: HostKeyTrust.knownHosts(in: folder),
                            trusted: entries[HostKeyTrust.entryKey(host: host, port: port)])
    }

    func trust(_ key: SSHHostKey, host: String, port: Int) {
        entries = HostKeyTrust.adding(key, host: host, port: port, to: entries)
    }

    func forget(host: String, port: Int) {
        entries[HostKeyTrust.entryKey(host: host, port: port)] = nil
    }
}
