import Foundation
import Network

/// Editable Machine fields, as a value the validator can check off the main actor.
public struct MachineDraft: Equatable, Sendable {
    public var name: String
    public var kind: MachineKind
    public var host: String
    public var port: Int
    public var username: String?

    public init(name: String, kind: MachineKind, host: String, port: Int, username: String? = nil) {
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    public init(_ machine: Machine) {
        self.init(
            name: machine.name, kind: machine.kindValue,
            host: machine.host, port: machine.port, username: machine.username
        )
    }
}

/// Field-level validation rules (BackendSchema › Data validation).
public struct MachineValidator: Sendable {
    public enum Field: String, Sendable {
        case name, host, port, username, groupName
    }

    public enum Reason: Equatable, Sendable {
        case empty
        case tooLong(max: Int)
        case invalidHost
        case outOfRange
        case duplicate
    }

    public struct Issue: Equatable, Sendable {
        public let field: Field
        public let reason: Reason

        public init(_ field: Field, _ reason: Reason) {
            self.field = field
            self.reason = reason
        }
    }

    public static let maxNameLength = 64
    public static let maxGroupNameLength = 40
    public static let portRange = 1...65535

    public init() {}

    /// Checks a Machine. `existingKeys` maps every stored machine id to its
    /// `normalizedKey`; the entry for `editingID` (the machine being edited) is ignored.
    public func validate(
        _ draft: MachineDraft,
        existingKeys: [UUID: String] = [:],
        editingID: UUID? = nil
    ) -> [Issue] {
        var issues: [Issue] = []

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            issues.append(Issue(.name, .empty))
        } else if name.count > Self.maxNameLength {
            issues.append(Issue(.name, .tooLong(max: Self.maxNameLength)))
        }

        let hostValid: Bool
        if draft.host.isEmpty {
            issues.append(Issue(.host, .empty))
            hostValid = false
        } else if !Self.isValidHost(draft.host) {
            issues.append(Issue(.host, .invalidHost))
            hostValid = false
        } else {
            hostValid = true
        }

        let portValid = Self.portRange.contains(draft.port)
        if !portValid {
            issues.append(Issue(.port, .outOfRange))
        }

        if draft.kind == .macARD,
           (draft.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(Issue(.username, .empty))
        }

        if hostValid && portValid {
            let key = Self.normalizedKey(host: draft.host, port: draft.port)
            let clash = existingKeys.contains { id, existing in id != editingID && existing == key }
            if clash {
                issues.append(Issue(.host, .duplicate))
            }
        }

        return issues
    }

    /// Checks a MachineGroup name. `existingNames` maps every stored group id to its
    /// name; the entry for `editingID` is ignored. Uniqueness is case-insensitive.
    public func validateGroupName(
        _ rawName: String,
        existingNames: [UUID: String] = [:],
        editingID: UUID? = nil
    ) -> [Issue] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return [Issue(.groupName, .empty)] }
        if name.count > Self.maxGroupNameLength {
            return [Issue(.groupName, .tooLong(max: Self.maxGroupNameLength))]
        }
        let clash = existingNames.contains { id, existing in
            id != editingID
                && existing.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame  // "Straße" == "STRASSE"
        }
        return clash ? [Issue(.groupName, .duplicate)] : []
    }

    /// Uniqueness key `host:port`, with equivalent spellings of a host mapped to one form:
    /// IPv6 literals in canonical text (lowercased zone kept), DNS names lowercased
    /// without their trailing dot.
    public static func normalizedKey(host: String, port: Int) -> String {
        let normalizedHost: String
        if let (address, zone) = parseIPv6(host) {
            normalizedHost = "\(address)" + (zone.map { "%" + $0.lowercased() } ?? "")
        } else {
            normalizedHost = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        }
        return "\(normalizedHost):\(port)"
    }

    // MARK: Host

    /// A DNS name (RFC 1123), a dotted-quad IPv4 literal or an IPv6 literal.
    /// No scheme, path, port, brackets or whitespace. IPv6 zone ids (`fe80::1%en0`)
    /// are accepted for link-local LAN Macs; IPv4 shorthand (`10.1`) and leading
    /// zeros (`010.0.0.1`) are not.
    static func isValidHost(_ host: String) -> Bool {
        isIPv4Literal(host) || isIPv6Literal(host) || isDNSName(host)
    }

    static func isIPv4Literal(_ host: String) -> Bool {
        // `IPv4Address` also takes inet_aton shorthand ("1", "10.1") and "%zone": require a dotted quad.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) }),
              // "010" is octal to inet_aton and decimal elsewhere: ambiguous, so rejected.
              parts.allSatisfy({ $0.count == 1 || $0.first != "0" })
        else { return false }
        return IPv4Address(host) != nil
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        parseIPv6(host) != nil
    }

    /// Splits an IPv6 literal into its address and optional zone id. The zone is checked
    /// syntactically only: `IPv6Address` resolves zones against this Mac's interfaces and
    /// drops unknown ones, but machines sync to other Macs.
    static func parseIPv6(_ host: String) -> (address: IPv6Address, zone: String?)? {
        guard host.contains(":"), !host.contains(where: \.isWhitespace) else { return nil }
        let pieces = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let zone = pieces.count == 2 ? String(pieces[1]) : nil
        if let zone, !isValidZone(zone) { return nil }
        guard let address = IPv6Address(String(pieces[0])) else { return nil }
        return (address, zone)
    }

    /// An interface name (`en0`, `bridge100`: starts with a letter) or an interface index
    /// (`7`: digits only). A digit-led name such as `25en0` is a URL-escaped `%25en0`.
    static func isValidZone(_ zone: String) -> Bool {
        guard let first = zone.first,
              zone.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || ".-_".contains($0) })
        else { return false }
        return first.isASCIILetter || zone.allSatisfy(\.isASCIIDigit)
    }

    static func isDNSName(_ host: String) -> Bool {
        var name = Substring(host)
        if name.hasSuffix(".") { name = name.dropLast() }  // fully qualified form
        guard !name.isEmpty, name.utf8.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.utf8.count),
                  label.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }),
                  label.first != "-", label.last != "-"
            else { return false }
        }
        // An all-numeric last label is a malformed IP (e.g. "256.1.1.1"), not a host name.
        return !labels.last!.allSatisfy(\.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
