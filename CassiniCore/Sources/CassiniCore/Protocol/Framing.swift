import Foundation

/// An outer control-plane frame: `<opcode:u8> <len:u8> <payload:len>` (spec §3.4).
/// By convention `payload[0]` is the sub-op.
public struct OuterFrame: Equatable, Sendable {
    public let opcode: UInt8
    public let payload: [UInt8]
    public var subOp: UInt8? { payload.first }
    public init(opcode: UInt8, payload: [UInt8]) {
        self.opcode = opcode
        self.payload = payload
    }
}

/// An inner TLV event record: `<type:u8> <len:u8> <ctr:u16 LE> <sess:u16 LE>
/// <payload:(len-4)>` (spec §3.4). `len` counts the 4-byte ctr+sess header.
public struct InnerRecord: Equatable, Sendable {
    public let type: UInt8
    public let counter: UInt16
    public let session: UInt16
    public let payload: [UInt8]

    /// 32-bit monotonic event-sequence cursor (NOT wall-clock): `(sess<<16)|ctr`.
    public var ringTime: UInt32 { (UInt32(session) << 16) | UInt32(counter) }

    /// Structurally complete but semantically suspect (spec §3.4): keep out of the
    /// sync-cursor advance.
    public var isSuspect: Bool { ringTime >= 0x8000_0000 }

    public init(type: UInt8, counter: UInt16, session: UInt16, payload: [UInt8]) {
        self.type = type
        self.counter = counter
        self.session = session
        self.payload = payload
    }
}

/// The two shapes an ATT value can take (spec §3.4).
public enum ParsedValue: Equatable, Sendable {
    case outer([OuterFrame])
    case inner([InnerRecord])
}

public enum RingFraming {
    /// Known outer-frame opcodes (control plane). Used to disambiguate an ATT
    /// value: if the first byte is one of these, parse outer frames; otherwise
    /// parse inner records (spec §3.4 / §3.6).
    public static let outerOpcodes: Set<UInt8> = [
        0x06, 0x07, 0x08, 0x0C, 0x0D, 0x10, 0x11, 0x12, 0x13,
        0x16, 0x17, 0x18, 0x1A, 0x1B, 0x1C, 0x24, 0x25, 0x28, 0x29, 0x2F, 0x33,
    ]

    /// Disambiguate and parse an entire ATT value.
    public static func parse(_ bytes: [UInt8]) -> ParsedValue {
        guard let first = bytes.first else { return .inner([]) }
        return outerOpcodes.contains(first) ? .outer(parseOuter(bytes)) : .inner(parseInner(bytes))
    }

    /// Parse packed outer frames; consume `2 + len` and loop. Stops when the
    /// next byte is not a known opcode or the value is exhausted.
    public static func parseOuter(_ bytes: [UInt8]) -> [OuterFrame] {
        var frames: [OuterFrame] = []
        var i = 0
        while i + 2 <= bytes.count {
            let opcode = bytes[i]
            guard outerOpcodes.contains(opcode) else { break }
            let len = Int(bytes[i + 1])
            let start = i + 2
            guard start + len <= bytes.count else { break } // truncated tail
            frames.append(OuterFrame(opcode: opcode, payload: Array(bytes[start..<start + len])))
            i = start + len
        }
        return frames
    }

    /// Parse concatenated inner TLV records. A record needs `len >= 4`; stop on a
    /// truncated tail.
    public static func parseInner(_ bytes: [UInt8]) -> [InnerRecord] {
        var records: [InnerRecord] = []
        var i = 0
        while i + 2 <= bytes.count {
            let type = bytes[i]
            let len = Int(bytes[i + 1])
            guard len >= 4 else { break }
            let start = i + 2
            guard start + len <= bytes.count else { break } // truncated tail
            let ctr = UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
            let sess = UInt16(bytes[start + 2]) | (UInt16(bytes[start + 3]) << 8)
            let payload = Array(bytes[(start + 4)..<(start + len)])
            records.append(InnerRecord(type: type, counter: ctr, session: sess, payload: payload))
            i = start + len
        }
        return records
    }
}
