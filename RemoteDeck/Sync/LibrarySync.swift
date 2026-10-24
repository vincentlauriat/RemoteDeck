import AppKit
import CloudKit
import CoreData
import Foundation
import Observation
import Security
import SwiftData
import RemoteDeckCore

// MARK: - iCloud account

/// The iCloud account as CloudKit sees it (`CKAccountStatus`), shown in Settings › iCloud Sync.
enum CloudAccountStatus: Equatable, Sendable {
    case available
    /// No iCloud account on this Mac: "Sign in to iCloud to sync your library".
    case noAccount
    /// Parental controls or a device management profile forbid iCloud for this app.
    case restricted
    /// Signed in, but iCloud cannot be used right now (e.g. the account needs attention in System
    /// Settings).
    case temporarilyUnavailable
    /// CloudKit could not tell (no network to cloudd, or an error).
    case couldNotDetermine

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        default: self = .couldNotDetermine
        }
    }
}

/// Reads the account status. Injectable: the hosted tests and the demo never construct a
/// `CKContainer` (it traps in a process not entitled to the container).
protocol CloudAccountStatusProviding: Sendable {
    func accountStatus() async -> CloudAccountStatus
}

/// The real status, from the app's one container.
struct CloudKitAccountStatusProvider: CloudAccountStatusProviding {
    let containerIdentifier: String

    func accountStatus() async -> CloudAccountStatus {
        do {
            return CloudAccountStatus(try await CKContainer(identifier: containerIdentifier).accountStatus())
        } catch {
            return .couldNotDetermine
        }
    }
}

/// What the signature of this process allows.
enum CloudSyncEntitlement {
    /// True when the app is signed with the iCloud container (a build from Vincent's team profile).
    /// False under `swift test`, for an ad-hoc or unsigned build (CI): sync then stays off whatever
    /// the setting, since opening a CloudKit store there fails.
    static var isPresent: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String]
        else { return false }
        return containers.contains(RemoteDeckSchema.cloudKitContainerIdentifier)
    }
}

// MARK: - Sync events

/// One CloudKit mirroring event (`NSPersistentCloudKitContainer.Event`), reduced to what the
/// Settings Window and the duplicate merge need. Built from the notification in the app; the tests
/// hand them to `LibrarySync.handle` directly (the Event class has no public initializer).
struct SyncEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case setup, `import`, export }

    let id: UUID
    let kind: Kind
    /// nil while the event runs.
    let endDate: Date?
    let succeeded: Bool
    let errorDescription: String?

    init(id: UUID = UUID(), kind: Kind, endDate: Date?, succeeded: Bool, errorDescription: String? = nil) {
        self.id = id
        self.kind = kind
        self.endDate = endDate
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }

    init?(_ notification: Notification) {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return nil }
        let kind: Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: return nil
        }
        self.init(id: event.identifier, kind: kind, endDate: event.endDate, succeeded: event.succeeded,
                  errorDescription: event.error.map { String(describing: $0) })
    }
}

// MARK: - Model

/// iCloud Sync of the Machine Library (T4.3, TRD › Sync): the account status, what the store
/// opened with, the mirroring activity, and the duplicate merge after each import.
///
/// The Library store gets its CloudKit configuration when it opens, at launch: a change of the
/// setting applies at the next launch (`needsRestart`), the Settings Window says so. Reopening
/// the container live would mean swapping it under the Library, every session, the watch feed,
/// the history and four scenes.
@Observable
@MainActor
final class LibrarySync {
    /// What Settings › iCloud Sync says under the switch (AppFlow › Settings Window, Empty and
    /// blocked states › iCloud signed out). Views map it to `settings.t`.
    enum StatusLine: Equatable {
        /// This build is not signed with the iCloud container (ad-hoc or CI build).
        case notEntitled
        /// Waiting for the first account status.
        case checking
        case signedOut
        case restricted
        case unavailable
        /// The setting is on but the CloudKit store failed to open: the library runs locally.
        case openFailed(String)
        /// The setting changed since launch: quit and reopen to apply.
        case restartToTurnOn
        case restartToTurnOff
        case syncing
        /// The last mirroring event failed.
        case failed(String)
        case synced(Date)
        /// On, no mirroring event yet in this run.
        case on
        /// Off: the library stays on this Mac.
        case off
    }

    /// The Library store opened with CloudKit at this launch.
    let isActive: Bool
    /// The signature carries the iCloud container (`CloudSyncEntitlement`).
    let isEntitled: Bool
    /// Why the store opened without CloudKit although the setting was on (the CloudKit store
    /// failed to open; the library then runs on its local store).
    let openError: String?
    /// nil until the first answer.
    private(set) var accountStatus: CloudAccountStatus?
    /// A mirroring event is running (setup, import or export).
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private let statusProvider: (any CloudAccountStatusProviding)?
    @ObservationIgnored private let merger: LibraryMerger?
    @ObservationIgnored private let onRemoteChange: @MainActor () -> Void
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var running: Set<UUID> = []
    /// A CloudKit setup ended successfully in this run: before that, the store may hold a partial
    /// import, and no merge runs.
    @ObservationIgnored private var isSetUp = false
    /// An import ended while another event still ran: merge once they are all done.
    @ObservationIgnored private var mergePending = false
    @ObservationIgnored private var statusGeneration = 0

    /// `statusProvider` nil: the status is never asked (hosted tests, demo modes, unentitled
    /// builds). `merger` nil: no duplicate merge (sync off, or a library in memory).
    init(isActive: Bool, isEntitled: Bool, openError: String? = nil,
         statusProvider: (any CloudAccountStatusProviding)?,
         merger: LibraryMerger?, onRemoteChange: @escaping @MainActor () -> Void = {},
         center: NotificationCenter = .default) {
        self.isActive = isActive
        self.isEntitled = isEntitled
        self.openError = openError
        self.statusProvider = statusProvider
        self.merger = merger
        self.onRemoteChange = onRemoteChange
        self.center = center
    }

    /// The setting differs from what the store opened with: quit and reopen to apply.
    func needsRestart(enabled: Bool) -> Bool { enabled != isActive }

    /// Turning the switch on needs a signed-in iCloud account (AppFlow › Toggle iCloud Sync);
    /// turning it off is always possible.
    var canTurnOn: Bool { isEntitled && accountStatus == .available }

    func statusLine(enabled: Bool) -> StatusLine {
        guard isEntitled else { return .notEntitled }
        switch accountStatus {
        case nil: return isActive ? activityLine : .checking
        case .noAccount: return .signedOut
        case .restricted: return .restricted
        case .temporarilyUnavailable, .couldNotDetermine: return .unavailable
        case .available: break
        }
        if enabled, !isActive, let openError { return .openFailed(openError) }
        if needsRestart(enabled: enabled) { return enabled ? .restartToTurnOn : .restartToTurnOff }
        return isActive ? activityLine : .off
    }

    private var activityLine: StatusLine {
        if isSyncing { return .syncing }
        if let lastError { return .failed(lastError) }
        if let lastSyncedAt { return .synced(lastSyncedAt) }
        return .on
    }

    /// Observes account changes and, when the store syncs, mirroring events. No merge here: the
    /// first one waits for CloudKit's setup and runs after an import, never while one runs.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccountStatus() }
        })
        if isActive {
            observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                object: nil, queue: .main) { [weak self] notification in
                let event = SyncEvent(notification)
                MainActor.assumeIsolated {
                    if let event { self?.handle(event) }
                }
            })
            // Back to the app after a while: merge what the background imports brought.
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mergeIfIdle() }
            })
        }
        refreshAccountStatus()
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func refreshAccountStatus() {
        guard let statusProvider else { return }
        statusGeneration += 1
        let generation = statusGeneration
        Task { [weak self] in
            let status = await statusProvider.accountStatus()
            guard let self, generation == self.statusGeneration else { return }
            self.accountStatus = status
        }
    }

    /// A mirroring event started or ended. An import that ended (successfully or not: a failed
    /// batch may still have saved some records) runs the merge and refreshes the watch feed.
    func handle(_ event: SyncEvent) {
        if event.endDate == nil {
            running.insert(event.id)
        } else {
            running.remove(event.id)
            if event.succeeded {
                lastSyncedAt = event.endDate
                lastError = nil
            } else {
                lastError = event.errorDescription
            }
            // A finished import also proves the setup ran (its own event may predate `start`).
            if event.succeeded, event.kind != .export { isSetUp = true }
            if event.kind == .import { mergePending = true }
        }
        isSyncing = !running.isEmpty
        if mergePending { mergeIfIdle() }
    }

    /// Merges (and refreshes the watch feed) only after setup and while no mirroring event runs:
    /// a half-imported batch could show one copy of a pair whose other half has not landed yet.
    private func mergeIfIdle() {
        guard isSetUp, running.isEmpty else { return }
        mergePending = false
        merger?.mergeDuplicates()
        onRemoteChange()
    }
}

// MARK: - Duplicate merge

/// Applies `LibraryDeduplication` to the store (BackendSchema › Data validation): duplicate groups
/// fold into one (their machines move), then duplicate machines (same lowercase `host:port`) fold
/// into the first created, which takes the fields of the most recently modified copy.
///
/// Passwords: the survivor keeps its own; if it has none on this Mac, the dropped machine's is
/// copied to it and read back. The dropped machines' items are deleted only after the model is
/// saved (a failed save deletes nothing; an item orphaned by a later failure is harmless). A machine
/// whose password cannot be read without a dialog, whose copy fails, or that has an open session on
/// this Mac is left for a later merge.
@MainActor
final class LibraryMerger {
    private let context: ModelContext
    private let passwords: any MachinePasswordStore
    private let hasSession: @MainActor (UUID) -> Bool

    init(context: ModelContext, passwords: any MachinePasswordStore,
         hasSession: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
        self.context = context
        self.passwords = passwords
        self.hasSession = hasSession
    }

    /// Returns the ids of the machines removed. Saves once, only when something changed.
    @discardableResult
    func mergeDuplicates() -> [UUID] {
        guard let machines = try? context.fetch(FetchDescriptor<Machine>()),
              let groups = try? context.fetch(FetchDescriptor<MachineGroup>()) else { return [] }
        var changed = false

        let groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for merge in LibraryDeduplication.groupMerges(groups.map(LibraryDeduplication.GroupFacts.init)) {
            guard let survivor = groupsByID[merge.survivor] else { continue }
            for id in merge.dropped {
                guard let dropped = groupsByID[id] else { continue }
                for machine in dropped.machines ?? [] { machine.group = survivor }
                context.delete(dropped)
                changed = true
            }
        }

        var removed: [UUID] = []
        var passwordsToDelete: [UUID] = []
        let machinesByID = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for merge in LibraryDeduplication.machineMerges(machines.map(LibraryDeduplication.MachineFacts.init)) {
            guard let survivor = machinesByID[merge.survivor] else { continue }
            for id in merge.dropped {
                guard let dropped = machinesByID[id], !hasSession(id),
                      let deletesPassword = foldPassword(of: id, into: merge.survivor) else { continue }
                // Only from a copy that goes now: a kept duplicate keeps its own fields.
                if id == merge.fieldsFrom { Self.copyFields(from: dropped, to: survivor) }
                survivor.lastConnectedAt = [survivor.lastConnectedAt, dropped.lastConnectedAt].compactMap { $0 }.max()
                context.delete(dropped)
                removed.append(id)
                if deletesPassword { passwordsToDelete.append(id) }
                changed = true
            }
        }

        guard changed else { return [] }
        do {
            try context.save()
        } catch {
            context.rollback()
            return []
        }
        for id in passwordsToDelete { try? passwords.deletePassword(for: id) }
        return removed
    }

    /// The user-visible fields of the most recently edited copy (its host and port share the key).
    private static func copyFields(from source: Machine, to target: Machine) {
        target.name = source.name
        target.kind = source.kind
        target.host = source.host
        target.port = source.port
        target.username = source.username
        target.group = source.group
        target.isFavorite = source.isFavorite
        target.isWatched = source.isWatched
        target.scalingMode = source.scalingMode
        target.sharedClipboard = source.sharedClipboard
        target.modifiedAt = source.modifiedAt
    }

    /// nil: keep the dropped machine for now. Otherwise it may go, and `true` says it has a password
    /// item to delete once the model is saved (the survivor already had one, or now has a copy that
    /// read back).
    private func foldPassword(of dropped: UUID, into survivor: UUID) -> Bool? {
        let kept: (password: String, scope: PasswordScope)?
        let leaving: (password: String, scope: PasswordScope)?
        do {
            kept = try passwords.storedPassword(for: survivor, allowsInteraction: false)
            leaving = try passwords.storedPassword(for: dropped, allowsInteraction: false)
        } catch {
            return nil
        }
        if kept == nil, let leaving {
            guard (try? passwords.storePassword(leaving.password, for: survivor)) != nil,
                  (try? passwords.storedPassword(for: survivor, allowsInteraction: false))?.password == leaving.password
            else { return nil }
        }
        return leaving != nil
    }
}
