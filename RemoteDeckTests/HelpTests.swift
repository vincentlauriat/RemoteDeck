import Foundation
import Testing
import ClaudeKit
@testable import RemoteDeck

/// Help and What's New (AppFlow › Help and What's New): the pure Markdown block splitter, the Releases
/// API answer, the window model's states on a fake transport, and that the test host never fetches.
/// Nothing here reaches the network.
@MainActor
struct HelpTests {
    // MARK: HelpDocument

    @Test func splitsTheReadmeConstructs() {
        let blocks = HelpDocument.parse("""
        <div align="center">

        # RemoteDeck

        **Native** remote screens.

        [![Release](https://img.shields.io/github/v/release/x/y)](https://github.com/x/y/releases)
        [![Swift](https://img.shields.io/badge/Swift-6-F05138)](https://swift.org)

        </div>

        <table><tr><td>HTML layout</td></tr></table>

        ![Library window](docs/assets/library.png)

        Setext title
        ------------

        | | |
        | --- | --- |
        | 🖥️ **Session** | Uses `a | b` and RemoteDeck-<version>.dmg |
        | Short |

        - Top
          continued
          - Nested
        - [x] Done
        - [ ] Not yet
        1. First
        2) Second

        > Quoted
        lazy line

        ```bash
        <div>kept in code</div>
        ```

        ---
        <!-- a comment
        on two lines -->
        Last\\
        line
        """)
        #expect(blocks == [
            .heading(level: 1, text: "RemoteDeck"),
            .paragraph("**Native** remote screens."),
            .heading(level: 2, text: "Setext title"),
            .table(header: ["", ""], rows: [
                ["🖥️ **Session**", "Uses `a | b` and RemoteDeck-<version>.dmg"],
                ["Short", ""],
            ]),
            .list([
                HelpListItem(marker: .bullet, depth: 0, text: "Top continued"),
                HelpListItem(marker: .bullet, depth: 1, text: "Nested"),
                HelpListItem(marker: .task(done: true), depth: 0, text: "Done"),
                HelpListItem(marker: .task(done: false), depth: 0, text: "Not yet"),
                HelpListItem(marker: .number(1), depth: 0, text: "First"),
                HelpListItem(marker: .number(2), depth: 0, text: "Second"),
            ]),
            .quote("Quoted lazy line"),
            .code("<div>kept in code</div>"),
            .rule,
            .paragraph("Last\nline"),
        ])
    }

    @Test func cleansInlineImagesAndTagsOnly() {
        #expect(HelpDocument.cleanInline("a ![x](y.png) b") == "a  b")
        #expect(HelpDocument.cleanInline("[![b](i.svg)](l) text") == "text")
        #expect(HelpDocument.cleanInline("one<br>two <b>bold</b>") == "one\ntwo bold")
        #expect(HelpDocument.cleanInline("RemoteDeck-<version>.dmg") == "RemoteDeck-<version>.dmg")
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(HelpDocument.parse("```\nline 1\n# not a heading") == [.code("line 1\n# not a heading")])
    }

    /// The README this window shows in a release: no HTML, badge or image survives, and its Features
    /// table and code blocks come through.
    @Test func theRepositoryReadmeRendersWithoutHTMLOrImages() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let blocks = HelpDocument.parse(try String(contentsOf: url, encoding: .utf8))
        let texts = blocks.flatMap { block -> [String] in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): [text]
            case .list(let items): items.map(\.text)
            case .table(let header, let rows): header + rows.flatMap { $0 }
            case .code, .rule: []
            }
        }
        #expect(!texts.isEmpty)
        for text in texts {
            #expect(!text.contains("<div"), "\(text)")
            #expect(!text.contains("<img"), "\(text)")
            #expect(!text.contains("img.shields.io"), "\(text)")
            #expect(!text.contains("!["), "\(text)")
        }
        #expect(blocks.contains { if case .table = $0 { true } else { false } })
        #expect(blocks.contains { if case .code = $0 { true } else { false } })
        #expect(blocks.first == .heading(level: 1, text: "RemoteDeck"))
    }

    @Test func relativeLinksResolveAgainstTheRepository() throws {
        let text = HelpRendered.inline("See [the licence](LICENSE) and [docs](https://example.org/x).")
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://github.com/vincentlauriat/RemoteDeck/blob/main/LICENSE", "https://example.org/x"])
    }

    // MARK: Releases API

    @Test func readsReleasesNewestFirstWithoutDrafts() throws {
        let json = """
        [{"tag_name":"v1.1.0","name":"Spring","published_at":"2027-03-01T10:00:00Z","prerelease":true,"draft":false,"body":"- One"},
         {"tag_name":"v1.0.1","name":null,"published_at":"2027-02-01T10:00:00Z","draft":true,"body":"secret"},
         {"tag_name":"v1.0.0","name":"  ","published_at":null,"body":null}]
        """
        let entries = try ReleaseNotes.entries(from: Data(json.utf8))
        #expect(entries == [
            ReleaseEntry(title: "Spring", date: "2027-03-01", isPrerelease: true,
                         notes: HelpRendered(source: [.list([HelpListItem(marker: .bullet, depth: 0, text: "One")])])),
            ReleaseEntry(title: "v1.0.0", date: nil, isPrerelease: false, notes: HelpRendered(source: [])),
        ])
        #expect(throws: HelpFailure.invalidResponse) { try ReleaseNotes.entries(from: Data(#"{"message":"x"}"#.utf8)) }
    }

    // MARK: HelpModel

    @Test func loadsTheReadme() async throws {
        let http = FakeHelpHTTP([.text(200, "# Title\n\nBody")])
        let model = HelpModel(page: .help, transport: http)
        await model.loadIfNeeded()
        #expect(model.phase == document([.heading(level: 1, text: "Title"), .paragraph("Body")]))
        let request = try #require(await http.requests.first)
        #expect(request.url == HelpPage.help.requestURL)
        #expect(request.url?.absoluteString == "https://raw.githubusercontent.com/vincentlauriat/RemoteDeck/main/README.md")
        // Already there: the window reappearing does not fetch again; Reload does.
        await model.loadIfNeeded()
        #expect(await http.requests.count == 1)
    }

    @Test func whatsNewAsksTheReleasesAPI() async throws {
        let http = FakeHelpHTTP([.text(200, "[]")])
        let model = HelpModel(page: .whatsNew, transport: http)
        await model.load()
        #expect(model.phase == .empty)
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/vincentlauriat/RemoteDeck/releases?per_page=10")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test(arguments: [
        (FakeHelpHTTP.Reply.text(404, "Not Found"), HelpFailure.notPublished),
        (.text(429, ""), .rateLimited),
        (.headers(403, ["x-ratelimit-remaining": "0"]), .rateLimited),
        (.text(403, ""), .http(status: 403)),
        (.text(500, ""), .http(status: 500)),
        (.failure(URLError(.notConnectedToInternet)), .offline),
        (.failure(URLError(.timedOut)), .offline),
        (.failure(URLError(.cannotFindHost)), .offline),
        (.failure(URLError(.serverCertificateUntrusted)), .network(code: URLError.serverCertificateUntrusted.rawValue)),
        (.bytes(200, Data([0xFF, 0xFE, 0xFD])), .invalidResponse),
        (.bytes(200, Data(count: HelpModel.maxResponseBytes + 1)), .tooLarge),
    ])
    func failuresHaveTheirReason(reply: FakeHelpHTTP.Reply, failure: HelpFailure) async {
        let model = HelpModel(page: .help, transport: FakeHelpHTTP([reply]))
        await model.load()
        #expect(model.phase == .failed(failure))
    }

    @Test func retryAfterAFailureFetchesAgain() async {
        let http = FakeHelpHTTP([.failure(URLError(.notConnectedToInternet)), .text(200, "Back")])
        let model = HelpModel(page: .help, transport: http)
        await model.loadIfNeeded()
        #expect(model.phase == .failed(.offline))
        await model.loadIfNeeded()   // reopening a failed window tries again
        #expect(model.phase == document([.paragraph("Back")]))
    }

    /// A Reload while a slow request is on its way: the late answer never replaces the newer page.
    @Test func aLateAnswerLosesToTheNewerLoad() async {
        let http = FakeHelpHTTP([.gated(200, "Old"), .text(200, "New")])
        let model = HelpModel(page: .help, transport: http)
        let first = Task { await model.load() }
        await http.waitUntilGated(1)
        await model.load()
        #expect(model.phase == document([.paragraph("New")]))
        await http.openGates()
        await first.value
        #expect(model.phase == document([.paragraph("New")]))
    }

    @Test func aCancelledLoadLeavesTheWindowReadyToFetchAgain() async {
        let http = FakeHelpHTTP([.gated(200, "Old"), .text(200, "Again")])
        let model = HelpModel(page: .help, transport: http)
        let task = Task { await model.loadIfNeeded() }
        await http.waitUntilGated(1)
        task.cancel()   // the window closed while the answer was on its way
        await http.openGates()
        await task.value
        #expect(model.phase == .idle)
        await model.loadIfNeeded()
        #expect(model.phase == document([.paragraph("Again")]))
    }

    /// `-LibraryDemo help | whats-new`: the sample pages load through the demo transport.
    @Test func theDemoPagesLoad() async throws {
        let help = HelpModel(page: .help, transport: LibraryDemo.HelpTransport())
        await help.load()
        guard case .loaded(.document(let page)) = help.phase else {
            Issue.record("help: \(help.phase)"); return
        }
        #expect(page.source.first == .heading(level: 1, text: "RemoteDeck"))
        let whatsNew = HelpModel(page: .whatsNew, transport: LibraryDemo.HelpTransport())
        await whatsNew.load()
        guard case .loaded(.releases(let entries)) = whatsNew.phase else {
            Issue.record("whats new: \(whatsNew.phase)"); return
        }
        #expect(entries.map(\.title) == ["v0.2.0 (demo)", "v0.1.0"])
    }

    // MARK: Review fixes (2026-10-25)

    /// Both patterns the regex version backtracked on (seconds for 20k–40k scalars), 100k scalars each,
    /// in one paragraph: split, cleaned and rendered well under half a second, even in Debug.
    @Test(arguments: ["[![a", "<img a", "![a](", "[![a](b)"])
    func pathologicalInlineTextStaysLinear(pattern: String) {
        // "x " first: a line opening with `<img` is an HTML block line, dropped before any inline scan.
        let text = "x " + String(repeating: pattern, count: 100_000 / pattern.count)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let blocks = HelpDocument.parse(text)
            _ = HelpRendered(source: blocks)
        }
        #expect(elapsed < .milliseconds(500), "\(pattern): \(elapsed)")
    }

    @Test func blockTextIsCapped() {
        let blocks = HelpDocument.parse(String(repeating: "a", count: HelpDocument.maxBlockScalars + 50))
        guard case .paragraph(let text) = blocks.first else { Issue.record("\(blocks)"); return }
        #expect(text.unicodeScalars.count == HelpDocument.maxBlockScalars + 1)
        #expect(text.hasSuffix("…"))
    }

    /// The model splits and renders off the main actor: while a page that takes a while to render
    /// (thousands of paragraphs) is built, the main actor keeps getting turns, and no gap between them
    /// comes near the time the rendering takes.
    @Test func decodingRunsOffTheMainActor() async throws {
        let body = String(repeating: "Some **bold** word and a [link](https://example.org).\n\n", count: 6_000)
        let data = Data(body.utf8)
        let clock = ContinuousClock()
        let renderTime = try await Task.detached { try clock.measure { _ = try HelpModel.decode(data, page: .help) } }.value
        let model = HelpModel(page: .help, transport: FakeHelpHTTP([.text(200, body)]))
        let load = Task { await model.load() }
        var last = clock.now
        var longestGap = Duration.zero
        while model.phase == .loading || model.phase == .idle {
            await Task.yield()
            let now = clock.now
            longestGap = max(longestGap, now - last)
            last = now
        }
        await load.value
        guard case .loaded = model.phase else { Issue.record("\(model.phase)"); return }
        #expect(renderTime > .milliseconds(40), "page too quick to tell: \(renderTime)")
        #expect(longestGap < renderTime / 2, "main actor held \(longestGap) of \(renderTime)")
    }

    @Test(arguments: [
        ("file:///etc/passwd", false), ("javascript:alert(1)", false),
        ("x-apple.systempreferences:com.apple.preference.security", false), ("mailto:a@example.org", false),
        ("myapp://open", false), ("//example.org/x", false),
        ("HTTPS://Example.org/x", true), ("http://example.org", true), ("https://github.com/x", true),
    ])
    func linkPolicyAllowsOnlyWebLinks(link: String, allowed: Bool) throws {
        #expect(HelpLinkPolicy.allows(try #require(URL(string: link))) == allowed)
    }

    @Test func refusedLinksBecomePlainText() {
        let text = HelpRendered.inline("[a](file:///etc/passwd) [b](javascript:alert(1)) <file:///tmp/x> [c](mailto:a@b.org) [ok](https://example.org)")
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://example.org"])
        #expect(String(text.characters).contains("a"))
    }

    @Test func aSpoofedAddressShowsTheRealHost() {
        let spoof = HelpRendered.inline("Get it at [https://github.com/vincentlauriat](https://evil.example/x).")
        #expect(String(spoof.characters) == "Get it at https://github.com/vincentlauriat (evil.example).")
        let honest = HelpRendered.inline("See [www.github.com/x](https://github.com/x) and [the docs](https://evil.example).")
        #expect(String(honest.characters) == "See www.github.com/x and the docs.")
    }

    @Test func bidiAndInvisibleScalarsAreStripped() throws {
        let text = "a\u{202E}b\u{2066}c\u{200B}d\u{FEFF}e\u{200F}f 🖥️ 👨\u{200D}💻"
        #expect(HelpDocument.cleanInline(text) == "abcdef 🖥️ 👨\u{200D}💻")
        let json = #"[{"tag_name":"v1","name":"v1\u202e.0","published_at":"2027-01-01T00:00:00Z","body":""}]"#
        #expect(try ReleaseNotes.entries(from: Data(json.utf8)).first?.title == "v1.0")
    }

    @Test func onlyKnownBlockTagsDropALine() {
        #expect(HelpDocument.parse("<https://example.org>") == [.paragraph("<https://example.org>")])
        #expect(HelpDocument.parse("<kbd>⌘</kbd> opens it") == [.paragraph("⌘ opens it")])
        #expect(HelpDocument.parse("<version> is the tag") == [.paragraph("<version> is the tag")])
        #expect(HelpDocument.parse("<p align=\"center\">\n<h1>Big</h1>\n</p>\nText") == [.paragraph("Text")])
    }

    @Test func headingClosingHashesNeedASpace() {
        #expect(HelpDocument.parse("## C#") == [.heading(level: 2, text: "C#")])
        #expect(HelpDocument.parse("## Title ##") == [.heading(level: 2, text: "Title")])
    }

    @Test func aForbiddenAnswerWithRetryAfterIsRateLimited() async {
        let model = HelpModel(page: .help, transport: FakeHelpHTTP([.headers(403, ["Retry-After": "60"])]))
        await model.load()
        #expect(model.phase == .failed(.rateLimited))
    }

    @Test func anAnnouncedOversizedBodyIsRefused() async {
        let headers = ["Content-Length": String(HelpModel.maxResponseBytes + 1)]
        let model = HelpModel(page: .help, transport: FakeHelpHTTP([.headers(200, headers)]))
        await model.load()
        #expect(model.phase == .failed(.tooLarge))
    }

    // MARK: Never fetched here

    @Test func theSourceIsGitHubOnlyInTheReleasedApp() {
        #expect(HelpSource.resolve(isRunningTests: false, demoMode: nil, framebufferDebugMode: nil) == .github)
        #expect(HelpSource.resolve(isRunningTests: true, demoMode: nil, framebufferDebugMode: nil) == .disabled)
        #expect(HelpSource.resolve(isRunningTests: true, demoMode: "help", framebufferDebugMode: nil) == .disabled)
        for mode in ["list", "session", "help", "whats-new", "help-offline", "history"] {
            #expect(HelpSource.resolve(isRunningTests: false, demoMode: mode, framebufferDebugMode: nil) == .demo)
        }
        #expect(HelpSource.resolve(isRunningTests: false, demoMode: nil, framebufferDebugMode: "stream") == .demo)
        #expect(HelpSource.transport(for: .github) is LiveHelpTransport)
        #expect(HelpSource.transport(for: .disabled) is DisabledHelpTransport)
    }

    /// This process is the hosted test run: the App that hosts it wired both windows on the disabled
    /// transport (recorded by `HelpSource.appTransport`), and no live request was ever sent.
    @Test func thisTestHostNeverFetches() async {
        #expect(HelpSource.wiredByApp == .disabled)
        #expect(LiveHelpTransport.requestCount.withLock { $0 } == 0)
        let model = HelpModel(page: .help, transport: HelpSource.transport(for: .disabled))
        await model.load()
        #expect(model.phase == .failed(.disabled))
    }

    private func document(_ blocks: [HelpBlock]) -> HelpModel.Phase {
        .loaded(.document(HelpRendered(source: blocks)))
    }
}

/// A scripted transport for the Help tests: answers in order and records every request.
actor FakeHelpHTTP: HTTPTransport {
    enum Reply: Sendable {
        case text(Int, String)
        case bytes(Int, Data)
        case headers(Int, [String: String])
        case failure(URLError)
        /// Answers only once the test calls `openGates()`, even if the task was cancelled meanwhile
        /// (a reply already on its way).
        case gated(Int, String)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var gatedCount = 0
    private var gateWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    /// Returns once `count` requests are waiting on a gate.
    func waitUntilGated(_ count: Int) async {
        if gatedCount >= count { return }
        await withCheckedContinuation { gateWaiters.append((count, $0)) }
    }

    func openGates() {
        let open = gates
        gates = []
        open.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        func response(_ status: Int, _ headers: [String: String]? = nil) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        switch replies.removeFirst() {
        case .text(let status, let body): return (Data(body.utf8), response(status))
        case .bytes(let status, let data): return (data, response(status))
        case .headers(let status, let headers): return (Data(), response(status, headers))
        case .failure(let error): throw error
        case .gated(let status, let body):
            await withCheckedContinuation { continuation in
                gates.append(continuation)
                gatedCount += 1
                let ready = gateWaiters.filter { $0.0 <= gatedCount }
                gateWaiters.removeAll { $0.0 <= gatedCount }
                ready.forEach { $0.1.resume() }
            }
            return (Data(body.utf8), response(status))
        }
    }
}
