import Foundation
import SwiftData

/// Migration plan for the SwiftData schema. CloudKit-synced changes must stay additive
/// (BackendSchema › Migrations): V1 → V2 only adds the optional `Machine.modifiedAt`.
public enum RemoteDeckMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [RemoteDeckSchemaV1.self, RemoteDeckSchemaV2.self] }
    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: RemoteDeckSchemaV1.self, toVersion: RemoteDeckSchemaV2.self)]
    }
}

/// Builds the app's single `ModelContainer` with two stores: synced and local.
public enum RemoteDeckSchema {
    public static let syncedConfigurationName = "Synced"
    /// The one CloudKit container of both apps (Vincent, 2026-10-25): Debug builds reach its
    /// Development environment, Release builds its Production one.
    public static let cloudKitContainerIdentifier = "iCloud.fr.vincentlauriat.remotedeck"
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
    ///
    /// `cloudKitContainer` non-nil mirrors the Library store (Machine, MachineGroup) to that
    /// container's private database (iCloud Sync, T4.3); the History store never leaves this Mac.
    /// Only a process entitled to the container may pass it (the app, when the setting is on): an
    /// unentitled one fails to open the store. Ignored in memory.
    public static func makeContainer(inMemory: Bool = false, storeDirectory: URL? = nil,
                                     cloudKitContainer: String? = nil) throws -> ModelContainer {
        try makeContainer(versionedSchema: RemoteDeckSchemaV2.self, syncedModels: syncedModels,
                          localModels: localModels, inMemory: inMemory, storeDirectory: storeDirectory,
                          cloudKitContainer: cloudKitContainer)
    }

    /// The Library store's CloudKit setting: the container's private database, or none. Always explicit:
    /// `.automatic` would pick the first iCloud container of an entitled process even with sync off.
    static func libraryCloudKitDatabase(_ container: String?) -> ModelConfiguration.CloudKitDatabase {
        container.map { .private($0) } ?? .none
    }

    /// Any schema version's container, with the migration plan: the migration tests write V1 stores.
    static func makeContainer(versionedSchema: any VersionedSchema.Type,
                              syncedModels: [any PersistentModel.Type],
                              localModels: [any PersistentModel.Type],
                              inMemory: Bool, storeDirectory: URL?,
                              cloudKitContainer: String?) throws -> ModelContainer {
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
                cloudKitDatabase: libraryCloudKitDatabase(cloudKitContainer)
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
            for: Schema(versionedSchema: versionedSchema),
            migrationPlan: RemoteDeckMigrationPlan.self,
            configurations: [synced, local]
        )
    }
}
