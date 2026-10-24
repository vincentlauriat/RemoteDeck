/// Text from the other side (a server's reason or desktop name, a `type` action Claude proposes) made
/// safe to show (T5.3 M2, L8): nothing in it can hide, reorder or fake what the user reads.
///
/// Invisible scalars are the Unicode general categories Cc (C0, DEL, C1 controls), Cf (format:
/// bidi overrides and isolates such as U+202E, zero-width spaces and joiners, U+FEFF, tag
/// characters), Zl and Zp (line and paragraph separators), every default-ignorable code point
/// (variation selectors, U+034F, Hangul fillers…) and every space separator but U+0020. Each is
/// shown as `\u{XXXX}`.
public enum DisplayText {
    /// Longest server string shown, in Unicode scalars (a single Character can carry any number of
    /// combining marks, so characters would not bound it).
    public static let serverStringLimit = 200

    public static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        // Default-ignorable code points render as nothing: variation selectors, U+034F, Hangul fillers
        // (U+115F, U+1160, U+3164, U+FFA0), Mongolian free variation selectors…
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        // Any space but U+0020 (no-break, ideographic, en/em, thin…): it reads as a space.
        case .spaceSeparator: return scalar != " "
        default: return false
        }
    }

    /// Holds an invisible scalar other than a line feed or a tab (shown as `\u{…}`).
    public static func hasHiddenScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { isInvisible($0) && $0 != "\n" && $0 != "\t" }
    }

    static func escaped(_ scalar: Unicode.Scalar) -> String {
        "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
    }

    /// The whole text with every invisible scalar visible: a line feed as ⏎ (followed by the line
    /// break itself, so a multi-line text keeps its lines), a tab as ⇥, any other as `\u{XXXX}`.
    public static func revealingInvisibles(_ text: String) -> String {
        var shown = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": shown += "⏎\n"
            case "\t": shown += "⇥"
            case _ where isInvisible(scalar): shown += escaped(scalar)
            default: shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }

    /// A server-controlled string on one line: at most `limit` scalars (then "…"), and every
    /// invisible scalar, line ends included, as `\u{XXXX}`.
    public static func serverString(_ text: String, limit: Int = serverStringLimit) -> String {
        let scalars = text.unicodeScalars
        var shown = ""
        for scalar in scalars.prefix(limit) {
            if isInvisible(scalar) { shown += escaped(scalar) } else { shown.unicodeScalars.append(scalar) }
        }
        if scalars.count > limit { shown += "…" }
        return shown
    }
}
