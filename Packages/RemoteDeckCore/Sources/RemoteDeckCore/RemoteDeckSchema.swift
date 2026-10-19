import Foundation
import SwiftData

/// Migration plan for the SwiftData schema. Empty until V2; CloudKit-synced changes
/// must stay additive (BackendSchema › Migrations).
public enum RemoteDeckMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [RemoteDeckSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// Builds the app's single `ModelContainer` with two stores: synced and local.
public enum RemoteDeckSchema {
    public static let syncedConfigurationName = "Synced"
    public static let localConfigurationName = "Local"

    /// Models stored in the CloudKit-synced store.
    public static var syncedModels: [any PersistentModel.Type] { [Machine.self, MachineGroup.self] }

    /// Models that never leave this Mac.
    public static var localModels: [any PersistentModel.Type] { [SessionRecord.self, AssistantAction.self] }

    /// One container, two `ModelConfiguration`s. `inMemory` is for tests and previews.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let synced = ModelConfiguration(
            syncedConfigurationName,
            schema: Schema(syncedModels),
            isStoredInMemoryOnly: inMemory,
            // Off until T4.3: the iCloud container and its provisioning profile do not exist yet.
            // T4.3 switches this to `.private("iCloud.…")`.
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            localConfigurationName,
            schema: Schema(localModels),
            isStoredInMemoryOnly: inMemory,
            // Always off: Session History and Assistant Actions stay on this Mac.
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: Schema(versionedSchema: RemoteDeckSchemaV1.self),
            migrationPlan: RemoteDeckMigrationPlan.self,
            configurations: [synced, local]
        )
    }
}
