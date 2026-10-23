import Foundation

/// Finds the exact bytes of the elements of a top-level array field in a JSON object, without
/// decoding them: the response's content blocks are replayed with their original key order and
/// spelling (`Conversation`). A small scanner: strings (with escapes), nesting, scalars.
enum RawJSON {
    /// The bytes of each element of `object[key]` when it is an array, `nil` otherwise or when the
    /// data is not a well-formed object at that level.
    static func arrayElements(ofKey key: String, in data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var index = 0
        skipSpace(bytes, &index)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index += 1
        while true {
            skipSpace(bytes, &index)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "}") { return nil }
            let keyStart = index
            guard skipString(bytes, &index),
                  let name = try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<index])) else { return nil }
            skipSpace(bytes, &index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipSpace(bytes, &index)
            if name == key {
                guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
                return elements(bytes, &index)
            }
            guard skipValue(bytes, &index) else { return nil }
            skipSpace(bytes, &index)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            return nil
        }
    }

    private static func elements(_ bytes: [UInt8], _ index: inout Int) -> [Data]? {
        index += 1   // [
        var result: [Data] = []
        skipSpace(bytes, &index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { return result }
        while true {
            skipSpace(bytes, &index)
            let start = index
            guard skipValue(bytes, &index) else { return nil }
            result.append(Data(bytes[start..<index]))
            skipSpace(bytes, &index)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { return result }
            return nil
        }
    }

    private static func skipSpace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    /// At an opening quote: moves past the closing one.
    private static func skipString(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return false }
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): index += 1; return true
            default: index += 1
            }
        }
        return false
    }

    private static func skipValue(_ bytes: [UInt8], _ index: inout Int) -> Bool {
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            return skipString(bytes, &index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard skipString(bytes, &index) else { return false }
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { index += 1; return true }
                default:
                    break
                }
                index += 1
            }
            return false
        default:
            // Number, true, false, null: up to the next delimiter.
            let start = index
            while index < bytes.count,
                  ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
            return index > start
        }
    }
}
