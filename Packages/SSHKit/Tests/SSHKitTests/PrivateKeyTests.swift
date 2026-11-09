import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSH
import Testing
@testable import SSHKit

@Suite struct PrivateKeyTests {
    @Test func parsesUnencryptedEd25519RSAAndECDSA() throws {
        let ed25519 = try SSHPrivateKey.parse(openSSH: fixture("id_ed25519"), passphrase: nil)
        #expect(ed25519.algorithm == "ssh-ed25519")

        let rsa = try SSHPrivateKey.parse(openSSH: fixture("id_rsa"), passphrase: nil)
        #expect(rsa.algorithm == "ssh-rsa")
        // Signs with RFC 8332 SHA-2 only, never SHA-1 `ssh-rsa`.
        #expect(rsa.signatureAlgorithms == ["rsa-sha2-512", "rsa-sha2-256"])

        let ecdsa = try SSHPrivateKey.parse(openSSH: fixture("id_ecdsa"), passphrase: nil)
        #expect(ecdsa.algorithm == "ecdsa-sha2-nistp256")
    }

    @Test(arguments: ["id_ed25519", "id_rsa", "id_ecdsa"])
    func publicHalfMatchesTheDotPubFile(name: String) throws {
        let key = try SSHPrivateKey.parse(openSSH: fixture(name), passphrase: nil)
        let pub = try SSHHostKey(openSSHPublicKey: fixture(name + ".pub"))
        #expect(key.publicKey == pub)
    }

    @Test(arguments: ["id_ed25519", "id_rsa", "id_ecdsa"])
    func signaturesVerifyWithThePublicKey(name: String) throws {
        let key = try SSHPrivateKey.parse(openSSH: fixture(name), passphrase: nil)
        #expect(key.nioSSHPrivateKeys.count == key.signatureAlgorithms.count)
        let digest = SHA256.hash(data: Data("session identifier".utf8))
        let other = SHA256.hash(data: Data("tampered".utf8))
        for nioKey in key.nioSSHPrivateKeys {
            let signature = try nioKey.sign(digest: digest)
            #expect(nioKey.publicKey.isValidSignature(signature, for: digest))
            #expect(!nioKey.publicKey.isValidSignature(signature, for: other))
        }
    }

    @Test func rsaHostKeyAcceptsSHA2SignaturesOnly() throws {
        let key = try SSHPrivateKey.parse(openSSH: fixture("id_rsa"), passphrase: nil)
        guard case .rsa(let rsa, let body) = key.material else { Issue.record("not RSA"); return }
        let hostKey = SSHRSAHostKey(body: body)
        let data = Data("exchange hash".utf8)

        #expect(hostKey.isValidSignature(RSASHA2Signature<RSASHA512>(rawRepresentation: try RSASHA512.sign(rsa, data)), for: data))
        #expect(hostKey.isValidSignature(RSASHA2Signature<RSASHA256>(rawRepresentation: try RSASHA256.sign(rsa, data)), for: data))
        // A valid SHA-1 PKCS #1 signature by the same key, as an `ssh-rsa` server would send it.
        let sha1 = try rsa.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
        #expect(!hostKey.isValidSignature(SHA1RSASignature(rawRepresentation: sha1), for: data))
        // A SHA-512 signature over other data.
        #expect(!hostKey.isValidSignature(RSASHA2Signature<RSASHA512>(rawRepresentation: try RSASHA512.sign(rsa, Data("other".utf8))), for: data))
    }

    @Test func parsesEncryptedEd25519WithItsPassphrase() throws {
        let key = try SSHPrivateKey.parse(openSSH: fixture("id_ed25519_encrypted"), passphrase: "test-pass")
        #expect(key.algorithm == "ssh-ed25519")
        #expect(key.publicKey == (try SSHHostKey(openSSHPublicKey: fixture("id_ed25519_encrypted.pub"))))
    }

    @Test(arguments: ["id_rsa_encrypted", "id_ecdsa_encrypted"])
    func parsesEncryptedRSAAndECDSAWithTheirPassphrase(name: String) throws {
        let key = try SSHPrivateKey.parse(openSSH: fixture(name), passphrase: "test-pass")
        #expect(key.publicKey == (try SSHHostKey(openSSHPublicKey: fixture(name + ".pub"))))
    }

    @Test func parsesAKeyHardenedWith100BcryptRounds() throws {
        // `ssh-keygen -a 100`: more rounds than Citadel's own reader accepts (it stops at 31).
        let text = try fixture("id_ed25519_100rounds")
        let key = try SSHPrivateKey.parse(openSSH: text, passphrase: "test-pass")
        #expect(key.publicKey == (try SSHHostKey(openSSHPublicKey: fixture("id_ed25519_100rounds.pub"))))
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHPrivateKey.parse(openSSH: text, passphrase: "not-the-pass") }
    }

    @Test func bcryptRoundsAboveTheCapThrowMalformed() throws {
        // The same key with its rounds field rewritten to 1025: refused before the KDF runs.
        let text = try Self.rewritingBcryptRounds(of: fixture("id_ed25519_100rounds"), to: 1025)
        #expect(throws: SSHKeyError.malformed) { try SSHPrivateKey.parse(openSSH: text, passphrase: "test-pass") }
    }

    /// The outer layer only (no bcrypt): the public key and whether a passphrase is needed.
    @Test(arguments: [("id_ed25519", false), ("id_rsa", false), ("id_ecdsa", false),
                      ("id_ed25519_encrypted", true), ("id_rsa_encrypted", true), ("id_ecdsa_encrypted", true)])
    func inspectReadsThePublicKeyWithoutDecrypting(name: String, encrypted: Bool) throws {
        let info = try SSHPrivateKey.inspect(openSSH: fixture(name))
        #expect(info.publicKey == (try SSHHostKey(openSSHPublicKey: fixture(name + ".pub"))))
        #expect(info.isEncrypted == encrypted)
        #expect(info.algorithm == info.publicKey.algorithm)
    }

    @Test func inspectRefusesWhatParseRefuses() {
        #expect(throws: SSHKeyError.malformed) { try SSHPrivateKey.inspect(openSSH: "hello world") }
        #expect(throws: SSHKeyError.unsupportedKeyType("RSA PRIVATE KEY")) {
            try SSHPrivateKey.inspect(openSSH: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n")
        }
    }

    @Test func encryptedKeyWithoutPassphraseThrowsPassphraseRequired() throws {
        let text = try fixture("id_ed25519_encrypted")
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHPrivateKey.parse(openSSH: text, passphrase: nil) }
        #expect(throws: SSHKeyError.passphraseRequired) { try SSHPrivateKey.parse(openSSH: text, passphrase: "") }
    }

    @Test func encryptedKeyWithWrongPassphraseThrowsWrongPassphrase() throws {
        let text = try fixture("id_ed25519_encrypted")
        #expect(throws: SSHKeyError.wrongPassphrase) { try SSHPrivateKey.parse(openSSH: text, passphrase: "not-the-pass") }
    }

    @Test func garbageThrowsMalformed() {
        #expect(throws: SSHKeyError.malformed) { try SSHPrivateKey.parse(openSSH: "", passphrase: nil) }
        #expect(throws: SSHKeyError.malformed) { try SSHPrivateKey.parse(openSSH: "hello world", passphrase: nil) }
        #expect(throws: SSHKeyError.malformed) {
            try SSHPrivateKey.parse(openSSH: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n", passphrase: nil)
        }
    }

    @Test func truncatedKeyThrowsMalformed() throws {
        let lines = try fixture("id_ed25519").split(separator: "\n")
        let truncated = ([lines[0], lines[1]] + [lines.last!]).joined(separator: "\n")
        #expect(throws: SSHKeyError.malformed) { try SSHPrivateKey.parse(openSSH: truncated, passphrase: nil) }
    }

    @Test func otherKeyFormatsAndTypesThrowUnsupportedKeyType() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"
        #expect(throws: SSHKeyError.unsupportedKeyType("RSA PRIVATE KEY")) { try SSHPrivateKey.parse(openSSH: pem, passphrase: nil) }
        #expect(throws: SSHKeyError.unsupportedKeyType("ssh-dss")) {
            try SSHPrivateKey.parse(openSSH: Self.container(publicKeyType: "ssh-dss"), passphrase: nil)
        }
    }

    /// `text` with the bcrypt rounds (the last uint32 of the KDF options) set to `rounds`.
    static func rewritingBcryptRounds(of text: String, to rounds: UInt32) throws -> String {
        let lines = text.split(separator: "\n")
        var bytes = [UInt8](try #require(Data(base64Encoded: lines[1 ..< lines.count - 1].joined())))
        var offset = 15
        func skipString() { offset += 4 + Int(bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }) }
        skipString()  // cipher
        skipString()  // kdf name
        skipString()  // kdf options: string salt, uint32 rounds
        bytes.replaceSubrange(offset - 4 ..< offset, with: withUnsafeBytes(of: rounds.bigEndian, Array.init))
        return "\(lines[0])\n\(Data(bytes).base64EncodedString())\n\(lines[lines.count - 1])\n"
    }

    /// An unencrypted `openssh-key-v1` container whose public key names `publicKeyType` (no key material).
    static func container(publicKeyType: String) -> String {
        func string(_ bytes: [UInt8]) -> [UInt8] { withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init) + bytes }
        var blob = Array("openssh-key-v1\0".utf8)
        blob += string(Array("none".utf8)) + string(Array("none".utf8)) + string([])
        blob += withUnsafeBytes(of: UInt32(1).bigEndian, Array.init)
        blob += string(string(Array(publicKeyType.utf8)))
        blob += string([0, 0, 0, 1, 0, 0, 0, 1] + string(Array(publicKeyType.utf8)))
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(Data(blob).base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}

/// A SHA-1 `ssh-rsa` signature, which SSHKit must never accept.
private struct SHA1RSASignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "ssh-rsa"
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(rawRepresentation) }
    static func read(from buffer: inout ByteBuffer) throws -> Self { Self(rawRepresentation: Data(buffer.readableBytesView)) }
}
