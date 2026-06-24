import Foundation

/// Little-endian / signed integer helpers used by the decoders (spec §3.9).
/// All take a payload byte array and an offset.
enum ByteMath {
    /// Signed 8-bit: `b - 256 if b >= 128`.
    static func i8(_ b: UInt8) -> Int { b >= 128 ? Int(b) - 256 : Int(b) }

    static func u16le(_ p: [UInt8], _ o: Int) -> Int { Int(p[o]) | (Int(p[o + 1]) << 8) }

    static func i16le(_ p: [UInt8], _ o: Int) -> Int {
        let v = u16le(p, o)
        return v >= 0x8000 ? v - 0x10000 : v
    }

    static func u16be(_ p: [UInt8], _ o: Int) -> Int { (Int(p[o]) << 8) | Int(p[o + 1]) }

    static func u24le(_ p: [UInt8], _ o: Int) -> Int {
        Int(p[o]) | (Int(p[o + 1]) << 8) | (Int(p[o + 2]) << 16)
    }

    static func u32le(_ p: [UInt8], _ o: Int) -> UInt32 {
        UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16) | (UInt32(p[o + 3]) << 24)
    }

    /// Median of a non-empty sorted-on-the-fly Int collection; nil if empty.
    static func median(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? Double(s[n / 2]) : Double(s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
