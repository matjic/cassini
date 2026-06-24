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

    // MARK: Sleep / extended decoders (spec §3.5 + open_ring supplement)

    @Test func sleepTempSeries() {
        // two u16 LE centi-°C: 0x0CD8=3288→32.88, 0x0CE2=3298→32.98
        let st = try! #require(RingDecoders.sleepTempEvent([0xD8, 0x0C, 0xE2, 0x0C]))
        #expect(st.tempsC.count == 2)
        #expect(abs(st.tempsC[0] - 32.88) < 0.001)
        #expect(abs((st.lastC ?? 0) - 32.98) < 0.001)
        #expect(RingDecoders.sleepTempEvent([0x00]) == nil)   // odd length
    }

    @Test func bedtimeWindow() {
        let b = try! #require(RingDecoders.bedtimePeriod([0x01, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00]))
        #expect(b.startRingTime == 1)
        #expect(b.endRingTime == 255)
        #expect(RingDecoders.bedtimePeriod([0x01, 0x02]) == nil)
    }

    @Test func sleepPeriodInfoScales() {
        // avg_hr 130*0.5=65, breath 64/8=8.0, sleep_state 2, motion 10, cv 0x8000/65536=0.5
        let p: [UInt8] = [130, 0x00, 0x00, 0x00, 64, 64, 10, 2, 0x00, 0x80]
        let sp = try! #require(RingDecoders.sleepPeriodInfo(p))
        #expect(sp.averageHr == 65.0)
        #expect(sp.breath == 8.0)
        #expect(sp.sleepState == 2)
        #expect(sp.motionCount == 10)
        #expect(abs(sp.cv - 0.5) < 0.001)
        #expect(RingDecoders.sleepPeriodInfo([UInt8](repeating: 0, count: 9)) == nil)
    }

    @Test func stateChangeEnum() {
        let s = try! #require(RingDecoders.stateChange([0x06, 0x68, 0x69]))  // 6 + "hi"
        #expect(s.state == 6)
        #expect(s.stateName == "FINGER_HR_USER_IN_REST")
        #expect(s.isAsleep)
        #expect(s.text == "hi")
    }

    @Test func onDemandMeasFields() {
        // 00 80 00 2d 02 00 00 00 → field0=0x008000, f1=0x022d/10=55.7
        let m = try! #require(RingDecoders.onDemandMeas([0x00, 0x80, 0x00, 0x2d, 0x02, 0x00, 0x00, 0x00]))
        #expect(m.field0 == 0x8000)
        #expect(abs((m.f1 ?? 0) - 55.7) < 0.01)
        #expect(m.b1 == 0)
    }

    @Test func featureSessionKind() {
        let f = try! #require(RingDecoders.featureSession([0x0d, 0x01]))
        #expect(f.feature == 0x0d)
        #expect(f.kind == "cva_ppg_sampler_v1")
        #expect(RingDecoders.featureSession([0x02, 0x00])?.kind == "spo2_v1")
    }

    @Test func sleepAcmValues() {
        // first value = whole p[1] + p[0]/255
        let v = try! #require(RingDecoders.sleepACMPeriod([0x80, 0x08, 0x00, 0x00, 0x00, 0x00, 0,0,0,0,0,0]))
        #expect(abs(v.values[0] - (8.0 + 128.0 / 255.0)) < 0.001)
        #expect(v.values.count == 6)
        #expect(RingDecoders.sleepACMPeriod([0,0,0]) == nil)
    }

    /// CVA raw-PPG delta codec: 0x80 marker + 3-byte LE absolute, then signed deltas.
    @Test func cvaPpgDeltaCodec() {
        let dec = CVARawPPGDecoder()
        // absolute 0x000064 = 100, then +1, then -2 (0xFE)
        let out = dec.feed([0x80, 0x64, 0x00, 0x00, 0x01, 0xFE])
        #expect(out == [100, 101, 99])
        #expect(dec.sampleCount == 3)
        // negative absolute via sign-extension: 0xFFFFFF = -1
        let neg = CVARawPPGDecoder().feed([0x80, 0xFF, 0xFF, 0xFF])
        #expect(neg == [-1])
    }
}
