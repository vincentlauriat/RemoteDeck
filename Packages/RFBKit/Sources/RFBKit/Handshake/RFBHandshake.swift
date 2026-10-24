import Foundation

/// RFB security types RFBKit knows about (RFC 6143 §7.2 and the IANA registry).
public enum SecurityType {
    public static let invalid: UInt8 = 0
    public static let none: UInt8 = 1
    public static let vncAuthentication: UInt8 = 2
    public static let appleDiffieHellman: UInt8 = 30
    /// Newer Apple-only types offered by recent macOS versions; not implemented (PRD open question 3).
    public static let newerApple: Set<UInt8> = [33, 35, 36]
    /// Types this client can complete.
    public static let supported: Set<UInt8> = [none, vncAuthentication, appleDiffieHellman]
}

/// Outcome of a completed handshake: the session is "connected" once ServerInit has been parsed.
public struct HandshakeResult: Equatable, Sendable {
    /// Version announced by the server (e.g. 3.889 for Apple).
    public let serverVersion: ProtocolVersion
    /// Version the client answered with and that governs the rest of the handshake.
    public let version: ProtocolVersion
    public let securityType: UInt8
    public let serverInit: ServerInit
    /// Bytes received after ServerInit, the start of the normal-protocol stream.
    public let remainder: Data
}

/// What the caller must do after feeding bytes: send `outgoing` (possibly empty) and, when `result`
/// is set, stop — the handshake is complete.
public struct HandshakeStep: Equatable, Sendable {
    public var outgoing: Data
    public var result: HandshakeResult?
}

/// Transport-agnostic RFB handshake (RFC 6143 §7.1–§7.3): ProtocolVersion, security negotiation,
/// authentication (types 1, 2, 30), SecurityResult, ClientInit and ServerInit.
///
/// Feed it every byte received from the server with `receive(_:)`, send back what it returns, and
/// stop when a `HandshakeResult` comes out. Input can arrive in chunks of any size. Every length
/// field is checked against a limit as soon as it is parsed, before its payload is awaited.
///
/// Version handling: the client answers min(server, 3.8). Apple servers announce `RFB 003.889`;
/// like other clients (libvncclient, noVNC), RFBKit answers 3.8 and then speaks plain 3.8, which
/// Apple servers accept (`ProtocolVersion.negotiated()`).
public struct RFBHandshake: Sendable {
    /// Longest reason string or desktop name accepted.
    public static let maxStringLength = 16 * 1024
    /// Upper bound for buffered, not yet parsed input.
    static let maxBufferedBytes = 64 * 1024

    private enum State: Equatable {
        case version
        case securityTypeList          // 3.7 / 3.8: U8 count + types
        case securityTypeChosen        // 3.3: U32 type chosen by the server
        case refusalReason             // U32 length + reason, then fail
        case vncChallenge
        case appleDHParameters
        case securityResult
        case failureReason             // 3.8 only, after a failed SecurityResult
        case serverInit
        case connected
        case failed(RFBError)
    }

    private let credentials: RFBCredentials
    private let sharedFlag: Bool
    private let entropy: HandshakeEntropy
    private var state = State.version
    private var buffer: [UInt8] = []
    private var serverVersion: ProtocolVersion?
    private var version: ProtocolVersion?
    private var securityType: UInt8?

    /// - Parameters:
    ///   - credentials: used to pick the security type (see `selectSecurityType`).
    ///   - shared: ClientInit shared flag; `true` keeps other viewers connected.
    ///   - entropy: random source for Apple DH; inject a fixed one in tests only.
    public init(credentials: RFBCredentials, shared: Bool = true, entropy: HandshakeEntropy = .system) {
        self.credentials = credentials
        self.sharedFlag = shared
        self.entropy = entropy
    }

    /// Processes bytes received from the server. After an error, every later call throws it again.
    public mutating func receive(_ bytes: some Sequence<UInt8>) throws(RFBError) -> HandshakeStep {
        switch state {
        case .failed(let error): throw error
        case .connected: throw .protocolViolation("handshake already complete")
        default: break
        }
        buffer.append(contentsOf: bytes)
        var outgoing: [UInt8] = []
        do throws(RFBError) {
            while try advance(&outgoing) {}
            if state != .connected, buffer.count > Self.maxBufferedBytes {
                throw RFBError.protocolViolation("too much unparsed handshake data")
            }
        } catch {
            state = .failed(error)
            buffer = []
            throw error
        }
        guard state == .connected, let serverInit = pendingServerInit else {
            return HandshakeStep(outgoing: Data(outgoing), result: nil)
        }
        let result = HandshakeResult(serverVersion: serverVersion!, version: version!,
                                     securityType: securityType!, serverInit: serverInit,
                                     remainder: Data(buffer))
        buffer = []
        pendingServerInit = nil
        return HandshakeStep(outgoing: Data(outgoing), result: result)
    }

    /// The error to report when the server closes the connection before the handshake completes.
    ///
    /// A close while waiting for the SecurityResult (or its reason) after credentials were sent
    /// (types 2 and 30) is reported as `authFailed`: some servers drop the connection instead of
    /// sending a failure. That mapping is a heuristic — not verified against a real Apple server yet.
    public func errorForClosedConnection() -> RFBError {
        switch state {
        case .failed(let error):
            return error
        case .securityResult, .failureReason:
            let sentCredentials = securityType == SecurityType.vncAuthentication
                || securityType == SecurityType.appleDiffieHellman
            return sentCredentials ? .authFailed(reason: nil) : .connectionClosed
        default:
            return .connectionClosed
        }
    }

    private var pendingServerInit: ServerInit?

    /// Bytes received but not yet parsed (bounded by `maxBufferedBytes`).
    var bufferedCount: Int { buffer.count }

    // MARK: State machine

    /// Parses one message if it is complete. Returns `true` when it consumed input and moved on.
    private mutating func advance(_ out: inout [UInt8]) throws(RFBError) -> Bool {
        switch state {
        case .version:
            guard buffer.count >= 12 else { return false }
            let banner = Array(buffer[0..<12])
            guard let announced = ProtocolVersion(banner: Data(banner)) else {
                throw .protocolViolation("malformed ProtocolVersion banner")
            }
            guard let negotiated = announced.negotiated() else {
                throw .unsupportedVersion(String(decoding: banner.dropLast(), as: UTF8.self))
            }
            consume(12)
            serverVersion = announced
            version = negotiated
            out += negotiated.banner
            state = negotiated == .v3_3 ? .securityTypeChosen : .securityTypeList

        case .securityTypeList:
            guard let count = byte(at: 0) else { return false }
            if count == 0 {
                consume(1)
                state = .refusalReason
                return true
            }
            guard buffer.count >= 1 + Int(count) else { return false }
            let offered = Array(buffer[1..<(1 + Int(count))])
            consume(1 + Int(count))
            let selected = try Self.selectSecurityType(offered: offered, credentials: credentials)
            out.append(selected)
            begin(selected, &out)

        case .securityTypeChosen:
            guard let type = u32(at: 0) else { return false }
            consume(4)
            // A 3.3 server imposes the type; with a required one, anything else stops here (type 1
            // would send ClientInit at once, type 2 the DES response). 0 stays a refusal.
            if let required = credentials.requiredSecurityType, type != 0, type <= 255, type != UInt32(required) {
                throw .requiredSecurityTypeMissing(required: required, offered: [UInt8(type)])
            }
            switch type {
            case 0:
                state = .refusalReason
            case UInt32(SecurityType.none) where credentials.password != nil:
                // A password is configured: never a session without authentication (T5.3).
                throw .requiredSecurityTypeMissing(required: SecurityType.vncAuthentication, offered: [SecurityType.none])
            case UInt32(SecurityType.none):
                begin(SecurityType.none, &out)
            case UInt32(SecurityType.vncAuthentication):
                guard credentials.password != nil else {
                    throw .credentialsRequired(securityType: SecurityType.vncAuthentication)
                }
                begin(SecurityType.vncAuthentication, &out)
            case 3...255:
                // Rejected on purpose, type 30 included: RFC 6143 §7.1.2 lets a 3.3 server choose
                // only 1 or 2, and Apple servers announce 3.889, which is negotiated as 3.8.
                throw .unsupportedSecurityTypes([UInt8(type)])
            default:
                throw .protocolViolation("invalid security type \(type)")
            }

        case .refusalReason:
            guard let reason = try string(lengthAt: 0) else { return false }
            throw .connectionRefused(reason: reason)

        case .vncChallenge:
            guard buffer.count >= VNCAuth.challengeLength else { return false }
            let challenge = Array(buffer[0..<VNCAuth.challengeLength])
            consume(VNCAuth.challengeLength)
            out += try VNCAuth.response(challenge: challenge, password: credentials.password ?? "")
            state = .securityResult

        case .appleDHParameters:
            guard let generator = u16(at: 0), let keyLength = u16(at: 2).map(Int.init) else { return false }
            guard (1...AppleDHAuth.maxKeyLength).contains(keyLength) else {
                throw .protocolViolation("Apple DH key length \(keyLength) out of range")
            }
            guard buffer.count >= 4 + 2 * keyLength else { return false }
            let parameters = AppleDHAuth.Parameters(
                generator: generator,
                prime: Array(buffer[4..<(4 + keyLength)]),
                serverPublicKey: Array(buffer[(4 + keyLength)..<(4 + 2 * keyLength)]))
            consume(4 + 2 * keyLength)
            let privateKeyLength = AppleDHAuth.privateKeyLength(forKeyLength: keyLength)
            var privateKey = entropy.privateKey(privateKeyLength)
            var padding = entropy.credentialPadding(AppleDHAuth.credentialBlockLength)
            defer {
                wipe(&privateKey)
                wipe(&padding)
            }
            guard privateKey.count == privateKeyLength, padding.count == AppleDHAuth.credentialBlockLength else {
                preconditionFailure("HandshakeEntropy returned the wrong number of bytes")
            }
            out += try AppleDHAuth.response(parameters: parameters,
                                            username: credentials.username ?? "",
                                            password: credentials.password ?? "",
                                            privateKey: privateKey, padding: padding)
            state = .securityResult

        case .securityResult:
            guard let result = u32(at: 0) else { return false }
            consume(4)
            if result == 0 {
                out.append(sharedFlag ? 1 : 0)   // ClientInit
                state = .serverInit
            } else if version == .v3_8 {
                state = .failureReason
            } else {
                throw .authFailed(reason: nil)
            }

        case .failureReason:
            guard let reason = try string(lengthAt: 0) else { return false }
            throw .authFailed(reason: reason)

        case .serverInit:
            guard buffer.count >= 24, let width = u16(at: 0), let height = u16(at: 2),
                  let nameLength = u32(at: 20) else { return false }
            guard nameLength <= Self.maxStringLength else {
                throw .protocolViolation("desktop name length \(nameLength) exceeds limit")
            }
            guard buffer.count >= 24 + Int(nameLength) else { return false }
            let pixelFormat = PixelFormat(wire: buffer[4..<20])
            let name = String(decoding: buffer[24..<(24 + Int(nameLength))], as: UTF8.self)
            consume(24 + Int(nameLength))
            pendingServerInit = ServerInit(width: width, height: height, pixelFormat: pixelFormat, name: name)
            state = .connected
            return false

        case .connected, .failed:
            return false
        }
        return true
    }

    /// Enters the authentication phase of `type`, sending ClientInit right away when no
    /// SecurityResult follows (type 1 before 3.8, RFC 6143 §7.1.3).
    private mutating func begin(_ type: UInt8, _ out: inout [UInt8]) {
        securityType = type
        switch type {
        case SecurityType.vncAuthentication:
            state = .vncChallenge
        case SecurityType.appleDiffieHellman:
            state = .appleDHParameters
        default:  // none
            if version == .v3_8 {
                state = .securityResult
            } else {
                out.append(sharedFlag ? 1 : 0)   // ClientInit
                state = .serverInit
            }
        }
    }

    /// Picks the security type by preference among those the credentials allow:
    /// 30 (Apple DH) when a user name and password are set, then 2 (VNC) when a password is set, then 1
    /// only when no password is set.
    /// With `credentials.requiredSecurityType`, that type or an error: never a fallback to 2 or 1.
    package static func selectSecurityType(offered: [UInt8], credentials: RFBCredentials) throws(RFBError) -> UInt8 {
        let hasUser = !(credentials.username ?? "").isEmpty
        let hasPassword = credentials.password != nil
        if let required = credentials.requiredSecurityType {
            guard offered.contains(required) else {
                throw .requiredSecurityTypeMissing(required: required, offered: offered)
            }
            switch required {
            case SecurityType.appleDiffieHellman where !(hasUser && hasPassword),
                 SecurityType.vncAuthentication where !hasPassword:
                throw .credentialsRequired(securityType: required)
            case SecurityType.none, SecurityType.vncAuthentication, SecurityType.appleDiffieHellman:
                return required
            default:
                throw .unsupportedSecurityTypes(offered)
            }
        }
        if offered.contains(SecurityType.appleDiffieHellman), hasUser, hasPassword {
            return SecurityType.appleDiffieHellman
        }
        if offered.contains(SecurityType.vncAuthentication), hasPassword {
            return SecurityType.vncAuthentication
        }
        // A password is configured: never type 1 (no authentication) in its place (T5.3). A server
        // offering Apple DH asks for the user name; any other wants no password.
        if hasPassword {
            if offered.contains(SecurityType.appleDiffieHellman) {
                throw .credentialsRequired(securityType: SecurityType.appleDiffieHellman)
            }
            if offered.contains(SecurityType.none) {
                throw .requiredSecurityTypeMissing(required: SecurityType.vncAuthentication, offered: offered)
            }
        }
        if offered.contains(SecurityType.none) {
            return SecurityType.none
        }
        if offered.contains(SecurityType.appleDiffieHellman) {
            throw .credentialsRequired(securityType: SecurityType.appleDiffieHellman)
        }
        if offered.contains(SecurityType.vncAuthentication) {
            throw .credentialsRequired(securityType: SecurityType.vncAuthentication)
        }
        if offered.contains(where: SecurityType.newerApple.contains) {
            throw .unsupportedAppleSecurityTypes(offered)
        }
        throw .unsupportedSecurityTypes(offered)
    }

    // MARK: Buffer access (big-endian, RFC 6143 §7)

    private mutating func consume(_ count: Int) {
        buffer.removeFirst(count)
    }

    private func byte(at offset: Int) -> UInt8? {
        buffer.count > offset ? buffer[offset] : nil
    }

    private func u16(at offset: Int) -> UInt16? {
        guard buffer.count >= offset + 2 else { return nil }
        return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    private func u32(at offset: Int) -> UInt32? {
        guard buffer.count >= offset + 4 else { return nil }
        return buffer[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// A U32-length-prefixed string at `offset`, or `nil` while incomplete. The length is checked
    /// before the payload is awaited. Consumes the string when complete.
    private mutating func string(lengthAt offset: Int) throws(RFBError) -> String? {
        guard let length = u32(at: offset) else { return nil }
        guard length <= Self.maxStringLength else {
            throw .protocolViolation("string length \(length) exceeds limit")
        }
        let end = offset + 4 + Int(length)
        guard buffer.count >= end else { return nil }
        let text = String(decoding: buffer[(offset + 4)..<end], as: UTF8.self)
        consume(end)
        return text
    }
}
