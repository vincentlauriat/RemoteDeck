import Foundation
import Security
import RemoteDeckCore

/// The Keychain secrets of SSH machines (BackendSchema › KeychainCredential): `sshKey.<id>` (an
/// imported private key) and `sshPassphrase.<id>` (its remembered passphrase), synchronizable;
/// `sshLocalPassphrase.<id>` (the remembered passphrase of a key used in place from `~/.ssh`), local.
/// A machine password stays a `MachinePasswordStore` item. Values are never logged.
@MainActor
protocol SSHSecretStore {
    /// The secret, synced item first then its local fallback; nil when there is none. With
    /// `allowsInteraction` false a read that would need a dialog fails (errSecInteractionNotAllowed).
    func secret(_ account: KeychainAccount, allowsInteraction: Bool) throws(KeychainError) -> String?
    /// Synced items fall back to a local item on -34018 (unentitled build), as machine passwords.
    func setSecret(_ value: String, for account: KeychainAccount) throws(KeychainError)
    /// Both scopes; deleting a missing item succeeds.
    func deleteSecret(_ account: KeychainAccount) throws(KeychainError)
}

/// The per-scope Keychain primitives (`KeychainStore`'s), so the fallback and migration rules can be
/// driven by a fake. Not main-actor: the launch migration runs detached.
protocol ScopedSecretKeychain: Sendable {
    func read(_ account: KeychainAccount, synchronizable: Bool, allowsInteraction: Bool) throws(KeychainError) -> String?
    func save(_ secret: String, for account: KeychainAccount, synchronizable: Bool) throws(KeychainError)
    func delete(_ account: KeychainAccount, synchronizable: Bool) throws(KeychainError)
    /// Every copy, whatever its sync flag.
    func delete(_ account: KeychainAccount) throws(KeychainError)
}

extension KeychainStore: ScopedSecretKeychain {}

/// The app's store (`KeychainStore.app`), with the machine-password rules of `MachinePasswordStore`:
/// a synced read refused with -34018 counts as no synced item; a synced save refused with -34018
/// writes a local item instead, and a synced save removes a stale local copy.
@MainActor
struct KeychainSSHSecretStore: SSHSecretStore {
    let keychain: any ScopedSecretKeychain

    func secret(_ account: KeychainAccount, allowsInteraction: Bool) throws(KeychainError) -> String? {
        if account.isSynchronizable {
            do throws(KeychainError) {
                if let synced = try keychain.read(account, synchronizable: true, allowsInteraction: allowsInteraction) {
                    return synced
                }
            } catch {
                guard error.status == errSecMissingEntitlement else { throw error }
            }
        }
        return try keychain.read(account, synchronizable: false, allowsInteraction: allowsInteraction)
    }

    func setSecret(_ value: String, for account: KeychainAccount) throws(KeychainError) {
        guard account.isSynchronizable else {
            try keychain.save(value, for: account, synchronizable: false)
            return
        }
        do throws(KeychainError) {
            try keychain.save(value, for: account, synchronizable: true)
        } catch {
            guard error.status == errSecMissingEntitlement else { throw error }
            try keychain.save(value, for: account, synchronizable: false)
            return
        }
        try? keychain.delete(account, synchronizable: false)
    }

    func deleteSecret(_ account: KeychainAccount) throws(KeychainError) {
        try keychain.delete(account)
    }
}

/// SSH secrets kept in memory only: whenever the library itself is in memory (store fallback,
/// `-LibraryDemo`, test host), as `InMemoryPasswordStore`.
@MainActor
final class InMemorySSHSecretStore: SSHSecretStore {
    private var items: [KeychainAccount: String] = [:]

    func secret(_ account: KeychainAccount, allowsInteraction: Bool) throws(KeychainError) -> String? {
        items[account]
    }

    func setSecret(_ value: String, for account: KeychainAccount) throws(KeychainError) {
        items[account] = value
    }

    func deleteSecret(_ account: KeychainAccount) throws(KeychainError) {
        items[account] = nil
    }
}

/// Launch migration of SSH secrets (T4.3 rules, `LocalPasswordMigration`): the synchronizable
/// `sshKey.<id>` and `sshPassphrase.<id>` an unentitled build left as local items move to synced
/// items, each deleted only once its synced copy reads back; an existing synced item wins. Reads
/// never ask. `sshLocalPassphrase.<id>` is local by design and never moves.
enum SSHSecretMigration {
    nonisolated static func migrateLocalToSynced(machineIDs: [UUID],
                                                 keychain: some ScopedSecretKeychain) -> [KeychainAccount] {
        let syncedKinds: [(UUID) -> KeychainAccount] = [KeychainAccount.sshPrivateKey, KeychainAccount.sshKeyPassphrase]
        return syncedKinds.flatMap { account in
            LocalPasswordMigration.migrate(
                machineIDs,
                readLocal: { id throws(KeychainError) in
                    try keychain.read(account(id), synchronizable: false, allowsInteraction: false)
                },
                readSynced: { id throws(KeychainError) in
                    try keychain.read(account(id), synchronizable: true, allowsInteraction: false)
                },
                writeSynced: { secret, id throws(KeychainError) in
                    try keychain.save(secret, for: account(id), synchronizable: true)
                },
                deleteLocal: { id throws(KeychainError) in
                    try keychain.delete(account(id), synchronizable: false)
                }
            ).map(account)
        }
    }
}
