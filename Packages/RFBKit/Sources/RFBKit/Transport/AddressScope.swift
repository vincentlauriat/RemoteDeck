import Darwin
import Network

/// Where an IP address is, for the public-Internet warning (T5.3 H1, TRD › Security › Transport): RFB
/// is not encrypted beyond the ARD credential exchange, so screen, keystrokes and clipboard cross
/// every network between the two machines in clear.
///
/// Pure: built from the address bytes (4 for IPv4, 16 for IPv6). An IPv4-mapped IPv6 address
/// (`::ffff:a.b.c.d`) is classified as its IPv4 address.
public enum AddressScope: Equatable, Sendable {
    /// 127.0.0.0/8, ::1; also "this host" (0.0.0.0/8, ::), which a connection reaches locally.
    case loopback
    /// RFC 1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
    case privateNetwork
    /// RFC 6598 shared address space 100.64.0.0/10: carrier-grade NAT, and Tailscale's addresses.
    case sharedAddressSpace
    /// 169.254.0.0/16, fe80::/10.
    case linkLocal
    /// IPv6 unique local addresses fc00::/7 (Tailscale's IPv6 included).
    case uniqueLocal
    /// Anything else: reached across the Internet.
    case publicInternet

    public var isPublicInternet: Bool { self == .publicInternet }

    /// `nil` unless `bytes` has 4 (IPv4) or 16 (IPv6) bytes.
    public init?(addressBytes bytes: [UInt8]) {
        switch bytes.count {
        case 4: self = Self.ipv4(bytes)
        case 16: self = Self.ipv6(bytes)
        default: return nil
        }
    }

    /// The scope of an IP literal as typed in the Machine Editor's host field (`10.0.0.2`, `fe80::1`,
    /// `[fe80::1%en0]`, `::ffff:192.168.1.2`); `nil` for a host name or anything `inet_pton` does not
    /// read as an address (it accepts only full dotted quads for IPv4: `10.1`, `1` or `010.1.1.1` are
    /// left to the connection, which classifies what they resolve to).
    public init?(literal: String) {
        var text = Substring(literal.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("["), text.hasSuffix("]") { text = text.dropFirst().dropLast() }
        if let zone = text.firstIndex(of: "%") { text = text[..<zone] }   // fe80::1%en0
        // inet_pton reads "010.1.1.1" as 10.1.1.1, getaddrinfo (the connection) as octal 8.1.1.1:
        // a leading zero is left to the resolver rather than guessed.
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        let ambiguous = octets.count == 4 && octets.contains { $0.count > 1 && $0.hasPrefix("0") }
        var v4 = in_addr()
        if !ambiguous, inet_pton(AF_INET, String(text), &v4) == 1 {
            self = Self.ipv4(withUnsafeBytes(of: v4.s_addr) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, String(text), &v6) == 1 {
            self = Self.ipv6(withUnsafeBytes(of: v6) { Array($0) })
            return
        }
        return nil
    }

    private static func ipv4(_ b: [UInt8]) -> AddressScope {
        switch (b[0], b[1]) {
        case (127, _), (0, _): .loopback
        case (10, _), (172, 16...31), (192, 168): .privateNetwork
        case (100, 64...127): .sharedAddressSpace
        case (169, 254): .linkLocal
        default: .publicInternet
        }
    }

    private static func ipv6(_ b: [UInt8]) -> AddressScope {
        // ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return ipv4(Array(b[12..<16])) }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return .loopback }   // :: and ::1
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return .linkLocal }             // fe80::/10
        if b[0] & 0xFE == 0xFC { return .uniqueLocal }                          // fc00::/7
        return .publicInternet
    }
}

/// Whether a connection may go on to the address it reached (T5.3 H1): a public address only once the
/// user confirmed it; any other scope always.
public enum PublicAddressPolicy {
    public static func admits(_ address: RemoteAddress, confirmed: Bool) -> Bool {
        confirmed || !address.scope.isPublicInternet
    }
}

/// The address a connection actually reached, as `RFBConnection.open` saw it once TCP was up.
public struct RemoteAddress: Equatable, Sendable {
    /// The IP address as text (or the endpoint's description when it is not an IP address).
    public let text: String
    public let scope: AddressScope

    public init(text: String, scope: AddressScope) {
        self.text = text
        self.scope = scope
    }

    /// The remote endpoint of a ready connection (`NWConnection.currentPath?.remoteEndpoint`). An
    /// endpoint that is not an IP address (a proxy, or none at all) cannot be placed, so it counts
    /// as the public Internet: the warning may then show for nothing, never be missed.
    public init(endpoint: NWEndpoint?, fallbackText: String) {
        switch endpoint {
        case .hostPort(.ipv4(let address), _)?:
            self.init(text: "\(address)", scope: AddressScope(addressBytes: Array(address.rawValue)) ?? .publicInternet)
        case .hostPort(.ipv6(let address), _)?:
            self.init(text: "\(address)", scope: AddressScope(addressBytes: Array(address.rawValue)) ?? .publicInternet)
        default:
            self.init(text: fallbackText, scope: .publicInternet)
        }
    }
}
