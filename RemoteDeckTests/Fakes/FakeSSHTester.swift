import Foundation
import SSHKit
@testable import RemoteDeck

/// An SSH Test connection without the network: records each call, optionally presents a host key
/// to the editor's validator first (refused → `.hostKeyRejected`), then answers `result`.
actor FakeSSHTester: SSHTester {
    /// What the test authenticated with (`SSHCredentials` is not Equatable).
    enum Credentials: Equatable, Sendable {
        case password(user: String, password: String)
        case key(user: String, algorithm: String)
    }

    struct Call: Sendable {
        let host: String
        let port: UInt16
        let credentials: Credentials
        let timeout: Duration
    }

    private(set) var calls: [Call] = []
    private var result: Result<Void, SSHError>
    private let hostKey: SSHHostKey?
    private let hangs: Bool

    init(result: Result<Void, SSHError> = .success(()), hostKey: SSHHostKey? = nil, hangs: Bool = false) {
        self.result = result
        self.hostKey = hostKey
        self.hangs = hangs
    }

    func test(host: String, port: UInt16, credentials: SSHCredentials, timeout: Duration,
              trusted: @escaping @Sendable (SSHHostKey) async -> Bool) async throws(SSHError) {
        let summary: Credentials = switch credentials {
        case .password(let user, let password): .password(user: user, password: password)
        case .key(let user, let key): .key(user: user, algorithm: key.algorithm)
        }
        calls.append(Call(host: host, port: port, credentials: summary, timeout: timeout))
        if let hostKey, !(await trusted(hostKey)) { throw .hostKeyRejected(hostKey) }
        if hangs {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                throw .connectionClosed
            }
        }
        try result.get()
    }
}

/// The "Import Key…" panel: answers the URL it was given (nil: Cancel), never a panel.
@MainActor
final class FakeKeyFilePicker: KeyFilePicking {
    var url: URL?

    init(url: URL? = nil) {
        self.url = url
    }

    func chooseKeyFile() async -> URL? { url }
}
