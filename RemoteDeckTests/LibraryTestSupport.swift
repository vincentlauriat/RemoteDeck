import Foundation
import Security
import SwiftData
import RemoteDeckCore
import RFBKit
@testable import RemoteDeck

/// In-memory stand-in for the Keychain, one dictionary per scope, with injectable failures.
@MainActor
final class FakePasswordStore: MachinePasswordStore {
    /// Synced (iCloud Keychain) items.
    var items: [UUID: String] = [:]
    /// Local fallback items.
    var localItems: [UUID: String] = [:]
    var readError: KeychainError?
    /// Only the synced read fails (e.g. -34018).
    var syncedReadError: KeychainError?
    var saveError: KeychainError?
    /// Only the synced save fails (e.g. -34018, missing entitlement).
    var syncedSaveError: KeychainError?
    var deleteError: KeychainError?
    private(set) var log: [String] = []

    func password(for machineID: UUID, scope: PasswordScope) throws(KeychainError) -> String? {
        log.append("read.\(scope)")
        if let readError { throw readError }
        if scope == .synced, let syncedReadError { throw syncedReadError }
        return scope == .synced ? items[machineID] : localItems[machineID]
    }

    func setPassword(_ password: String, for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        log.append("save.\(scope)")
        if let saveError { throw saveError }
        if scope == .synced, let syncedSaveError { throw syncedSaveError }
        if scope == .synced { items[machineID] = password } else { localItems[machineID] = password }
    }

    func deletePassword(for machineID: UUID, scope: PasswordScope) throws(KeychainError) {
        log.append("delete.\(scope)")
        if let deleteError { throw deleteError }
        if scope == .synced { items[machineID] = nil } else { localItems[machineID] = nil }
    }

    func deletePassword(for machineID: UUID) throws(KeychainError) {
        log.append("delete")
        if let deleteError { throw deleteError }
        items[machineID] = nil
        localItems[machineID] = nil
    }

    /// Calls that change the store (saves and deletes).
    var writes: [String] { log.filter { !$0.hasPrefix("read") } }
}

/// Records Test connection calls; answers with `result`, or hangs until cancelled.
actor FakeConnectionTester: ConnectionTester {
    struct Call: Sendable {
        let host: String
        let port: UInt16
        let credentials: RFBCredentials
        let timeout: Duration
    }

    private(set) var calls: [Call] = []
    private var result: Result<Void, RFBError>
    private var hangs: Bool
    /// Ignores cancellation and answers `result` after this delay: a result racing a cancel.
    private var lateBy: Duration?

    init(result: Result<Void, RFBError> = .success(()), hangs: Bool = false, lateBy: Duration? = nil) {
        self.result = result
        self.hangs = hangs
        self.lateBy = lateBy
    }

    func set(result: Result<Void, RFBError>, hangs: Bool = false) {
        self.result = result
        self.hangs = hangs
    }

    func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
        calls.append(Call(host: host, port: port, credentials: credentials, timeout: timeout))
        if let lateBy {
            try? await Task.sleep(for: lateBy)
            try result.get()
            return
        }
        if hangs {
            // Like RFBConnection.open: cancellation ends the attempt with `.cancelled`.
            try? await Task.sleep(for: .seconds(30))
            throw .cancelled
        }
        try result.get()
    }
}

@MainActor
func makeTestContext() throws -> ModelContext {
    ModelContext(try RemoteDeckSchema.makeContainer(inMemory: true))
}

/// Polls `condition` on the main actor (up to `timeout`).
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// English strings, so assertions do not depend on the Mac's language.
func english(_ key: String) -> String {
    Strings.table["en"]?[key] ?? key
}

extension KeychainError {
    static let missingEntitlement = KeychainError(status: errSecMissingEntitlement)
    static let interactionNotAllowed = KeychainError(status: errSecInteractionNotAllowed)
}
