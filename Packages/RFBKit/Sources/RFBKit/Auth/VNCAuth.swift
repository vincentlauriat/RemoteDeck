import Foundation

/// RFB security type 2, VNC Authentication (RFC 6143 §7.2.2).
///
/// The server sends a 16-byte challenge; the client returns it DES-encrypted (ECB) with the password
/// as the key. The password is truncated or zero-padded to 8 bytes, and — the classic VNC quirk that
/// RFC 6143 leaves out — each key byte is bit-reversed (bit 0 becomes bit 7) before use.
enum VNCAuth {
    static let challengeLength = 16

    static func response(challenge: [UInt8], password: String) throws(RFBError) -> [UInt8] {
        guard challenge.count == challengeLength else {
            throw .protocolViolation("VNC challenge must be \(challengeLength) bytes")
        }
        var key = desKey(password: password)
        defer { wipe(&key) }
        return try ECBCipher.encrypt(.des, key: key, plaintext: challenge)
    }

    /// The 8-byte DES key: UTF-8 password bytes, truncated/zero-padded, each byte bit-reversed.
    static func desKey(password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() {
            key[index] = reverseBits(byte)
        }
        return key
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}
