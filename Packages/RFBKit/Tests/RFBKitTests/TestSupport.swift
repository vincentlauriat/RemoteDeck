import Foundation
import Testing
@testable import RFBKit

// Vector shapes filled in by the generated `AuthVectors.swift`.

struct VNCVector: Sendable {
    let password: String
    let key: String
    let challenge: String
    let response: String
}

struct ModPowVector: Sendable {
    let base: String
    let exponent: String
    let modulus: String
    let result: String
}

struct AppleDHVector: Sendable, CustomTestStringConvertible {
    let name: String
    let generator: UInt16
    let prime: String
    let serverPublicKey: String
    let privateKey: String
    let padding: String
    let username: String
    let password: String
    let clientPublicKey: String
    let sharedSecret: String
    let aesKey: String
    let plaintext: String
    let ciphertext: String

    var testDescription: String { name }

    var keyLength: Int { prime.count / 2 }

    var parameters: AppleDHAuth.Parameters {
        AppleDHAuth.Parameters(generator: generator, prime: [UInt8](hex: prime),
                               serverPublicKey: [UInt8](hex: serverPublicKey))
    }

    /// Server message carrying the DH parameters: generator, key length, prime, public key.
    var serverParametersMessage: [UInt8] {
        UInt16(generator).bigEndianBytes + UInt16(keyLength).bigEndianBytes
            + [UInt8](hex: prime) + [UInt8](hex: serverPublicKey)
    }

    /// Expected client answer: ciphertext then client public key.
    var expectedClientResponse: [UInt8] {
        [UInt8](hex: ciphertext) + [UInt8](hex: clientPublicKey)
    }

    var credentials: RFBCredentials { RFBCredentials(username: username, password: password) }

    /// Entropy that replays this vector's private key and padding.
    var entropy: HandshakeEntropy {
        let privateKey = [UInt8](hex: privateKey)
        let padding = [UInt8](hex: padding)
        return HandshakeEntropy(privateKey: { count in
            precondition(count == privateKey.count, "unexpected private key length")
            return privateKey
        }, credentialPadding: { count in
            precondition(count == padding.count, "unexpected padding length")
            return padding
        })
    }
}

extension [UInt8] {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "odd hex length")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(truncatingIfNeeded: self)] }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self)]
    }
}

/// Hand-built RFC 6143 server messages.
enum ServerMessage {
    static func banner(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func string(_ text: String) -> [UInt8] {
        UInt32(text.utf8.count).bigEndianBytes + Array(text.utf8)
    }

    static func securityResult(_ value: UInt32) -> [UInt8] { value.bigEndianBytes }

    static let pixelFormat = PixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
                                         redMax: 255, greenMax: 255, blueMax: 255,
                                         redShift: 16, greenShift: 8, blueShift: 0)

    static func serverInit(width: UInt16 = 1920, height: UInt16 = 1080, name: String = "minim6") -> [UInt8] {
        width.bigEndianBytes + height.bigEndianBytes
            + [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
            + string(name)
    }
}

/// How a recorded server stream is split before being fed to the handshake.
enum Chunking: String, CaseIterable, Sendable {
    case whole, byteByByte, sevenBytes

    func split(_ bytes: [UInt8]) -> [[UInt8]] {
        let size = switch self {
        case .whole: Swift.max(1, bytes.count)
        case .byteByByte: 1
        case .sevenBytes: 7
        }
        return stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<Swift.min($0 + size, bytes.count)]) }
    }
}

struct HandshakeOutcome: Sendable {
    var clientBytes: [UInt8] = []
    var result: HandshakeResult?
    var error: RFBError?
    /// Server bytes not yet fed when the result came out, plus the result's own remainder.
    var streamAfterServerInit: [UInt8] = []
}

/// Feeds a recorded server stream to a handshake and collects what the client sends.
func drive(_ handshake: inout RFBHandshake, server: [UInt8], chunking: Chunking) -> HandshakeOutcome {
    var outcome = HandshakeOutcome()
    for chunk in chunking.split(server) {
        if outcome.result != nil {
            outcome.streamAfterServerInit += chunk
            continue
        }
        do {
            let step = try handshake.receive(chunk)
            outcome.clientBytes += step.outgoing
            if let result = step.result {
                outcome.result = result
                outcome.streamAfterServerInit = Array(result.remainder)
            }
        } catch {
            outcome.error = error
            break
        }
    }
    return outcome
}

/// Runs CPU-heavy work (big modPows) on a GCD thread instead of Swift's cooperative pool, so it
/// cannot starve the loopback tests whose Network callbacks need pool threads to resume.
func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Timing tests run only with `RFBKIT_PERF=1` (they are CPU-heavy and wall-clock sensitive).
let perfTestsEnabled = ProcessInfo.processInfo.environment["RFBKIT_PERF"] == "1"
