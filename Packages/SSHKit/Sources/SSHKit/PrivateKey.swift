@preconcurrency import Citadel
import Crypto
import _CryptoExtras
import Foundation
import NIOSSH

/// Why a private key file could not be read.
public enum SSHKeyError: Error, Equatable, Sendable {
    /// The key is encrypted and no passphrase was given (nil or empty).
    case passphraseRequired
    /// The passphrase does not decrypt the key.
    case wrongPassphrase
    /// A key type, cipher or file format SSHKit does not read, such as `ssh-dss`, a security key
    /// (`sk-…`) or a PEM `RSA PRIVATE KEY` file.
    case unsupportedKeyType(String)
    /// Not a key file, or a damaged one.
    case malformed
}

/// A user's private key, read from an OpenSSH key file (the `openssh-key-v1` format, what
/// `ssh-keygen` writes): ed25519, RSA (signing with RFC 8332 SHA-2 only) and ECDSA P-256, plain or
/// encrypted with a passphrase.
public struct SSHPrivateKey: Sendable {
    enum Material: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case rsa(_RSA.Signing.PrivateKey, RSAPublicBody)
        case ecdsaP256(P256.Signing.PrivateKey)
    }

    let material: Material
    /// The public half, as the key's `.pub` file holds it.
    let publicKey: SSHHostKey

    /// The key type: `ssh-ed25519`, `ssh-rsa` or `ecdsa-sha2-nistp256`.
    public var algorithm: String { publicKey.algorithm }

    /// The signature algorithms the key authenticates with, preferred first.
    var signatureAlgorithms: [String] {
        switch material {
        case .ed25519: ["ssh-ed25519"]
        case .rsa: [RSASHA512.name, RSASHA256.name]
        case .ecdsaP256: ["ecdsa-sha2-nistp256"]
        }
    }

    /// The key as swift-nio-ssh offers it, one per entry of `signatureAlgorithms`, in that order.
    var nioSSHPrivateKeys: [NIOSSHPrivateKey] {
        switch material {
        case .ed25519(let key):
            [NIOSSHPrivateKey(ed25519Key: key)]
        case .rsa(let key, let body):
            [NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA512>(key: key, body: body)),
             NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA256>(key: key, body: body))]
        case .ecdsaP256(let key):
            [NIOSSHPrivateKey(p256Key: key)]
        }
    }

    /// What an OpenSSH private key file holds, read from its outer layer only: never decrypts, so
    /// it is cheap (no bcrypt_pbkdf) and needs no passphrase. For an editor that shows the key type
    /// of a key it imports and knows whether to ask for its passphrase.
    public struct FileInfo: Equatable, Sendable {
        /// The public half.
        public let publicKey: SSHHostKey
        /// The private section is encrypted: `parse` needs a passphrase.
        public let isEncrypted: Bool

        public var algorithm: String { publicKey.algorithm }
    }

    /// Reads the outer layer of an OpenSSH private key file: the same refusals as `parse` before
    /// any decryption (not a key file, a PEM file, an unsupported key type), never
    /// `passphraseRequired` or `wrongPassphrase`.
    public static func inspect(openSSH text: String) throws(SSHKeyError) -> FileInfo {
        let container = try OpenSSHKeyContainer(text: text)
        guard supportedKeyTypes.contains(container.publicKey.algorithm) else {
            throw .unsupportedKeyType(container.publicKey.algorithm)
        }
        return FileInfo(publicKey: container.publicKey,
                        isEncrypted: OpenSSHPrivateSectionDecryption.isEncrypted(cipherName: container.cipher,
                                                                                  kdfName: container.kdf))
    }

    /// Reads an OpenSSH private key file. The container is parsed here; an encrypted private section
    /// is decrypted with Citadel's bcrypt_pbkdf and AES-CTR (`OpenSSHPrivateSectionDecryption`, see
    /// Packages/Vendor/PATCHES.md), and the key material goes to swift-crypto. A wrong passphrase is
    /// told apart from a damaged file by the section's two check integers, as OpenSSH does.
    public static func parse(openSSH text: String, passphrase: String?) throws(SSHKeyError) -> SSHPrivateKey {
        let container = try OpenSSHKeyContainer(text: text)

        // Refuse an unsupported key type before asking for a passphrase it would not need.
        guard supportedKeyTypes.contains(container.publicKey.algorithm) else {
            throw .unsupportedKeyType(container.publicKey.algorithm)
        }

        let encrypted = OpenSSHPrivateSectionDecryption.isEncrypted(cipherName: container.cipher, kdfName: container.kdf)
        let secret: Data?
        if encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
            secret = Data(passphrase.utf8)
        } else {
            secret = nil
        }

        let section: Data
        do {
            section = try OpenSSHPrivateSectionDecryption.decrypt(
                Data(container.privateSection), cipherName: container.cipher, kdfName: container.kdf,
                kdfOptions: Data(container.kdfOptions), passphrase: secret
            )
        } catch {
            switch error {
            case .unsupportedCipher(let name): throw .unsupportedKeyType(name)
            case .unsupportedKDF(let name): throw .unsupportedKeyType(name)
            case .passphraseRequired: throw .passphraseRequired
            case .malformed: throw .malformed
            }
        }

        var reader = SSHWireReader(section)
        guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32() else { throw .malformed }
        guard check1 == check2 else { throw encrypted ? .wrongPassphrase : .malformed }

        guard let type = reader.readUTF8String(), type == container.publicKey.algorithm else { throw .malformed }
        let material = try readMaterial(type: type, from: &reader)
        guard reader.readString() != nil, isValidPadding(reader.readRest()) else {  // comment, padding
            throw .malformed
        }

        let key = SSHPrivateKey(material: material, publicKey: container.publicKey)
        // The private half must belong to the public key the file declares.
        guard key.derivedPublicKey == container.publicKey else { throw .malformed }
        return key
    }

    static let supportedKeyTypes: Set<String> = ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"]

    /// The key-type specific fields of the private section (OpenSSH PROTOCOL.key, `sshkey_private_serialize`).
    private static func readMaterial(type: String, from reader: inout SSHWireReader) throws(SSHKeyError) -> Material {
        switch type {
        case "ssh-ed25519":
            // string public (32), string private (64 = seed 32 + public 32)
            guard let publicBytes = reader.readString(), publicBytes.count == 32,
                  let privateBytes = reader.readString(), privateBytes.count == 64,
                  Array(privateBytes[32...]) == publicBytes,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes[..<32])
            else { throw .malformed }
            return .ed25519(key)

        case "ssh-rsa":
            // mpint n, e, d, iqmp, p, q
            guard let n = reader.readMpint(), let e = reader.readMpint(), let d = reader.readMpint(),
                  reader.readMpint() != nil, let p = reader.readMpint(), let q = reader.readMpint(),
                  let key = try? _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)
            else { throw .malformed }
            return .rsa(key, RSAPublicBody(e: e, n: n))

        case "ecdsa-sha2-nistp256":
            // string curve, string Q, mpint d
            guard reader.readUTF8String() == "nistp256", reader.readString() != nil,
                  var d = reader.readMpint(), d.count <= 32
            else { throw .malformed }
            d = [UInt8](repeating: 0, count: 32 - d.count) + d
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: d) else { throw .malformed }
            return .ecdsaP256(key)

        default:
            throw .unsupportedKeyType(type)
        }
    }

    /// OpenSSH pads the private section with 1, 2, 3, … up to its cipher's block size.
    private static func isValidPadding(_ padding: [UInt8]) -> Bool {
        padding.count < 16 && padding.enumerated().allSatisfy { $0.element == UInt8($0.offset + 1) }
    }

    /// The public key computed from the private material.
    private var derivedPublicKey: SSHHostKey {
        let blob: [UInt8]
        switch material {
        case .ed25519(let key):
            blob = SSHWire.string("ssh-ed25519") + SSHWire.string(Array(key.publicKey.rawRepresentation))
        case .rsa(_, let body):
            blob = SSHWire.string("ssh-rsa") + body.bytes
        case .ecdsaP256(let key):
            blob = SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256")
                + SSHWire.string(Array(key.publicKey.x963Representation))
        }
        return SSHHostKey(algorithm: publicKey.algorithm, blob: Data(blob))
    }
}

/// The outer layer of an `openssh-key-v1` file (OpenSSH PROTOCOL.key): cipher, KDF, the one public
/// key, and the private section, still encrypted when the key has a passphrase.
struct OpenSSHKeyContainer {
    let cipher: String
    let kdf: String
    let kdfOptions: [UInt8]
    let publicKey: SSHHostKey
    let privateSection: [UInt8]

    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    init(text: String) throws(SSHKeyError) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { throw .malformed }
        if first != Self.begin, let label = Self.pemLabel(first) {
            // A PEM file (`RSA PRIVATE KEY`, `EC PRIVATE KEY`, `PRIVATE KEY`, …): not read by SSHKit.
            throw .unsupportedKeyType(label)
        }
        guard first == Self.begin, last == Self.end, lines.count > 2,
              let data = Data(base64Encoded: lines[1 ..< lines.count - 1].joined())
        else { throw .malformed }

        var reader = SSHWireReader(data)
        guard reader.readBytes(15) == Array("openssh-key-v1\0".utf8),
              let cipher = reader.readUTF8String(),
              let kdf = reader.readUTF8String(),
              let kdfOptions = reader.readString(),
              reader.readUInt32() == 1,
              let publicBlob = reader.readString(),
              let privateSection = reader.readString()
        else { throw .malformed }

        var publicReader = SSHWireReader(publicBlob)
        guard let algorithm = publicReader.readUTF8String() else { throw .malformed }

        self.cipher = cipher
        self.kdf = kdf
        self.kdfOptions = kdfOptions
        self.publicKey = SSHHostKey(algorithm: algorithm, blob: Data(publicBlob))
        self.privateSection = privateSection
    }

    /// `X` in `-----BEGIN X-----`.
    private static func pemLabel(_ line: String) -> String? {
        guard line.hasPrefix("-----BEGIN "), line.hasSuffix("-----"), line.count > 16 else { return nil }
        return String(line.dropFirst(11).dropLast(5))
    }
}
