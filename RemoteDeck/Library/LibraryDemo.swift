#if DEBUG
import Foundation
import SwiftData
import ClaudeKit
import RemoteDeckCore
import RFBKit

/// Debug-only `-LibraryDemo list|editor|session|discovery` launch argument: runs the Library Window on an
/// in-memory store seeded with sample machines (for screenshots), with in-memory passwords, so neither
/// the real store nor the Keychain is touched. `editor` also opens the Machine Editor on the first
/// machine; `session` opens three tabs of one Session Window: "Mac mini" and "NAS" (a synthetic
/// desktop) and "Studio" (authentication fails), then selects the second tab as ⌘2 does. Test connection uses `LibraryDemo.Tester`, which answers "Reachable, auth
/// OK" after half a second, and sessions use `LibraryDemo.Connection`: no network access at all (the
/// sample hosts are not real machines). `discovery` opens the Discovery Panel on fake Bonjour results
/// (`LibraryDemo.discovery`; the demo never browses the network, in any mode). The Accessibility
/// prompt is never shown in demo mode.
///
/// Empty and blocked states (T3.8, AppFlow › Empty and blocked states): `empty` (no sample machines:
/// "No machines yet"), `store-error` (the in-memory library banner, with a simulated error),
/// `discovery-empty` (nothing found, after 2 s), `discovery-blocked` (Local Network denied),
/// `discovery-failed` (a browser failure with its code), and `onboarding` (the Onboarding Sheet over an
/// empty library; nothing is persisted, the notification button answers "allowed" without the system
/// prompt, and its last page opens the fake Discovery Panel). Every other mode never shows onboarding.
///
/// `watch` (T4.5, Status Notifications): "Mac mini", "NAS" and "Build server" are watched and probed
/// every 3 s by `WatchProbe` (no network): "Mac mini" always answers, "NAS" answers twice then fails
/// three times (so it goes offline and comes back), "Build server" never answers. Notifications go to
/// `WatchPoster`, which prints them on stderr: Notification Center is never used in any demo mode.
///
/// `history` (T4.6, Session History): the sample library plus a fixed set of past records
/// (`seedHistory`, placed relative to launch: every outcome, slow and fast connects, a record older than
/// the 30-day window, one left without an end by a "killed run", two of machines deleted since, one
/// with a comma and quotes in its name), and the Session History window open at launch; "Mac mini" is
/// connected on the fake connection, so its newest row is in progress.
enum LibraryDemo {
    struct Tester: ConnectionTester {
        func test(host: String, port: UInt16, credentials: RFBCredentials, timeout: Duration,
                  allowsPublicInternet: Bool) async throws(RFBError) {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                throw .cancelled
            }
            // As the real tester: a public IP literal is refused unless confirmed (never contacted).
            let address = RemoteAddress(text: host, scope: AddressScope(literal: host) ?? .privateNetwork)
            guard PublicAddressPolicy.admits(address, confirmed: allowsPublicInternet) else {
                throw .publicAddressNotAdmitted(address: address.text)
            }
        }
    }

    static var mode: String? { UserDefaults.standard.string(forKey: "LibraryDemo") }
    static var isEnabled: Bool { mode != nil }
    static var opensEditor: Bool { mode == "editor" }
    static var opensSessions: Bool { mode == "session" }
    static var opensDiscovery: Bool { mode == "discovery" || discoveryScenario != .lan }
    /// `empty` and `onboarding` start from an empty library, as on a first launch.
    static var seedsLibrary: Bool { mode != "empty" && mode != OnboardingLaunch.demoMode }
    static var simulatesStoreError: Bool { mode == "store-error" }
    static var watchesMachines: Bool { mode == "watch" }
    static var showsHistory: Bool { mode == "history" }
    static let storeError = "Demo: simulated SwiftData error (the on-disk store could not be opened)"

    /// Answers "allowed" after half a second: the demo never shows the system prompt.
    struct NotificationAuthorizer: NotificationAuthorizing {
        func requestAuthorization() async -> NotificationAuthorization {
            try? await Task.sleep(for: .milliseconds(500))
            return .granted
        }
    }

    /// What the fake browsers report.
    enum DiscoveryScenario {
        case lan, empty, blocked, failed
    }

    static var discoveryScenario: DiscoveryScenario {
        switch mode {
        case "discovery-empty": .empty
        case "discovery-blocked": .blocked
        case "discovery-failed": .failed
        default: .lan
        }
    }

    /// kDNSServiceErr_ServiceNotRunning, shown as the failed state's code.
    static let failureCode = -65563

    /// Fake Bonjour LAN: "Mac mini" (already in the sample library), an iMac with Remote
    /// Management, a VNC-only Raspberry Pi on port 5901; results arrive after 0.6 s.
    struct Browsers: BonjourBrowserFactory {
        var scenario: DiscoveryScenario = .lan

        static let endpoints: [BonjourService: BonjourEndpoint] = [
            BonjourService(name: "Mac mini", type: .rfb, domain: "local."): BonjourEndpoint(host: "mini.local", port: 5900),
            BonjourService(name: "Mac mini", type: .netAssistant, domain: "local."): BonjourEndpoint(host: "mini.local", port: 3283),
            BonjourService(name: "Office iMac", type: .rfb, domain: "local."): BonjourEndpoint(host: "office-imac.local", port: 5900),
            BonjourService(name: "Office iMac", type: .netAssistant, domain: "local."): BonjourEndpoint(host: "office-imac.local", port: 3283),
            BonjourService(name: "Raspberry Pi", type: .rfb, domain: "local."): BonjourEndpoint(host: "raspberrypi.local", port: 5901),
        ]

        func events(for type: BonjourServiceType) -> AsyncStream<BonjourBrowseEvent> {
            AsyncStream { continuation in
                switch scenario {
                case .lan: break
                case .empty:
                    continuation.yield(.ready)
                    return
                case .blocked:
                    continuation.yield(.waiting(.permissionDenied))
                    return
                case .failed:
                    continuation.yield(.failed(.error(code: LibraryDemo.failureCode)))
                    return
                }
                continuation.yield(.ready)
                let task = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    continuation.yield(.results(Set(Self.endpoints.keys.filter { $0.type == type })))
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    struct Resolver: BonjourResolver {
        func resolve(_ service: BonjourService) async -> BonjourEndpoint? {
            Browsers.endpoints[service]
        }
    }

    @MainActor
    static func discovery() -> DiscoveryService {
        let scenario = discoveryScenario
        return DiscoveryService(browsers: Browsers(scenario: scenario), resolver: Resolver(),
                                emptyAfter: scenario == .empty ? .seconds(2) : DiscoveryService.defaultEmptyAfter)
    }
    /// The machines `session` opens, in order, as three tabs of one Session Window. "Mac mini" twice:
    /// the second Connect must select its tab, not open a second tab or connection.
    static let sessionMachineNames = ["Mac mini", "NAS", "Studio", "Mac mini"]
    /// Then the second tab is selected as ⌘2 would (AC6): "NAS" in front, the others still connected.
    static let selectsSecondTabAfter: Duration = .seconds(3)

    /// `resilience` (T5.1): "Mac mini" and "NAS" open as two tabs; each first connection drops 4 s
    /// after its first frame. "Mac mini" reconnects on its own 2 s later; the automatic attempt of
    /// "NAS" fails, so it shows "Connection lost", and its Reconnect works. The path monitor and sleep
    /// and wake are the real ones (turn Wi-Fi off, sleep the Mac): the connections stay fake.
    static var simulatesDrops: Bool { mode == "resilience" }
    static let resilienceMachineNames = ["Mac mini", "NAS"]
    @MainActor private static var resilienceAttempts: [String: Int] = [:]

    /// A fake session: the color-bar test pattern after 0.8 s; "studio.local" fails authentication.
    actor Connection: SessionConnection {
        private let failsAuthentication: Bool
        private let failsToConnect: Bool
        private let dropsAfter: Duration?
        private var continuation: AsyncThrowingStream<RFBEvent, any Error>.Continuation?
        private var received: Int64 = 0
        private var dropTask: Task<Void, Never>?

        private let host: String

        init(_ target: SessionTarget, failsToConnect: Bool = false, dropsAfter: Duration? = nil) {
            host = target.host
            failsAuthentication = target.host == "studio.local"
            self.failsToConnect = failsToConnect
            self.dropsAfter = dropsAfter
        }

        func setClipboardSharing(_ on: Bool) {}

        func shareClipboard(_ text: String) async throws(RFBError) -> ClipboardShare { .notSharing }

        /// The "address reached" is the host when it is an IP literal (`public`: a documentation-range
        /// address, never contacted), else a LAN address.
        func connect(credentials: RFBCredentials, timeout: Duration, allowsPublicInternet: Bool) async throws(RFBError)
            -> RemoteAddress {
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                throw .cancelled
            }
            let address = RemoteAddress(text: host, scope: AddressScope(literal: host) ?? .privateNetwork)
            if !PublicAddressPolicy.admits(address, confirmed: allowsPublicInternet) {
                throw .publicAddressNotAdmitted(address: address.text)
            }
            if failsAuthentication { throw .authFailed(reason: nil) }
            if failsToConnect { throw .network("demo: no route to host") }
            return address
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
            if let dropsAfter {
                dropTask = Task { [weak self] in
                    try? await Task.sleep(for: dropsAfter)
                    await self?.drop()
                }
            }
            return stream
        }

        /// The server goes away (`resilience`).
        private func drop() {
            continuation?.finish(throwing: RFBError.connectionClosed)
            continuation = nil
        }

        /// The test pattern, as the session shows it (the Claude Assistant's screenshot).
        func framebufferSnapshot() -> Framebuffer? {
            guard continuation != nil else { return nil }
            let width = 1920, height = 1080
            return try? Framebuffer(width: width, height: height,
                                    pixels: FramebufferDebugView.testPattern(width: width, height: height))
        }

        func send(_ messages: [ClientMessage]) async throws(RFBError) {}

        func close() {
            dropTask?.cancel()
            continuation?.finish()
            continuation = nil
        }

        var receivedByteCount: Int64 { received }
    }

    @MainActor
    static func connection(_ target: SessionTarget) -> any SessionConnection {
        guard simulatesDrops else { return Connection(target) }
        let attempt = resilienceAttempts[target.host, default: 0]
        resilienceAttempts[target.host] = attempt + 1
        switch (target.host, attempt) {
        case (_, 0): return Connection(target, dropsAfter: .seconds(4))
        case ("nas.local", 1): return Connection(target, failsToConnect: true)
        default: return Connection(target)
        }
    }

    // MARK: Claude Assistant (`-LibraryDemo assistant`)

    /// `assistant`: one "Mac mini" session with the Claude Assistant Panel open, an in-memory demo key
    /// and scripted API answers (`ScriptedTransport`): no request leaves the Mac, no token is spent.
    static var scriptsAssistant: Bool { mode == "assistant" }
    static let assistantKey = "sk-ant-demo-not-a-real-key"

    static func assistantClient() -> MessagesClient {
        MessagesClient(transport: ScriptedTransport(), retry: RetryPolicy(maxRetries: 0))
    }

    /// First request: a progress note, an answer and two proposed actions (a click, then typing).
    /// Every later one: a short final answer. `GET /v1/models` (the key check) answers 200.
    struct ScriptedTransport: HTTPTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .milliseconds(900))
            let url = request.url ?? ClaudeAPI.messagesURL
            let body = request.httpBody.flatMap { try? JSONValue.decode($0) }
            let turns = body?["messages"]?.arrayValue?.count ?? 0
            let reply: JSONValue = request.httpMethod == "GET" ? ["data": []] : turns <= 1 ? Self.firstTurn : Self.lastTurn
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (reply.encoded(), response)
        }

        static let firstTurn: JSONValue = [
            "type": "message", "id": "msg_demo_1", "role": "assistant", "model": .string(ClaudeAPI.defaultModel),
            "stop_reason": "tool_use",
            "content": [
                ["type": "thinking", "thinking": "", "signature": "demo"],
                ["type": "text", "text": "The screen shows a colour-bar test pattern. I'll open the search field and type the command."],
                ["type": "thinking", "thinking": "Clicking the centre of the screen first.", "signature": "demo"],
                ["type": "tool_use", "id": "toolu_demo_click", "name": "left_click", "toolset_name": "computer",
                 "input": ["coordinate": [640, 360]]],
                ["type": "tool_use", "id": "toolu_demo_type", "name": "type", "toolset_name": "computer",
                 "input": ["text": "uptime\n"]],
            ],
            "usage": ["input_tokens": 1234, "output_tokens": 210, "cache_creation_input_tokens": 4600,
                      "cache_read_input_tokens": 0],
        ]

        static let lastTurn: JSONValue = [
            "type": "message", "id": "msg_demo_2", "role": "assistant", "model": .string(ClaudeAPI.defaultModel),
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "Done. (Demo: scripted answer, no request was sent.)"]],
            "usage": ["input_tokens": 80, "output_tokens": 30, "cache_creation_input_tokens": 300,
                      "cache_read_input_tokens": 5834],
        ]
    }

    // MARK: Status Notifications (`-LibraryDemo watch`)

    static let watchedMachineNames: Set<String> = ["Mac mini", "NAS", "Build server"]
    static let watchConfiguration = ReachabilityMonitor.Configuration(
        interval: .seconds(3), timeout: .seconds(2), failuresBeforeOffline: 2, maxConcurrentProbes: 4,
        wakeGrace: .seconds(3))

    /// Scripted answers per sample host, after 0.3 s; never a socket.
    actor WatchProbe: ReachabilityProbe {
        private var counts: [String: Int] = [:]

        func probe(host: String, port: Int) async -> ProbeOutcome {
            try? await Task.sleep(for: .milliseconds(300))
            let count = counts[host, default: 0]
            counts[host] = count + 1
            switch host {
            case "mini.local": return .reachable
            case "nas.local": return count % 5 < 2 ? .reachable : .unreachable   // up, up, down, down, down…
            default: return .unreachable
            }
        }
    }

    /// Always "network available": the demo never watches the real path.
    @MainActor
    final class AlwaysOnlinePath: NetworkPathMonitoring {
        func start(_ onChange: @escaping @MainActor @Sendable (Bool) -> Void) {}
        func cancel() {}
    }

    /// Allowed, and prints instead of posting.
    @MainActor
    final class WatchPoster: NotificationPosting {
        private let t: @MainActor (String) -> String

        init(t: @escaping @MainActor (String) -> String) {
            self.t = t
        }

        func authorizationStatus() async -> NotificationPermission { .authorized }

        func post(_ change: StatusChange) async {
            let content = StatusNotificationContent(change) { t($0) }
            FileHandle.standardError.write(Data("[LibraryDemo watch] notification: \(content.title) — \(content.body)\n".utf8))
        }

        func removeDelivered(_ machineID: UUID) async {}
    }

    /// Marks the once-per-run prompt as already shown, so a demo session never asks for access.
    @MainActor
    static func suppressAccessibilityPrompt() {
        var policy = AccessibilityPromptPolicy()
        _ = policy.shouldPrompt(captureStarted: true, trusted: false)
        SystemShortcutTap.promptPolicy = policy
    }

    // MARK: Session History (`-LibraryDemo history`)

    /// One past attempt: days before launch, connect time, length in minutes (nil: no end), outcome.
    private struct PastAttempt {
        let machine: String
        let daysAgo: Double
        let connectMillis: Int?
        let minutes: Double?
        let outcome: SessionOutcome
        var tokens = 0
    }

    private static let pastAttempts: [PastAttempt] = [
        PastAttempt(machine: "Mac mini", daysAgo: 0.1, connectMillis: 640, minutes: 35, outcome: .connected, tokens: 6044),
        PastAttempt(machine: "Mac mini", daysAgo: 1.2, connectMillis: 710, minutes: 92, outcome: .connected),
        PastAttempt(machine: "Mac mini", daysAgo: 2.4, connectMillis: 1320, minutes: 8, outcome: .connected),
        PastAttempt(machine: "Mac mini", daysAgo: 4.0, connectMillis: nil, minutes: 0.05, outcome: .cancelled),
        PastAttempt(machine: "Mac mini", daysAgo: 6.5, connectMillis: 880, minutes: 121, outcome: .connected),
        PastAttempt(machine: "Mac mini", daysAgo: 9.0, connectMillis: 2400, minutes: 14, outcome: .connected),
        PastAttempt(machine: "Mac mini", daysAgo: 13.3, connectMillis: 760, minutes: 47, outcome: .connected),
        PastAttempt(machine: "Mac mini", daysAgo: 45.0, connectMillis: 9100, minutes: 20, outcome: .connected),
        PastAttempt(machine: "NAS", daysAgo: 0.8, connectMillis: 6200, minutes: 12, outcome: .connected),
        PastAttempt(machine: "NAS", daysAgo: 3.1, connectMillis: 4980, minutes: 25, outcome: .connected),
        PastAttempt(machine: "NAS", daysAgo: 5.2, connectMillis: 1900, minutes: 3, outcome: .dropped),
        PastAttempt(machine: "NAS", daysAgo: 7.7, connectMillis: nil, minutes: 0.17, outcome: .unreachable),
        PastAttempt(machine: "Studio", daysAgo: 2.0, connectMillis: nil, minutes: 0.02, outcome: .authFailed),
        PastAttempt(machine: "Studio", daysAgo: 2.0, connectMillis: nil, minutes: 0.03, outcome: .authFailed),
        PastAttempt(machine: "Build server", daysAgo: 3.0, connectMillis: 1800, minutes: nil, outcome: .connected),
        PastAttempt(machine: "Build server", daysAgo: 11.0, connectMillis: 1050, minutes: 66, outcome: .connected),
        PastAttempt(machine: "Old iMac", daysAgo: 10.0, connectMillis: 1500, minutes: 30, outcome: .connected),
        PastAttempt(machine: "Old iMac", daysAgo: 20.0, connectMillis: 7300, minutes: 18, outcome: .connected),
        PastAttempt(machine: "Lab, \"rack 2\"", daysAgo: 16.0, connectMillis: 1100, minutes: 9, outcome: .connected),
    ]

    /// The past records; "Old iMac" and the lab machine are not in the library (deleted since).
    @MainActor
    static func seedHistory(_ context: ModelContext, now: Date) {
        let library = (try? context.fetch(FetchDescriptor<Machine>())) ?? []
        var ids = Dictionary(library.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        for attempt in pastAttempts {
            let machineID = ids[attempt.machine] ?? UUID()
            ids[attempt.machine] = machineID
            let start = now.addingTimeInterval(-attempt.daysAgo * 86_400)
            context.insert(SessionRecord(
                machineID: machineID, machineName: attempt.machine, startedAt: start,
                connectMillis: attempt.connectMillis,
                endedAt: attempt.minutes.map { start.addingTimeInterval($0 * 60) },
                outcome: attempt.outcome,
                bytesReceived: attempt.connectMillis == nil ? 0 : Int64((attempt.minutes ?? 10) * 9_000_000),
                assistantTokens: attempt.tokens))
        }
        try? context.save()
    }

    @MainActor
    static func seed(_ context: ModelContext) {
        let servers = MachineGroup(name: "Servers", sortOrder: 0)
        let office = MachineGroup(name: "Office", sortOrder: 1)
        context.insert(servers)
        context.insert(office)
        var machines = [
            Machine(name: "Mac mini", kind: .macARD, host: "mini.local", username: "vincent", isFavorite: true),
            Machine(name: "Build server", kind: .macARD, host: "10.0.1.20", username: "admin"),
            Machine(name: "NAS", kind: .vnc, host: "nas.local", port: 5901),
            Machine(name: "Studio", kind: .macARD, host: "studio.local", username: "vincent"),
            Machine(name: "Computer use", kind: .anthropicVM, host: "127.0.0.1"),
        ]
        machines[1].group = servers
        machines[2].group = servers
        machines[3].group = office
        if watchesMachines {
            machines.filter { watchedMachineNames.contains($0.name) }.forEach { $0.isWatched = true }
        }
        if showsPublicAddress {
            machines.append(Machine(name: publicMachineName, kind: .macARD, host: "203.0.113.10", username: "vincent"))
        }
        machines.forEach(context.insert)
        try? context.save()
    }

    /// `public` (T5.3 H1): one more machine at 203.0.113.10 (TEST-NET-3, a documentation address the
    /// demo never contacts), connected at launch: the "Unencrypted connection over the Internet" sheet,
    /// then, after Connect anyway, the orange toolbar badge and the shared clipboard off.
    static var showsPublicAddress: Bool { mode == "public" }
    static let publicMachineName = "Cloud Mac"

    // MARK: iCloud Sync (`-LibraryDemo sync | sync-signed-out`)

    /// `sync` (T4.3): the Settings Window opens on a library that syncs (account available, a
    /// "Syncing…" import, then "Last synced"); `sync-signed-out`: no iCloud account, sync off and the
    /// switch disabled ("Sign in to iCloud to sync your library"). The account status is fake, no
    /// `CKContainer` is ever made, the store stays in memory and the settings live in a throwaway
    /// defaults domain, so the Debug app's real iCloud Sync setting is never written.
    static var showsSync: Bool { mode == "sync" || mode == "sync-signed-out" }
    static var syncsInDemo: Bool { mode == "sync" }
    static let syncDefaultsSuite = "fr.vincentlauriat.remotedeck.demo.sync"

    /// A fresh defaults domain for the sync modes, with the setting each one shows.
    static func syncDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: syncDefaultsSuite) ?? .standard
        defaults.removePersistentDomain(forName: syncDefaultsSuite)
        defaults.set(syncsInDemo, forKey: AppSettings.Key.iCloudSyncEnabled)
        defaults.set(true, forKey: AppSettings.Key.onboardingCompleted)
        return defaults
    }

    struct AccountStatus: CloudAccountStatusProviding {
        let status: CloudAccountStatus

        func accountStatus() async -> CloudAccountStatus {
            try? await Task.sleep(for: .milliseconds(500))
            return status
        }
    }

    static var accountStatus: AccountStatus { AccountStatus(status: syncsInDemo ? .available : .noAccount) }

    /// `sync`: one import that runs 2 s, then ends: "Syncing…", then "Last synced".
    static func simulateSync(_ sync: LibrarySync) {
        guard syncsInDemo else { return }
        let id = UUID()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            sync.handle(SyncEvent(id: id, kind: .import, endDate: nil, succeeded: false))
            try? await Task.sleep(for: .seconds(2))
            sync.handle(SyncEvent(id: id, kind: .import, endDate: .now, succeeded: true))
        }
    }
}
#endif
