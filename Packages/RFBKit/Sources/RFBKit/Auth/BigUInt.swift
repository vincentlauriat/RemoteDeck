import Foundation

/// Minimal unsigned big integer for Apple DH authentication (type 30): byte conversion, comparison,
/// subtraction, reduction and modular exponentiation for odd moduli up to a few thousand bits.
/// It is internal and fixed-purpose, not a general arbitrary-precision library.
///
/// Limbs are 64-bit, least significant first.
///
/// Timing: `power(_:modulo:)` uses Montgomery multiplication with a data-independent sequence of
/// operations — every exponent bit costs one squaring and one multiplication, the result is picked
/// with a mask, and the final Montgomery subtraction is masked too — so its timing does not depend
/// on the exponent's bits (best effort: the compiler is not audited). This matters little here: the
/// exponent is a client-side ephemeral key used once per connection, so a network observer gets a
/// single timing sample. `reduced(modulo:)` and the Montgomery setup are not constant-time; they
/// only handle public values (generator, prime, server public key).
struct BigUInt: Equatable, Sendable, CustomStringConvertible {
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) {
        self.limbs = limbs.isEmpty ? [0] : limbs
        trim()
    }

    init(_ value: UInt64) {
        self.init(limbs: [value])
    }

    /// Big-endian bytes, as RFB sends them. Leading zero bytes are allowed.
    init(bigEndian bytes: some Collection<UInt8>) {
        let count = bytes.count
        var limbs = [UInt64](repeating: 0, count: max(1, (count + 7) / 8))
        for (offset, byte) in bytes.enumerated() {
            let position = count - 1 - offset  // byte position from the least significant end
            limbs[position / 8] |= UInt64(byte) << UInt64((position % 8) * 8)
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes left-padded with zeros to exactly `count` bytes.
    func bigEndianBytes(count: Int) -> [UInt8] {
        precondition(byteWidth <= count, "value does not fit in \(count) bytes")
        var bytes = [UInt8](repeating: 0, count: count)
        for position in 0..<min(count, limbs.count * 8) {
            bytes[count - 1 - position] = UInt8(truncatingIfNeeded: limbs[position / 8] >> UInt64((position % 8) * 8))
        }
        return bytes
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }
    var isOdd: Bool { limbs[0] & 1 == 1 }

    var bitWidth: Int {
        guard let top = limbs.last, top != 0 else { return 0 }
        return (limbs.count - 1) * 64 + (64 - top.leadingZeroBitCount)
    }

    var byteWidth: Int { (bitWidth + 7) / 8 }

    var description: String {
        bigEndianBytes(count: max(1, byteWidth)).map { String(format: "%02x", $0) }.joined()
    }

    private mutating func trim() {
        while limbs.count > 1, limbs.last == 0 { limbs.removeLast() }
    }

    // MARK: Comparison and subtraction

    static func compare(_ lhs: BigUInt, _ rhs: BigUInt) -> Int {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count ? -1 : 1 }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index] ? -1 : 1
        }
        return 0
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool { compare(lhs, rhs) < 0 }
    static func > (lhs: BigUInt, rhs: BigUInt) -> Bool { compare(lhs, rhs) > 0 }

    /// `self - other`; `other` must not be greater than `self`.
    func subtracting(_ other: BigUInt) -> BigUInt {
        precondition(!(self < other), "BigUInt subtraction underflow")
        var result = limbs
        var borrow: UInt64 = 0
        for index in result.indices {
            let rhs = index < other.limbs.count ? other.limbs[index] : 0
            let (partial, overflow1) = result[index].subtractingReportingOverflow(rhs)
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[index] = difference
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        return BigUInt(limbs: result)
    }

    // MARK: Modular arithmetic

    /// `self mod modulus`, by binary long division (shift and subtract). Not constant-time.
    func reduced(modulo modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "modulo zero")
        if self < modulus { return self }
        var remainder = [UInt64](repeating: 0, count: modulus.limbs.count)
        for bit in stride(from: bitWidth - 1, through: 0, by: -1) {
            let incoming = (limbs[bit / 64] >> UInt64(bit % 64)) & 1
            doubleModulo(&remainder, plus: incoming, modulus: modulus.limbs)
        }
        return BigUInt(limbs: remainder)
    }

    /// `self ^ exponent mod modulus` for an odd modulus > 1. `exponent` is big-endian; every one of
    /// its bits is processed (leading zeros included), so the running time depends on its length only.
    func power(_ exponent: [UInt8], modulo modulus: BigUInt) -> BigUInt {
        precondition(modulus.isOdd && modulus > BigUInt(1), "Montgomery needs an odd modulus > 1")
        let context = Montgomery(modulus: modulus.limbs)
        let n = context.count
        let base = reduced(modulo: modulus).limbs

        // One scratch allocation for the whole exponentiation (keeps debug builds fast too):
        // m | R² | base·R | result | candidate | one | t (n + 2 limbs).
        let capacity = 7 * n + 2
        let scratch = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        scratch.initialize(repeating: 0, count: capacity)
        defer {
            // Intermediate powers of the private exponent: wipe before freeing.
            let byteCount = capacity * MemoryLayout<UInt64>.stride
            _ = memset_s(scratch, byteCount, 0, byteCount)
            scratch.deallocate()
        }
        let m = scratch, r2 = scratch + n, baseM = scratch + 2 * n, result = scratch + 3 * n
        let candidate = scratch + 4 * n, one = scratch + 5 * n, t = scratch + 6 * n
        for index in 0..<n {
            m[index] = context.modulus[index]
            r2[index] = context.rSquared[index]
        }
        for (index, limb) in base.enumerated() { candidate[index] = limb }
        one[0] = 1
        let inverse = context.inverse
        Montgomery.multiply(candidate, r2, into: baseM, modulus: m, count: n, inverse: inverse, scratch: t)  // base·R
        Montgomery.multiply(one, r2, into: result, modulus: m, count: n, inverse: inverse, scratch: t)       // 1·R

        for byte in exponent {
            for shift in stride(from: 7, through: 0, by: -1) {
                let bit = UInt64((byte >> UInt8(shift)) & 1)
                Montgomery.multiply(result, result, into: result, modulus: m, count: n, inverse: inverse, scratch: t)
                Montgomery.multiply(result, baseM, into: candidate, modulus: m, count: n, inverse: inverse, scratch: t)
                let mask = 0 &- bit
                for index in 0..<n {
                    result[index] = (candidate[index] & mask) | (result[index] & ~mask)
                }
            }
        }
        Montgomery.multiply(result, one, into: result, modulus: m, count: n, inverse: inverse, scratch: t)  // leave Montgomery form
        return BigUInt(limbs: Array(UnsafeBufferPointer(start: result, count: n)))
    }
}

/// Montgomery arithmetic modulo an odd `m` with R = 2^(64·n) (CIOS method, Koç et al. 1996).
private struct Montgomery {
    let modulus: [UInt64]
    let count: Int
    /// −m⁻¹ mod 2⁶⁴.
    let inverse: UInt64
    /// R² mod m, used to enter Montgomery form.
    let rSquared: [UInt64]

    init(modulus: [UInt64]) {
        self.modulus = modulus
        count = modulus.count
        // Newton iteration for m0⁻¹ mod 2⁶⁴: x = 1 is right mod 2, each step doubles the bits.
        var x: UInt64 = 1
        for _ in 0..<6 { x = x &* (2 &- modulus[0] &* x) }
        inverse = 0 &- x
        // R² mod m: start at 1 (< m, since m > 1) and double 2·64·n times. Depends on m only.
        var value = [UInt64](repeating: 0, count: modulus.count)
        value[0] = 1
        for _ in 0..<(2 * 64 * modulus.count) {
            doubleModulo(&value, plus: 0, modulus: modulus)
        }
        rSquared = value
    }

    /// `output = a · b · R⁻¹ mod m` for `a, b < m` (n limbs each). `output` may alias `a` or `b`:
    /// they are only read before `output` is written. `t` is n + 2 limbs of scratch.
    static func multiply(_ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, into output: UnsafeMutablePointer<UInt64>,
                         modulus m: UnsafePointer<UInt64>, count n: Int, inverse: UInt64,
                         scratch t: UnsafeMutablePointer<UInt64>) {
        t.update(repeating: 0, count: n + 2)
        for i in 0..<n {
            // t += a · b[i]
            let bi = b[i]
            var carry: UInt64 = 0
            for j in 0..<n {
                let (high, low) = a[j].multipliedFullWidth(by: bi)
                let (sum1, overflow1) = low.addingReportingOverflow(t[j])
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            let (top, topOverflow) = t[n].addingReportingOverflow(carry)
            t[n] = top
            t[n + 1] = topOverflow ? 1 : 0
            // t = (t + q · m) / 2⁶⁴, with q chosen so the low limb cancels.
            let q = t[0] &* inverse
            let (high0, low0) = q.multipliedFullWidth(by: m[0])
            let (_, overflow0) = low0.addingReportingOverflow(t[0])
            carry = high0 &+ (overflow0 ? 1 : 0)
            for j in 1..<n {
                let (high, low) = q.multipliedFullWidth(by: m[j])
                let (sum1, overflow1) = low.addingReportingOverflow(t[j])
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                t[j - 1] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            let (last, lastOverflow) = t[n].addingReportingOverflow(carry)
            t[n - 1] = last
            t[n] = t[n + 1] &+ (lastOverflow ? 1 : 0)
        }
        // t < 2m: write t − m to output, then keep it only when t ≥ m (selected with a mask).
        var borrow: UInt64 = 0
        for j in 0..<n {
            let (partial, overflow1) = t[j].subtractingReportingOverflow(m[j])
            let (value, overflow2) = partial.subtractingReportingOverflow(borrow)
            output[j] = value
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        let mask = 0 &- (t[n] | (borrow ^ 1))
        for j in 0..<n {
            output[j] = (output[j] & mask) | (t[j] & ~mask)
        }
    }
}

/// `value = (2 * value + bit) mod modulus`, for `value < modulus` (same limb count).
private func doubleModulo(_ value: inout [UInt64], plus bit: UInt64, modulus: [UInt64]) {
    var carry = bit
    for index in value.indices {
        let next = value[index] >> 63
        value[index] = (value[index] << 1) | carry
        carry = next
    }
    // The doubled value is below 2 * modulus, so one subtraction is enough. With a carry out the
    // true value exceeds 2^(64n) > modulus and the wrapping subtraction lands on the right result.
    if carry == 1 || compareLimbs(value, modulus) >= 0 {
        var borrow: UInt64 = 0
        for index in value.indices {
            let (partial, overflow1) = value[index].subtractingReportingOverflow(modulus[index])
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            value[index] = difference
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
    }
}

private func compareLimbs(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
    for index in stride(from: lhs.count - 1, through: 0, by: -1) where lhs[index] != rhs[index] {
        return lhs[index] < rhs[index] ? -1 : 1
    }
    return 0
}
