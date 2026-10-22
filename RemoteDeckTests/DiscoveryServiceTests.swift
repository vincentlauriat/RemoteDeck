import Foundation
import Network
import dnssd
import SwiftData
import Testing
import RemoteDeckCore
@testable import RemoteDeck

/// Hands out one stream per browse and lets the test push browser events into it.
@MainActor
final class FakeBonjourBrowsers: BonjourBrowserFactory {
    private var continuations: [BonjourServiceType: AsyncStream<BonjourBrowseEvent>.Continuation] = [:]
    private(set) var started: [BonjourServiceType] = []

    func events(for type: BonjourServiceType) -> AsyncStream<BonjourBrowseEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BonjourBrowseEvent.self)
        continuations[type] = continuation
        started.append(type)
        return stream
    }

    func send(_ event: BonjourBrowseEvent, _ type: BonjourServiceType) {
        continuations[type]?.yield(event)
    }
}

/// Answers from a table; an unknown service does not resolve.
@MainActor
final class FakeBonjourResolver: BonjourResolver {
    var endpoints: [BonjourService: BonjourEndpoint]
    private(set) var calls: [BonjourService] = []

    init(_ endpoints: [BonjourService: BonjourEndpoint] = [:]) {
        self.endpoints = endpoints
    }

    func resolve(_ service: BonjourService) async -> BonjourEndpoint? {
        calls.append(service)
        return endpoints[service]
    }
}

/// Answers each resolution only when the test says so, and ignores cancellation (like a DNS-SD
/// answer already on its way): call `answer(_:with:)` with the call's index.
@MainActor
final class ControllableBonjourResolver: BonjourResolver {
    private var pending: [CheckedContinuation<BonjourEndpoint?, Never>?] = []
    var callCount: Int { pending.count }

    func resolve(_ service: BonjourService) async -> BonjourEndpoint? {
        await withCheckedContinuation { pending.append($0) }
    }

    func answer(_ index: Int, with endpoint: BonjourEndpoint?) {
        pending[index]?.resume(returning: endpoint)
        pending[index] = nil
    }
}

@MainActor
struct DiscoveryServiceTests {
    static let miniRFB = BonjourService(name: "minim6", type: .rfb, domain: "local.")
    static let miniARD = BonjourService(name: "minim6", type: .netAssistant, domain: "local.")
    static let piRFB = BonjourService(name: "Raspberry Pi", type: .rfb, domain: "local.")
    static let endpoints: [BonjourService: BonjourEndpoint] = [
        miniRFB: BonjourEndpoint(host: "minim6.local", port: 5900),
        miniARD: BonjourEndpoint(host: "minim6.local", port: 3283),
        piRFB: BonjourEndpoint(host: "raspberrypi.local", port: 5901),
    ]

    let browsers = FakeBonjourBrowsers()
    let resolver = FakeBonjourResolver(endpoints)

    private func service(excluding: Set<String> = [], emptyAfter: Duration = .seconds(60)) -> DiscoveryService {
        DiscoveryService(browsers: browsers, resolver: resolver, excludedHosts: excluding, emptyAfter: emptyAfter)
    }

    // MARK: Merge (a Mac may advertise both types)

    @Test func mergesBothServiceTypesOfAHostIntoOneRow() {
        let merged = DiscoveredMachine.merge([
            Self.miniARD: BonjourEndpoint(host: "MINIM6.local", port: 3283),
            Self.miniRFB: BonjourEndpoint(host: "minim6.local", port: 5900),
            Self.piRFB: BonjourEndpoint(host: "raspberrypi.local", port: 5901),
        ])
        #expect(merged.count == 2)
        let mini = merged[0]
        #expect(mini.name == "minim6")
        #expect(mini.host == "minim6.local")             // the RFB service's spelling
        #expect(mini.port == 5900)                       // never the ARD agent's 3283
        #expect(mini.services == [.rfb, .netAssistant])
        #expect(mini.kind == .macARD)
        let pi = merged[1]
        #expect(pi.port == 5901)
        #expect(pi.kind == .vnc)
    }

    @Test func remoteManagementAloneUsesTheScreenSharingPort() {
        let merged = DiscoveredMachine.merge([Self.miniARD: BonjourEndpoint(host: "minim6.local", port: 3283)])
        #expect(merged.map(\.port) == [5900])
        #expect(merged.map(\.kind) == [.macARD])
    }

    @Test func excludedHostIsNotListed() {
        let merged = DiscoveredMachine.merge(Self.endpoints, excludingHosts: ["minim6.local"])
        #expect(merged.map(\.name) == ["Raspberry Pi"])
    }

    @Test func serviceMergesResultsOfBothBrowsersAndFollowsRemovals() async {
        let discovery = service()
        discovery.start()
        #expect(browsers.started == [.rfb, .netAssistant])
        #expect(discovery.phase == .searching)

        browsers.send(.results([Self.miniRFB, Self.piRFB]), .rfb)
        browsers.send(.results([Self.miniARD]), .netAssistant)
        #expect(await waitUntil { discovery.machines.first?.services.count == 2 })
        #expect(discovery.machines.map(\.name) == ["minim6", "Raspberry Pi"])
        #expect(discovery.phase == .found)

        // Screen Sharing turned off on minim6: the row stays, with Remote Management only.
        browsers.send(.results([Self.piRFB]), .rfb)
        #expect(await waitUntil { discovery.machines.first?.services == [.netAssistant] })

        browsers.send(.results([]), .netAssistant)
        #expect(await waitUntil { discovery.machines.map(\.name) == ["Raspberry Pi"] })
        discovery.stop()
    }

    @Test func unresolvedServiceIsNotListed() async {
        let ghost = BonjourService(name: "Ghost", type: .rfb, domain: "local.")
        let discovery = service()
        discovery.start()
        browsers.send(.results([ghost, Self.piRFB]), .rfb)
        #expect(await waitUntil { resolver.calls.count == 2 && !discovery.machines.isEmpty })
        #expect(discovery.machines.map(\.name) == ["Raspberry Pi"])
        discovery.stop()
    }

    /// An event already buffered in the stream when `stop` runs is still handed to the consuming
    /// task: only the generation check keeps it out.
    @Test func eventsBufferedBeforeStopAreIgnored() async throws {
        let discovery = service()
        discovery.start()
        browsers.send(.results([Self.piRFB]), .rfb)   // buffered: the consumer has not run yet
        discovery.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolver.calls.isEmpty)
        #expect(discovery.machines.isEmpty)
    }

    /// A service that vanishes and comes back: the first (cancelled) resolution answering late must
    /// not overwrite the second one's result, nor drop it.
    @Test func lateAnswerOfACancelledResolutionIsIgnored() async {
        let resolver = ControllableBonjourResolver()
        let discovery = DiscoveryService(browsers: browsers, resolver: resolver, emptyAfter: .seconds(60))
        discovery.start()
        browsers.send(.results([Self.piRFB]), .rfb)
        #expect(await waitUntil { resolver.callCount == 1 })
        browsers.send(.results([]), .rfb)
        browsers.send(.results([Self.piRFB]), .rfb)
        #expect(await waitUntil { resolver.callCount == 2 })

        resolver.answer(1, with: BonjourEndpoint(host: "raspberrypi.local", port: 5901))
        #expect(await waitUntil { discovery.machines.map(\.port) == [5901] })
        resolver.answer(0, with: BonjourEndpoint(host: "stale.local", port: 9999))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(discovery.machines.map(\.host) == ["raspberrypi.local"])
        #expect(discovery.machines.map(\.port) == [5901])
        discovery.stop()
    }

    // MARK: Live backend helpers

    @Test func resolvedEndpointDropsTheRootDotAndReadsTheNetworkBytePort() {
        let mini = DNSSDResolver.endpoint(hostTarget: "minim6.local.", networkPort: UInt16(5900).bigEndian)
        #expect(mini == BonjourEndpoint(host: "minim6.local", port: 5900))
        // 5901 = 0x170D: byte-swapped it would read 3351.
        let pi = DNSSDResolver.endpoint(hostTarget: "raspberrypi.local", networkPort: UInt16(5901).bigEndian)
        #expect(pi == BonjourEndpoint(host: "raspberrypi.local", port: 5901))
    }

    @Test func browserErrorKeepsItsCode() {
        #expect(NWBonjourBrowserFactory.problem(.posix(.ENETDOWN)) == .error(code: Int(POSIXErrorCode.ENETDOWN.rawValue)))
        #expect(NWBonjourBrowserFactory.problem(.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)))
            == .error(code: Int(kDNSServiceErr_ServiceNotRunning)))
    }

    // MARK: Already in the library

    @Test func rowMatchingALibraryMachineIsMarkedAdded() throws {
        let context = try makeTestContext()
        context.insert(Machine(name: "Mini", kind: .macARD, host: "minim6.local.", username: "vincent"))
        let keys = Set(try context.fetch(FetchDescriptor<Machine>()).map(\.normalizedKey))
        // Another spelling of the same host (case, as the SRV record has it): same machine.
        let mini = DiscoveredMachine(host: "MinIM6.local", name: "minim6", port: 5900, services: [.rfb])
        #expect(mini.isInLibrary(keys))
        let pi = DiscoveredMachine(host: "raspberrypi.local", name: "Raspberry Pi", port: 5901, services: [.rfb])
        #expect(!pi.isInLibrary(keys))
        // Same host, another port: a different machine.
        let other = DiscoveredMachine(host: "minim6.local", name: "minim6", port: 5901, services: [.rfb])
        #expect(!other.isInLibrary(keys))
    }

    // MARK: Browser states

    @Test func policyDeniedMapsToPermissionDenied() {
        let denied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        #expect(NWBonjourBrowserFactory.problem(denied) == .permissionDenied)
        let other = NWError.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))
        #expect(NWBonjourBrowserFactory.problem(other) != .permissionDenied)
    }

    @Test func permissionDeniedShowsTheBlockedStateUntilTheBrowserIsReady() async {
        let discovery = service()
        discovery.start()
        browsers.send(.waiting(.permissionDenied), .rfb)
        #expect(await waitUntil { discovery.phase == .blocked })
        // Access granted in System Settings: the system retries the same browser.
        browsers.send(.ready, .rfb)
        #expect(await waitUntil { discovery.phase == .searching })
        discovery.stop()
    }

    @Test func otherWaitKeepsSearching() async throws {
        let discovery = service()
        discovery.start()
        browsers.send(.waiting(.error(code: 50)), .rfb)
        browsers.send(.ready, .netAssistant)
        try await Task.sleep(for: .milliseconds(50))
        #expect(discovery.phase == .searching)
        discovery.stop()
    }

    @Test func failedBrowserShowsTheErrorAndRetryStartsNewBrowsers() async {
        let discovery = service()
        discovery.start()
        browsers.send(.failed(.error(code: -65563)), .netAssistant)
        #expect(await waitUntil { discovery.phase == .failed(code: -65563) })
        discovery.start()
        #expect(browsers.started == [.rfb, .netAssistant, .rfb, .netAssistant])
        #expect(discovery.phase == .searching)
        discovery.stop()
    }

    @Test func oneFailedBrowserKeepsTheOtherBrowsersRows() async {
        let discovery = service()
        discovery.start()
        browsers.send(.results([Self.piRFB]), .rfb)
        #expect(await waitUntil { !discovery.machines.isEmpty })
        browsers.send(.failed(.error(code: -65563)), .netAssistant)
        #expect(await waitUntil { discovery.problemWithRows == .error(code: -65563) })
        #expect(discovery.phase == .found)
        #expect(discovery.machines.map(\.name) == ["Raspberry Pi"])
        // The last row goes away: the failure is all that is left to show.
        browsers.send(.results([]), .rfb)
        #expect(await waitUntil { discovery.phase == .failed(code: -65563) })
        #expect(discovery.problemWithRows == nil)
        discovery.stop()
    }

    @Test func nothingFoundTurnsIntoTheEmptyState() async {
        let discovery = service(emptyAfter: .milliseconds(30))
        discovery.start()
        #expect(discovery.phase == .searching)
        #expect(await waitUntil { discovery.phase == .empty })
        browsers.send(.results([Self.piRFB]), .rfb)
        #expect(await waitUntil { discovery.phase == .found })
        discovery.stop()
    }

    // MARK: Add → pre-filled Machine Editor

    @Test func addPrefillsTheEditorFromTheRow() throws {
        let context = try makeTestContext()
        let mini = try #require(DiscoveredMachine.merge(Self.endpoints).first)
        let editor = MachineEditorModel(machine: nil, context: context, passwords: FakePasswordStore(),
                                        tester: FakeConnectionTester(), defaultSharedClipboard: true,
                                        discovered: mini)
        #expect(editor.isNew)
        #expect(editor.kind == .macARD)
        #expect(editor.name == "minim6")
        #expect(editor.host == "minim6.local")
        #expect(editor.portText == "5900")
        #expect(editor.username.isEmpty)
        // Mac ARD needs a user name: Save asks for it rather than saving.
        #expect(editor.save() == nil)
        #expect(editor.issue(for: .username) == .empty)
    }

    @Test func prefilledNameIsCutToTheNameLimit() throws {
        let long = DiscoveredMachine(host: "pi.local", name: String(repeating: "x", count: 80), port: 5901, services: [.rfb])
        let editor = MachineEditorModel(machine: nil, context: try makeTestContext(), passwords: FakePasswordStore(),
                                        tester: FakeConnectionTester(), defaultSharedClipboard: true, discovered: long)
        #expect(editor.name.count == MachineValidator.maxNameLength)
        #expect(editor.kind == .vnc)
        #expect(editor.portText == "5901")
    }
}
