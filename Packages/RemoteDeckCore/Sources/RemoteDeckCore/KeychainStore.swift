import Foundation
import Security

/// Account of a KeychainCredential (BackendSchema › KeychainCredential).
public enum KeychainAccount: Hashable, Sendable {
    /// A machine password, synced through iCloud Keychain.
    case machine(UUID)
    /// The Anthropic API key, local to this Mac.
    case anthropicAPIKey

    /// Keychain account string: `machine.<uuid>` or `anthropic.apiKey`.
    public var name: String {
        switch self {
        case .machine(let id): "machine.\(id.uuidString)"
        case .anthropicAPIKey: "anthropic.apiKey"
        }
    }

    public var isSynchronizable: Bool {
        switch self {
        case .machine: true
        case .anthropicAPIKey: false
        }
    }
}

/// Generic-password store for secrets. Values are never logged.
///
/// Synchronizable items need a signed process with a keychain entitlement; without it
/// `SecItem*` returns `errSecMissingEntitlement` (-34018), surfaced as `KeychainError`.
public struct KeychainStore: Sendable {
    public static let defaultService = "fr.vincentlauriat.remotedeck"

    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Saves `secret` as UTF-8, replacing any existing value.
    public func save(_ secret: String, for account: KeychainAccount) throws(KeychainError) {
        let data = Data(secret.utf8)
        let status = SecItemAdd(addAttributes(for: account, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(
                query(for: account) as CFDictionary,
                updateAttributes(data: data) as CFDictionary
            ))
        } else {
            try check(status)
        }
    }

    /// The stored secret, or `nil` when there is none.
    public func read(_ account: KeychainAccount) throws(KeychainError) -> String? {
        var lookup = query(for: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return secret
    }

    /// Deletes the secret; deleting a missing item succeeds.
    public func delete(_ account: KeychainAccount) throws(KeychainError) {
        let status = SecItemDelete(deleteQuery(for: account) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    /// Attributes identifying an item. Carries `kSecAttrSynchronizable` on every call:
    /// without it, lookups and deletes never match synchronizable items.
    func query(for account: KeychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.name,
            kSecAttrSynchronizable as String: account.isSynchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }

    /// Matches the item whatever its sync flag, so a stray copy with the other flag goes too.
    func deleteQuery(for account: KeychainAccount) -> [String: Any] {
        var query = query(for: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return query
    }

    /// Attributes for `SecItemAdd`: identity, secret and accessibility.
    func addAttributes(for account: KeychainAccount, data: Data) -> [String: Any] {
        var attributes = query(for: account)
        attributes.merge(updateAttributes(data: data)) { _, new in new }
        return attributes
    }

    /// Attributes for `SecItemUpdate` when the item already exists.
    func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private func check(_ status: OSStatus) throws(KeychainError) {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// A failed Keychain call, carrying its `OSStatus`.
public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
