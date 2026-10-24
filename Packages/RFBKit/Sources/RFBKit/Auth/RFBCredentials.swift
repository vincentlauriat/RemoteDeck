import Foundation
import Security

/// Credentials used to authenticate a session. `description` never prints the password.
/// Its mirror is empty, so `dump()` and other reflection-based printing reveal nothing either.
public struct RFBCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// macOS user name; when set (with a password), Apple DH (type 30) is preferred.
    public var username: String?
    /// VNC password (type 2) or macOS password (type 30).
    public var password: String?
    /// The only security type these credentials may be used with, or `nil` for the usual preference
    /// (30, then 2, then 1). The app sets 30 for a Mac (ARD) with a user name (T5.3 M4): its macOS
    /// password must never go out as a VNC DES response, nor the session start unauthenticated.
    public var requiredSecurityType: UInt8?

    public init(username: String? = nil, password: String? = nil, requiredSecurityType: UInt8? = nil) {
        self.username = username
        self.password = password
        self.requiredSecurityType = requiredSecurityType
    }

    public static let none = RFBCredentials()

    public var description: String {
        "RFBCredentials(username: \(username == nil ? "nil" : "<set>"), password: \(password == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Sources of random bytes for Apple DH authentication, injectable so tests are deterministic.
///
/// The private key and the credential padding come from two separate providers, so a test vector
/// can pin each one without depending on the order in which they are consumed.
public struct HandshakeEntropy: Sendable {
    /// Returns `count` random bytes the DH private exponent is derived from (`count` = min(key length, 64),
    /// see `AppleDHAuth.maxPrivateKeyLength` and `AppleDHAuth.privateExponent`).
    public var privateKey: @Sendable (_ count: Int) -> [UInt8]
    /// Returns 128 bytes that fill the credential block before the user name and password are copied in.
    public var credentialPadding: @Sendable (_ count: Int) -> [UInt8]

    public init(privateKey: @escaping @Sendable (Int) -> [UInt8],
                credentialPadding: @escaping @Sendable (Int) -> [UInt8]) {
        self.privateKey = privateKey
        self.credentialPadding = credentialPadding
    }

    /// Cryptographically secure bytes from `SecRandomCopyBytes`.
    public static let system = HandshakeEntropy(privateKey: secureRandomBytes, credentialPadding: secureRandomBytes)
}

@Sendable func secureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    // SecRandomCopyBytes only fails when the system RNG is unavailable; continuing with zeros
    // would silently weaken the key, so stop instead.
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return bytes
}

/// Overwrites key material in place. `memset_s` is not elided by the optimizer.
/// Best effort: copies made earlier by copy-on-write are not reachable from here.
func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = memset_s(base, raw.count, 0, raw.count)
    }
}
