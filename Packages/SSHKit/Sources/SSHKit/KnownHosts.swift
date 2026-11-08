import Crypto
import Foundation

/// What a `known_hosts` file says about a server's host key.
public enum KnownHostsMatch: Equatable, Sendable {
    /// A line for this host lists exactly this key.
    case match
    /// A line for this host lists a different key of the same key type: the key changed.
    case mismatch
    /// No line for this host lists a key of this key type (the host may be known under another one).
    case notFound
}

/// A parsed OpenSSH `known_hosts` file (pure: no file access).
///
/// Supported: plain names (case-insensitive), `[host]:port`, comma lists, and hashed entries
/// (`|1|salt|hash`, HMAC-SHA1). Not supported, so never matching: wildcard or negated patterns
/// (`*`, `?`, `!`) and the `@revoked` / `@cert-authority` markers. Malformed lines are skipped.
public struct KnownHosts: Sendable {
    private enum HostPattern: Sendable {
        case plain(String)
        case hashed(salt: Data, hash: Data)
    }

    private struct Entry: Sendable {
        let patterns: [HostPattern]
        let key: SSHHostKey
    }

    private let entries: [Entry]

    public init(parsing text: String) {
        var entries: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@"),
                  let key = try? SSHHostKey(openSSHPublicKey: "\(fields[1]) \(fields[2])")
            else { continue }
            var patterns: [HostPattern] = []
            for item in fields[0].split(separator: ",") {
                if item.hasPrefix("|1|") {
                    let parts = item.split(separator: "|", omittingEmptySubsequences: false)
                    if parts.count == 4, let salt = Data(base64Encoded: String(parts[2])),
                       let hash = Data(base64Encoded: String(parts[3])) {
                        patterns.append(.hashed(salt: salt, hash: hash))
                    }
                } else if !item.contains(where: { "*?!".contains($0) }) {
                    patterns.append(.plain(item.lowercased()))
                }
            }
            if !patterns.isEmpty { entries.append(Entry(patterns: patterns, key: key)) }
        }
        self.entries = entries
    }

    public func lookup(host: String, port: Int, key: SSHHostKey) -> KnownHostsMatch {
        let name = port == 22 ? host : "[\(host)]:\(port)"
        let lowered = name.lowercased()
        let family = Self.keyType(key.algorithm)
        var result = KnownHostsMatch.notFound
        for entry in entries where entry.patterns.contains(where: { Self.matches($0, name: name, lowered: lowered) }) {
            if entry.key.blob == key.blob && Self.keyType(entry.key.algorithm) == family { return .match }
            if Self.keyType(entry.key.algorithm) == family { result = .mismatch }
        }
        return result
    }

    private static func matches(_ pattern: HostPattern, name: String, lowered: String) -> Bool {
        switch pattern {
        case .plain(let value):
            return value == lowered
        case .hashed(let salt, let hash):
            // OpenSSH hashes the host as written, lowercased.
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(lowered.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
    }

    /// `known_hosts` stores RSA keys as `ssh-rsa`, while a server may sign with `rsa-sha2-*`.
    private static func keyType(_ algorithm: String) -> String {
        algorithm == "rsa-sha2-256" || algorithm == "rsa-sha2-512" ? "ssh-rsa" : algorithm
    }
}
