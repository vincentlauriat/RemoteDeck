import Foundation
import SwiftData
import Testing
@testable import RemoteDeckCore

@MainActor
struct StoreLocationTests {
    @Test func onDiskStoresUseAppSpecificFilesInTheGivenDirectory() throws {
        let directory = URL.temporaryDirectory.appending(path: "RemoteDeckStoreTests-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let container = try RemoteDeckSchema.makeContainer(storeDirectory: directory)
        let urls = Dictionary(uniqueKeysWithValues: container.configurations.map { ($0.name, $0.url) })
        #expect(urls["Synced"] == directory.appending(path: "RemoteDeckLibrary.store"))
        #expect(urls["Local"] == directory.appending(path: "RemoteDeckHistory.store"))

        let context = ModelContext(container)
        context.insert(Machine(name: "Mini", host: "mini.local"))
        context.insert(SessionRecord(machineID: UUID(), machineName: "Mini", outcome: .connected))
        try context.save()

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.contains("RemoteDeckLibrary.store"))
        #expect(files.contains("RemoteDeckHistory.store"))
        #expect(!files.contains("default.store"))

        // A second container on the same directory reads the same data back.
        let reopened = ModelContext(try RemoteDeckSchema.makeContainer(storeDirectory: directory))
        #expect(try reopened.fetch(FetchDescriptor<Machine>()).map(\.name) == ["Mini"])
        #expect(try reopened.fetchCount(FetchDescriptor<SessionRecord>()) == 1)
    }

    @Test func defaultDirectoryIsPerBundleIdentifier() {
        let dev = RemoteDeckSchema.defaultStoreDirectory(bundleIdentifier: "fr.vincentlauriat.remotedeck.dev")
        let prod = RemoteDeckSchema.defaultStoreDirectory(bundleIdentifier: "fr.vincentlauriat.remotedeck")
        #expect(dev.lastPathComponent == "fr.vincentlauriat.remotedeck.dev")
        #expect(dev.deletingLastPathComponent() == URL.applicationSupportDirectory)
        #expect(dev != prod)
    }
}
