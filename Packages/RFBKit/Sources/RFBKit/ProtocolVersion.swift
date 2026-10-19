import Foundation

/// RFB protocol version exchanged in the first 12 bytes of a session (RFC 6143 §7.1.1).
public struct ProtocolVersion: Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public static let v3_3 = ProtocolVersion(major: 3, minor: 3)
    public static let v3_7 = ProtocolVersion(major: 3, minor: 7)
    public static let v3_8 = ProtocolVersion(major: 3, minor: 8)

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses the `"RFB xxx.yyy\n"` banner sent by the server.
    public init?(banner: Data) {
        guard banner.count == 12,
              let text = String(data: banner, encoding: .ascii),
              text.hasPrefix("RFB "), text.hasSuffix("\n") else { return nil }
        let digits = text.dropFirst(4).dropLast().split(separator: ".")
        guard digits.count == 2, digits.allSatisfy({ $0.count == 3 }),
              let major = Int(digits[0]), let minor = Int(digits[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    /// Wire form, e.g. `"RFB 003.008\n"`.
    public var banner: Data {
        Data(String(format: "RFB %03d.%03d\n", major, minor).utf8)
    }

    /// The version the client answers with: the highest version both sides support.
    /// Servers announcing an unknown minor (e.g. Apple's 3.889) are answered with 3.8.
    public func negotiated() -> ProtocolVersion? {
        guard major == 3 else { return nil }
        switch minor {
        case 8...: return .v3_8
        case 7: return .v3_7
        case 3...6: return .v3_3
        default: return nil
        }
    }

    public var description: String { "\(major).\(minor)" }
}
