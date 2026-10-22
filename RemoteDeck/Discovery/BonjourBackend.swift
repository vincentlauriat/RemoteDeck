import Foundation
import Network
import dnssd
import SystemConfiguration

/// Live browsers: one `NWBrowser` per service type, on the main queue, peer-to-peer off.
struct NWBonjourBrowserFactory: BonjourBrowserFactory {
    func events(for type: BonjourServiceType) -> AsyncStream<BonjourBrowseEvent> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type.rawValue, domain: "local."), using: parameters)
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.ready)
                case .waiting(let error):
                    continuation.yield(.waiting(Self.problem(error)))
                case .failed(let error):
                    continuation.yield(.failed(Self.problem(error)))
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(.results(Set(results.compactMap { result in
                    guard case .service(let name, _, let domain, _) = result.endpoint else { return nil }
                    return BonjourService(name: name, type: type, domain: domain)
                })))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .main)
        }
    }

    /// TN3179 › Check for local network access: a browser denied Local Network access waits with
    /// kDNSServiceErr_PolicyDenied (-65570).
    nonisolated static func problem(_ error: NWError) -> BonjourProblem {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return .permissionDenied
        }
        return .error(code: error.errorCode)   // POSIX, DNS-SD, TLS or Wi-Fi Aware code (CustomNSError)
    }
}

/// Live resolver: `DNSServiceResolve` gives the SRV target (`minim6.local.`) and port from mDNS,
/// without opening a connection to the host (an `NWConnection` would, and yields an IP address).
struct DNSSDResolver: BonjourResolver {
    static let timeout: Duration = .seconds(5)

    /// A `DNSServiceResolveReply` answer: the SRV target without its root dot, and the port, which
    /// DNS-SD hands over in network byte order.
    nonisolated static func endpoint(hostTarget: String, networkPort: UInt16) -> BonjourEndpoint {
        BonjourEndpoint(host: hostTarget.hasSuffix(".") ? String(hostTarget.dropLast()) : hostTarget,
                        port: Int(UInt16(bigEndian: networkPort)))
    }

    func resolve(_ service: BonjourService) async -> BonjourEndpoint? {
        let operation = ResolveOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.start(service, timeout: Self.timeout, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in operation.finish(nil) }
        }
    }
}

/// One `DNSServiceResolve`, on the main queue: the first answer, a timeout or a cancel finishes it,
/// and the `DNSServiceRef` is deallocated on that same queue.
@MainActor
private final class ResolveOperation {
    private var ref: DNSServiceRef?
    private var continuation: CheckedContinuation<BonjourEndpoint?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func start(_ service: BonjourService, timeout: Duration,
               continuation: CheckedContinuation<BonjourEndpoint?, Never>) {
        guard !finished else {
            continuation.resume(returning: nil)   // cancelled before it started
            return
        }
        self.continuation = continuation
        var ref: DNSServiceRef?
        // Unretained: `DNSSDResolver.resolve` keeps the operation alive until it finishes, and the
        // callback can only run before `finish` deallocates the ref.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceResolve(
            &ref, 0, UInt32(kDNSServiceInterfaceIndexAny), service.name, service.type.rawValue, service.domain,
            { _, _, _, errorCode, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let endpoint: BonjourEndpoint? = if errorCode == kDNSServiceErr_NoError, let hostTarget {
                    DNSSDResolver.endpoint(hostTarget: String(cString: hostTarget), networkPort: port)
                } else {
                    nil
                }
                MainActor.assumeIsolated {   // DNSServiceSetDispatchQueue(.main) below
                    Unmanaged<ResolveOperation>.fromOpaque(context).takeUnretainedValue().finish(endpoint)
                }
            },
            context
        )
        guard status == kDNSServiceErr_NoError, let ref else {
            finish(nil)
            return
        }
        self.ref = ref
        guard DNSServiceSetDispatchQueue(ref, .main) == kDNSServiceErr_NoError else {
            finish(nil)   // never scheduled: no answer would ever come
            return
        }
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(nil)
        }
    }

    func finish(_ endpoint: BonjourEndpoint?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        continuation?.resume(returning: endpoint)
        continuation = nil
    }
}

enum LocalHost {
    /// This Mac's Bonjour host name (`<LocalHostName>.local`), so the panel does not list it.
    static var bonjourNames: Set<String> {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return [] }
        return ["\(name).local".lowercased()]
    }
}
