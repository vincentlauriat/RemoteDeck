import Foundation
import NIO

// RemoteDeck addition (see Packages/Vendor/PATCHES.md). Citadel decrypts OpenSSH key files only for
// the ed25519 and SHA-1 RSA types it parses itself, and keeps bcrypt_pbkdf and AES-CTR internal.
// This exposes exactly that step, unchanged, so RemoteDeck's SSHKit can read encrypted RSA and ECDSA
// key files without a second implementation of either primitive.

/// Decrypts the private section of an `openssh-key-v1` container with Citadel's own KDF and cipher.
public enum OpenSSHPrivateSectionDecryption {
    public enum Failure: Error, Equatable, Sendable {
        /// The container names a cipher Citadel does not implement (only `none`, `aes128-ctr`, `aes256-ctr`).
        case unsupportedCipher(String)
        /// The container names a KDF Citadel does not implement, or its options are out of range.
        case unsupportedKDF(String)
        /// The KDF needs a passphrase and none was given.
        case passphraseRequired
        /// The section's length or the KDF options are not well formed, or the cipher failed.
        case malformed
    }

    /// Whether the container's cipher and KDF mean the private section is encrypted.
    public static func isEncrypted(cipherName: String, kdfName: String) -> Bool {
        cipherName != "none" || kdfName != "none"
    }

    /// Returns the plaintext private section. With the wrong passphrase this returns garbage; the
    /// caller detects it from the section's two check integers, as OpenSSH does.
    public static func decrypt(
        _ section: Data,
        cipherName: String,
        kdfName: String,
        kdfOptions: Data,
        passphrase: Data?
    ) throws(Failure) -> Data {
        guard let cipher = OpenSSH.Cipher(rawValue: cipherName) else {
            throw .unsupportedCipher(cipherName)
        }

        // Re-encode the two fields so Citadel's own reader validates them. (Not with its
        // `writeSSHString(_: String)`, which moves the writer index past an unreserved buffer.)
        var kdfBuffer = ByteBuffer()
        kdfBuffer.writeInteger(UInt32(kdfName.utf8.count))
        kdfBuffer.writeString(kdfName)
        kdfBuffer.writeInteger(UInt32(kdfOptions.count))
        kdfBuffer.writeBytes(kdfOptions)
        let kdf: OpenSSH.KDF
        do {
            kdf = try OpenSSH.KDF(consuming: &kdfBuffer)
        } catch {
            throw .unsupportedKDF(kdfName)
        }

        if case .bcrypt = kdf, passphrase == nil {
            throw .passphraseRequired
        }
        if case .none = kdf, cipher != .none {
            // A cipher with no key derivation cannot be decrypted.
            throw .unsupportedKDF(kdfName)
        }
        guard section.count % cipher.blockSize == 0 else {
            throw .malformed
        }

        var buffer = ByteBuffer(data: section)
        do {
            try kdf.withKeyAndIV(cipher: cipher, basedOnDecryptionKey: passphrase) { key, iv in
                try cipher.decryptBuffer(&buffer, key: key, iv: iv)
            }
        } catch {
            throw .malformed
        }
        return Data(buffer.readableBytesView)
    }
}
