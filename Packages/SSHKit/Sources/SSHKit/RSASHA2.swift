import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSH

// RFC 8332 for swift-nio-ssh, through its public custom-key API only (ported from the SSH spike's
// adapter; see docs/superpowers/specs/2026-11-08-ssh-terminal-spike.md). Citadel signs RSA with
// SHA-1 `ssh-rsa` only, which OpenSSH refuses by default; these types sign and verify with
// `rsa-sha2-512` and `rsa-sha2-256`, and never accept a SHA-1 signature.
//
// An RSA host key arrives as a blob typed `ssh-rsa` under a negotiated `rsa-sha2-*` algorithm: the
// vendored swift-nio-ssh's RFC 8332 patch lets that through, and `SSHRSAHostKey` verifies it.

/// One RFC 8332 signature algorithm: its name and its PKCS #1 v1.5 hash.
protocol RSASHA2Variant: Sendable {
    static var name: String { get }
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data
    static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool
}

enum RSASHA512: RSASHA2Variant {
    static let name = "rsa-sha2-512"
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data {
        try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

enum RSASHA256: RSASHA2Variant {
    static let name = "rsa-sha2-256"
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: Data) throws -> Data {
        try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
    static func verify(_ key: _RSA.Signing.PublicKey, _ signature: Data, _ data: Data) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

enum RSASHA2Error: Error {
    case malformed
}

/// An `rsa-sha2-*` signature blob: the raw PKCS #1 v1.5 signature.
struct RSASHA2Signature<Variant: RSASHA2Variant>: NIOSSHSignatureProtocol, Sendable {
    static var signaturePrefix: String { Variant.name }
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(SSHWire.string(rawRepresentation))
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let length: UInt32 = buffer.readInteger(), let bytes = buffer.readData(length: Int(length)) else {
            throw RSASHA2Error.malformed
        }
        return Self(rawRepresentation: bytes)
    }
}

/// The body of an RSA public key blob after its type: `mpint e`, `mpint n`.
struct RSAPublicBody: Hashable, Sendable {
    let e: [UInt8]
    let n: [UInt8]

    init(e: [UInt8], n: [UInt8]) {
        self.e = SSHWire.magnitude(e)
        self.n = SSHWire.magnitude(n)
    }

    var bytes: [UInt8] { SSHWire.mpint(e) + SSHWire.mpint(n) }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(bytes)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSAPublicBody {
        guard let eLength: UInt32 = buffer.readInteger(), let e = buffer.readBytes(length: Int(eLength)),
              let nLength: UInt32 = buffer.readInteger(), let n = buffer.readBytes(length: Int(nLength))
        else { throw RSASHA2Error.malformed }
        return RSAPublicBody(e: e, n: n)
    }

    var cryptoKey: _RSA.Signing.PublicKey? {
        try? _RSA.Signing.PublicKey(n: n, e: e)
    }
}

/// An RSA public key offered or negotiated as `rsa-sha2-512` or `rsa-sha2-256`.
final class RSASHA2PublicKey<Variant: RSASHA2Variant>: NIOSSHPublicKeyProtocol, Sendable {
    static var publicKeyPrefix: String { Variant.name }
    let body: RSAPublicBody

    init(body: RSAPublicBody) { self.body = body }

    var rawRepresentation: Data { Data(body.bytes) }
    func write(to buffer: inout ByteBuffer) -> Int { body.write(to: &buffer) }
    static func read(from buffer: inout ByteBuffer) throws -> Self { Self(body: try RSAPublicBody.read(from: &buffer)) }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASHA2Signature<Variant>, let key = body.cryptoKey else { return false }
        return Variant.verify(key, signature.rawRepresentation, Data(data))
    }
}

/// An RSA host key as servers label it on the wire (`ssh-rsa`), accepting SHA-2 signatures only:
/// a SHA-1 `ssh-rsa` signature never verifies.
final class SSHRSAHostKey: NIOSSHPublicKeyProtocol, Sendable {
    static let publicKeyPrefix = "ssh-rsa"
    let body: RSAPublicBody

    init(body: RSAPublicBody) { self.body = body }

    var rawRepresentation: Data { Data(body.bytes) }
    func write(to buffer: inout ByteBuffer) -> Int { body.write(to: &buffer) }
    static func read(from buffer: inout ByteBuffer) throws -> SSHRSAHostKey { SSHRSAHostKey(body: try RSAPublicBody.read(from: &buffer)) }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let key = body.cryptoKey else { return false }
        if let signature = signature as? RSASHA2Signature<RSASHA512> {
            return RSASHA512.verify(key, signature.rawRepresentation, Data(data))
        }
        if let signature = signature as? RSASHA2Signature<RSASHA256> {
            return RSASHA256.verify(key, signature.rawRepresentation, Data(data))
        }
        return false
    }
}

/// An RSA private key that signs as `rsa-sha2-512` or `rsa-sha2-256`.
final class RSASHA2PrivateKey<Variant: RSASHA2Variant>: NIOSSHPrivateKeyProtocol, Sendable {
    static var keyPrefix: String { Variant.name }
    let key: _RSA.Signing.PrivateKey
    let body: RSAPublicBody

    init(key: _RSA.Signing.PrivateKey, body: RSAPublicBody) {
        self.key = key
        self.body = body
    }

    var publicKey: NIOSSHPublicKeyProtocol { RSASHA2PublicKey<Variant>(body: body) }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASHA2Signature<Variant>(rawRepresentation: try Variant.sign(key, Data(data)))
    }
}

enum RSASHA2 {
    /// Registers the RFC 8332 key and signature types with swift-nio-ssh, once per process.
    /// Call it before opening a connection.
    static func register() {
        _ = registration
    }

    private static let registration: Void = {
        NIOSSHAlgorithms.register(publicKey: RSASHA2PublicKey<RSASHA512>.self, signature: RSASHA2Signature<RSASHA512>.self)
        NIOSSHAlgorithms.register(publicKey: RSASHA2PublicKey<RSASHA256>.self, signature: RSASHA2Signature<RSASHA256>.self)
        NIOSSHAlgorithms.register(publicKey: SSHRSAHostKey.self, signature: RSASHA2Signature<RSASHA512>.self)
    }()
}
