// Added for RemoteDeck (see Packages/Vendor/PATCHES.md). Part of the vendored Citadel, under its
// MIT licence (`LICENSE`).
//
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
        /// The container names a KDF Citadel does not implement (only `none` and `bcrypt`).
        case unsupportedKDF(String)
        /// The KDF needs a passphrase and none was given.
        case passphraseRequired
        /// The section's length or the KDF options are not well formed (bcrypt rounds outside
        /// `bcryptRounds` included), or the cipher failed.
        case malformed
    }

    /// The bcrypt rounds accepted. ssh-keygen writes a default (24 from OpenSSH 10.5's ssh-keygen) and
    /// users raise it with `-a` (64 and 100 are common). The KDF's time grows linearly with the
    /// rounds, so a file asking for more than 1024 is treated as hostile rather than run.
    public static let bcryptRounds: ClosedRange<UInt32> = 1 ... 1024

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

        // The KDF is read here rather than by Citadel's `OpenSSH.KDF(consuming:)`, which refuses
        // bcrypt with 32 rounds or more, although `ssh-keygen -a 64` or `-a 100` keys are common.
        // The rounds are capped at `bcryptRounds` instead, so a hostile file cannot stall the KDF.
        let kdf: OpenSSH.KDF
        switch kdfName {
        case "none":
            guard kdfOptions.isEmpty else { throw .malformed }
            kdf = .none
        case "bcrypt":
            var options = ByteBuffer(data: kdfOptions)
            guard let saltLength: UInt32 = options.readInteger(),
                  let salt = options.readSlice(length: Int(saltLength)),
                  let rounds: UInt32 = options.readInteger(),
                  options.readableBytes == 0,
                  bcryptRounds.contains(rounds)
            else { throw .malformed }
            kdf = .bcrypt(salt: salt, iterations: rounds)
        default:
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
