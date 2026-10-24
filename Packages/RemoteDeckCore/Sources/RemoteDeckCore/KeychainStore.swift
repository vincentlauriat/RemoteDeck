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
///
/// `usesDataProtectionKeychain` (T4.3, TN3137): local items go to the data-protection keychain,
/// where `kSecAttrAccessible` applies, instead of the legacy file-based keychain. It needs a keychain
/// access group in the signature (`processHasKeychainAccessGroup`), so the app turns it on only
/// then; `swift test` and unsigned builds keep the file keychain. Items an older build left in the
/// file keychain stay readable (a local read falls back to it) until `migrateLegacyItem` or a save
/// moves them; deletes remove both copies.
public struct KeychainStore: Sendable {
    public static let defaultService = "fr.vincentlauriat.remotedeck"

    public let service: String
    public let usesDataProtectionKeychain: Bool

    public init(service: String = KeychainStore.defaultService, usesDataProtectionKeychain: Bool = false) {
        self.service = service
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
    }

    /// True when this process is signed with a keychain access group (the app built with its team's
    /// profile): the data-protection keychain and synchronizable items work. False under `swift test`
    /// and for an ad-hoc or unsigned build.
    public static var processHasKeychainAccessGroup: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        else { return false }
        return (groups as? [String])?.isEmpty == false
    }

    /// Saves `secret` as UTF-8, replacing any existing value.
    public func save(_ secret: String, for account: KeychainAccount) throws(KeychainError) {
        try save(secret, for: account, synchronizable: account.isSynchronizable)
    }

    /// Saves with an explicit sync flag. A machine password falls back to a local item
    /// (`synchronizable: false`) when the synced one is refused with -34018 (missing entitlement).
    /// In the data-protection keychain, a local save also removes the stale file-keychain copy.
    public func save(_ secret: String, for account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        try write(secret, for: account, synchronizable: synchronizable)
        if hasLegacyCopy(synchronizable: synchronizable) {
            try? delete(query: legacyQuery(for: account, synchronizable: synchronizable))
        }
    }

    private func write(_ secret: String, for account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
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

    /// Moves a local item an older build left in the file keychain to the data-protection keychain:
    /// written, read back equal, and only then deleted from the file keychain. Returns whether an item
    /// moved; `false` when there was none (or the store does not use the data-protection keychain).
    /// An item already in the data-protection keychain wins: the file copy is only removed.
    @discardableResult
    public func migrateLegacyItem(_ account: KeychainAccount) throws(KeychainError) -> Bool {
        let synchronizable = false
        guard hasLegacyCopy(synchronizable: synchronizable),
              let legacy = try readItem(legacyReadQuery(for: account, allowsInteraction: false)) else { return false }
        let current = try readItem(readQuery(for: account, synchronizable: synchronizable, allowsInteraction: true))
        if current == nil {
            try write(legacy, for: account, synchronizable: synchronizable)
            let written = try readItem(readQuery(for: account, synchronizable: synchronizable, allowsInteraction: true))
            guard written == legacy else { throw KeychainError(status: errSecDecode) }
        }
        try delete(query: legacyQuery(for: account, synchronizable: synchronizable))
        return true
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
    /// A local item not found in the data-protection keychain is looked up in the file keychain,
    /// where an older build left it. With `allowsInteraction` false that lookup carries the same
    /// non-interactive context; Security documents the context for data-protection items only, so a
    /// file-keychain access prompt may not be suppressed: callers that must never wait on one (the
    /// launch migration) run off the main actor.
    public func read(_ account: KeychainAccount, synchronizable: Bool,
                     allowsInteraction: Bool = true) throws(KeychainError) -> String? {
        let lookup = readQuery(for: account, synchronizable: synchronizable, allowsInteraction: allowsInteraction)
        if let found = try readItem(lookup) { return found }
        guard hasLegacyCopy(synchronizable: synchronizable) else { return nil }
        return try readItem(legacyReadQuery(for: account, allowsInteraction: allowsInteraction))
    }

    private func readItem(_ lookup: [String: Any]) throws(KeychainError) -> String? {
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
        if usesDataProtectionKeychain {
            var legacy = deleteQuery(for: account)
            legacy[kSecUseDataProtectionKeychain as String] = nil
            try delete(query: legacy)
        }
    }

    /// Deletes only the item carrying this sync flag (e.g. the local copy once migrated to synced),
    /// and its file-keychain copy for a local item.
    public func delete(_ account: KeychainAccount, synchronizable: Bool) throws(KeychainError) {
        try delete(query: query(for: account, synchronizable: synchronizable))
        if hasLegacyCopy(synchronizable: synchronizable) {
            try delete(query: legacyQuery(for: account, synchronizable: synchronizable))
        }
    }

    /// Only local items of a data-protection store can have a copy in the file keychain
    /// (synchronizable items always live in the data-protection keychain).
    private func hasLegacyCopy(synchronizable: Bool) -> Bool {
        usesDataProtectionKeychain && !synchronizable
    }

    /// The same local item in the legacy file-based keychain.
    func legacyQuery(for account: KeychainAccount, synchronizable: Bool) -> [String: Any] {
        var legacy = query(for: account, synchronizable: synchronizable)
        legacy[kSecUseDataProtectionKeychain as String] = nil
        return legacy
    }

    func legacyReadQuery(for account: KeychainAccount, allowsInteraction: Bool) -> [String: Any] {
        var lookup = readQuery(for: account, synchronizable: false, allowsInteraction: allowsInteraction)
        lookup[kSecUseDataProtectionKeychain as String] = nil
        return lookup
    }

    /// Launch migration (T4.3), off the main actor: local machine passwords to synced items, with the
    /// rules of `LocalPasswordMigration`; reads never ask.
    public func migrateLocalMachinePasswordsToSynced(_ machineIDs: [UUID]) -> [UUID] {
        LocalPasswordMigration.migrate(
            machineIDs,
            readLocal: { id throws(KeychainError) in try read(.machine(id), synchronizable: false, allowsInteraction: false) },
            readSynced: { id throws(KeychainError) in try read(.machine(id), synchronizable: true, allowsInteraction: false) },
            writeSynced: { secret, id throws(KeychainError) in try save(secret, for: .machine(id), synchronizable: true) },
            deleteLocal: { id throws(KeychainError) in try delete(.machine(id), synchronizable: false) })
    }

    /// Takes `account` from `source` (another service), for each sync flag it may carry, when this
    /// store has no such item: written here, read back equal, then (with `removingSource`) deleted
    /// from `source`. Returns whether anything was taken. Reads never ask.
    @discardableResult
    public func adopt(_ account: KeychainAccount, from source: KeychainStore,
                      removingSource: Bool) throws(KeychainError) -> Bool {
        var adopted = false
        for synchronizable in account.isSynchronizable ? [true, false] : [false] {
            guard let secret = try source.read(account, synchronizable: synchronizable, allowsInteraction: false),
                  try read(account, synchronizable: synchronizable, allowsInteraction: false) == nil else { continue }
            try save(secret, for: account, synchronizable: synchronizable)
            guard try read(account, synchronizable: synchronizable, allowsInteraction: false) == secret else {
                throw KeychainError(status: errSecDecode)
            }
            if removingSource { try source.delete(account, synchronizable: synchronizable) }
            adopted = true
        }
        return adopted
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.name,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        if usesDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
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
    /// carries it without effect; the entitled app uses the data-protection keychain (T4.3).
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

/// Rules of the local → synced password migration (T4.3), shared by the app's launch migration
/// (`KeychainStore`, off the main actor) and the `MachinePasswordStore` rules the hosted tests drive.
/// The local item is deleted only once the synced copy reads back equal; a synced item that already
/// exists wins (it may be a newer password set on another Mac) and the local copy just goes. A
/// machine whose synced read or save fails (no entitlement) keeps its local item. Returns the ids
/// migrated.
public enum LocalPasswordMigration {
    public static func migrate(_ ids: [UUID],
                               readLocal: (UUID) throws(KeychainError) -> String?,
                               readSynced: (UUID) throws(KeychainError) -> String?,
                               writeSynced: (String, UUID) throws(KeychainError) -> Void,
                               deleteLocal: (UUID) throws(KeychainError) -> Void) -> [UUID] {
        ids.filter { id in
            guard let local = try? readLocal(id) else { return false }
            let synced: String?
            do {
                synced = try readSynced(id)
            } catch {
                return false
            }
            if synced == nil {
                guard (try? writeSynced(local, id)) != nil, (try? readSynced(id)) == local else { return false }
            }
            return (try? deleteLocal(id)) != nil
        }
    }
}
