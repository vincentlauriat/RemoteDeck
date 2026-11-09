import AppKit
import CloudKit
import Foundation
import SwiftData
import Testing
import RemoteDeckCore
import SSHKit
@testable import RemoteDeck

/// Answers a fixed status and counts the calls; never a `CKContainer`.
private final class FakeAccountStatus: CloudAccountStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: CloudAccountStatus
    private var _calls = 0

    init(_ status: CloudAccountStatus) { _status = status }

    var status: CloudAccountStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func accountStatus() async -> CloudAccountStatus {
        lock.withLock {
            _calls += 1
            return _status
        }
    }
}

private final class SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor
private final class SeenAtSave {
    var value: String?
}

@MainActor
private final class RefreshCounter {
    var value = 0
}

/// Settings › iCloud Sync and the mirroring events (T4.3, AppFlow › Settings Window).
@MainActor
struct LibrarySyncTests {
    let center = NotificationCenter()

    private func sync(active: Bool, entitled: Bool = true, openError: String? = nil,
                      status: FakeAccountStatus? = FakeAccountStatus(.available),
                      merger: LibraryMerger? = nil, onRemoteChange: @escaping @MainActor () -> Void = {}) -> LibrarySync {
        LibrarySync(isActive: active, isEntitled: entitled, openError: openError, statusProvider: status,
                    merger: merger, onRemoteChange: onRemoteChange, center: center)
    }

    private func started(_ sync: LibrarySync) async -> Bool {
        sync.start()
        return await waitUntil { sync.accountStatus != nil }
    }

    @Test func statusLinesFollowTheAccountAndTheLaunch() async {
        let status = FakeAccountStatus(.available)
        let off = sync(active: false, status: status)
        #expect(off.statusLine(enabled: false) == .checking)
        #expect(await started(off))
        #expect(off.statusLine(enabled: false) == .off)
        #expect(off.canTurnOn)
        // Turned on in Settings: the store takes it at the next launch.
        #expect(off.statusLine(enabled: true) == .restartToTurnOn)
        #expect(off.needsRestart(enabled: true))

        let on = sync(active: true, status: status)
        #expect(await started(on))
        #expect(on.statusLine(enabled: true) == .on)
        #expect(on.statusLine(enabled: false) == .restartToTurnOff)
        on.stop()
        off.stop()
    }

    /// AppFlow › Empty and blocked states › iCloud signed out.
    @Test(arguments: [(CloudAccountStatus.noAccount, LibrarySync.StatusLine.signedOut),
                      (.restricted, .restricted), (.temporarilyUnavailable, .unavailable),
                      (.couldNotDetermine, .unavailable)])
    func unavailableAccountsBlockTurningOn(_ account: CloudAccountStatus, _ line: LibrarySync.StatusLine) async {
        let model = sync(active: false, status: FakeAccountStatus(account))
        #expect(await started(model))
        #expect(model.statusLine(enabled: false) == line)
        #expect(model.statusLine(enabled: true) == line)
        #expect(!model.canTurnOn)
        model.stop()
    }

    @Test func unentitledBuildNeverAsksTheAccount() async {
        let model = sync(active: false, entitled: false, status: nil)
        model.start()
        #expect(model.statusLine(enabled: true) == .notEntitled)
        #expect(!model.canTurnOn)
        model.stop()
    }

    @Test func cloudKitStoreThatFailedToOpenIsReported() async {
        let model = sync(active: false, openError: "boom")
        #expect(await started(model))
        #expect(model.statusLine(enabled: true) == .openFailed("boom"))
        #expect(model.statusLine(enabled: false) == .off)
        model.stop()
    }

    @Test func accountChangeRefreshesTheStatus() async {
        let status = FakeAccountStatus(.available)
        let model = sync(active: true, status: status)
        #expect(await started(model))
        status.status = .noAccount
        center.post(name: .CKAccountChanged, object: nil)
        #expect(await waitUntil { model.accountStatus == .noAccount })
        #expect(model.statusLine(enabled: true) == .signedOut)
        model.stop()
    }

    @Test func eventsDriveSyncingLastSyncedAndErrors() async {
        let model = sync(active: true)
        #expect(await started(model))
        let importID = UUID()
        let exportID = UUID()
        model.handle(SyncEvent(id: importID, kind: .import, endDate: nil, succeeded: false))
        model.handle(SyncEvent(id: exportID, kind: .export, endDate: nil, succeeded: false))
        #expect(model.statusLine(enabled: true) == .syncing)
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        model.handle(SyncEvent(id: importID, kind: .import, endDate: end, succeeded: true))
        #expect(model.isSyncing)   // the export still runs
        model.handle(SyncEvent(id: exportID, kind: .export, endDate: end, succeeded: true))
        #expect(model.statusLine(enabled: true) == .synced(end))

        model.handle(SyncEvent(kind: .export, endDate: end, succeeded: false, errorDescription: "quota"))
        #expect(model.statusLine(enabled: true) == .failed("quota"))
        model.handle(SyncEvent(kind: .import, endDate: end.addingTimeInterval(60), succeeded: true))
        #expect(model.statusLine(enabled: true) == .synced(end.addingTimeInterval(60)))
        model.stop()
    }

    /// The merge runs after an import that ended (not after exports), never at start, never before
    /// CloudKit's setup, never while another event runs; the watch feed is refreshed with it (imports
    /// post no `ModelContext.didSave`).
    @Test func importsRunTheMergeAndRefreshTheWatchFeed() async throws {
        let context = try makeTestContext()
        let first = Machine(name: "A", host: "mini.local", createdAt: Date(timeIntervalSince1970: 1))
        context.insert(first)
        context.insert(Machine(name: "A (other Mac)", host: "MINI.local", createdAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        let refreshes = RefreshCounter()
        let model = sync(active: true, merger: LibraryMerger(context: context, passwords: FakePasswordStore()),
                         onRemoteChange: { refreshes.value += 1 })
        #expect(await started(model))
        #expect(refreshes.value == 0)   // no pass at start
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(refreshes.value == 0)   // nor before setup
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 2)

        let setup = UUID()
        model.handle(SyncEvent(id: setup, kind: .setup, endDate: nil, succeeded: false))
        model.handle(SyncEvent(id: setup, kind: .setup, endDate: .now, succeeded: true))
        model.handle(SyncEvent(kind: .export, endDate: .now, succeeded: true))
        #expect(refreshes.value == 0)

        // An import ends while an export still runs: the merge waits for it.
        let export = UUID()
        model.handle(SyncEvent(id: export, kind: .export, endDate: nil, succeeded: false))
        model.handle(SyncEvent(kind: .import, endDate: .now, succeeded: true))
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 2)
        #expect(refreshes.value == 0)
        model.handle(SyncEvent(id: export, kind: .export, endDate: .now, succeeded: true))
        #expect(try context.fetch(FetchDescriptor<Machine>()).map(\.id) == [first.id])
        #expect(refreshes.value == 1)

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(refreshes.value == 2)
        model.stop()
    }

    /// A finished import also counts as setup (the setup event may have fired before `start`).
    @Test func importWithoutASeenSetupStillMerges() async throws {
        let context = try makeTestContext()
        context.insert(Machine(name: "A", host: "mini.local"))
        context.insert(Machine(name: "B", host: "mini.local"))
        try context.save()
        let model = sync(active: true, merger: LibraryMerger(context: context, passwords: FakePasswordStore()))
        #expect(await started(model))
        model.handle(SyncEvent(kind: .import, endDate: .now, succeeded: true))
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 1)
        model.stop()
    }

    @Test func inactiveSyncNeverMerges() async throws {
        let context = try makeTestContext()
        context.insert(Machine(name: "A", host: "mini.local"))
        context.insert(Machine(name: "B", host: "mini.local"))
        try context.save()
        let refreshes = RefreshCounter()
        let model = sync(active: false, merger: LibraryMerger(context: context, passwords: FakePasswordStore()),
                         onRemoteChange: { refreshes.value += 1 })
        #expect(await started(model))
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(try context.fetchCount(FetchDescriptor<Machine>()) == 2)
        #expect(refreshes.value == 0)
        model.stop()
    }
}

/// The duplicate merge applied to the store (BackendSchema › Data validation, T4.3).
@MainActor
struct LibraryMergerTests {
    let context: ModelContext
    let passwords = FakePasswordStore()
    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        context = try makeTestContext()
    }

    private func machine(_ name: String, host: String = "mini.local", modified: Date?) throws -> Machine {
        let machine = Machine(name: name, host: host, modifiedAt: modified)
        context.insert(machine)
        try context.save()
        return machine
    }

    private func names() throws -> [String] {
        try context.fetch(FetchDescriptor<Machine>()).map(\.name).sorted()
    }

    private func machine(_ name: String, host: String = "mini.local", created: Date, modified: Date?) throws -> Machine {
        let machine = Machine(name: name, host: host, createdAt: created, modifiedAt: modified)
        context.insert(machine)
        try context.save()
        return machine
    }

    /// The first created stays (review H1) and takes the newest copy's fields; each keeps its own
    /// password rule: the survivor's password stays, the dropped one's goes.
    @Test func firstCreatedSurvivesWithTheNewestFields() throws {
        let first = try machine("Old name", created: early, modified: early)
        let newer = try machine("New name", host: "Mini.Local", created: late, modified: late)
        newer.isFavorite = true
        newer.username = "vincent"
        _ = try machine("Other", host: "nas.local", modified: nil)
        try context.save()
        passwords.items[first.id] = "first-pw"
        passwords.items[newer.id] = "newer-pw"
        let newerID = newer.id

        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates() == [newerID])
        #expect(try names() == ["New name", "Other"])
        #expect(first.isFavorite && first.username == "vincent" && first.host == "Mini.Local")
        #expect(first.modifiedAt == late)
        #expect(passwords.items[first.id] == "first-pw")
        #expect(passwords.items[newerID] == nil)
    }

    /// Review M4: the dropped password goes only after the model is saved.
    @Test func droppedPasswordIsDeletedAfterTheSave() throws {
        let first = try machine("A", created: early, modified: nil)
        let second = try machine("B", created: late, modified: nil)
        passwords.items[first.id] = "a"
        passwords.items[second.id] = "b"
        let secondID = second.id
        let store = passwords
        let seenAtSave = SeenAtSave()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context,
                                                              queue: nil) { _ in
            MainActor.assumeIsolated { seenAtSave.value = store.items[secondID] }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates() == [secondID])
        #expect(seenAtSave.value == "b")
        #expect(passwords.items[secondID] == nil)
    }

    @Test func survivorWithoutPasswordTakesTheDroppedOne() throws {
        let first = try machine("First", created: early, modified: nil)
        let later = try machine("Later", created: late, modified: nil)
        passwords.localItems[later.id] = "only-here"
        let laterID = later.id

        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates() == [laterID])
        #expect(passwords.items[first.id] == "only-here")
        #expect(passwords.items[laterID] == nil && passwords.localItems[laterID] == nil)
        // Read without any dialog: a merge never prompts.
        #expect(!passwords.log.contains { $0.hasPrefix("read") && !$0.hasSuffix(".noUI") })
    }

    @Test func copyThatDoesNotReadBackKeepsTheDuplicate() throws {
        _ = try machine("New", created: early, modified: nil)
        let old = try machine("Old", created: late, modified: nil)
        passwords.items[old.id] = "pw"
        passwords.dropsSyncedWrites = true

        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates().isEmpty)
        #expect(try names() == ["New", "Old"])
        #expect(passwords.items[old.id] == "pw")
    }

    @Test func unreadablePasswordsKeepTheDuplicateForLater() throws {
        _ = try machine("Old", modified: early)
        _ = try machine("New", modified: late)
        passwords.interactionRequiredError = .interactionNotAllowed

        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates().isEmpty)
        #expect(try names() == ["New", "Old"])
        #expect(passwords.writes.isEmpty)
    }

    @Test func machineWithAnOpenSessionIsNotDropped() throws {
        _ = try machine("New", created: early, modified: nil)
        let old = try machine("Old", created: late, modified: nil)
        let oldID = old.id
        let merger = LibraryMerger(context: context, passwords: passwords, hasSession: { $0 == oldID })
        #expect(merger.mergeDuplicates().isEmpty)
        #expect(try names() == ["New", "Old"])
    }

    @Test func duplicateGroupsFoldIntoOneWithTheirMachines() throws {
        let lab = MachineGroup(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Lab", sortOrder: 4)
        let other = MachineGroup(id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!, name: " lab", sortOrder: 1)
        context.insert(lab)
        context.insert(other)
        let a = try machine("A", host: "a.local", modified: nil)
        let b = try machine("B", host: "b.local", modified: nil)
        a.group = lab
        b.group = other
        try context.save()

        LibraryMerger(context: context, passwords: passwords).mergeDuplicates()
        let groups = try context.fetch(FetchDescriptor<MachineGroup>())
        #expect(groups.map(\.id) == [lab.id])
        #expect(a.group?.id == lab.id && b.group?.id == lab.id)
    }

    @Test func nothingToMergeSavesNothing() throws {
        _ = try machine("A", host: "a.local", modified: nil)
        // Posted synchronously on the saving thread (queue nil); a duplicate pair proves it counts.
        let saves = SaveCounter()
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context,
                                                              queue: nil) { _ in saves.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates().isEmpty)
        #expect(saves.count == 0)
        _ = try machine("A again", host: "A.local", modified: nil)
        let afterInsert = saves.count
        #expect(afterInsert == 1)
        #expect(LibraryMerger(context: context, passwords: passwords).mergeDuplicates().count == 1)
        #expect(saves.count == afterInsert + 1)
    }
}

/// The post-import sweep of this Mac's SSH state (Important 2 of the final review): a machine deleted
/// or merged on another Mac arrives through CloudKit, so its local passphrase and trusted host keys
/// must go on this Mac too. Fakes and an in-memory store only, never the real Keychain or defaults.
@MainActor
struct OrphanedSSHStateSweepTests {
    let context: ModelContext
    let secrets = FakeSSHSecrets()
    let trust = InMemoryTrustedHostKeys(folder: FakeSSHFolderAccess())
    let center = NotificationCenter()
    private var hostKey: SSHHostKey { SSHTestKeys.hostKey(SSHTestKeys.ed25519Public) }

    init() throws {
        context = try makeTestContext()
    }

    private func merger(hasSession: @escaping @MainActor (UUID) -> Bool = { _ in false }) -> LibraryMerger {
        LibraryMerger(context: context, passwords: FakePasswordStore(), sshSecrets: secrets,
                      trustedHostKeys: trust, hasSession: hasSession)
    }

    /// One kept machine, plus the local state of a machine deleted on another Mac (not in the store).
    private func seed() throws -> (kept: UUID, gone: UUID) {
        let kept = Machine(name: "Pi", kind: .ssh, host: "pi.local", port: 22, username: "vincent",
                           sshAuthMethod: .keyInSSHFolder, sshKeyFileName: "id_ed25519")
        context.insert(kept)
        try context.save()
        let gone = UUID()
        secrets.items[.sshLocalKeyPassphrase(kept.id)] = "kept"
        secrets.items[.sshLocalKeyPassphrase(gone)] = "orphan"
        secrets.items[.sshPrivateKey(kept.id)] = "synced key"
        trust.trust(hostKey, host: "pi.local", port: 22)
        trust.trust(hostKey, host: "gone.local", port: 2222)
        return (kept.id, gone)
    }

    @Test func sweepDeletesOrphanedLocalPassphrasesAndUnusedTrust() throws {
        let (kept, gone) = try seed()
        merger().sweepOrphanedSSHState()
        #expect(secrets.items[.sshLocalKeyPassphrase(kept)] == "kept")
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == nil)
        #expect(secrets.items[.sshPrivateKey(kept)] == "synced key")
        #expect(secrets.deleted == [.sshLocalKeyPassphrase(gone)])
        #expect(trust.hasTrustedKeys(host: "pi.local", port: 22))
        #expect(!trust.hasTrustedKeys(host: "gone.local", port: 2222))
    }

    /// A machine with an open session keeps its passphrase for now; a listing that fails deletes
    /// nothing.
    @Test func openSessionsAndListingFailuresKeepThePassphrase() throws {
        let (_, gone) = try seed()
        merger(hasSession: { $0 == gone }).sweepOrphanedSSHState()
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == "orphan")
        secrets.listError = .interactionNotAllowed
        merger().sweepOrphanedSSHState()
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == "orphan")
    }

    /// Never before a successful import (an empty or reset store would make every passphrase look
    /// orphaned): not after setup alone, not on app activation, not after a failed import, and a new
    /// setup starting clears the earlier import.
    @Test func syncSweepsOnlyAfterASuccessfulImport() async throws {
        let (_, gone) = try seed()
        let sync = LibrarySync(isActive: true, isEntitled: true, statusProvider: nil, merger: merger(),
                               center: center)
        sync.start()
        defer { sync.stop() }
        sync.handle(SyncEvent(kind: .setup, endDate: .now, succeeded: true))
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == "orphan")
        sync.handle(SyncEvent(kind: .import, endDate: .now, succeeded: false, errorDescription: "partial"))
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == "orphan")
        #expect(trust.hasTrustedKeys(host: "gone.local", port: 2222))

        // A setup starts again (zone reset): the earlier import no longer counts.
        let setup = UUID()
        sync.handle(SyncEvent(kind: .import, endDate: .now, succeeded: true))
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == nil)
        secrets.items[.sshLocalKeyPassphrase(gone)] = "orphan again"
        sync.handle(SyncEvent(id: setup, kind: .setup, endDate: nil, succeeded: false))
        sync.handle(SyncEvent(id: setup, kind: .setup, endDate: .now, succeeded: true))
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == "orphan again")
        sync.handle(SyncEvent(kind: .import, endDate: .now, succeeded: true))
        #expect(secrets.items[.sshLocalKeyPassphrase(gone)] == nil)
        #expect(!trust.hasTrustedKeys(host: "gone.local", port: 2222))
    }
}
