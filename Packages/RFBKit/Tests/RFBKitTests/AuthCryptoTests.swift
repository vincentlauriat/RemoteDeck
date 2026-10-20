import Foundation
import Testing
@testable import RFBKit

/// Crypto building blocks checked against `AuthVectors` (Python `pow`/`hashlib` + OpenSSL CLI,
/// see `Vectors/generate_auth_vectors.py`). DES responses come from
/// `openssl enc -des-ecb -nopad -K <bit-reversed key> -provider legacy -provider default`.
struct VNCAuthTests {
    @Test(arguments: AuthVectors.vnc.map(\.password))
    func desKeyIsTruncatedPaddedAndBitReversed(password: String) throws {
        let vector = try #require(AuthVectors.vnc.first { $0.password == password })
        #expect(VNCAuth.desKey(password: password).hex == vector.key)
    }

    @Test(arguments: AuthVectors.vnc.map(\.password))
    func responseMatchesOpenSSL(password: String) throws {
        let vector = try #require(AuthVectors.vnc.first { $0.password == password })
        let response = try VNCAuth.response(challenge: [UInt8](hex: vector.challenge), password: password)
        #expect(response.hex == vector.response)
    }

    @Test func rejectsWrongChallengeLength() {
        #expect(throws: RFBError.self) { try VNCAuth.response(challenge: [0, 1, 2], password: "x") }
    }

    @Test func reversesBits() {
        #expect(VNCAuth.reverseBits(0b0000_0001) == 0b1000_0000)
        #expect(VNCAuth.reverseBits(0b1100_1010) == 0b0101_0011)
    }
}

struct BigUIntTests {
    @Test func bytesRoundTripWithPadding() {
        let value = BigUInt(bigEndian: [0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        #expect(value.byteWidth == 9)
        #expect(value.bigEndianBytes(count: 12) == [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(BigUInt(bigEndian: []).isZero)
    }

    @Test func comparesAndSubtracts() {
        let a = BigUInt(bigEndian: [UInt8](hex: "010000000000000000"))
        let b = BigUInt(1)
        #expect(b < a)
        #expect(a.subtracting(b) == BigUInt(bigEndian: [UInt8](hex: "ffffffffffffffff")))
    }

    @Test(arguments: AuthVectors.modPow.indices)
    func modPowMatchesPython(index: Int) async throws {
        let vector = AuthVectors.modPow[index]
        let result = try await offCooperativePool {
            BigUInt(bigEndian: [UInt8](hex: vector.base))
                .power([UInt8](hex: vector.exponent), modulo: BigUInt(bigEndian: [UInt8](hex: vector.modulus)))
        }
        #expect(result.bigEndianBytes(count: vector.modulus.count / 2).hex == vector.result)
    }

    @Test func reducesLargerValues() {
        let value = BigUInt(bigEndian: [UInt8](hex: "0123456789abcdef0123456789abcdef"))
        let modulus = BigUInt(bigEndian: [UInt8](hex: "fffffffb"))
        // Python: hex(0x0123456789abcdef0123456789abcdef % 0xfffffffb)
        #expect(value.reduced(modulo: modulus) == BigUInt(bigEndian: [UInt8](hex: "8f5c28da")))
    }

    @Test func addsWithCarry() {
        let value = BigUInt(bigEndian: [UInt8](hex: "ffffffffffffffffff"))
        #expect(value.adding(BigUInt(2)) == BigUInt(bigEndian: [UInt8](hex: "01000000000000000001")))  // Python: hex(0xff…ff + 2)
        #expect(BigUInt(0).adding(BigUInt(0)).isZero)
    }

    /// Timing of the client side of one Apple DH exchange (`AppleDHAuth.response`: two modPows with the
    /// 64-byte private key, plus MD5/AES) per key size, and, for comparison, of one modPow with a
    /// full-length exponent (what the client did before the exponent was capped at 512 bits).
    /// Best of 5 on an Apple Silicon dev Mac (4096-bit fix, 4-bit window modPow):
    /// - release (`swift test -c release -Xswiftc -enable-testing`): 4096-bit exchange ≈ 88 ms
    ///   (one modPow with a full 512-byte exponent: ≈ 0.35 s; ≈ 0.55 s before the window);
    /// - debug: 4096-bit exchange ≈ 1.5 s (full-length exponent: ≈ 5 s per modPow; ≈ 7.9 s before).
    /// Asserted at 4096 bits: < 150 ms in release, < 3 s in debug (the default connect timeout is 10 s).
    /// Gated behind `RFBKIT_PERF=1`: `RFBKIT_PERF=1 swift test --filter modPowTiming`.
    @Test(.enabled(if: perfTestsEnabled, "set RFBKIT_PERF=1 to run timing tests"), arguments: [128, 256, 512])
    func modPowTiming(keyLength: Int) throws {
        let vector = try #require(AuthVectors.appleDH.first { $0.keyLength == keyLength })
        let prime = BigUInt(bigEndian: [UInt8](hex: vector.prime))
        let privateKey = [UInt8](hex: vector.privateKey)
        let padding = [UInt8](hex: vector.padding)
        let fullExponent = [UInt8](repeating: 0xA5, count: keyLength)
        let clock = ContinuousClock()
        var exchange = Duration.seconds(600)
        var fullModPow = Duration.seconds(600)
        for _ in 0..<5 {
            exchange = min(exchange, try clock.measure {
                _ = try AppleDHAuth.response(parameters: vector.parameters, username: vector.username,
                                             password: vector.password, privateKey: privateKey, padding: padding)
            })
        }
        for _ in 0..<(keyLength == 512 ? 2 : 5) {
            fullModPow = min(fullModPow, clock.measure { _ = BigUInt(2).power(fullExponent, modulo: prime) })
        }
        print("Apple DH \(keyLength * 8)-bit: exchange (2 modPows, \(privateKey.count)-byte key) best = \(exchange); "
              + "one modPow with a \(keyLength)-byte exponent best = \(fullModPow)")
        if keyLength == 512 {
            #if DEBUG
            #expect(exchange < .seconds(3))
            #else
            #expect(exchange < .milliseconds(150))
            #endif
        }
    }
}

struct AppleDHAuthTests {
    @Test(arguments: AuthVectors.appleDH)
    func responseMatchesIndependentVectors(vector: AppleDHVector) async throws {
        let response = try await offCooperativePool {
            try AppleDHAuth.response(parameters: vector.parameters,
                                     username: vector.username, password: vector.password,
                                     privateKey: [UInt8](hex: vector.privateKey),
                                     padding: [UInt8](hex: vector.padding))
        }
        #expect(response.count == 128 + vector.keyLength)
        #expect(Array(response.prefix(128)).hex == vector.ciphertext)
        #expect(Array(response.suffix(vector.keyLength)).hex == vector.clientPublicKey)
    }

    @Test(arguments: AuthVectors.appleDH)
    func intermediateValuesMatch(vector: AppleDHVector) async throws {
        let prime = BigUInt(bigEndian: [UInt8](hex: vector.prime))
        #expect([UInt8](hex: vector.privateKey).count == AppleDHAuth.privateKeyLength(forKeyLength: vector.keyLength))
        let exponent = AppleDHAuth.privateExponent(randomBytes: [UInt8](hex: vector.privateKey), prime: prime)
        #expect(exponent.hex == vector.exponent)
        let shared = try await offCooperativePool {
            BigUInt(bigEndian: [UInt8](hex: vector.serverPublicKey))
                .power(exponent, modulo: prime)
                .bigEndianBytes(count: vector.keyLength)
        }
        #expect(shared.hex == vector.sharedSecret)
        let block = try AppleDHAuth.credentialBlock(username: vector.username, password: vector.password,
                                                    padding: [UInt8](hex: vector.padding))
        #expect(block.hex == vector.plaintext)
    }

    @Test func rejectsCredentialsLongerThan63Bytes() {
        let padding = [UInt8](repeating: 0xAA, count: 128)
        #expect(throws: RFBError.credentialTooLong) {
            try AppleDHAuth.credentialBlock(username: String(repeating: "u", count: 64), password: "p", padding: padding)
        }
        #expect(throws: RFBError.credentialTooLong) {
            // 32 × "é" = 64 UTF-8 bytes.
            try AppleDHAuth.credentialBlock(username: "u", password: String(repeating: "é", count: 32), padding: padding)
        }
    }

    @Test func rejectsBadParameters() throws {
        let vector = try #require(AuthVectors.appleDH.first)
        var even = vector.parameters
        even.prime[even.prime.count - 1] &= 0xFE
        #expect(throws: RFBError.self) { try AppleDHAuth.validate(even) }

        var generatorOne = vector.parameters
        generatorOne.generator = 1
        #expect(throws: RFBError.self) { try AppleDHAuth.validate(generatorOne) }

        var publicOne = vector.parameters
        publicOne.serverPublicKey = [UInt8](repeating: 0, count: vector.keyLength - 1) + [1]
        #expect(throws: RFBError.self) { try AppleDHAuth.validate(publicOne) }

        var publicPMinus1 = vector.parameters
        publicPMinus1.serverPublicKey = BigUInt(bigEndian: vector.parameters.prime).subtracting(BigUInt(1))
            .bigEndianBytes(count: vector.keyLength)
        #expect(throws: RFBError.self) { try AppleDHAuth.validate(publicPMinus1) }
    }
}
