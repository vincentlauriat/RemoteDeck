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

    /// Timing of one exponentiation per key size (the client does two per connection); only 1024-bit
    /// is asserted. Measured on an Apple Silicon dev Mac, best of 5 — see the T2.5 report:
    /// release (`swift test -c release -Xswiftc -enable-testing`) ≈ 8.5 ms at 1024 bits; debug ≈ 140 ms.
    /// Gated behind `RFBKIT_PERF=1`: `RFBKIT_PERF=1 swift test --filter modPowTiming`.
    @Test(.enabled(if: perfTestsEnabled, "set RFBKIT_PERF=1 to run timing tests"), arguments: [128, 256])
    func modPowTiming(keyLength: Int) throws {
        let vector = try #require(AuthVectors.appleDH.first { $0.keyLength == keyLength })
        let prime = BigUInt(bigEndian: [UInt8](hex: vector.prime))
        let exponent = [UInt8](hex: vector.privateKey)
        let clock = ContinuousClock()
        var best = Duration.seconds(600)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = BigUInt(2).power(exponent, modulo: prime) }
            best = min(best, elapsed)
        }
        print("modPow \(keyLength * 8)-bit: best of 5 = \(best)")
        if keyLength == 128 {
            #expect(best < .seconds(2))
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
        let shared = try await offCooperativePool {
            BigUInt(bigEndian: [UInt8](hex: vector.serverPublicKey))
                .power([UInt8](hex: vector.privateKey), modulo: BigUInt(bigEndian: [UInt8](hex: vector.prime)))
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
