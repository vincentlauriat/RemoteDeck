import Foundation
import SwiftData
import Testing
@testable import RemoteDeckCore

/// Duplicate merge of the synced library (T4.3, BackendSchema › Data validation).
struct LibraryDeduplicationTests {
    typealias Facts = LibraryDeduplication.MachineFacts
    typealias GroupFacts = LibraryDeduplication.GroupFacts

    let early = Date(timeIntervalSince1970: 1_700_000_000)
    let late = Date(timeIntervalSince1970: 1_800_000_000)

    func facts(_ key: String, modified: Date?, created: Date, id: UUID = UUID()) -> Facts {
        Facts(id: id, key: key, modifiedAt: modified, createdAt: created)
    }

    @Test func distinctKeysNeedNoMerge() {
        let machines = [facts("a:5900", modified: nil, created: early), facts("b:5900", modified: nil, created: early),
                        facts("a:5901", modified: nil, created: early)]
        #expect(LibraryDeduplication.machineMerges(machines).isEmpty)
    }

    @Test func survivorIsTheFirstCreatedAndTakesTheNewestFields() {
        let first = facts("mini.local:5900", modified: early, created: early)
        let edited = facts("mini.local:5900", modified: late, created: late)
        let never = facts("mini.local:5900", modified: nil, created: late.addingTimeInterval(1))
        let merges = LibraryDeduplication.machineMerges([edited, never, first])
        #expect(merges == [LibraryDeduplication.Merge(survivor: first.id, dropped: [edited.id, never.id],
                                                      fieldsFrom: edited.id)])
    }

    @Test func survivorEditedLastKeepsItsFields() {
        let first = facts("k", modified: late, created: early)
        let other = facts("k", modified: early, created: late)
        let never = facts("k", modified: nil, created: late)
        #expect(LibraryDeduplication.machineMerges([other, first, never]).first?.fieldsFrom == nil)
        #expect(LibraryDeduplication.machineMerges([other, first, never]).first?.survivor == first.id)
    }

    @Test func sameCreationFallsBackToTheSmallerID() {
        let low = facts("k", modified: nil, created: late, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let high = facts("k", modified: late, created: late, id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!)
        #expect(LibraryDeduplication.machineMerges([low, high]).first?.survivor == low.id)
        #expect(LibraryDeduplication.machineMerges([high, low]).first?.survivor == low.id)
        #expect(LibraryDeduplication.machineMerges([high, low]).first?.fieldsFrom == high.id)
    }

    /// Review H1: two Macs each see the other's copy with a different, not yet synced `modifiedAt`
    /// (each edited its own copy last). Both must keep the same survivor, or each deletes the other's.
    @Test func macsWithDifferentEditSnapshotsKeepTheSameSurvivor() {
        let a = UUID(uuidString: "11111111-0000-0000-0000-000000000000")!
        let b = UUID(uuidString: "22222222-0000-0000-0000-000000000000")!
        let created = early
        // Mac A: its copy `a` edited late, `b` as last synced (early).
        let macA = [facts("k", modified: late, created: created, id: a), facts("k", modified: early, created: created.addingTimeInterval(5), id: b)]
        // Mac B: its copy `b` edited later still, `a` as last synced (early).
        let macB = [facts("k", modified: early, created: created, id: a), facts("k", modified: late.addingTimeInterval(9), created: created.addingTimeInterval(5), id: b)]
        let survivorA = LibraryDeduplication.machineMerges(macA).first?.survivor
        let survivorB = LibraryDeduplication.machineMerges(macB).first?.survivor
        #expect(survivorA == a)
        #expect(survivorA == survivorB)
    }

    /// The plan does not depend on the order the records arrive.
    @Test func planDoesNotDependOnTheOrderTheRecordsArrive() {
        var generator = SystemRandomNumberGenerator()
        var machines: [Facts] = []
        for key in ["a:5900", "b:5900", "c:5900"] {
            machines.append(facts(key, modified: late, created: late))
            machines.append(facts(key, modified: late, created: late))
            machines.append(facts(key, modified: nil, created: early))
        }
        machines.append(facts("solo:5900", modified: nil, created: early))
        let reference = LibraryDeduplication.machineMerges(machines)
        #expect(reference.count == 3)
        for _ in 0..<50 {
            #expect(LibraryDeduplication.machineMerges(machines.shuffled(using: &generator)) == reference)
        }
    }

    @Test func factsUseTheNormalizedKey() {
        let machine = Machine(name: "Mini", host: "Mini.LOCAL", port: 5901, modifiedAt: late)
        let facts = Facts(machine)
        #expect(facts.key == "mini.local:5901")
        #expect(facts.modifiedAt == late)
        #expect(facts.id == machine.id)
    }

    @Test func groupsMergeByTrimmedCaseInsensitiveName() {
        let low = GroupFacts(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: " lab ", sortOrder: 2)
        let high = GroupFacts(id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!, name: "Lab", sortOrder: 0)
        let other = GroupFacts(id: UUID(), name: "Office", sortOrder: 1)
        let merges = LibraryDeduplication.groupMerges([high, other, low])
        #expect(merges == [LibraryDeduplication.Merge(survivor: low.id, dropped: [high.id])])
    }

    /// Review H1: the group survivor ignores `sortOrder`, which two Macs may see differently.
    @Test func macsWithDifferentGroupOrdersKeepTheSameGroup() {
        let a = UUID(uuidString: "11111111-0000-0000-0000-000000000000")!
        let b = UUID(uuidString: "22222222-0000-0000-0000-000000000000")!
        let macA = [GroupFacts(id: a, name: "Lab", sortOrder: 5), GroupFacts(id: b, name: "Lab", sortOrder: 1)]
        let macB = [GroupFacts(id: a, name: "Lab", sortOrder: 0), GroupFacts(id: b, name: "Lab", sortOrder: 3)]
        #expect(LibraryDeduplication.groupMerges(macA).first?.survivor == a)
        #expect(LibraryDeduplication.groupMerges(macB).first?.survivor == a)
    }

    /// The survivor of a merge takes the newest copy's user-visible fields, SSH ones included (V3).
    @MainActor
    @Test func dedupCopiesSSHFields() throws {
        let context = ModelContext(try RemoteDeckSchema.makeContainer(inMemory: true))
        let group = MachineGroup(name: "Cloud")
        let survivor = Machine(name: "Old", kind: .vnc, host: "vm.example.com", port: 22, createdAt: early)
        let newest = Machine(name: "Azure VM", kind: .ssh, host: "VM.example.com", port: 22, username: "azureuser",
                             isFavorite: true, isWatched: true, scalingMode: .actual, sharedClipboard: false,
                             lastConnectedAt: late, createdAt: late, modifiedAt: late)
        newest.sshAuth = .keyInSSHFolder
        newest.sshKeyFileName = "id_ed25519"
        newest.portForwards = [PortForward(label: "Web", localPort: 8080, remotePort: 80)]
        for model in [group, survivor, newest] as [any PersistentModel] { context.insert(model) }
        newest.group = group

        LibraryDeduplication.copyFields(from: newest, to: survivor)

        #expect(survivor.name == "Azure VM" && survivor.kindValue == .ssh)
        #expect(survivor.host == "VM.example.com" && survivor.port == 22 && survivor.username == "azureuser")
        #expect(survivor.group?.name == "Cloud")
        #expect(survivor.isFavorite && survivor.isWatched && survivor.scalingModeValue == .actual)
        #expect(!survivor.sharedClipboard && survivor.modifiedAt == late)
        #expect(survivor.sshAuthMethod == "keyInSSHFolder" && survivor.sshKeyFileName == "id_ed25519")
        #expect(survivor.portForwardsData == newest.portForwardsData)
        #expect(survivor.portForwards == newest.portForwards)
        // Identity and history are the survivor's own: never copied.
        #expect(survivor.id != newest.id && survivor.createdAt == early && survivor.lastConnectedAt == nil)
    }
}
