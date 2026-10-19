import CryptoKit
import Foundation

/// RFB security type 30, Apple Remote Desktop Diffie-Hellman authentication.
///
/// Not in RFC 6143; the wire format below is the one implemented by libvncclient, noVNC and
/// other open-source ARD clients:
/// - server → client: generator (U16), key length k (U16), prime (k bytes), server public key (k bytes);
/// - client: private key x (512 bits, see `maxPrivateKeyLength`), public key gˣ mod p,
///   shared secret = serverPublicˣ mod p (left-padded to k),
///   AES key = MD5(shared secret);
/// - credentials: 128 bytes, user name in the first 64 and password in the last 64, each NUL-terminated,
///   the rest random; AES-128-ECB, no padding;
/// - client → server: ciphertext (128 bytes), then the client public key (k bytes).
///
/// The exchange is unauthenticated, so it protects against passive eavesdropping only; a MITM can
/// substitute its own parameters. RFBKit does not enforce a minimum prime size for that reason.
enum AppleDHAuth {
    /// Largest key length accepted from a server: 512 bytes = 4096-bit prime. macOS 26 servers send
    /// the RFC 3526 group 16 prime (4096 bits) with generator 5.
    static let maxKeyLength = 512
    /// Length of the random private exponent drawn per connection: 64 bytes = 512 bits.
    ///
    /// The exponent does not need to be as long as the prime. For DH over a safe prime (the MODP
    /// groups are safe primes), an exponent of at least twice the target security strength is enough:
    /// - RFC 3526 §8 estimates group 16 (4096-bit) at 150–240 bits of strength, with exponent sizes of
    ///   300–480 bits;
    /// - NIST SP 800-56A Rev. 3 §5.6.1.1.1 requires a private key bit length N with 2s ≤ N ≤ len(q)
    ///   for the approved safe-prime groups, and Table 25 gives MODP-4096 at most s = 152 (N ≥ 304).
    ///   NIST's groups use g = 2 while macOS sends g = 5 with the same prime, so this applies by analogy.
    /// 512 bits covers every group up to 4096 bits, and keeps the two modPows of a 4096-bit exchange
    /// fast: their cost is linear in the exponent length, so a full 4096-bit exponent is 8× slower.
    static let maxPrivateKeyLength = 64
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

    /// Number of random bytes the private exponent is drawn from for a `keyLength`-byte prime.
    static func privateKeyLength(forKeyLength keyLength: Int) -> Int {
        min(keyLength, maxPrivateKeyLength)
    }

    /// The private exponent actually used, x = 2 + (r mod (p − 3)), which keeps it in [2, p − 2] for
    /// any random bytes r. For primes longer than 64 bytes r < p − 3, so this is just r + 2. Returned
    /// big-endian on min(k, |r| + 1) bytes: `BigUInt.power` walks every byte it is given, so the
    /// exponent must stay short (never padded to the key length k).
    static func privateExponent(randomBytes: [UInt8], prime: BigUInt) -> [UInt8] {
        let exponent = BigUInt(bigEndian: randomBytes).reduced(modulo: prime.subtracting(BigUInt(3)))
            .adding(BigUInt(2))
        return exponent.bigEndianBytes(count: min(prime.byteWidth, randomBytes.count + 1))
    }

    /// The bytes the client sends: AES ciphertext of the credentials (128) followed by its public key (k).
    static func response(parameters: Parameters, username: String, password: String,
                         privateKey: [UInt8], padding: [UInt8]) throws(RFBError) -> [UInt8] {
        try validate(parameters)
        let keyLength = parameters.keyLength
        let prime = BigUInt(bigEndian: parameters.prime)
        let generator = BigUInt(UInt64(parameters.generator))
        let serverPublic = BigUInt(bigEndian: parameters.serverPublicKey)

        var exponent = privateExponent(randomBytes: privateKey, prime: prime)
        let clientPublic = generator.power(exponent, modulo: prime).bigEndianBytes(count: keyLength)
        var shared = serverPublic.power(exponent, modulo: prime).bigEndianBytes(count: keyLength)
        wipe(&exponent)
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
