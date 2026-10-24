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
}
