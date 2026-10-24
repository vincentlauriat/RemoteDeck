import Foundation
import Security
import SwiftData
import RemoteDeckCore
import RFBKit

// MARK: - Machine passwords

/// Where a machine password is kept: the synchronizable item (iCloud Keychain), or the local
/// fallback used while the build lacks the iCloud Keychain entitlement (-34018).
enum PasswordScope: Equatable, Sendable {
    case synced
    case local

    var isSynchronizable: Bool { self == .synced }
}

/// Keychain primitives for machine passwords (account `machine.<id>`, BackendSchema ›
/// KeychainCredential), one item per scope. The fallback and migration rules live in the
/// extension below, so tests drive them with a fake.
@MainActor
protocol MachinePasswordStore {
    func password(for machineID: UUID, scope: PasswordScope) throws(KeychainError) -> String?
    /// `allowsInteraction` false: never a system dialog; a read that needs one fails instead
    /// (`errSecInteractionNotAllowed`). Stores without any UI ignore it.
    func password(for machineID: UUID, scope: PasswordScope, allowsInteraction: Bool) throws(KeychainError) -> String?
    func setPassword(_ password: String, for machineID: UUID, scope: PasswordScope) throws(KeychainError)
    func deletePassword(for machineID: UUID, scope: PasswordScope) throws(KeychainError)
    /// Deletes both scopes.
    func deletePassword(for machineID: UUID) throws(KeychainError)
}

extension MachinePasswordStore {
    func password(for machineID: UUID, scope: PasswordScope, allowsInteraction: Bool) throws(KeychainError) -> String? {
        try password(for: machineID, scope: scope)
    }

    /// The synced password, else the local one. A synced read refused with -34018 counts as
    /// "no synced item".
    func storedPassword(for machineID: UUID,
                        allowsInteraction: Bool = true) throws(KeychainError) -> (password: String, scope: PasswordScope)? {
        do throws(KeychainError) {
            if let synced = try password(for: machineID, scope: .synced, allowsInteraction: allowsInteraction) {
                return (synced, .synced)
            }
        } catch {
            // No entitlement: only the local fallback can exist.
            guard error.status == errSecMissingEntitlement else { throw error }
        }
        return try password(for: machineID, scope: .local, allowsInteraction: allowsInteraction).map { ($0, .local) }
    }

    /// Saves to iCloud Keychain; on -34018 saves a local item instead (Vincent, 2026-10-22).
    /// After a synced save, a stale local copy is removed.
    @discardableResult
    func storePassword(_ password: String, for machineID: UUID) throws(KeychainError) -> PasswordScope {
        do throws(KeychainError) {
            try setPassword(password, for: machineID, scope: .synced)
        } catch {
            guard error.status == errSecMissingEntitlement else { throw error }
            try setPassword(password, for: machineID, scope: .local)
            return .local
        }
        try? deletePassword(for: machineID, scope: .local)
        return .synced
    }

    /// T4.3: moves local passwords (the -34018 fallback of an unentitled build) to iCloud Keychain,
    /// with the rules of `LocalPasswordMigration` (read back before any delete; an existing synced
    /// item wins).
    @discardableResult
    func migrateLocalPasswordsToSynced(machineIDs: [UUID]) -> [UUID] {
        LocalPasswordMigration.migrate(
            machineIDs,
            readLocal: { id throws(KeychainError) in try password(for: id, scope: .local) },
            readSynced: { id throws(KeychainError) in try password(for: id, scope: .synced) },
            writeSynced: { secret, id throws(KeychainError) in try setPassword(secret, for: id, scope: .synced) },
            deleteLocal: { id throws(KeychainError) in try deletePassword(for: id, scope: .local) })
    }
}

extension KeychainStore: MachinePasswordStore {
    func password(for machineID: UUID, scope: PasswordScope) throws(KeychainError) -> String? {
        try read(.machine(machineID), synchronizable: scope.isSynchronizable)
    }

    func password(for machineID: UUID, scope: PasswordScope, allowsInteraction: Bool) throws(KeychainError) -> String? {
        try read(.machine(machineID), synchronizable: scope.isSynchronizable, allowsInteraction: allowsInteraction)
    }

    func setPassword(_ password: String, for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        try save(password, for: .machine(machineID), synchronizable: scope.isSynchronizable)
    }

    func deletePassword(for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        try delete(.machine(machineID), synchronizable: scope.isSynchronizable)
    }

    func deletePassword(for machineID: UUID) throws(KeychainError) {
        try delete(.machine(machineID))  // kSecAttrSynchronizableAny: both scopes
    }
}

/// Passwords kept in memory only: used whenever the library itself is in memory (store fallback,
/// `-LibraryDemo`, test host), so no Keychain item outlives the machines it belongs to.
@MainActor
final class InMemoryPasswordStore: MachinePasswordStore {
    private var items: [PasswordKey: String] = [:]

    private struct PasswordKey: Hashable {
        let id: UUID
        let scope: PasswordScope
    }

    func password(for machineID: UUID, scope: PasswordScope) throws(KeychainError) -> String? {
        items[PasswordKey(id: machineID, scope: scope)]
    }

    func setPassword(_ password: String, for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        items[PasswordKey(id: machineID, scope: scope)] = password
    }

    func deletePassword(for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        items[PasswordKey(id: machineID, scope: scope)] = nil
    }

    func deletePassword(for machineID: UUID) throws(KeychainError) {
        items[PasswordKey(id: machineID, scope: .synced)] = nil
        items[PasswordKey(id: machineID, scope: .local)] = nil
    }
}

// MARK: - Test connection

/// Opens and closes one RFB connection to check reachability and credentials.
/// Injectable so tests never touch the network.
protocol ConnectionTester: Sendable {
    /// `allowsPublicInternet` false: an address on the public Internet is refused right after TCP,
    /// before any credential (`PublicAddressPolicy`, as for a session; T5.3).
    func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration,
              allowsPublicInternet: Bool) async throws(RFBError)
}

/// The real tester: `RFBConnection.open`, then `close()` at once (it is a test, not a session).
struct RFBConnectionTester: ConnectionTester {
    func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration,
              allowsPublicInternet: Bool) async throws(RFBError) {
        let connection = RFBConnection(host: host, port: port)
        _ = try await connection.open(credentials: credentials, timeout: timeout,
                                      allowsPublicInternet: allowsPublicInternet)
        await connection.close()
    }
}

/// Why a Test connection failed, as shown in the Machine Editor (AppFlow › Machine Editor).
enum TestConnectionFailure: Equatable, Sendable {
    /// Transport error (DNS, TCP refused, no route): "Unreachable".
    case unreachable
    /// No answer before the 5 s deadline: "Unreachable" with the timeout spelled out.
    case timedOut
    /// The server closed the connection during the handshake.
    case connectionClosed
    /// RFB-level refusal before authentication (with the server's reason, if any).
    case refused(reason: String?)
    case authFailed(reason: String?)
    /// None of the offered security types is supported (`apple`: only the newer Apple-only types).
    case unsupportedSecurityType(offered: [UInt8], apple: Bool)
    /// The server wants credentials that were not given (`username`: Apple DH needs a user name too).
    case credentialsRequired(username: Bool)
    case credentialTooLong
    /// A Mac with a user name, and the server did not offer Apple authentication (type 30), or a 3.3
    /// server imposed another type (T5.3 M4): nothing but the version banner was sent.
    case appleAuthenticationMissing(offered: [UInt8])
    /// A password is set and the server offers no password authentication, only none (type 1), or a
    /// 3.3 server imposed type 1 (T5.3): no session without authentication.
    case passwordAuthenticationMissing(offered: [UInt8])
    /// The address is on the public Internet and was not confirmed for this machine and host: the
    /// session asks first; the Machine Editor's Test stops there (no credential sent).
    case publicAddressNotConfirmed
    /// Not an RFB 3.x server (banner shown).
    case notRFBServer(banner: String)
    /// Protocol violation or crypto failure.
    case unexpectedResponse

    /// `nil` for `.cancelled`: a cancelled test goes back to idle, never to an error.
    init?(_ error: RFBError) {
        switch error {
        case .cancelled: return nil
        case .network: self = .unreachable
        case .timeout: self = .timedOut
        case .connectionClosed: self = .connectionClosed
        case .connectionRefused(let reason): self = .refused(reason: reason)
        case .authFailed(let reason): self = .authFailed(reason: reason)
        case .unsupportedSecurityTypes(let types): self = .unsupportedSecurityType(offered: types, apple: false)
        case .unsupportedAppleSecurityTypes(let types): self = .unsupportedSecurityType(offered: types, apple: true)
        case .credentialsRequired(let type): self = .credentialsRequired(username: type == 30)
        case .credentialTooLong: self = .credentialTooLong
        case .requiredSecurityTypeMissing(SecurityType.appleDiffieHellman, let offered):
            self = .appleAuthenticationMissing(offered: offered)
        case .requiredSecurityTypeMissing(_, let offered): self = .passwordAuthenticationMissing(offered: offered)
        case .publicAddressNotAdmitted: self = .publicAddressNotConfirmed
        case .unsupportedVersion(let banner): self = .notRFBServer(banner: banner)
        case .protocolViolation, .cryptoFailure: self = .unexpectedResponse
        }
    }

    /// Localized message (`settings.t` is passed in so the mapping stays testable per language).
    func message(_ t: (String) -> String) -> String {
        /// The server's reason is server-controlled (T5.3 L8): at most 200 scalars on one line, its
        /// invisible scalars (bidi overrides, zero-width, controls) shown as `\u{…}`.
        func withReason(_ key: String, _ reason: String?) -> String {
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                return t(key)
            }
            return "\(t(key)) — \(DisplayText.serverString(reason))"
        }
        switch self {
        case .unreachable: return t("test_unreachable")
        case .timedOut: return t("test_timeout")
        case .connectionClosed: return t("test_closed")
        case .refused(let reason): return withReason("test_refused", reason)
        case .authFailed(let reason): return withReason("test_auth_failed", reason)
        case .unsupportedSecurityType(let offered, let apple):
            let list = offered.map(String.init).joined(separator: ", ")
            return "\(t(apple ? "test_unsupported_apple" : "test_unsupported")) (\(list))"
        case .credentialsRequired(let username):
            return t(username ? "test_needs_username_password" : "test_needs_password")
        case .credentialTooLong: return t("test_credential_too_long")
        case .appleAuthenticationMissing(let offered):
            let list = offered.map(String.init).joined(separator: ", ")
            return list.isEmpty ? t("test_ard_requires_apple_auth") : "\(t("test_ard_requires_apple_auth")) (\(list))"
        case .passwordAuthenticationMissing(let offered):
            let list = offered.map(String.init).joined(separator: ", ")
            return list.isEmpty ? t("test_password_auth_missing") : "\(t("test_password_auth_missing")) (\(list))"
        case .publicAddressNotConfirmed: return t("test_public_not_confirmed")
        case .notRFBServer: return t("test_not_rfb")
        case .unexpectedResponse: return t("test_unexpected")
        }
    }
}

enum TestConnectionState: Equatable, Sendable {
    case idle
    case testing
    case succeeded
    case failed(TestConnectionFailure)
}

// MARK: - Store

/// Opens the app's SwiftData container (two stores; the Library one mirrored to CloudKit when iCloud
/// Sync is on, T4.3).
enum LibraryStore {
    /// What `open` produced.
    struct Opened {
        let container: ModelContainer
        /// In memory: requested, or the on-disk store failed (`error`).
        let isInMemory: Bool
        /// Why the on-disk store could not be opened at all.
        let error: (any Error)?
        /// The Library store mirrors to `cloudKitContainer`.
        let syncsWithICloud: Bool
        /// Why the CloudKit store failed to open, when the local one then opened instead.
        let syncError: (any Error)?
    }

    /// The CloudKit container the Library store opens with: only with the setting on, an on-disk
    /// library, and a signature carrying the container (never under the hosted tests, a demo mode,
    /// an ad-hoc or CI build).
    static func cloudKitContainer(syncEnabled: Bool, isInMemory: Bool, isEntitled: Bool) -> String? {
        syncEnabled && !isInMemory && isEntitled ? RemoteDeckSchema.cloudKitContainerIdentifier : nil
    }

    /// True when the process is an XCTest / Swift Testing host. The hosted `RemoteDeckTests` run
    /// inside the app, whose `App.init` would otherwise open the user's on-disk store.
    static func isRunningTests(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// Opens the on-disk stores, with CloudKit when `cloudKitContainer` is set. If the CloudKit store
    /// fails, the same files open without it (`syncError`: Settings shows "iCloud unavailable"); if
    /// the on-disk store cannot be opened at all, the library runs on an empty in-memory store so the
    /// app stays usable, and the window says so in a persistent banner. `onDisk` (given the CloudKit
    /// container or nil) is injectable so tests can reach both fallbacks.
    static func open(inMemory: Bool, cloudKitContainer: String? = nil,
                     onDisk: (String?) throws -> ModelContainer = { try RemoteDeckSchema.makeContainer(cloudKitContainer: $0) })
        -> Opened {
        guard !inMemory else {
            return Opened(container: inMemoryContainer(), isInMemory: true, error: nil, syncsWithICloud: false, syncError: nil)
        }
        var syncError: (any Error)?
        if let cloudKitContainer {
            do {
                return Opened(container: try onDisk(cloudKitContainer), isInMemory: false, error: nil,
                              syncsWithICloud: true, syncError: nil)
            } catch {
                syncError = error
            }
        }
        do {
            return Opened(container: try onDisk(nil), isInMemory: false, error: nil, syncsWithICloud: false,
                          syncError: syncError)
        } catch {
            return Opened(container: inMemoryContainer(), isInMemory: true, error: error, syncsWithICloud: false,
                          syncError: syncError)
        }
    }

    /// Passwords follow the library: an in-memory library gets an in-memory password store,
    /// otherwise its machines would leave orphaned Keychain items behind. The on-disk library uses
    /// the data-protection keychain when the signature allows it (T4.3).
    static func passwordStore(isInMemory: Bool) -> any MachinePasswordStore {
        isInMemory ? InMemoryPasswordStore() : KeychainStore.app
    }

    private static func inMemoryContainer() -> ModelContainer {
        do {
            return try RemoteDeckSchema.makeContainer(inMemory: true)
        } catch {
            // Only a schema bug can break an in-memory container: nothing to fall back to.
            fatalError("In-memory SwiftData container failed: \(error)")
        }
    }
}

// MARK: - Messages

extension MachineValidator.Reason {
    /// Inline error under a Machine Editor field (BackendSchema › Data validation).
    func message(for field: MachineValidator.Field, _ t: (String) -> String) -> String {
        switch (self, field) {
        case (.empty, .name): return t("err_name_empty")
        case (.empty, .host): return t("err_host_empty")
        case (.empty, .username): return t("err_username_empty")
        case (.empty, .groupName): return t("err_group_empty")
        case (.tooLong(let max), _): return t("err_name_too_long").replacingOccurrences(of: "%d", with: String(max))
        case (.invalidHost, _): return t("err_host_invalid")
        case (.outOfRange, _): return t("err_port")
        case (.duplicate, .groupName): return t("err_group_duplicate")
        case (.duplicate, _): return t("err_duplicate")
        case (.empty, .port): return t("err_port")
        }
    }
}

extension KeychainError {
    /// Inline error under the password field when the Keychain refuses a write or a delete.
    /// (-34018 on save no longer reaches here: it falls back to a local item.)
    func passwordMessage(deleting: Bool, _ t: (String) -> String) -> String {
        t(deleting ? "password_delete_failed" : "password_save_failed")
            .replacingOccurrences(of: "%@", with: String(status))
    }
}

extension KeychainStore {
    /// The Keychain service of this build: Debug (`….remotedeck.dev`) never reads or writes the Release
    /// app's items, which share the keychain access group (T4.3 review).
    static var appService: String {
        #if DEBUG
        KeychainStore.defaultService + ".dev"
        #else
        KeychainStore.defaultService
        #endif
    }

    /// The app's store: the data-protection keychain when this build is signed with a keychain access
    /// group (T4.3), the file keychain otherwise (ad-hoc or CI builds).
    static var app: KeychainStore {
        KeychainStore(service: appService, usesDataProtectionKeychain: KeychainStore.processHasKeychainAccessGroup)
    }

    /// Launch migration of the on-disk app (T4.3), run detached: no read may hold the main actor on a
    /// file-keychain prompt. The API key and local machine passwords an older build left in the file
    /// keychain move to the data-protection keychain, local machine passwords to iCloud Keychain; each
    /// item is deleted only after its new copy is read back. Debug first takes its own machines'
    /// items from the shared service it used before T4.3 (moved: those machines are Debug's), and a
    /// copy of the API key (left in place: it may be the Release app's). Without a keychain access
    /// group (ad-hoc, CI) nothing moves.
    func migrateAtLaunch(machineIDs: [UUID]) {
        guard usesDataProtectionKeychain else { return }
        if service != KeychainStore.defaultService {
            // Data-protection store of the old service: also finds (and deletes) its file-keychain copies.
            let shared = KeychainStore(usesDataProtectionKeychain: true)
            for id in machineIDs { _ = try? adopt(.machine(id), from: shared, removingSource: true) }
            _ = try? adopt(.anthropicAPIKey, from: shared, removingSource: false)
        }
        _ = try? migrateLegacyItem(.anthropicAPIKey)
        _ = migrateLocalMachinePasswordsToSynced(machineIDs)
    }
}
