import Foundation
import Network
import dnssd

/// Reachability probe for Status Notifications (TRD › Performance): a TCP connection to `host:port`,
/// closed as soon as it is established. No byte is sent or read: no RFB handshake, no credentials.
/// An open port answers; a closed one (Screen Sharing turned off: TCP reset), an unknown host or no
/// route does not.
///
/// The banner is not read on purpose: the question is "does the machine still answer", and the
/// connect alone answers it without leaving a half-open RFB session on the server or waiting for
/// the 12 bytes.
public enum TCPProbe {
    public enum Outcome: Equatable, Sendable {
        case reachable
        case unreachable
        /// Local Network privacy refused the connection (TN3179): nothing is known about the host.
        case localNetworkDenied
    }

    /// `.reachable` once the connection is ready. Any failure is `.unreachable`, except a Local
    /// Network refusal; a cancelled caller gets `.unreachable` at once (the connection is cancelled
    /// with it). `connectTimeout` (whole seconds, at least 1) is Network.framework's TCP connection
    /// timeout, a backstop: callers race the probe against their own deadline.
    public static func probe(host: String, port: UInt16, connectTimeout: Int = 5) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else { return .unreachable }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, connectTimeout)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: NWParameters(tls: nil, tcp: tcp))
        let queue = DispatchQueue(label: "RFBKit.TCPProbe")
        let pending = PendingResult<Outcome>()
        let outcome = await withTaskCancellationHandler {
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                pending.attach(continuation)
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready:
                        pending.resume(with: .success(.reachable))
                        connection?.cancel()   // close at once (FIN)
                    case .waiting(let error), .failed(let error):
                        pending.resume(with: .success(classify(error, path: connection?.currentPath)))
                        connection?.cancel()
                    case .cancelled:
                        pending.resume(with: .success(.unreachable))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            // Ends the wait even when no state update will come (cancel before `start`, review M1).
            pending.resume(with: .success(.unreachable))
            connection.cancel()
        }
        return Task.isCancelled ? .unreachable : (outcome ?? .unreachable)
    }

    /// Local Network denied: the path says so, or DNS-SD refused a `.local` name (PolicyDenied).
    static func classify(_ error: NWError, path: NWPath?) -> Outcome {
        if path?.unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return .localNetworkDenied
        }
        return .unreachable
    }
}
