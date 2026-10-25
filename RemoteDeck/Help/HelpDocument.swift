import Foundation

/// One block of a Help or What's New page (TRD › Architecture › Help). The README and the release
/// notes are Markdown from GitHub; they are split into these blocks by `HelpDocument.parse`, and each
/// block's text is rendered natively (`AttributedString(markdown:)`, inline syntax only). No HTML is
/// ever interpreted, no script exists to run and no image is loaded.
enum HelpBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([HelpListItem])
    case code(String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct HelpListItem: Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    var marker: Marker
    /// Nesting level, 0 for a top-level item.
    var depth: Int
    var text: String
}

/// A small, pure Markdown block splitter: ATX and setext headings, paragraphs, bullet, numbered and
/// task lists (nested by indentation), fenced code, block quotes, GitHub tables and rules. HTML
/// blocks and comments are dropped; inline images are dropped (a linked badge with them) and a few
/// inline HTML tags are removed (`HelpDocument.cleanInline`), the rest stays literal text.
enum HelpDocument {
    static func parse(_ markdown: String) -> [HelpBlock] {
        var parser = Parser(lines: markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n"))
        return parser.run()
    }

    /// Longest text one block keeps, in Unicode scalars (a code block: `maxCodeScalars`); the rest is
    /// cut and ends with "…". The README's longest paragraph is under 1 000.
    static let maxBlockScalars = 20_000
    static let maxCodeScalars = 100_000

    /// Presentational tags removed from inline text (`<br>` becomes a line break).
    static let inlineTags: Set<String> = ["img", "div", "p", "span", "a", "b", "i", "em", "strong", "sub", "sup",
                                          "picture", "source", "details", "summary", "kbd", "center", "font", "br"]
    /// A line that opens with one of these is an HTML block line and is dropped.
    static let blockTags: Set<String> = ["div", "table", "p", "img", "picture", "details", "summary", "br", "hr",
                                         "h1", "h2", "h3", "h4", "h5", "h6", "center", "a"]

    /// Bidi controls and invisible scalars that could reorder or hide text: LRE…RLO (U+202A–202E),
    /// LRI…PDI (U+2066–2069), ZWSP, ZWNJ, LRM, RLM (U+200B, 200C, 200E, 200F), ALM (U+061C) and BOM
    /// (U+FEFF). U+200D (zero-width joiner) stays: emoji sequences need it. Narrower than RFBKit's
    /// `DisplayText.isInvisible`, which would also take emoji variation selectors (🖥️).
    static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B, 0x200C, 0x200E, 0x200F, 0x061C, 0xFEFF: true
        default: false
        }
    }

    static func stripInvisibles(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isStripped) else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.lazy.filter { !isStripped($0) })
        return String(view)
    }

    /// Inline clean-up applied to every text a block carries: bidi and invisible scalars go, linked
    /// images (badges) and images go (never loaded), `<br>` becomes a line break, the tags in
    /// `inlineTags` are removed. Anything else that looks like a tag (`RemoteDeck-<version>.dmg`) is
    /// kept as text. One forward scan: each lookahead is bounded and stops at the characters that
    /// would start the next attempt, so the cost stays linear in the text (no regex backtracking).
    static func cleanInline(_ text: String) -> String {
        let input = Array(stripInvisibles(text).unicodeScalars)
        var output = String.UnicodeScalarView()
        var i = 0
        while i < input.count {
            let c = input[i]
            if c == "[", let end = linkedImageEnd(input, from: i) {
                i = end
            } else if c == "!", let end = imageEnd(input, from: i) {
                i = end
            } else if c == "<", let (end, name) = tagEnd(input, from: i), inlineTags.contains(name) {
                if name == "br" { output.append("\n") }
                i = end
            } else {
                output.append(c)
                i += 1
            }
        }
        return String(output).trimmingCharacters(in: .whitespaces)
    }

    /// `[` … `]` from `start`: the index after `]`, the content at most `limit` scalars, without a
    /// line feed or any of `stops`.
    private static func bracketEnd(_ s: [Unicode.Scalar], from start: Int, open: Unicode.Scalar, close: Unicode.Scalar,
                                   limit: Int, stops: Set<Unicode.Scalar>) -> Int? {
        guard start < s.count, s[start] == open else { return nil }
        var j = start + 1
        while j < s.count, j - start <= limit + 1 {
            let c = s[j]
            if c == close { return j + 1 }
            if c == "\n" || stops.contains(c) { return nil }
            j += 1
        }
        return nil
    }

    /// `![alt](target)`: the index after it.
    static func imageEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + 1 < s.count, s[start] == "!" else { return nil }
        guard let altEnd = bracketEnd(s, from: start + 1, open: "[", close: "]", limit: 256, stops: ["[", "!"]) else { return nil }
        return bracketEnd(s, from: altEnd, open: "(", close: ")", limit: 512, stops: ["(", "[", "!", "<"])
    }

    /// `[![alt](image)](target)`: the index after it.
    static func linkedImageEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + 1 < s.count, s[start] == "[", let imageEnd = imageEnd(s, from: start + 1),
              imageEnd < s.count, s[imageEnd] == "]" else { return nil }
        return bracketEnd(s, from: imageEnd + 1, open: "(", close: ")", limit: 512, stops: ["(", "[", "!", "<"])
    }

    /// `<name …>`, `</name>` or `<name/>`: the index after `>` and the lowercased name. The name is
    /// at most 16 ASCII letters or digits; the attributes at most 256 scalars, without `<` or a line feed.
    static func tagEnd(_ s: [Unicode.Scalar], from start: Int) -> (Int, String)? {
        guard start < s.count, s[start] == "<" else { return nil }
        var j = start + 1
        if j < s.count, s[j] == "/" { j += 1 }
        let nameStart = j
        while j < s.count, j - nameStart < 16, s[j].isASCII, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) {
            j += 1
        }
        guard j > nameStart, j < s.count else { return nil }
        let name = String(String.UnicodeScalarView(s[nameStart..<j])).lowercased()
        guard s[j] == ">" || s[j] == "/" || s[j] == " " || s[j] == "\t" else { return nil }
        let attributesStart = j
        while j < s.count, j - attributesStart <= 256 {
            let c = s[j]
            if c == ">" { return (j + 1, name) }
            if c == "<" || c == "\n" { return nil }
            j += 1
        }
        return nil
    }

    /// Whether a (trimmed) line opens with an HTML block tag: `<div align="center">`, `</div>`, `<img …>`.
    /// `<https://…>` (an autolink) and `<kbd>` lines are text.
    static func opensHTMLBlock(_ trimmed: String) -> Bool {
        let scalars = Array(trimmed.unicodeScalars.prefix(24))
        guard scalars.first == "<" else { return false }
        var j = 1
        if j < scalars.count, scalars[j] == "/" { j += 1 }
        let nameStart = j
        while j < scalars.count, scalars[j].isASCII, scalars[j].properties.isAlphabetic || ("0"..."9").contains(scalars[j]) {
            j += 1
        }
        guard j > nameStart else { return false }
        let name = String(String.UnicodeScalarView(scalars[nameStart..<j])).lowercased()
        guard blockTags.contains(name) else { return false }
        return j == scalars.count || [">", "/", " ", "\t"].contains(scalars[j])
    }

    /// At most `limit` scalars, then "…".
    static func capped(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard let end = scalars.index(scalars.startIndex, offsetBy: limit, limitedBy: scalars.endIndex),
              end < scalars.endIndex else { return text }
        return String(scalars[..<end]) + "…"
    }

    /// `cleanInline`, then `capped` to `maxBlockScalars`.
    static func inlineText(_ text: String) -> String {
        capped(cleanInline(text), limit: maxBlockScalars)
    }

    private struct Parser {
        let lines: [String]
        var index = 0
        var blocks: [HelpBlock] = []
        var paragraph: [String] = []
        var items: [HelpListItem] = []
        var quote: [String] = []

        init(lines: [String]) { self.lines = lines }

        mutating func run() -> [HelpBlock] {
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    flushAll()
                } else if let fence = Self.fence(trimmed) {
                    flushAll()
                    readCode(fence: fence)
                    continue
                } else if trimmed.hasPrefix("<!--") {
                    flushAll()
                    skipComment()
                    continue
                } else if quote.isEmpty && HelpDocument.opensHTMLBlock(trimmed) {
                    flushAll()   // an HTML block line (`<div align="center">`, `<img …>`): dropped
                } else if !paragraph.isEmpty && Self.isSetextUnderline(trimmed) {
                    let text = paragraph.joined(separator: " ")
                    paragraph = []
                    append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                } else if let heading = Self.heading(trimmed) {
                    flushAll()
                    append(heading)
                } else if Self.isRule(trimmed) {
                    flushAll()
                    blocks.append(.rule)
                } else if trimmed.hasPrefix(">") {
                    flushParagraph()
                    flushList()
                    var body = trimmed.dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    quote.append(String(body))
                } else if trimmed.contains("|"), index + 1 < lines.count, Self.isTableDelimiter(lines[index + 1]) {
                    flushAll()
                    readTable()
                    continue
                } else if let item = Self.listItem(line) {
                    flushParagraph()
                    flushQuote()
                    items.append(item)
                } else if !items.isEmpty && line.first == " " {
                    items[items.count - 1].text += " " + trimmed   // continuation of the last item
                } else if !quote.isEmpty {
                    quote.append(trimmed)   // lazy continuation
                } else {
                    flushList()
                    paragraph.append(Self.hardBreak(line) ? String(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))) + "\n" : trimmed)
                }
                index += 1
            }
            flushAll()
            return blocks
        }

        mutating func append(_ block: HelpBlock) {
            switch block {
            case .heading(let level, let text):
                let text = HelpDocument.inlineText(text)
                if !text.isEmpty { blocks.append(.heading(level: level, text: text)) }
            case .paragraph(let text):
                let text = HelpDocument.inlineText(text)
                if !text.isEmpty { blocks.append(.paragraph(text)) }
            default:
                blocks.append(block)
            }
        }

        mutating func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            var text = ""
            for part in paragraph {
                if !text.isEmpty && !text.hasSuffix("\n") { text += " " }
                text += part
            }
            paragraph = []
            append(.paragraph(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        mutating func flushList() {
            guard !items.isEmpty else { return }
            let cleaned = items.map { HelpListItem(marker: $0.marker, depth: $0.depth, text: HelpDocument.inlineText($0.text)) }
            items = []
            blocks.append(.list(cleaned))
        }

        mutating func flushQuote() {
            guard !quote.isEmpty else { return }
            let text = HelpDocument.inlineText(quote.joined(separator: " "))
            quote = []
            if !text.isEmpty { blocks.append(.quote(text)) }
        }

        /// From the opening fence to the matching closing one (or the end of the text).
        mutating func readCode(fence: String) {
            index += 1
            var body: [String] = []
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(fence) && trimmed.allSatisfy({ $0 == fence.first }) {
                    index += 1
                    break
                }
                body.append(lines[index])
                index += 1
            }
            blocks.append(.code(HelpDocument.capped(HelpDocument.stripInvisibles(body.joined(separator: "\n")),
                                                   limit: HelpDocument.maxCodeScalars)))
        }

        mutating func skipComment() {
            while index < lines.count {
                let done = lines[index].contains("-->")
                index += 1
                if done { return }
            }
        }

        mutating func readTable() {
            let header = Self.cells(lines[index]).map(HelpDocument.inlineText)
            index += 2   // header and delimiter
            var rows: [[String]] = []
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed.contains("|") else { break }
                var row = Self.cells(line).map(HelpDocument.inlineText)
                if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                rows.append(Array(row.prefix(max(header.count, 1))))
                index += 1
            }
            blocks.append(.table(header: header, rows: rows))
        }

        static func fence(_ trimmed: String) -> String? {
            for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
                let marker = fence.first!
                return String(trimmed.prefix { $0 == marker })
            }
            return nil
        }

        static func heading(_ trimmed: String) -> HelpBlock? {
            let hashes = trimmed.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count) else { return nil }
            let rest = trimmed.dropFirst(hashes.count)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // A closing sequence of #s (`## Title ##`), only after a space: `## C#` stays "C#".
            let closing = text.reversed().prefix { $0 == "#" }.count
            if closing > 0 {
                let rest = text.dropLast(closing)
                if rest.isEmpty || rest.last == " " || rest.last == "\t" { text = String(rest) }
            }
            return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
        }

        static func isRule(_ trimmed: String) -> Bool {
            let compact = trimmed.filter { $0 != " " }
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        static func isSetextUnderline(_ trimmed: String) -> Bool {
            guard let first = trimmed.first, first == "=" || first == "-" else { return false }
            return trimmed.allSatisfy { $0 == first }
        }

        static func isTableDelimiter(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return false }
            let cells = cells(trimmed)
            return !cells.isEmpty && cells.allSatisfy { cell in
                let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return !core.isEmpty && core.allSatisfy { $0 == "-" }
            }
        }

        /// The cells of a table row: split on `|` outside code spans, `\|` kept as a literal bar.
        static func cells(_ line: String) -> [String] {
            var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
            if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
            if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }
            var cells: [String] = []
            var current = ""
            var inCode = false
            var escaped = false
            for character in trimmed {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "`" {
                    inCode.toggle()
                    current.append(character)
                } else if character == "|" && !inCode {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if escaped { current.append("\\") }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        static func listItem(_ line: String) -> HelpListItem? {
            let expanded = line.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix { $0 == " " }.count
            let rest = expanded.dropFirst(indent)
            var marker: HelpListItem.Marker
            var body: Substring
            if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
                marker = .bullet
                body = rest.dropFirst(2)
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
                let after = rest.dropFirst(digits.count)
                guard let punctuation = after.first, punctuation == "." || punctuation == ")",
                      after.dropFirst().first == " " else { return nil }
                marker = .number(number)
                body = after.dropFirst(2)
            }
            var text = body.trimmingCharacters(in: .whitespaces)
            if marker == .bullet {
                let lower = text.lowercased()
                if lower.hasPrefix("[ ] ") || lower == "[ ]" {
                    marker = .task(done: false)
                    text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("[x] ") || lower == "[x]" {
                    marker = .task(done: true)
                    text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            }
            return HelpListItem(marker: marker, depth: min(indent / 2, 4), text: text)
        }

        static func hardBreak(_ line: String) -> Bool {
            line.hasSuffix("  ") || line.hasSuffix("\\")
        }
    }
}
