import Foundation
import LocalAuthentication
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
        try save(secret, for: account, synchronizable: account.isSynchronizable)
    }

    /// Saves with an explicit sync flag. A machine password falls back to a local item
    /// (`synchronizable: false`) when the synced one is refused with -34018 (missing entitlement).
    public func save(_ secret: String, for account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        let data = Data(secret.utf8)
        let status = SecItemAdd(addAttributes(for: account, synchronizable: synchronizable, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(
                query(for: account, synchronizable: synchronizable) as CFDictionary,
                updateAttributes(data: data, synchronizable: synchronizable) as CFDictionary
            ))
        } else {
            try check(status)
        }
    }

    /// The stored secret, or `nil` when there is none.
    public func read(_ account: KeychainAccount) throws(KeychainError) -> String? {
        try read(account, synchronizable: account.isSynchronizable)
    }

    /// Reads the item carrying exactly this sync flag. With `allowsInteraction` false, a read that
    /// would need the user (an authentication dialog) fails with `errSecInteractionNotAllowed`
    /// instead of showing it (an automatic reconnect, T5.1). Per Security's SecItem.h this holds for
    /// Data Protection keychain items (synchronizable ones); a legacy file-keychain item may still
    /// ask.
    public func read(_ account: KeychainAccount, synchronizable: Bool,
                     allowsInteraction: Bool = true) throws(KeychainError) -> String? {
        let lookup = readQuery(for: account, synchronizable: synchronizable, allowsInteraction: allowsInteraction)
        var result: AnyObject?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return secret
    }

    /// Deletes the secret, synced and local copies alike; deleting a missing item succeeds.
    public func delete(_ account: KeychainAccount) throws(KeychainError) {
        try delete(query: deleteQuery(for: account))
    }

    /// Deletes only the item carrying this sync flag (e.g. the local copy once migrated to synced).
    public func delete(_ account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        try delete(query: query(for: account, synchronizable: synchronizable))
    }

    private func delete(query: [String: Any]) throws(KeychainError) {
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    /// `SecItemCopyMatching` query for one item's data.
    func readQuery(for account: KeychainAccount, synchronizable: Bool, allowsInteraction: Bool) -> [String: Any] {
        var lookup = query(for: account, synchronizable: synchronizable)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsInteraction {
            // The non-deprecated form of kSecUseAuthenticationUIFail.
            let context = LAContext()
            context.interactionNotAllowed = true
            lookup[kSecUseAuthenticationContext as String] = context
        }
        return lookup
    }

    /// Attributes identifying an item. Carries `kSecAttrSynchronizable` on every call:
    /// without it, lookups and deletes never match synchronizable items.
    func query(for account: KeychainAccount) -> [String: Any] {
        query(for: account, synchronizable: account.isSynchronizable)
    }

    func query(for account: KeychainAccount, synchronizable: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.name,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
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
        addAttributes(for: account, synchronizable: account.isSynchronizable, data: data)
    }

    func addAttributes(for account: KeychainAccount, synchronizable: Bool, data: Data) -> [String: Any] {
        var attributes = query(for: account, synchronizable: synchronizable)
        attributes.merge(updateAttributes(data: data, synchronizable: synchronizable)) { _, new in new }
        return attributes
    }

    /// Attributes for `SecItemUpdate` when the item already exists (also written on every save, so an
    /// existing item takes the current accessibility at its next save).
    ///
    /// A synchronizable item must be able to leave this Mac (`AfterFirstUnlock`; a `ThisDeviceOnly`
    /// class is refused with it). Local items (the API key, the machine-password fallback) are
    /// `AfterFirstUnlockThisDeviceOnly` (T5.3 L2): never in a backup restored elsewhere. Per
    /// SecItem.h, macOS applies `kSecAttrAccessible` only to synchronizable or data-protection
    /// keychain items, so a local item in the file-based keychain (what an unentitled build gets)
    /// carries it without effect until local items move to the data-protection keychain (T4.3).
    func updateAttributes(data: Data, synchronizable: Bool) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
