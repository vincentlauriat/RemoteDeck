import Foundation

/// One importable `Host` block of an OpenSSH client configuration.
public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    /// Relative to `~/.ssh` when the file named it under `~/.ssh/`, else as written.
    public var identityFile: String?

    public init(alias: String, hostName: String?, user: String?, port: Int?, identityFile: String?) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

/// Reads the machines an `~/.ssh/config` names, for import. Only what an import needs: `Host`
/// blocks with a single plain alias (no pattern, no negation, no list), and in them `HostName`,
/// `User`, `Port` and `IdentityFile`. Everything else is skipped, `Include` and `Match` included;
/// a `Match` line ends the current block. Keywords are case-insensitive; the first value of a
/// keyword wins, as in OpenSSH.
public enum SSHConfigFile {
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        func finishBlock() {
            if let host = current { hosts.append(host) }
            current = nil
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, arguments) = tokenize(String(line)) else { continue }
            switch keyword {
            case "host":
                finishBlock()
                if arguments.count == 1, isPlainAlias(arguments[0]) {
                    current = SSHConfigHost(alias: arguments[0], hostName: nil, user: nil, port: nil, identityFile: nil)
                }
            case "match":
                finishBlock()
            case "hostname":
                if current?.hostName == nil { current?.hostName = arguments.first }
            case "user":
                if current?.user == nil { current?.user = arguments.first }
            case "port":
                if current?.port == nil, let value = arguments.first.flatMap({ Int($0) }), (1 ... 65535).contains(value) {
                    current?.port = value
                }
            case "identityfile":
                if current?.identityFile == nil { current?.identityFile = arguments.first.map(relativeToDotSSH) }
            default:
                break
            }
        }
        finishBlock()
        return hosts
    }

    /// Splits a line into its lowercased keyword and its arguments: whitespace separated, an `=`
    /// allowed between keyword and value, double quotes grouping, and a `#` at the start of a token
    /// commenting out the rest of the line. Nil for blank and comment-only lines.
    static func tokenize(_ line: String) -> (keyword: String, arguments: [String])? {
        var tokens: [String] = []
        var token = ""
        var inToken = false
        var inQuotes = false
        var keywordEnded = false

        func endToken() {
            if inToken { tokens.append(token) }
            token = ""
            inToken = false
        }

        for character in line {
            if inQuotes {
                if character == "\"" { inQuotes = false } else { token.append(character) }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                inToken = true
            case " ", "\t":
                endToken()
            case "=" where tokens.count + (inToken ? 1 : 0) == 1 && !keywordEnded:
                // `Keyword=value` or `Keyword = value`: one `=` ends the keyword.
                endToken()
                keywordEnded = true
            case "#" where !inToken:
                endToken()
                return finish(tokens)
            default:
                token.append(character)
                inToken = true
            }
        }
        endToken()
        return finish(tokens)
    }

    private static func finish(_ tokens: [String]) -> (keyword: String, arguments: [String])? {
        guard let keyword = tokens.first else { return nil }
        return (keyword.lowercased(), Array(tokens.dropFirst()))
    }

    /// An alias that names one machine: no `*`/`?` pattern, no `!` negation, no `,` list.
    private static func isPlainAlias(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.contains(where: { "*?!,".contains($0) })
    }

    private static func relativeToDotSSH(_ path: String) -> String {
        for prefix in ["~/.ssh/", "%d/.ssh/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }
}
