import Foundation

/// Reads the SSH wire encodings of RFC 4251 §5 (`uint32`, `string`, `mpint`) from bytes, never
/// past their end: every read returns nil instead.
struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining == 0 }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, count <= remaining else { return nil }
        defer { offset += count }
        return Array(bytes[offset ..< offset + count])
    }

    mutating func readUInt32() -> UInt32? {
        readBytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    /// An SSH `string`: a `uint32` length, then that many bytes.
    mutating func readString() -> [UInt8]? {
        guard let length = readUInt32(), length <= UInt32(remaining) else { return nil }
        return readBytes(Int(length))
    }

    mutating func readUTF8String() -> String? {
        readString().flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// An SSH `mpint` read as an unsigned big-endian magnitude, without leading zero bytes.
    mutating func readMpint() -> [UInt8]? {
        readString().map(SSHWire.magnitude)
    }

    /// The bytes not read yet.
    mutating func readRest() -> [UInt8] {
        readBytes(remaining) ?? []
    }
}

enum SSHWire {
    static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func string<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        uint32(UInt32(bytes.count)) + bytes
    }

    static func string(_ text: String) -> [UInt8] {
        string(Array(text.utf8))
    }

    /// An unsigned magnitude written as an SSH `mpint`: no leading zeros, plus one zero byte when
    /// the top bit is set so the value stays positive.
    static func mpint<Bytes: Collection>(_ magnitude: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var value = SSHWire.magnitude(Array(magnitude))
        if value == [0] { value = [] }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return string(value)
    }

    /// Drops the leading zero bytes of a big-endian integer, keeping one byte for zero.
    static func magnitude(_ bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.firstIndex(where: { $0 != 0 }) else { return bytes.isEmpty ? [] : [0] }
        return Array(bytes[first...])
    }
}
