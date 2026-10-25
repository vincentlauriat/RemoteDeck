import Foundation

/// Which links a Help page may carry (TRD › Architecture › Help): absolute http and https only.
/// `file:`, `javascript:`, `mailto:`, `x-apple.systempreferences:`, custom schemes and anything
/// without a scheme lose their link and stay plain text. The windows' `openURL` checks again.
enum HelpLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// The host a link text names, when the text reads as a web address ("https://x.org/a",
    /// "www.x.org", "x.org/path"); nil for ordinary words.
    static func hostNamed(by text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let lower = trimmed.lowercased()
        let candidate = lower.hasPrefix("http://") || lower.hasPrefix("https://") ? lower : "https://" + lower
        guard let host = URL(string: candidate)?.host, host.contains("."),
              host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true
        else { return nil }
        return host
    }

    static func sameSite(_ a: String, _ b: String) -> Bool {
        func bare(_ host: String) -> String {
            let lower = host.lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        return bare(a) == bare(b)
    }
}

/// A block ready to draw: every inline text already parsed into an `AttributedString` with the link
/// policy applied, so the view never parses Markdown in `body`.
enum HelpRenderedBlock: Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list([(marker: HelpListItem.Marker, depth: Int, text: AttributedString)])
    case code(String)
    case quote(AttributedString)
    case table(header: [AttributedString]?, rows: [[AttributedString]])
    case rule
}

/// A page's blocks, in source form (compared by tests) and rendered (drawn by the view). Built off
/// the main actor by `HelpModel`.
struct HelpRendered: Equatable, Sendable {
    let source: [HelpBlock]
    let blocks: [HelpRenderedBlock]

    init(source: [HelpBlock]) {
        self.source = source
        blocks = source.map(Self.render)
    }

    static func == (lhs: HelpRendered, rhs: HelpRendered) -> Bool { lhs.source == rhs.source }

    private static func render(_ block: HelpBlock) -> HelpRenderedBlock {
        switch block {
        case .heading(let level, let text): .heading(level: level, text: inline(text))
        case .paragraph(let text): .paragraph(inline(text))
        case .list(let items): .list(items.map { (marker: $0.marker, depth: $0.depth, text: inline($0.text)) })
        case .code(let text): .code(text)
        case .quote(let text): .quote(inline(text))
        case .table(let header, let rows):
            // `| | |` headers (the README's Features table) have nothing to show.
            .table(header: header.contains { !$0.isEmpty } ? header.map(inline) : nil,
                   rows: rows.map { $0.map(inline) })
        case .rule: .rule
        }
    }

    /// Inline Markdown only (emphasis, code spans, links); relative links resolve against the
    /// repository on GitHub. A link the policy refuses becomes plain text; a link whose text reads as
    /// another site's address gets its real host appended, "(github.com)". A text that does not parse
    /// is shown as typed.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options, baseURL: HelpPage.linkBase) else {
            return AttributedString(text)
        }
        var result = AttributedString()
        // Runs of one link are contiguous: gather each link's text before checking it.
        var pending: (text: AttributedString, url: URL)?
        func flush() {
            guard let (linkText, url) = pending else { return }
            pending = nil
            result.append(linkText)
            if let named = HelpLinkPolicy.hostNamed(by: String(linkText.characters)), let target = url.host,
               !HelpLinkPolicy.sameSite(named, target) {
                result.append(AttributedString(" (\(target))"))
            }
        }
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let link = run.link {
                let absolute = link.absoluteURL
                if HelpLinkPolicy.allows(absolute) {
                    piece.link = absolute
                    if let current = pending, current.url == absolute {
                        pending = (current.text + piece, absolute)
                    } else {
                        flush()
                        pending = (piece, absolute)
                    }
                    continue
                }
                piece.link = nil
            }
            flush()
            result.append(piece)
        }
        flush()
        return result
    }
}
