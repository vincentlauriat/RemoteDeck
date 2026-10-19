import Foundation

/// Every failure RFBKit reports while opening a session.
///
/// Cases never carry secrets: no password, key or credential bytes appear in an error.
public enum RFBError: Error, Equatable, Sendable {
    /// The server banner is not an RFB 3.x version this client speaks. Carries the banner text.
    case unsupportedVersion(String)
    /// The server refused the connection before authentication (zero security types in 3.7/3.8,
    /// or security type 0 in 3.3), with the reason string it sent.
    case connectionRefused(reason: String?)
    /// None of the offered security types is implemented (1, 2 and 30 are). Carries the offered list.
    case unsupportedSecurityTypes([UInt8])
    /// Like `unsupportedSecurityTypes`, but the list contains one of the newer Apple-only types
    /// (33, 35, 36) seen on recent macOS. Kept apart so the UI can explain it (PRD open question 3).
    case unsupportedAppleSecurityTypes([UInt8])
    /// A supported security type was offered, but the credentials it needs are missing
    /// (type 30 needs a user name and a password, type 2 a password).
    case credentialsRequired(securityType: UInt8)
    /// A user name or password is longer than 63 UTF-8 bytes, the limit of Apple DH authentication.
    case credentialTooLong
    /// The server rejected the credentials. 3.8 servers send a reason; 3.3/3.7 servers do not.
    case authFailed(reason: String?)
    /// The server sent something RFC 6143 does not allow, or a length beyond RFBKit's limits.
    case protocolViolation(String)
    /// A CommonCrypto call failed (status code).
    case cryptoFailure(status: Int32)
    /// The connection and handshake did not complete before the deadline.
    case timeout
    /// The task running `RFBConnection.open` was cancelled; the connection was closed.
    /// RFBKit reports this typed case rather than `CancellationError`, so callers see one error type.
    case cancelled
    /// The server closed the connection in the middle of the handshake.
    case connectionClosed
    /// A transport error from Network.framework (description of the `NWError`).
    case network(String)
}
