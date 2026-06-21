import Testing
@testable import CassiniCore

private func hex(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        bytes.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return bytes
}

@Suite("Decoders")
struct DecoderTests {
    /// Spec §6.4 vector: payload `00051f2c073c410b8a5c127758` → r ≈ [0.080,0.113,0.180,0.289].
    @Test func spo2ReferenceVector() {
        let samples = RingDecoders.spo2RPI(hex("00051f2c073c410b8a5c127758"))
        let r = try! #require(samples).map { $0.rValue }
        let expected = [0.080, 0.113, 0.180, 0.289]
        #expect(r.count == 4)
        for (a, b) in zip(r, expected) {
            #expect(abs(a - b) < 0.001)
        }
    }

    @Test func spo2EmptyAndShort() {
        #expect(RingDecoders.spo2RPI([0x00]) == [])
        #expect(RingDecoders.spo2RPI([]) == nil)
    }

    @Test func ibiRejectsWrongLength() {
        #expect(RingDecoders.ibiAndAmplitude([UInt8](repeating: 0, count: 13)) == nil)
        #expect(RingDecoders.ibiAndAmplitude([UInt8](repeating: 0, count: 14)) != nil)
    }

    /// Six identical-ish IBI bytes should yield an HR in a sane range.
    @Test func ibiHrInRange() {
        // payload[i] high bytes ~100 → ibi ≈ 800ms → ~75 bpm
        var p = [UInt8](repeating: 0, count: 14)
        for i in 0..<6 { p[i] = 100 }      // (100<<3)=800
        let r = try! #require(RingDecoders.ibiAndAmplitude(p))
        let hr = try! #require(r.hrBpm)
        #expect(hr > 60 && hr < 90)
    }

    @Test func greenQualityFlags() {
        // value 800ms (lo=100), clean beat (qB=0): lo=0x64, hi=(800 & 7)=0 → 0x00
        let g = try! #require(RingDecoders.greenIBIQuality([0x64, 0x00, 0x64, 0x00]))
        #expect(g.pairs.count == 2)
        #expect(g.pairs[0].qB == 0)
        #expect(g.hrBpm != nil)
    }

    @Test func hrvSkipsPadding() {
        let h = try! #require(RingDecoders.hrvEvent([60, 40, 0, 0]))
        #expect(h.windows.count == 1)
        #expect(h.windows[0].hrBpm == 60)
        #expect(h.windows[0].rmssdMs == 40)
    }

    @Test func tempAbsentChannelIsNil() {
        // offset 0,2 u16 (2 channels); offset 4 i16 sentinel 0x8000 → nil
        let t = try! #require(RingDecoders.tempEvent([0x10, 0x0E, 0x20, 0x0E, 0x00, 0x80]))
        #expect(t.channelsC.count == 3)
        #expect(t.channelsC[2] == nil)
        let c0 = try! #require(t.channelsC[0])
        #expect(abs(c0 - 36.0) < 0.5)
    }

    @Test func motionMagnitude() {
        let m = try! #require(RingDecoders.motionEvent([0x00, 0x01, 0xFF, 0x02]))
        #expect(m.acmX == 8)
        #expect(m.acmY == -8)  // 0xFF = -1 * 8
        #expect(m.acmZ == 16)
        #expect(m.magnitude == 32)
    }

    @Test func batteryDecode() {
        // raw: 0D len 64 .. .. .. C8 0F  → pct=0x64=100, mv=0x0FC8=4040
        let b = try! #require(RingDecoders.battery(rawValue: [0x0D, 0x08, 0x64, 0x00, 0x00, 0x00, 0xC8, 0x0F]))
        #expect(b.percent == 100)
        #expect(b.voltageMv == 4040)
    }

    @Test func timeSyncAnchor() {
        let ts = try! #require(RingDecoders.timeSyncInd([0x01, 0x10, 0x00, 0x00]))
        #expect(ts.token == 0x01)
        #expect(ts.tickMs == 100.0)
        #expect(ts.ringUnixSeconds == 0x10 * 256)
    }
}
