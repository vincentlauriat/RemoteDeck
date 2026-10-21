/// X11 keysyms (X11 `keysymdef.h`), the key values of RFB KeyEvents (RFC 6143 §7.5.4).
public enum Keysym {
    public static let backSpace: UInt32 = 0xFF08
    public static let tab: UInt32 = 0xFF09
    public static let `return`: UInt32 = 0xFF0D
    public static let escape: UInt32 = 0xFF1B
    public static let delete: UInt32 = 0xFFFF
    public static let home: UInt32 = 0xFF50
    public static let left: UInt32 = 0xFF51
    public static let up: UInt32 = 0xFF52
    public static let right: UInt32 = 0xFF53
    public static let down: UInt32 = 0xFF54
    public static let pageUp: UInt32 = 0xFF55
    public static let pageDown: UInt32 = 0xFF56
    public static let end: UInt32 = 0xFF57
    public static let menu: UInt32 = 0xFF67
    public static let help: UInt32 = 0xFF6A
    public static let numLock: UInt32 = 0xFF7F
    public static let space: UInt32 = 0x0020
    public static let hiraganaKatakana: UInt32 = 0xFF27
    public static let eisuToggle: UInt32 = 0xFF30

    public static let kpEnter: UInt32 = 0xFF8D
    public static let kpMultiply: UInt32 = 0xFFAA
    public static let kpAdd: UInt32 = 0xFFAB
    public static let kpSubtract: UInt32 = 0xFFAD
    public static let kpDivide: UInt32 = 0xFFAF
    public static let kpEqual: UInt32 = 0xFFBD
    /// `KP_0` … `KP_9`.
    public static func kp(_ digit: Int) -> UInt32 {
        precondition((0...9).contains(digit), "keypad digit must be 0…9")
        return 0xFFB0 + UInt32(digit)
    }

    /// `F1` … `F35` (`F1` is 0xFFBE).
    public static func f(_ number: Int) -> UInt32 {
        precondition((1...35).contains(number), "function key must be F1…F35")
        return 0xFFBE + UInt32(number - 1)
    }

    public static let shiftL: UInt32 = 0xFFE1
    public static let shiftR: UInt32 = 0xFFE2
    public static let controlL: UInt32 = 0xFFE3
    public static let controlR: UInt32 = 0xFFE4
    public static let capsLock: UInt32 = 0xFFE5
    public static let metaL: UInt32 = 0xFFE7
    public static let metaR: UInt32 = 0xFFE8
    public static let altL: UInt32 = 0xFFE9
    public static let altR: UInt32 = 0xFFEA
    public static let superL: UInt32 = 0xFFEB
    public static let superR: UInt32 = 0xFFEC

    /// The keysym that types `scalar`: Latin-1 printable characters are their own keysym, any other
    /// Unicode character is `0x0100_0000 + code point` (X11 `keysymdef.h`, "Unicode" section). `nil`
    /// for control characters and for the private-use range AppKit uses for function keys
    /// (U+F700…U+F8FF), which never stand for a character.
    public static func forCharacter(_ scalar: Unicode.Scalar) -> UInt32? {
        let value = scalar.value
        switch value {
        case 0x20...0x7E, 0xA0...0xFF: return value
        case 0..<0x20, 0x7F..<0xA0, 0xF700...0xF8FF: return nil
        default: return 0x0100_0000 + value
        }
    }
}
