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
    func setPassword(_ password: String, for machineID: UUID, scope: PasswordScope) throws(KeychainError)
    func deletePassword(for machineID: UUID, scope: PasswordScope) throws(KeychainError)
    /// Deletes both scopes.
    func deletePassword(for machineID: UUID) throws(KeychainError)
}

extension MachinePasswordStore {
    /// The synced password, else the local one. A synced read refused with -34018 counts as
    /// "no synced item".
    func storedPassword(for machineID: UUID) throws(KeychainError) -> (password: String, scope: PasswordScope)? {
        do throws(KeychainError) {
            if let synced = try password(for: machineID, scope: .synced) { return (synced, .synced) }
        } catch {
            // No entitlement: only the local fallback can exist.
            guard error.status == errSecMissingEntitlement else { throw error }
        }
        return try password(for: machineID, scope: .local).map { ($0, .local) }
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

    /// T4.3 hook: once the entitlement exists, moves every local password to iCloud Keychain.
    /// Returns the migrated ids; a machine whose synced save still fails keeps its local item.
    @discardableResult
    func migrateLocalPasswordsToSynced(machineIDs: [UUID]) -> [UUID] {
        machineIDs.filter { id in
            guard let local = try? password(for: id, scope: .local) else { return false }
            guard (try? setPassword(local, for: id, scope: .synced)) != nil else { return false }
            try? deletePassword(for: id, scope: .local)
            return true
        }
    }
}

extension KeychainStore: MachinePasswordStore {
    func password(for machineID: UUID, scope: PasswordScope) throws(KeychainError) -> String? {
        try read(.machine(machineID), synchronizable: scope.isSynchronizable)
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
    func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration) async throws(RFBError)
}

/// The real tester: `RFBConnection.open`, then `close()` at once (it is a test, not a session).
struct RFBConnectionTester: ConnectionTester {
    func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
        let connection = RFBConnection(host: host, port: port)
        _ = try await connection.open(credentials: credentials, timeout: timeout)
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
        case .unsupportedVersion(let banner): self = .notRFBServer(banner: banner)
        case .protocolViolation, .cryptoFailure: self = .unexpectedResponse
        }
    }

    /// Localized message (`settings.t` is passed in so the mapping stays testable per language).
    func message(_ t: (String) -> String) -> String {
        func withReason(_ key: String, _ reason: String?) -> String {
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                return t(key)
            }
            return "\(t(key)) — \(reason)"
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

/// Opens the app's SwiftData container (two stores, CloudKit off until T4.3).
enum LibraryStore {
    /// True when the process is an XCTest / Swift Testing host. The hosted `RemoteDeckTests` run
    /// inside the app, whose `App.init` would otherwise open the user's on-disk store.
    static func isRunningTests(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    /// The container, whether it is in memory (requested, or the on-disk store failed), and the
    /// error if the on-disk store could not be opened. In that case the library runs on an empty
    /// in-memory store so the app stays usable, and the window says so in a persistent banner.
    static func open(inMemory: Bool) -> (container: ModelContainer, isInMemory: Bool, error: (any Error)?) {
        if !inMemory {
            do {
                return (try RemoteDeckSchema.makeContainer(), false, nil)
            } catch {
                return (inMemoryContainer(), true, error)
            }
        }
        return (inMemoryContainer(), true, nil)
    }

    /// Passwords follow the library: an in-memory library gets an in-memory password store,
    /// otherwise its machines would leave orphaned Keychain items behind.
    static func passwordStore(isInMemory: Bool) -> any MachinePasswordStore {
        isInMemory ? InMemoryPasswordStore() : KeychainStore()
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
