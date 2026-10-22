#if DEBUG
import Foundation
import SwiftData
import RemoteDeckCore
import RFBKit

/// Debug-only `-LibraryDemo list|editor` launch argument: runs the Library Window on an in-memory
/// store seeded with sample machines (for screenshots), with in-memory passwords, so neither the
/// real store nor the Keychain is touched. `editor` also opens the Machine Editor on the first
/// machine. Test connection uses `LibraryDemo.Tester`, which answers "Reachable, auth OK" after
/// half a second without any network access (the sample hosts are not real machines).
enum LibraryDemo {
    struct Tester: ConnectionTester {
        func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                throw .cancelled
            }
        }
    }

    static var mode: String? { UserDefaults.standard.string(forKey: "LibraryDemo") }
    static var isEnabled: Bool { mode != nil }
    static var opensEditor: Bool { mode == "editor" }

    @MainActor
    static func seed(_ context: ModelContext) {
        let servers = MachineGroup(name: "Servers", sortOrder: 0)
        let office = MachineGroup(name: "Office", sortOrder: 1)
        context.insert(servers)
        context.insert(office)
        let machines = [
            Machine(name: "Mac mini", kind: .macARD, host: "mini.local", username: "vincent", isFavorite: true),
            Machine(name: "Build server", kind: .macARD, host: "10.0.1.20", username: "admin"),
            Machine(name: "NAS", kind: .vnc, host: "nas.local", port: 5901),
            Machine(name: "Studio", kind: .macARD, host: "studio.local", username: "vincent"),
            Machine(name: "Computer use", kind: .anthropicVM, host: "127.0.0.1"),
        ]
        machines[1].group = servers
        machines[2].group = servers
        machines[3].group = office
        machines.forEach(context.insert)
        try? context.save()
    }
}
#endif
