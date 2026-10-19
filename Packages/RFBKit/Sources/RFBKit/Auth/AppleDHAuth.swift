import CryptoKit
import Foundation

/// RFB security type 30, Apple Remote Desktop Diffie-Hellman authentication.
///
/// Not in RFC 6143; the wire format below is the one implemented by libvncclient, noVNC and
/// other open-source ARD clients:
/// - server → client: generator (U16), key length k (U16), prime (k bytes), server public key (k bytes);
/// - client: private key x, public key gˣ mod p, shared secret = serverPublicˣ mod p (left-padded to k),
///   AES key = MD5(shared secret);
/// - credentials: 128 bytes, user name in the first 64 and password in the last 64, each NUL-terminated,
///   the rest random; AES-128-ECB, no padding;
/// - client → server: ciphertext (128 bytes), then the client public key (k bytes).
///
/// The exchange is unauthenticated, so it protects against passive eavesdropping only; a MITM can
/// substitute its own parameters. RFBKit does not enforce a minimum prime size for that reason.
enum AppleDHAuth {
    /// Largest key length accepted from a server: 256 bytes = 2048-bit prime.
    static let maxKeyLength = 256
    /// Longest user name or password in UTF-8 bytes (64-byte field minus the NUL terminator).
    static let maxCredentialLength = 63
    static let credentialBlockLength = 128

    struct Parameters: Equatable {
        var generator: UInt16
        var prime: [UInt8]
        var serverPublicKey: [UInt8]

        var keyLength: Int { prime.count }
    }

    /// Validates the server parameters: odd prime > 3, 1 < g < p − 1, 1 < server public key < p − 1.
    static func validate(_ parameters: Parameters) throws(RFBError) {
        let prime = BigUInt(bigEndian: parameters.prime)
        guard prime.isOdd, prime > BigUInt(3) else {
            throw .protocolViolation("Apple DH prime must be odd and greater than 3")
        }
        let upper = prime.subtracting(BigUInt(1))
        let generator = BigUInt(UInt64(parameters.generator))
        guard generator > BigUInt(1), generator < upper else {
            throw .protocolViolation("Apple DH generator out of range")
        }
        let serverPublic = BigUInt(bigEndian: parameters.serverPublicKey)
        guard serverPublic > BigUInt(1), serverPublic < upper else {
            throw .protocolViolation("Apple DH server public key out of range")
        }
    }

    /// Builds the 128-byte credential block: `padding`, overwritten by the NUL-terminated user name
    /// at offset 0 and the NUL-terminated password at offset 64.
    static func credentialBlock(username: String, password: String, padding: [UInt8]) throws(RFBError) -> [UInt8] {
        precondition(padding.count == credentialBlockLength, "credential padding must be 128 bytes")
        var user = Array(username.utf8)
        var pass = Array(password.utf8)
        defer {
            wipe(&user)
            wipe(&pass)
        }
        guard user.count <= maxCredentialLength, pass.count <= maxCredentialLength else {
            throw .credentialTooLong
        }
        var block = padding
        block.replaceSubrange(0..<user.count, with: user)
        block[user.count] = 0
        block.replaceSubrange(64..<(64 + pass.count), with: pass)
        block[64 + pass.count] = 0
        return block
    }

    /// The bytes the client sends: AES ciphertext of the credentials (128) followed by its public key (k).
    static func response(parameters: Parameters, username: String, password: String,
                         privateKey: [UInt8], padding: [UInt8]) throws(RFBError) -> [UInt8] {
        try validate(parameters)
        let keyLength = parameters.keyLength
        let prime = BigUInt(bigEndian: parameters.prime)
        let generator = BigUInt(UInt64(parameters.generator))
        let serverPublic = BigUInt(bigEndian: parameters.serverPublicKey)

        let clientPublic = generator.power(privateKey, modulo: prime).bigEndianBytes(count: keyLength)
        var shared = serverPublic.power(privateKey, modulo: prime).bigEndianBytes(count: keyLength)
        var aesKey = Array(Insecure.MD5.hash(data: shared))
        var block = try credentialBlock(username: username, password: password, padding: padding)
        defer {
            wipe(&shared)
            wipe(&aesKey)
            wipe(&block)
        }
        let ciphertext = try ECBCipher.encrypt(.aes128, key: aesKey, plaintext: block)
        return ciphertext + clientPublic
    }
}
