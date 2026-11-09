import Crypto
import Foundation

/// A server's host key, or any SSH public key, as the SSH wire carries it.
public struct SSHHostKey: Hashable, Sendable {
    /// The key type, such as `ssh-ed25519`, `ssh-rsa` or `ecdsa-sha2-nistp256`.
    public let algorithm: String
    /// The whole public key blob (RFC 4253 §6.6), starting with the key type.
    public let blob: Data

    public init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
    }

    /// Reads one line of an OpenSSH public key file or `known_hosts` key field:
    /// `"<algorithm> <base64 blob> [comment]"`. The blob must name the same key type.
    public init(openSSHPublicKey text: String) throws(SSHKeyError) {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
        guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else {
            throw .malformed
        }
        let algorithm = String(fields[0])
        var reader = SSHWireReader(data)
        guard reader.readUTF8String() == algorithm else {
            throw .malformed
        }
        self.init(algorithm: algorithm, blob: data)
    }

    /// The fingerprint as `ssh-keygen -l` and OpenSSH's prompts show it:
    /// `SHA256:` then the unpadded base64 of the blob's SHA-256.
    public var fingerprintSHA256: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// `"<algorithm> <base64 blob>"`, the form `known_hosts` and `.pub` files use.
    public var openSSHPublicKey: String {
        "\(algorithm) \(blob.base64EncodedString())"
    }
}
