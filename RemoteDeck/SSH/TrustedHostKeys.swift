import Foundation
import RemoteDeckCore
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

/// Why `~/.ssh/known_hosts` could not be consulted for the last decision (not set when there is no
/// grant at all, or the folder has no `known_hosts` file: both are normal).
enum KnownHostsProblem: Equatable, Sendable {
    /// A grant was made on this Mac but its bookmark no longer resolves: "~/.ssh access lost"
    /// (grant the folder again). A stale bookmark is re-created, never reported.
    case accessLost
    /// The folder is granted but `known_hosts` exists and cannot be read (permissions, not UTF-8,
    /// larger than `SSHFolderAccess.maxFileSize`).
    case unreadable
}

/// RemoteDeck's own trusted host keys, local to this Mac (never synced: trust is a per-Mac
/// judgement, as `PublicAddressConsents`), plus a read-only look at `~/.ssh/known_hosts` when the
/// folder is granted.
///
/// A key `known_hosts` matches is also pinned in the own list, so the host stays trusted (and a
/// different key of the same type is `.changed`) if the `~/.ssh` grant is later lost.
@MainActor
protocol TrustedHostKeys: AnyObject {
    func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision
    /// The user accepted an unknown key (never called for a changed one).
    func trust(_ key: SSHHostKey, host: String, port: Int)
    /// The machine was deleted, or "Remove from RemoteDeck's trusted keys…".
    func forget(host: String, port: Int)
    /// RemoteDeck's own list has a key for this `host:port` (what "Remove from RemoteDeck's trusted
    /// keys…" removes; `~/.ssh/known_hosts` is never consulted nor changed).
    func hasTrustedKeys(host: String, port: Int) -> Bool
    /// Forgets every `host:port` none of `machines` (the whole library) uses: the post-import sweep
    /// of a machine deleted, merged or moved on another Mac, and of the unowned entry a Test of an
    /// unsaved address left (`LibraryMerger.sweepOrphanedSSHState`).
    func forgetEntries(unusedBy machines: [Machine])
    /// Set by each `decision`: why `known_hosts` was not consulted, nil when it was or when there
    /// is no grant to consult.
    var lastKnownHostsProblem: KnownHostsProblem? { get }
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

    /// `known_hosts` first (when given): a match is trusted (`fromKnownHosts`: pin it), a mismatch
    /// (or a revoked key) is changed; not found there, the own list: same type and fingerprint →
    /// trusted, same type and another fingerprint → changed, otherwise unknown (a host known only
    /// under another key type asks).
    nonisolated static func decide(key: SSHHostKey, host: String, port: Int, knownHosts: KnownHosts?,
                                   trusted: [String: String]?) -> (decision: HostKeyDecision, fromKnownHosts: Bool) {
        if let knownHosts {
            switch knownHosts.lookup(host: normalized(host), port: port, key: key) {
            case .match: return (.trusted, true)
            case .mismatch: return (.changed(previousFingerprint: HostKeyDecision.knownHostsConflict), false)
            case .notFound: break
            }
        }
        guard let fingerprint = trusted?[keyType(key.algorithm)] else { return (.unknown, false) }
        return (fingerprint == key.fingerprintSHA256 ? .trusted : .changed(previousFingerprint: fingerprint), false)
    }

    /// `~/.ssh/known_hosts` and why it could not be read. No grant, or no such file: (nil, nil).
    @MainActor
    static func knownHosts(in folder: any SSHFolderAccessing) -> (KnownHosts?, KnownHostsProblem?) {
        guard folder.isGranted else { return (nil, folder.accessLost ? .accessLost : nil) }
        do {
            return (KnownHosts(parsing: try folder.readFile("known_hosts")), nil)
        } catch SSHFolderError.fileMissing {
            return (nil, nil)
        } catch SSHFolderError.notGranted {
            return (nil, .accessLost)
        } catch {
            return (nil, .unreadable)
        }
    }

    nonisolated static func adding(_ key: SSHHostKey, host: String, port: Int, to entries: Entries) -> Entries {
        var entries = entries
        entries[entryKey(host: host, port: port), default: [:]][keyType(key.algorithm)] = key.fingerprintSHA256
        return entries
    }

    /// Reads the stored list value by value: a malformed entry (another app version, a hand edit) is
    /// dropped alone, never the whole list.
    nonisolated static func entries(from stored: [String: Any]?) -> Entries {
        var entries: Entries = [:]
        for (hostPort, value) in stored ?? [:] {
            guard let byType = value as? [String: Any] else { continue }
            let valid = byType.compactMapValues { $0 as? String }
            if !valid.isEmpty { entries[hostPort] = valid }
        }
        return entries
    }
}

/// The shared behaviour of both stores, over their `entries`.
@MainActor
protocol TrustedHostKeyStore: TrustedHostKeys {
    var folder: any SSHFolderAccessing { get }
    var entries: HostKeyTrust.Entries { get set }
    var lastKnownHostsProblem: KnownHostsProblem? { get set }
}

extension TrustedHostKeyStore {
    func decision(for key: SSHHostKey, host: String, port: Int) -> HostKeyDecision {
        let (knownHosts, problem) = HostKeyTrust.knownHosts(in: folder)
        lastKnownHostsProblem = problem
        let entryKey = HostKeyTrust.entryKey(host: host, port: port)
        let (decision, fromKnownHosts) = HostKeyTrust.decide(key: key, host: host, port: port,
                                                            knownHosts: knownHosts, trusted: entries[entryKey])
        // Pinned once (no write when already there).
        if fromKnownHosts, entries[entryKey]?[HostKeyTrust.keyType(key.algorithm)] != key.fingerprintSHA256 {
            trust(key, host: host, port: port)
        }
        return decision
    }

    func trust(_ key: SSHHostKey, host: String, port: Int) {
        entries = HostKeyTrust.adding(key, host: host, port: port, to: entries)
    }

    func forget(host: String, port: Int) {
        entries[HostKeyTrust.entryKey(host: host, port: port)] = nil
    }

    func hasTrustedKeys(host: String, port: Int) -> Bool {
        entries[HostKeyTrust.entryKey(host: host, port: port)]?.isEmpty == false
    }

    func forgetEntries(unusedBy machines: [Machine]) {
        let used = Set(machines.map { HostKeyTrust.entryKey(host: $0.host, port: $0.port) })
        let kept = entries.filter { used.contains($0.key) }
        if kept.count != entries.count { entries = kept }
    }
}

extension TrustedHostKeys {
    /// Forgets `host:port` unless one of `others` (the machines that remain, or the other machines
    /// of the library) still has it, a synced duplicate not merged yet for instance: the machine was
    /// deleted, or its host or port edited.
    func forget(host: String, port: Int, unlessUsedBy others: [Machine]) {
        let entryKey = HostKeyTrust.entryKey(host: host, port: port)
        guard !others.contains(where: { HostKeyTrust.entryKey(host: $0.host, port: $0.port) == entryKey }) else { return }
        forget(host: host, port: port)
    }
}

/// The app's store: UserDefaults `trustedHostKeys` = `["host:port": ["key type": "SHA256:…"]]`
/// (BackendSchema › AppSettings).
@MainActor
final class UserDefaultsTrustedHostKeys: TrustedHostKeyStore {
    static let key = "trustedHostKeys"

    private let defaults: UserDefaults
    let folder: any SSHFolderAccessing
    var lastKnownHostsProblem: KnownHostsProblem?

    init(defaults: UserDefaults = .standard, folder: any SSHFolderAccessing) {
        self.defaults = defaults
        self.folder = folder
    }

    var entries: HostKeyTrust.Entries {
        get { HostKeyTrust.entries(from: defaults.dictionary(forKey: Self.key)) }
        set { newValue.isEmpty ? defaults.removeObject(forKey: Self.key) : defaults.set(newValue, forKey: Self.key) }
    }
}

/// The hosted tests and the demo modes: nothing is written to the user's defaults.
@MainActor
final class InMemoryTrustedHostKeys: TrustedHostKeyStore {
    var entries: HostKeyTrust.Entries = [:]
    let folder: any SSHFolderAccessing
    var lastKnownHostsProblem: KnownHostsProblem?

    init(folder: any SSHFolderAccessing) {
        self.folder = folder
    }
}
