import Foundation
import Testing
@testable import RFBKit

/// Hand-built RFC 6143 handshakes fed to the pure state machine, each in one piece, byte by byte
/// and in 7-byte chunks. Crypto bytes come from `AuthVectors` (independent of RFBKit).
///
/// Real captures from a macOS host (minim6) belong in `Captures/` — see its README; none yet.
struct HandshakeTests {
    static let vnc = AuthVectors.vnc[0]  // password "secret"
    static let dh1024 = AuthVectors.appleDH.first { $0.keyLength == 128 }!
    static let dhSmall = AuthVectors.appleDH.first { $0.keyLength == 2 }!
    static let dh4096 = AuthVectors.appleDH.first { $0.keyLength == 512 }!
    static let bell: [UInt8] = [2]  // a Bell message right after ServerInit

    // MARK: Successful handshakes

    @Test(arguments: Chunking.allCases)
    func v38VNCAuthSuccess(chunking: Chunking) throws {
        let server = ServerMessage.banner("RFB 003.008\n") + [2, 1, 2] + [UInt8](hex: Self.vnc.challenge)
            + ServerMessage.securityResult(0) + ServerMessage.serverInit() + Self.bell
        var handshake = RFBHandshake(credentials: RFBCredentials(password: Self.vnc.password))
        let outcome = drive(&handshake, server: server, chunking: chunking)

        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.008\n".utf8) + [2] + [UInt8](hex: Self.vnc.response) + [1])
        let result = try #require(outcome.result)
        #expect(result.version == .v3_8)
        #expect(result.securityType == 2)
        #expect(result.serverInit == ServerInit(width: 1920, height: 1080,
                                                pixelFormat: ServerMessage.pixelFormat, name: "minim6"))
        #expect(outcome.streamAfterServerInit == Self.bell)
    }

    @Test(arguments: Chunking.allCases)
    func appleBannerWithDHAuthSuccess(chunking: Chunking) async throws {
        let vector = Self.dh1024
        let server = ServerMessage.banner("RFB 003.889\n") + [2, 30, 2] + vector.serverParametersMessage
            + ServerMessage.securityResult(0) + ServerMessage.serverInit(width: 3024, height: 1964, name: "Mac mini")
        let outcome = try await offCooperativePool {
            var handshake = RFBHandshake(credentials: vector.credentials, shared: false, entropy: vector.entropy)
            return drive(&handshake, server: server, chunking: chunking)
        }

        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.008\n".utf8) + [30] + vector.expectedClientResponse + [0])
        let result = try #require(outcome.result)
        #expect(result.serverVersion == ProtocolVersion(major: 3, minor: 889))
        #expect(result.version == .v3_8)
        #expect(result.securityType == 30)
        #expect(result.serverInit.name == "Mac mini")
        #expect(result.serverInit.width == 3024)
    }

    /// What a macOS 26 server sends: RFC 3526 group 16 (4096-bit prime), generator 5, key length 512.
    @Test(arguments: Chunking.allCases)
    func appleDH4096Success(chunking: Chunking) async throws {
        let vector = Self.dh4096
        #expect(vector.generator == 5)
        let server = ServerMessage.banner("RFB 003.889\n") + [5, 30, 33, 36, 2, 35] + vector.serverParametersMessage
            + ServerMessage.securityResult(0) + ServerMessage.serverInit(name: "minim6")
        let outcome = try await offCooperativePool {
            var handshake = RFBHandshake(credentials: vector.credentials, entropy: vector.entropy)
            return drive(&handshake, server: server, chunking: chunking)
        }

        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.008\n".utf8) + [30] + vector.expectedClientResponse + [1])
        #expect(vector.expectedClientResponse.count == 128 + 512)
        let result = try #require(outcome.result)
        #expect(result.securityType == 30)
        #expect(result.serverInit.name == "minim6")
    }

    @Test(arguments: Chunking.allCases)
    func dhWithLeftPaddedSharedSecret(chunking: Chunking) throws {
        let vector = Self.dhSmall
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 30] + vector.serverParametersMessage
            + ServerMessage.securityResult(0) + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: vector.credentials, entropy: vector.entropy)
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.008\n".utf8) + [30] + vector.expectedClientResponse + [1])
        #expect(outcome.result != nil)
    }

    @Test(arguments: Chunking.allCases)
    func v33ServerChosenVNCAuth(chunking: Chunking) throws {
        let server = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(2)
            + [UInt8](hex: Self.vnc.challenge) + ServerMessage.securityResult(0) + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: RFBCredentials(password: Self.vnc.password))
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == nil)
        // 3.3: no selection byte from the client.
        #expect(outcome.clientBytes == Array("RFB 003.003\n".utf8) + [UInt8](hex: Self.vnc.response) + [1])
        #expect(outcome.result?.version == .v3_3)
    }

    @Test(arguments: Chunking.allCases)
    func v33NoneHasNoSecurityResult(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(1) + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: .none)
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.003\n".utf8) + [1])
        #expect(outcome.result?.securityType == 1)
    }

    @Test(arguments: Chunking.allCases)
    func v37NoneHasNoSecurityResult(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.007\n") + [1, 1] + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: .none)
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.007\n".utf8) + [1, 1])  // selection + ClientInit
        #expect(outcome.result?.version == .v3_7)
    }

    @Test(arguments: Chunking.allCases)
    func v38NoneWaitsForSecurityResult(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 1] + ServerMessage.securityResult(0)
            + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: .none)
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == nil)
        #expect(outcome.clientBytes == Array("RFB 003.008\n".utf8) + [1, 1])
        #expect(outcome.result != nil)
    }

    @Test func clientInitWaitsForSecurityResult() throws {
        var handshake = RFBHandshake(credentials: .none)
        _ = try handshake.receive(ServerMessage.banner("RFB 003.008\n"))
        #expect(try handshake.receive([1, 1]).outgoing == Data([1]))  // selection only, no ClientInit yet
        #expect(try handshake.receive(ServerMessage.securityResult(0)).outgoing == Data([1]))
    }

    // MARK: Authentication failures (PRD criterion 2b)

    @Test(arguments: Chunking.allCases)
    func v38VNCAuthFailureWithReason(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 2] + [UInt8](hex: Self.vnc.challenge)
            + ServerMessage.securityResult(1) + ServerMessage.string("Authentication failed")
        var handshake = RFBHandshake(credentials: RFBCredentials(password: "wrong"))
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == .authFailed(reason: "Authentication failed"))
        #expect(outcome.result == nil)
        // No ClientInit after a failure. Fed in one piece, the error is thrown within the single
        // `receive` call, so nothing at all is returned to send.
        #expect(outcome.clientBytes.count == (chunking == .whole ? 0 : 12 + 1 + 16))
    }

    @Test func v33And37FailureHasNoReason() {
        for banner in ["RFB 003.003\n", "RFB 003.007\n"] {
            let security: [UInt8] = banner == "RFB 003.003\n" ? ServerMessage.securityResult(2) : [1, 2]
            let server = ServerMessage.banner(banner) + security + [UInt8](hex: Self.vnc.challenge)
                + ServerMessage.securityResult(1)
            var handshake = RFBHandshake(credentials: RFBCredentials(password: "wrong"))
            #expect(drive(&handshake, server: server, chunking: .whole).error == .authFailed(reason: nil))
        }
    }

    @Test func errorIsStickyAfterFailure() {
        var handshake = RFBHandshake(credentials: RFBCredentials(password: "wrong"))
        let server = ServerMessage.banner("RFB 003.007\n") + [1, 2] + [UInt8](hex: Self.vnc.challenge)
            + ServerMessage.securityResult(1)
        _ = drive(&handshake, server: server, chunking: .whole)
        #expect(throws: RFBError.authFailed(reason: nil)) { try handshake.receive([0]) }
        #expect(handshake.errorForClosedConnection() == .authFailed(reason: nil))
    }

    @Test func closeAfterCredentialsIsReportedAsAuthFailure() throws {
        var handshake = RFBHandshake(credentials: RFBCredentials(password: "x"))
        _ = try handshake.receive(ServerMessage.banner("RFB 003.008\n") + [1, 2] + [UInt8](hex: Self.vnc.challenge))
        #expect(handshake.errorForClosedConnection() == .authFailed(reason: nil))
    }

    @Test func closeWhileWaitingForSecurityResultOfNoneIsConnectionClosed() throws {
        var handshake = RFBHandshake(credentials: .none)
        _ = try handshake.receive(ServerMessage.banner("RFB 003.008\n") + [1, 1])
        #expect(handshake.errorForClosedConnection() == .connectionClosed)  // no credentials were sent
    }

    @Test func closeBeforeAuthenticationIsConnectionClosed() throws {
        var handshake = RFBHandshake(credentials: .none)
        _ = try handshake.receive(Array("RFB 003.0".utf8))
        #expect(handshake.errorForClosedConnection() == .connectionClosed)
    }

    // MARK: Refusals and security-type selection

    @Test(arguments: Chunking.allCases)
    func zeroSecurityTypesCarriesReason(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.008\n") + [0] + ServerMessage.string("Too many security failures")
        var handshake = RFBHandshake(credentials: .none)
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == .connectionRefused(reason: "Too many security failures"))
    }

    @Test func v33SecurityTypeZeroCarriesReason() {
        let server = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(0) + ServerMessage.string("busy")
        var handshake = RFBHandshake(credentials: .none)
        #expect(drive(&handshake, server: server, chunking: .byteByByte).error == .connectionRefused(reason: "busy"))
    }

    @Test(arguments: Chunking.allCases)
    func onlyNewerAppleTypesIsDistinguishable(chunking: Chunking) {
        let server = ServerMessage.banner("RFB 003.889\n") + [3, 33, 35, 36]
        var handshake = RFBHandshake(credentials: RFBCredentials(username: "vincent", password: "pw"))
        let outcome = drive(&handshake, server: server, chunking: chunking)
        #expect(outcome.error == .unsupportedAppleSecurityTypes([33, 35, 36]))
    }

    @Test func unknownTypesListTheOffer() {
        let server = ServerMessage.banner("RFB 003.008\n") + [2, 16, 19]
        var handshake = RFBHandshake(credentials: RFBCredentials(password: "pw"))
        #expect(drive(&handshake, server: server, chunking: .whole).error == .unsupportedSecurityTypes([16, 19]))
    }

    @Test func selectionPrefersAppleDHThenVNCThenNone() throws {
        let all: [UInt8] = [1, 2, 30, 35]
        let full = RFBCredentials(username: "vincent", password: "pw")
        #expect(try RFBHandshake.selectSecurityType(offered: all, credentials: full) == 30)
        #expect(try RFBHandshake.selectSecurityType(offered: all, credentials: RFBCredentials(password: "pw")) == 2)
        #expect(try RFBHandshake.selectSecurityType(offered: all, credentials: .none) == 1)
        #expect(try RFBHandshake.selectSecurityType(offered: [2, 1], credentials: full) == 2)
        #expect(try RFBHandshake.selectSecurityType(offered: [33, 30, 2], credentials: full) == 30)
    }

    @Test func missingCredentialsAreNotUnsupportedTypes() {
        #expect(throws: RFBError.credentialsRequired(securityType: 30)) {
            try RFBHandshake.selectSecurityType(offered: [30, 2], credentials: .none)
        }
        #expect(throws: RFBError.credentialsRequired(securityType: 30)) {
            try RFBHandshake.selectSecurityType(offered: [30], credentials: RFBCredentials(password: "pw"))
        }
        #expect(throws: RFBError.credentialsRequired(securityType: 2)) {
            try RFBHandshake.selectSecurityType(offered: [2, 35], credentials: RFBCredentials(username: "vincent"))
        }
    }

    @Test func v33WithoutPasswordForVNCAuth() {
        let server = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(2)
        var handshake = RFBHandshake(credentials: .none)
        #expect(drive(&handshake, server: server, chunking: .whole).error == .credentialsRequired(securityType: 2))
    }

    @Test func dhCredentialTooLongFailsBeforeSending() async throws {
        let vector = Self.dh1024
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 30] + vector.serverParametersMessage
        let outcome = try await offCooperativePool {
            var handshake = RFBHandshake(credentials: RFBCredentials(username: String(repeating: "u", count: 64),
                                                                     password: "p"),
                                         entropy: vector.entropy)
            return drive(&handshake, server: server, chunking: .whole)
        }
        #expect(outcome.error == .credentialTooLong)
        #expect(outcome.clientBytes.isEmpty)  // nothing sent: the banner and selection were in the same feed
    }

    // MARK: Protocol violations and limits

    @Test func malformedAndUnsupportedBanners() {
        var malformed = RFBHandshake(credentials: .none)
        #expect(throws: RFBError.self) { try malformed.receive(Array("SSH-2.0-Open".utf8)) }
        var future = RFBHandshake(credentials: .none)
        #expect(throws: RFBError.unsupportedVersion("RFB 004.000")) { try future.receive(Array("RFB 004.000\n".utf8)) }
    }

    @Test func oversizedReasonIsRejectedFromItsLengthAlone() throws {
        var handshake = RFBHandshake(credentials: RFBCredentials(password: "x"))
        _ = try handshake.receive(ServerMessage.banner("RFB 003.008\n") + [1, 2] + [UInt8](hex: Self.vnc.challenge)
            + ServerMessage.securityResult(1))
        #expect(throws: RFBError.protocolViolation("string length 4294967295 exceeds limit")) {
            try handshake.receive([0xFF, 0xFF, 0xFF, 0xFF])
        }
    }

    @Test func oversizedRefusalReasonIsRejected() {
        let server = ServerMessage.banner("RFB 003.008\n") + [0] + UInt32(RFBHandshake.maxStringLength + 1).bigEndianBytes
        var handshake = RFBHandshake(credentials: .none)
        guard case .protocolViolation = drive(&handshake, server: server, chunking: .whole).error else {
            Issue.record("expected a protocol violation")
            return
        }
    }

    @Test func oversizedDesktopNameIsRejectedFromItsLengthAlone() throws {
        var handshake = RFBHandshake(credentials: .none)
        _ = try handshake.receive(ServerMessage.banner("RFB 003.007\n") + [1, 1])
        let header = Array(ServerMessage.serverInit().prefix(20)) + UInt32(0x7FFF_FFFF).bigEndianBytes
        #expect(throws: RFBError.protocolViolation("desktop name length 2147483647 exceeds limit")) {
            try handshake.receive(header)
        }
    }

    @Test(arguments: [0, 513, 0xFFFF])
    func dhKeyLengthOutOfRange(keyLength: Int) {
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 30] + UInt16(2).bigEndianBytes
            + UInt16(keyLength).bigEndianBytes
        var handshake = RFBHandshake(credentials: RFBCredentials(username: "u", password: "p"))
        #expect(drive(&handshake, server: server, chunking: .whole).error
            == .protocolViolation("Apple DH key length \(keyLength) out of range"))
    }

    @Test func dhEvenPrimeIsRejected() {
        var message = Self.dhSmall.serverParametersMessage
        message[5] &= 0xFE  // low byte of the 2-byte prime
        let server = ServerMessage.banner("RFB 003.008\n") + [1, 30] + message
        var handshake = RFBHandshake(credentials: Self.dhSmall.credentials, entropy: Self.dhSmall.entropy)
        guard case .protocolViolation = drive(&handshake, server: server, chunking: .whole).error else {
            Issue.record("expected a protocol violation")
            return
        }
    }

    @Test func v33InvalidSecurityType() {
        let server = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(300)
        var handshake = RFBHandshake(credentials: .none)
        #expect(drive(&handshake, server: server, chunking: .whole).error == .protocolViolation("invalid security type 300"))
    }

    /// RFC 6143 §7.1.2: a 3.3 server may choose only type 1 or 2, so type 30 is refused on purpose
    /// (Apple servers announce 3.889 and get the 3.8 list exchange instead).
    @Test func v33ServerChosenAppleDHIsRejectedOnPurpose() {
        var apple = RFBHandshake(credentials: RFBCredentials(username: "vincent", password: "pw"))
        let appleServer = ServerMessage.banner("RFB 003.003\n") + ServerMessage.securityResult(30)
        #expect(drive(&apple, server: appleServer, chunking: .whole).error == .unsupportedSecurityTypes([30]))
    }

    @Test(arguments: Chunking.allCases)
    func truncatedStreamProducesNoResult(chunking: Chunking) {
        let full = ServerMessage.banner("RFB 003.008\n") + [1, 1] + ServerMessage.securityResult(0) + ServerMessage.serverInit()
        var handshake = RFBHandshake(credentials: .none)
        let outcome = drive(&handshake, server: Array(full.dropLast(3)), chunking: chunking)
        #expect(outcome.error == nil)
        #expect(outcome.result == nil)
        #expect(handshake.errorForClosedConnection() == .connectionClosed)
    }

    @Test func receivingAfterCompletionIsAViolation() throws {
        var handshake = RFBHandshake(credentials: .none)
        let step = try handshake.receive(ServerMessage.banner("RFB 003.007\n") + [1, 1] + ServerMessage.serverInit())
        #expect(step.result != nil)
        #expect(throws: RFBError.self) { try handshake.receive([0]) }
    }

    @Test func credentialsDescriptionIsRedacted() {
        let credentials = RFBCredentials(username: "vincent", password: "hunter2")
        #expect(!String(describing: credentials).contains("hunter2"))
        #expect(!String(reflecting: credentials).contains("hunter2"))
        #expect(!String(describing: credentials).contains("vincent"))
        var dumped = ""
        dump(credentials, to: &dumped)
        dump(RFBHandshake(credentials: credentials), to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(!dumped.contains("vincent"))
    }
}
