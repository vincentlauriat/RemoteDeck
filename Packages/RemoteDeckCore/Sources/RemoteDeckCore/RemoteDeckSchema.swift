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

    /// File name of the synced store (Machine Library) inside the store directory.
    public static let syncedStoreFileName = "RemoteDeckLibrary.store"
    /// File name of the local store (Session History, Assistant Actions) inside the store directory.
    public static let localStoreFileName = "RemoteDeckHistory.store"

    /// `Application Support/<bundle id>/`. Inside the App Sandbox, Application Support is already
    /// per-app; the bundle-id folder keeps the Debug (`….dev`) and Release stores apart when the
    /// app runs unsandboxed (e.g. CI builds with `CODE_SIGNING_ALLOWED=NO`).
    public static func defaultStoreDirectory(bundleIdentifier: String) -> URL {
        URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    }

    /// One container, two `ModelConfiguration`s. `inMemory` is for tests and previews; otherwise
    /// both stores live in `storeDirectory` (created if needed) under app-specific file names.
    public static func makeContainer(inMemory: Bool = false, storeDirectory: URL? = nil) throws -> ModelContainer {
        let synced: ModelConfiguration
        let local: ModelConfiguration
        if inMemory {
            synced = ModelConfiguration(
                syncedConfigurationName,
                schema: Schema(syncedModels),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            local = ModelConfiguration(
                localConfigurationName,
                schema: Schema(localModels),
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        } else {
            let directory = storeDirectory
                ?? defaultStoreDirectory(bundleIdentifier: Bundle.main.bundleIdentifier ?? "fr.vincentlauriat.remotedeck")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            synced = ModelConfiguration(
                syncedConfigurationName,
                schema: Schema(syncedModels),
                url: directory.appending(path: syncedStoreFileName),
                // Off until T4.3: the iCloud container and its provisioning profile do not exist yet.
                // T4.3 switches this to `.private("iCloud.…")`.
                cloudKitDatabase: .none
            )
            local = ModelConfiguration(
                localConfigurationName,
                schema: Schema(localModels),
                url: directory.appending(path: localStoreFileName),
                // Always off: Session History and Assistant Actions stay on this Mac.
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: Schema(versionedSchema: RemoteDeckSchemaV1.self),
            migrationPlan: RemoteDeckMigrationPlan.self,
            configurations: [synced, local]
        )
    }
}
