import Testing
@testable import CassiniCore

@Suite("Framing")
struct FramingTests {
    /// First byte is a known outer opcode → parse as outer frames.
    @Test func disambiguatesOuter() {
        // 0x0D battery reply (8-byte payload), starts with known outer opcode.
        let bytes: [UInt8] = [0x0D, 0x06, 0x64, 0x00, 0x00, 0x00, 0xC8, 0x0F]
        guard case let .outer(frames) = RingFraming.parse(bytes) else {
            Issue.record("expected outer"); return
        }
        #expect(frames.count == 1)
        #expect(frames[0].opcode == 0x0D)
        #expect(frames[0].payload.count == 6)
    }

    /// Several outer frames packed in one ATT value.
    @Test func packedOuterFrames() {
        // 0x17 01 02  +  0x07 01 00  (two acks)
        let frames = RingFraming.parseOuter([0x17, 0x01, 0x02, 0x07, 0x01, 0x00])
        #expect(frames.count == 2)
        #expect(frames[0].opcode == 0x17)
        #expect(frames[1].opcode == 0x07)
        #expect(frames[1].subOp == 0x00)
    }

    /// Truncated outer tail is dropped, not crashed.
    @Test func truncatedOuterTail() {
        // valid 0x17 01 02, then 0x07 claims len 5 but only 1 byte follows
        let frames = RingFraming.parseOuter([0x17, 0x01, 0x02, 0x07, 0x05, 0x00])
        #expect(frames.count == 1)
    }

    /// First byte not an outer opcode → parse as inner TLV records.
    @Test func disambiguatesInner() {
        // type 0x60, len 0x12 (=18: 4 header + 14 payload), ctr=1, sess=0, 14 payload bytes
        var bytes: [UInt8] = [0x60, 0x12, 0x01, 0x00, 0x00, 0x00]
        bytes += [UInt8](repeating: 0xAA, count: 14)
        guard case let .inner(records) = RingFraming.parse(bytes) else {
            Issue.record("expected inner"); return
        }
        #expect(records.count == 1)
        #expect(records[0].type == 0x60)
        #expect(records[0].counter == 1)
        #expect(records[0].ringTime == 1)
        #expect(records[0].payload.count == 14)
    }

    /// ring_time packs session into the high 16 bits.
    @Test func ringTimeComposition() {
        let r = InnerRecord(type: 0x60, counter: 0x0002, session: 0x0001, payload: [])
        #expect(r.ringTime == 0x0001_0002)
    }

    /// Two inner records concatenated in one value.
    @Test func packedInnerRecords() {
        // 0x47 motion: len 8 (4 hdr + 4 payload) ×2
        let one: [UInt8] = [0x47, 0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03]
        let records = RingFraming.parseInner(one + one)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.type == 0x47 && $0.payload.count == 4 })
    }

    /// A record with len < 4 stops parsing (no room for ctr+sess header).
    @Test func innerRejectsShortLen() {
        #expect(RingFraming.parseInner([0x47, 0x03, 0x00, 0x00, 0x00]).isEmpty)
    }

    /// Suspect records (ring_time >= 2^31) are flagged.
    @Test func suspectFlag() {
        let r = InnerRecord(type: 0x60, counter: 0, session: 0x8000, payload: [])
        #expect(r.isSuspect)
    }
}
