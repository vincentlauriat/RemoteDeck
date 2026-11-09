import CoreData
import Foundation
import SwiftData
import Testing
@testable import RemoteDeckCore

/// iCloud Sync (T4.3): the synced models obey CloudKit's rules, the Library store gets the private
/// database only when asked, and a V1 store on disk opens as V2.
@MainActor
struct SyncSchemaTests {
    /// CloudKit refuses a model with a required property without a default, a required or one-way
    /// relationship, or a uniqueness constraint (BackendSchema › Tables). Adding one to Machine or
    /// MachineGroup must fail here, not at the first sync.
    @Test func syncedModelsFollowCloudKitRules() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: RemoteDeckSchema.syncedModels))
        #expect(Set(model.entities.compactMap(\.name)) == ["Machine", "MachineGroup"])
        for entity in model.entities {
            let name = entity.name ?? "?"
            #expect(entity.uniquenessConstraints.isEmpty, "\(name) has a uniqueness constraint")
            for (attribute, description) in entity.attributesByName {
                #expect(description.isOptional || description.defaultValue != nil,
                        "\(name).\(attribute) is required without a default")
            }
            for (relationship, description) in entity.relationshipsByName {
                #expect(description.isOptional, "\(name).\(relationship) is required")
                #expect(description.inverseRelationship != nil, "\(name).\(relationship) has no inverse")
            }
        }
    }

    /// V3 (SSH machines) adds three optional Machine fields; the CloudKit rule above covers them, and
    /// they must exist on the synced entity as optional attributes.
    @Test func syncedV3PropertiesAreOptionalOrDefaulted() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: RemoteDeckSchema.syncedModels))
        let machine = try #require(model.entitiesByName["Machine"])
        for name in ["sshAuthMethod", "sshKeyFileName", "portForwardsData"] {
            let attribute = try #require(machine.attributesByName[name], "Machine.\(name) missing")
            #expect(attribute.isOptional, "Machine.\(name) is required")
        }
        let v3 = try #require(NSManagedObjectModel.makeManagedObjectModel(
            for: [RemoteDeckSchemaV3.Machine.self, RemoteDeckSchemaV3.MachineGroup.self]))
        for entity in v3.entities {
            for (attribute, description) in entity.attributesByName {
                #expect(description.isOptional || description.defaultValue != nil,
                        "\(entity.name ?? "?").\(attribute) is required without a default")
            }
        }
        #expect(RemoteDeckSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
    }

    @Test func libraryStoreSyncsOnlyWhenGivenAContainer() {
        let none = String(describing: ModelConfiguration.CloudKitDatabase.none)
        #expect(String(describing: RemoteDeckSchema.libraryCloudKitDatabase(nil)) == none)
        let synced = String(describing: RemoteDeckSchema.libraryCloudKitDatabase("iCloud.fr.vincentlauriat.remotedeck"))
        #expect(synced != none)
        #expect(synced != String(describing: ModelConfiguration.CloudKitDatabase.automatic))
        #expect(synced.contains("iCloud.fr.vincentlauriat.remotedeck"))
        #expect(RemoteDeckSchema.cloudKitContainerIdentifier == "iCloud.fr.vincentlauriat.remotedeck")
    }

    @Test func historyStoreNeverSyncs() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckSyncTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Unentitled process: a `.private` Library store cannot be opened here, so only the
        // configuration of the always-local History store is checked on a real container.
        let container = try RemoteDeckSchema.makeContainer(storeDirectory: directory)
        let none = String(describing: ModelConfiguration.CloudKitDatabase.none)
        for configuration in container.configurations {
            #expect(String(describing: configuration.cloudKitDatabase) == none)
        }
    }

    /// The stores written before T4.3 (schema V1) open as V2: data kept, `modifiedAt` nil.
    @Test func versionOneStoreMigratesToVersionTwo() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let machineID = UUID()
        do {
            let v1 = try RemoteDeckSchema.makeContainer(
                versionedSchema: RemoteDeckSchemaV1.self,
                syncedModels: [RemoteDeckSchemaV1.Machine.self, RemoteDeckSchemaV1.MachineGroup.self],
                localModels: [RemoteDeckSchemaV1.SessionRecord.self, RemoteDeckSchemaV1.AssistantAction.self],
                inMemory: false, storeDirectory: directory, cloudKitContainer: nil)
            let context = ModelContext(v1)
            let group = RemoteDeckSchemaV1.MachineGroup(name: "Lab")
            let machine = RemoteDeckSchemaV1.Machine(id: machineID, name: "Mini", host: "mini.local",
                                                     port: 5901, username: "vincent", isFavorite: true,
                                                     createdAt: created)
            context.insert(group)
            context.insert(machine)
            machine.group = group
            context.insert(RemoteDeckSchemaV1.SessionRecord(machineID: machineID, machineName: "Mini",
                                                             outcome: .connected))
            try context.save()
        }

        let v2 = ModelContext(try RemoteDeckSchema.makeContainer(storeDirectory: directory))
        let machine = try #require(try v2.fetch(FetchDescriptor<Machine>()).first)
        #expect(machine.id == machineID)
        #expect(machine.name == "Mini" && machine.host == "mini.local" && machine.port == 5901)
        #expect(machine.username == "vincent" && machine.isFavorite)
        #expect(machine.createdAt == created)
        #expect(machine.group?.name == "Lab")
        #expect(machine.modifiedAt == nil)
        #expect(try v2.fetchCount(FetchDescriptor<SessionRecord>()) == 1)

        let edited = Date(timeIntervalSince1970: 1_800_000_000)
        machine.modifiedAt = edited
        try v2.save()
        let reopened = ModelContext(try RemoteDeckSchema.makeContainer(storeDirectory: directory))
        #expect(try reopened.fetch(FetchDescriptor<Machine>()).first?.modifiedAt == edited)
    }

    /// A store written by the V2 app (schema V2) opens as V3: fields kept, the SSH ones nil.
    @Test func v2StoreOpensAsV3OnDisk() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_750_000_000)
        let machineID = UUID()
        do {
            let v2 = try RemoteDeckSchema.makeContainer(
                versionedSchema: RemoteDeckSchemaV2.self,
                syncedModels: [RemoteDeckSchemaV2.Machine.self, RemoteDeckSchemaV2.MachineGroup.self],
                localModels: [RemoteDeckSchemaV2.SessionRecord.self, RemoteDeckSchemaV2.AssistantAction.self],
                inMemory: false, storeDirectory: directory, cloudKitContainer: nil)
            let context = ModelContext(v2)
            let group = RemoteDeckSchemaV2.MachineGroup(name: "Lab")
            let machine = RemoteDeckSchemaV2.Machine(id: machineID, name: "Mini", kind: .vnc, host: "mini.local",
                                                     port: 5901, username: "vincent", isWatched: true,
                                                     createdAt: created, modifiedAt: modified)
            context.insert(group)
            context.insert(machine)
            machine.group = group
            context.insert(RemoteDeckSchemaV2.SessionRecord(machineID: machineID, machineName: "Mini",
                                                             outcome: .dropped))
            try context.save()
        }

        let v3 = ModelContext(try RemoteDeckSchema.makeContainer(storeDirectory: directory))
        let machine = try #require(try v3.fetch(FetchDescriptor<Machine>()).first)
        #expect(machine.id == machineID)
        #expect(machine.name == "Mini" && machine.kindValue == .vnc && machine.host == "mini.local")
        #expect(machine.port == 5901 && machine.username == "vincent" && machine.isWatched)
        #expect(machine.createdAt == created && machine.modifiedAt == modified)
        #expect(machine.group?.name == "Lab")
        #expect(machine.sshAuthMethod == nil && machine.sshKeyFileName == nil && machine.portForwardsData == nil)
        #expect(machine.sshAuth == .password && machine.portForwards.isEmpty)
        let record = try #require(try v3.fetch(FetchDescriptor<SessionRecord>()).first)
        #expect(record.outcomeValue == .dropped)

        machine.kindValue = .ssh
        machine.sshAuth = .keyInSSHFolder
        machine.sshKeyFileName = "id_ed25519"
        machine.portForwards = [PortForward(localPort: 8080, remotePort: 80)]
        try v3.save()
        let reopened = ModelContext(try RemoteDeckSchema.makeContainer(storeDirectory: directory))
        let fetched = try #require(try reopened.fetch(FetchDescriptor<Machine>()).first)
        #expect(fetched.kindValue == .ssh && fetched.sshAuth == .keyInSSHFolder)
        #expect(fetched.sshKeyFileName == "id_ed25519")
        #expect(fetched.portForwards.map(\.localPort) == [8080])
    }
}
