import CommonCrypto
import Foundation

/// Single-purpose ECB encryption (no padding) through CommonCrypto, for the two legacy RFB schemes.
/// ECB is what the protocols mandate; it is not a design choice of RFBKit.
enum ECBCipher {
    enum Algorithm {
        case des, aes128

        var ccAlgorithm: CCAlgorithm {
            switch self {
            case .des: CCAlgorithm(kCCAlgorithmDES)
            case .aes128: CCAlgorithm(kCCAlgorithmAES)
            }
        }

        var keySize: Int {
            switch self {
            case .des: kCCKeySizeDES
            case .aes128: kCCKeySizeAES128
            }
        }

        var blockSize: Int {
            switch self {
            case .des: kCCBlockSizeDES
            case .aes128: kCCBlockSizeAES128
            }
        }
    }

    /// Encrypts `plaintext`, whose length must be a multiple of the block size.
    static func encrypt(_ algorithm: Algorithm, key: [UInt8], plaintext: [UInt8]) throws(RFBError) -> [UInt8] {
        precondition(key.count == algorithm.keySize, "wrong key size")
        precondition(plaintext.count % algorithm.blockSize == 0, "plaintext not block-aligned")
        var output = [UInt8](repeating: 0, count: plaintext.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), algorithm.ccAlgorithm, CCOptions(kCCOptionECBMode),
                             key, key.count, nil,
                             plaintext, plaintext.count,
                             &output, output.count, &moved)
        guard status == kCCSuccess, moved == plaintext.count else {
            throw .cryptoFailure(status: status)
        }
        return output
    }
}
