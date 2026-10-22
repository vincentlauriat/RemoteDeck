#if DEBUG
import Foundation
import SwiftData
import RemoteDeckCore
import RFBKit

/// Debug-only `-LibraryDemo list|editor|session` launch argument: runs the Library Window on an
/// in-memory store seeded with sample machines (for screenshots), with in-memory passwords, so neither
/// the real store nor the Keychain is touched. `editor` also opens the Machine Editor on the first
/// machine; `session` opens two Session Windows: "Mac mini" (a synthetic desktop) and "Studio"
/// (authentication fails). Test connection uses `LibraryDemo.Tester`, which answers "Reachable, auth
/// OK" after half a second, and sessions use `LibraryDemo.Connection`: no network access at all (the
/// sample hosts are not real machines). The Accessibility prompt is never shown in demo mode.
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
    static var opensSessions: Bool { mode == "session" }
    /// The machines `session` opens, in order. "Mac mini" twice: the second Connect must bring its
    /// window forward, not open a second window or connection.
    static let sessionMachineNames = ["Mac mini", "Studio", "Mac mini"]

    /// A fake session: the color-bar test pattern after 0.8 s; "studio.local" fails authentication.
    actor Connection: SessionConnection {
        private let failsAuthentication: Bool
        private var continuation: AsyncThrowingStream<RFBEvent, any Error>.Continuation?
        private var received: Int64 = 0

        init(_ target: SessionTarget) {
            failsAuthentication = target.host == "studio.local"
        }

        func connect(credentials: RFBCredentials, timeout: Duration) async throws(RFBError) {
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                throw .cancelled
            }
            if failsAuthentication { throw .authFailed(reason: nil) }
        }

        func events() async throws(RFBError) -> any AsyncSequence<RFBEvent, any Error> & Sendable {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: RFBEvent.self)
            let width = 1920, height = 1080
            continuation.yield(.framebufferUpdate(FramebufferUpdate(
                width: width, height: height,
                regions: [.init(rect: RFBRect(x: 0, y: 0, width: width, height: height),
                                pixels: FramebufferDebugView.testPattern(width: width, height: height))])))
            received = Int64(width * height * 4)
            self.continuation = continuation
            return stream
        }

        func send(_ messages: [ClientMessage]) async throws(RFBError) {}

        func close() {
            continuation?.finish()
            continuation = nil
        }

        var receivedByteCount: Int64 { received }
    }

    static func connection(_ target: SessionTarget) -> any SessionConnection {
        Connection(target)
    }

    /// Marks the once-per-run prompt as already shown, so a demo session never asks for access.
    @MainActor
    static func suppressAccessibilityPrompt() {
        var policy = AccessibilityPromptPolicy()
        _ = policy.shouldPrompt(captureStarted: true, trusted: false)
        SystemShortcutTap.promptPolicy = policy
    }

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
