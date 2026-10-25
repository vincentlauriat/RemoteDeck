import Foundation
import Observation
import Synchronization
import ClaudeKit

/// The two pages of the Help menu (AppFlow › Help and What's New), both read live from the public
/// GitHub repository, as MarkdownViewer does: the README on `main`, and the GitHub Releases.
enum HelpPage: String, CaseIterable, Sendable {
    case help
    case whatsNew

    static let repository = "vincentlauriat/RemoteDeck"
    /// Relative links in the README resolve against the repository's files on GitHub.
    static let linkBase = URL(string: "https://github.com/\(repository)/blob/main/")!

    /// What the window fetches.
    var requestURL: URL {
        switch self {
        case .help: URL(string: "https://raw.githubusercontent.com/\(Self.repository)/main/README.md")!
        case .whatsNew: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=10")!
        }
    }

    /// What its "Open on GitHub" button opens in the browser.
    var webURL: URL {
        switch self {
        case .help: URL(string: "https://github.com/\(Self.repository)#readme")!
        case .whatsNew: URL(string: "https://github.com/\(Self.repository)/releases")!
        }
    }

    var request: URLRequest {
        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        switch self {
        case .help: request.setValue("text/plain", forHTTPHeaderField: "Accept")
        case .whatsNew:
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return request
    }
}

/// Why a page could not be shown. The view turns it into text; the model never holds UI strings.
enum HelpFailure: Error, Equatable, Sendable {
    /// No network, the host could not be found or reached, or the request timed out.
    case offline
    /// HTTP 404: the repository (or its README) is not public yet.
    case notPublished
    /// GitHub's rate limit for unauthenticated requests (HTTP 429, or 403 with no request left).
    case rateLimited
    /// Any other HTTP status.
    case http(status: Int)
    /// Another URL loading error, by its `URLError` code.
    case network(code: Int)
    /// Not UTF-8 text, or JSON that is not a list of releases.
    case invalidResponse
    /// More than `HelpModel.maxResponseBytes`.
    case tooLarge
    /// This process never fetches (hosted tests): `HelpSource.disabled`.
    case disabled
}

/// One GitHub release, as What's New shows it.
struct ReleaseEntry: Equatable, Sendable {
    var title: String
    /// `YYYY-MM-DD`, from `published_at`.
    var date: String?
    var isPrerelease: Bool
    /// Empty when the release has no notes.
    var notes: HelpRendered
}

enum HelpContent: Equatable, Sendable {
    case document(HelpRendered)
    case releases([ReleaseEntry])
}

/// The GitHub Releases API answer: `[{tag_name, name, published_at, prerelease, draft, body}]`.
enum ReleaseNotes {
    private struct Release: Decodable {
        let tagName: String
        let name: String?
        let publishedAt: String?
        let prerelease: Bool?
        let draft: Bool?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, publishedAt = "published_at", prerelease, draft, body
        }
    }

    /// Newest first, as the API returns them; drafts (never public) are skipped.
    static func entries(from data: Data) throws(HelpFailure) -> [ReleaseEntry] {
        let releases: [Release]
        do {
            releases = try JSONDecoder().decode([Release].self, from: data)
        } catch {
            throw .invalidResponse
        }
        return releases.filter { $0.draft != true }.map { release in
            let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = HelpDocument.capped(HelpDocument.stripInvisibles(name.isEmpty ? release.tagName : name),
                                            limit: 200)
            return ReleaseEntry(title: title,
                                date: release.publishedAt.map { HelpDocument.stripInvisibles(String($0.prefix(10))) },
                                isPrerelease: release.prerelease == true,
                                notes: HelpRendered(source: HelpDocument.parse(release.body ?? "")))
        }
    }
}

/// Where Help and What's New get their bytes (TRD › Architecture › Help).
enum HelpSource: Equatable {
    /// GitHub, through `LiveHelpTransport` (an ephemeral session).
    case github
    /// Fixed sample pages, never the network: every `-LibraryDemo` and `-FramebufferDebug` mode.
    case demo
    /// Never fetches: the hosted tests. Each window shows `HelpFailure.disabled`.
    case disabled

    static func resolve(isRunningTests: Bool, demoMode: String?, framebufferDebugMode: String?) -> HelpSource {
        if isRunningTests { return .disabled }
        if demoMode != nil || framebufferDebugMode != nil { return .demo }
        return .github
    }

    /// What the App wired at launch (`RemoteDeckApp.init`); the hosted tests check it is `.disabled`.
    @MainActor private(set) static var wiredByApp: HelpSource?

    /// The transport for this source, recorded as the App's choice.
    @MainActor static func appTransport(for source: HelpSource) -> any HTTPTransport {
        wiredByApp = source
        return transport(for: source)
    }

    static func transport(for source: HelpSource) -> any HTTPTransport {
        switch source {
        case .github: LiveHelpTransport()
        case .disabled: DisabledHelpTransport()
        case .demo:
            #if DEBUG
            LibraryDemo.HelpTransport()
            #else
            DisabledHelpTransport()
            #endif
        }
    }
}

/// The real transport: ClaudeKit's ephemeral `URLSessionTransport` (T5.3 L1: no URL cache, no cookie
/// or credential storage), with a process-wide count of the requests it sent (hosted tests check 0).
/// The body is streamed and stops past `HelpModel.maxResponseBytes` (or at once when the announced
/// `Content-Length` is already above it), so an oversized answer is never read whole.
struct LiveHelpTransport: HTTPTransport {
    static let requestCount = Mutex(0)
    private let session = URLSessionTransport.ephemeralSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        Self.requestCount.withLock { $0 += 1 }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(HelpModel.maxResponseBytes) { throw HelpFailure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > HelpModel.maxResponseBytes { throw HelpFailure.tooLarge }
        }
        return (data, http)
    }
}

/// `HelpSource.disabled`: throws at once, never touches the network.
struct DisabledHelpTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw HelpFailure.disabled
    }
}

/// One Help or What's New window's state (AppFlow › Help and What's New): loading, the page, "no
/// release yet" or a failure with Retry. Fetches only when its window appears (`loadIfNeeded`) or on
/// Retry, never at launch; a newer load wins over a late answer (generation token).
@MainActor
@Observable
final class HelpModel {
    enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded(HelpContent)
        /// What's New with no published release.
        case empty
        case failed(HelpFailure)
    }

    /// The README is about 10 KB and ten releases' notes a few more: anything above this is not them.
    nonisolated static let maxResponseBytes = 2 * 1024 * 1024

    let page: HelpPage
    private(set) var phase: Phase = .idle
    @ObservationIgnored private let transport: any HTTPTransport
    @ObservationIgnored private var generation = 0

    init(page: HelpPage, transport: any HTTPTransport) {
        self.page = page
        self.transport = transport
    }

    var isLoading: Bool { phase == .loading }

    /// The window appeared: fetch unless the page is already there or on its way.
    func loadIfNeeded() async {
        switch phase {
        case .idle, .failed: await load()
        case .loading, .loaded, .empty: break
        }
    }

    /// Fetches again whatever the state (Retry, Reload).
    func load() async {
        generation += 1
        let token = generation
        phase = .loading
        let result: Phase
        do {
            result = try await fetch()
        } catch {
            result = .failed(error)
        }
        guard token == generation else { return }
        // The window closed mid-request (its `.task` was cancelled): fetch again when it reopens.
        phase = Task.isCancelled ? .idle : result
    }

    private func fetch() async throws(HelpFailure) -> Phase {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(page.request)
        } catch let failure as HelpFailure {
            throw failure
        } catch let error as URLError {
            throw Self.failure(for: error)
        } catch {
            throw .network(code: (error as NSError).code)
        }
        try Self.check(response)
        if response.expectedContentLength > Int64(Self.maxResponseBytes) { throw .tooLarge }
        guard data.count <= Self.maxResponseBytes else { throw .tooLarge }
        // Decoding, splitting and building the attributed strings run off the main actor: a hostile or
        // huge page never holds the Session Windows.
        let page = page
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Phase, HelpFailure> in
            do throws(HelpFailure) {
                return .success(try Self.decode(data, page: page))
            } catch {
                return .failure(error)
            }
        }.value
        return try result.get()
    }

    nonisolated static func decode(_ data: Data, page: HelpPage) throws(HelpFailure) -> Phase {
        switch page {
        case .help:
            guard let text = String(data: data, encoding: .utf8) else { throw .invalidResponse }
            return .loaded(.document(HelpRendered(source: HelpDocument.parse(text))))
        case .whatsNew:
            let entries = try ReleaseNotes.entries(from: data)
            return entries.isEmpty ? .empty : .loaded(.releases(entries))
        }
    }

    static func check(_ response: HTTPURLResponse) throws(HelpFailure) {
        switch response.statusCode {
        case 200...299: return
        case 404: throw .notPublished
        case 429: throw .rateLimited
        case 403 where response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            || response.value(forHTTPHeaderField: "retry-after") != nil: throw .rateLimited
        default: throw .http(status: response.statusCode)
        }
    }

    static func failure(for error: URLError) -> HelpFailure {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            .offline
        default:
            .network(code: error.errorCode)
        }
    }
}
