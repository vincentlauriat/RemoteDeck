import Foundation
import Observation
import RemoteDeckCore

// MARK: - Bonjour vocabulary

/// The service types the Discovery Panel browses (TRD › External services). Both are listed in
/// `NSBonjourServices` (project.yml).
enum BonjourServiceType: String, CaseIterable, Sendable {
    /// Screen Sharing / any RFB server.
    case rfb = "_rfb._tcp"
    /// Apple Remote Desktop agent (Remote Management). Its port (3283) is not the RFB port.
    case netAssistant = "_net-assistant._udp"
}

/// A Bonjour service instance. No interface: the same service seen on several interfaces (Wi-Fi,
/// Ethernet, loopback for this Mac) is one service.
struct BonjourService: Hashable, Sendable {
    let name: String
    let type: BonjourServiceType
    let domain: String
}

/// A resolved service: the SRV target host (without its trailing dot) and port.
struct BonjourEndpoint: Hashable, Sendable {
    let host: String
    let port: Int
}

enum BonjourProblem: Equatable, Sendable {
    /// Local Network access denied (kDNSServiceErr_PolicyDenied, TN3179).
    case permissionDenied
    /// Any other browser error, with its code (`NWError`'s POSIX, DNS-SD or TLS code).
    case error(code: Int)
}

enum BonjourBrowseEvent: Equatable, Sendable {
    case ready
    /// The browser's whole current result set.
    case results(Set<BonjourService>)
    /// The browser keeps running and retries by itself (e.g. Local Network access granted later).
    case waiting(BonjourProblem)
    /// The browser stopped; Retry starts a new one.
    case failed(BonjourProblem)
}

/// One browser per service type. The stream ends when the browser fails; cancelling the
/// consuming task stops the browser.
@MainActor
protocol BonjourBrowserFactory {
    func events(for type: BonjourServiceType) -> AsyncStream<BonjourBrowseEvent>
}

/// Resolves a service to its host name and port, without connecting to it. `nil`: not resolved
/// in time.
@MainActor
protocol BonjourResolver {
    func resolve(_ service: BonjourService) async -> BonjourEndpoint?
}

// MARK: - Discovered machine

/// A Discovery Panel row: the services of one host, merged.
struct DiscoveredMachine: Identifiable, Equatable, Sendable {
    /// Host name as resolved, e.g. `minim6.local`.
    let host: String
    let name: String
    /// The RFB port: `_rfb._tcp`'s when the host advertises it, else 5900 (Screen Sharing).
    let port: Int
    let services: Set<BonjourServiceType>

    var id: String { host.lowercased() }

    /// Remote Management (`_net-assistant._udp`) means a Mac; an RFB service alone cannot be
    /// told apart from another VNC server without connecting, so it is guessed VNC.
    var kind: MachineKind { services.contains(.netAssistant) ? .macARD : .vnc }

    var normalizedKey: String { MachineValidator.normalizedKey(host: host, port: port) }

    /// Already in the library: a machine has the same `host:port` (MachineValidator's key).
    func isInLibrary(_ libraryKeys: Set<String>) -> Bool {
        libraryKeys.contains(normalizedKey)
    }

    /// Groups resolved services by host (a Mac may advertise both types) and drops `excludedHosts`
    /// (this Mac). Sorted by name.
    static func merge(_ resolved: [BonjourService: BonjourEndpoint],
                      excludingHosts excludedHosts: Set<String> = []) -> [DiscoveredMachine] {
        let byHost = Dictionary(grouping: resolved) { $0.value.host.lowercased() }
        return byHost.compactMap { hostKey, entries -> DiscoveredMachine? in
            guard !excludedHosts.contains(hostKey) else { return nil }
            let rfb = entries.filter { $0.key.type == .rfb }.min { $0.key.name < $1.key.name }
            let named = rfb ?? entries.min { $0.key.name < $1.key.name }!
            return DiscoveredMachine(
                host: named.value.host,
                name: named.key.name,
                port: rfb?.value.port ?? 5900,
                services: Set(entries.map(\.key.type))
            )
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.host < $1.host : order == .orderedAscending
        }
    }
}

// MARK: - Discovery service

/// Discovery Panel state (AppFlow › Discovery Panel): one browser per service type, each new
/// service resolved to `host:port`, results merged per host. Runs only while the panel is open.
@Observable
@MainActor
final class DiscoveryService {
    enum Phase: Equatable {
        /// "Searching…" until a row appears or `emptyAfter` passes.
        case searching
        case found
        /// No result after `emptyAfter`: empty state with Retry.
        case empty
        /// Local Network access denied: blocked state with a link to System Settings.
        case blocked
        /// A browser failed and nothing is listed: message (with the error code) and Retry.
        case failed(code: Int)
    }

    /// AppFlow: "No result after 10 s → empty state".
    static let defaultEmptyAfter: Duration = .seconds(10)

    private(set) var machines: [DiscoveredMachine] = []
    private(set) var timedOut = false
    private var problems: [BonjourServiceType: BonjourProblem] = [:]

    /// Rows win: one browser failing (or denied) never hides what the other one found.
    var phase: Phase {
        if !machines.isEmpty { return .found }
        if problems.values.contains(.permissionDenied) { return .blocked }
        if let code = failureCode { return .failed(code: code) }
        return timedOut ? .empty : .searching
    }

    /// A browser problem while rows are listed: shown under the list, so the user knows some
    /// machines may be missing.
    var problemWithRows: BonjourProblem? {
        guard !machines.isEmpty else { return nil }
        if problems.values.contains(.permissionDenied) { return .permissionDenied }
        return failureCode.map { .error(code: $0) }
    }

    private var failureCode: Int? {
        problems.values.lazy.compactMap { problem -> Int? in
            if case .error(let code) = problem { code } else { nil }
        }.first
    }

    @ObservationIgnored private let browsers: any BonjourBrowserFactory
    @ObservationIgnored private let resolver: any BonjourResolver
    @ObservationIgnored private let excludedHosts: Set<String>
    @ObservationIgnored private let emptyAfter: Duration
    @ObservationIgnored private var results: [BonjourServiceType: Set<BonjourService>] = [:]
    @ObservationIgnored private var resolved: [BonjourService: BonjourEndpoint] = [:]
    /// Running resolutions, each with its id: a service that vanishes and comes back gets a new
    /// one, and a late answer from the cancelled resolution never lands.
    @ObservationIgnored private var resolving: [BonjourService: (id: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var nextResolutionID = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Bumped by every start and stop, so a late event or resolution never lands on a newer run.
    @ObservationIgnored private var generation = 0

    init(browsers: any BonjourBrowserFactory, resolver: any BonjourResolver,
         excludedHosts: Set<String> = [], emptyAfter: Duration = defaultEmptyAfter) {
        self.browsers = browsers
        self.resolver = resolver
        self.excludedHosts = Set(excludedHosts.map { $0.lowercased() })
        self.emptyAfter = emptyAfter
    }

    /// Starts (or restarts, for Retry) browsing both service types.
    func start() {
        stop()
        machines = []
        timedOut = false
        problems = [:]
        results = [:]
        resolved = [:]
        let generation = self.generation
        for type in BonjourServiceType.allCases {
            let events = browsers.events(for: type)
            tasks.append(Task { [weak self] in
                for await event in events {
                    guard let self, self.generation == generation else { return }
                    self.handle(event, for: type)
                }
            })
        }
        let emptyAfter = self.emptyAfter
        tasks.append(Task { [weak self] in
            do {
                try await Task.sleep(for: emptyAfter)
            } catch {
                return
            }
            guard let self, self.generation == generation else { return }
            self.timedOut = true
        })
    }

    /// Stops the browsers and pending resolutions (panel closed).
    func stop() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        resolving.values.forEach { $0.task.cancel() }
        resolving = [:]
    }

    private func handle(_ event: BonjourBrowseEvent, for type: BonjourServiceType) {
        switch event {
        case .ready:
            problems[type] = nil
        case .results(let services):
            problems[type] = nil
            update(services, for: type)
        case .waiting(let problem):
            // Only a denial is shown: other waits (no network yet) keep "Searching…".
            problems[type] = problem == .permissionDenied ? problem : nil
        case .failed(let problem):
            problems[type] = problem
        }
    }

    private func update(_ services: Set<BonjourService>, for type: BonjourServiceType) {
        let previous = results[type] ?? []
        results[type] = services
        for gone in previous.subtracting(services) {
            resolving.removeValue(forKey: gone)?.task.cancel()
            resolved[gone] = nil
        }
        for new in services.subtracting(previous) {
            resolve(new)
        }
        refresh()
    }

    private func resolve(_ service: BonjourService) {
        let generation = self.generation
        let resolver = self.resolver
        nextResolutionID += 1
        let id = nextResolutionID
        let task = Task { [weak self] in
            let endpoint = await resolver.resolve(service)
            guard !Task.isCancelled, let self, self.generation == generation,
                  self.resolving[service]?.id == id else { return }
            self.resolving[service] = nil
            self.resolved[service] = endpoint
            self.refresh()
        }
        resolving[service] = (id, task)
    }

    private func refresh() {
        let merged = DiscoveredMachine.merge(resolved, excludingHosts: excludedHosts)
        if merged != machines { machines = merged }
    }
}
