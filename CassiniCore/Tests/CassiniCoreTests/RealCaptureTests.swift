import Testing
import Foundation
@testable import CassiniCore

/// Regression tests built from REAL captured notification values
/// (cassini-20260623-220023.log). Each vector is a full ATT value; ground-truth
/// decoded values are the app's own logged output.
@Suite("RealCapture")
struct RealCaptureTests {

    // MARK: Framing — control frames must parse as OUTER (the 0x09/0x1F bug)

    /// 0x09 time_or_id_resp was being misparsed as an inner record, injecting a
    /// bogus ring_time (33554690) that corrupted the sync cursor. It must be outer.
    @Test func firmwareIdResp_isOuter_notInner() {
        let value: [UInt8] = [0x09, 0x12, 0x02, 0x01, 0x00, 0x02, 0x0c, 0x00, 0x01,
                              0x00, 0x01, 0x05, 0x00, 0x0f, 0x3c, 0xdc, 0x6c, 0xf8, 0x38, 0xa0]
        guard case .outer(let frames) = RingFraming.parse(value) else {
            Issue.record("0x09 should parse as outer"); return
        }
        #expect(frames.first?.opcode == 0x09)
    }

    /// 0x1F state_query_resp likewise — was showing up as a phantom "marker" inner.
    @Test func stateQueryResp_isOuter() {
        let value: [UInt8] = [0x1f, 0x04, 0x20, 0x05, 0x03, 0x00]
        guard case .outer(let frames) = RingFraming.parse(value) else {
            Issue.record("0x1F should parse as outer"); return
        }
        #expect(frames.first?.opcode == 0x1f)
    }

    // MARK: Real inner-record decodes (value → framing → decoder)

    /// Pull the single inner record out of a clean one-record ATT value.
    private func record(_ value: [UInt8]) -> InnerRecord {
        guard case .inner(let recs) = RingFraming.parse(value), let r = recs.first else {
            fatalError("expected one inner record")
        }
        return r
    }

    @Test func realTimeSync() {
        let r = record([0x42, 0x0d, 0xaa, 0x46, 0x00, 0x00, 0x01, 0x24, 0x38, 0x6a,
                        0x00, 0x00, 0x00, 0x00, 0xf6])
        #expect(r.ringTime == 18090)
        let ts = try! #require(RingDecoders.timeSyncInd(r.payload))
        #expect(ts.token == 0x01)
        #expect(ts.timeCounter == 6_961_188)            // 0x6a3824 LE
        #expect(ts.ringUnixSeconds == 1_782_064_128)    // Jun 21 2026 17:48 UTC
        #expect(ts.tickMs == 100.0)
    }

    @Test func realIBIHeartRate() {
        // log: IBI/HR rt=275445 hr=59 ibi=[1087, 878, 1007, 971, 1030, 1041]
        let r = record([0x60, 0x12, 0xf5, 0x33, 0x04, 0x00, 0x87, 0x6d, 0x7d, 0x79,
                        0x80, 0x82, 0x01, 0xd4, 0xdd, 0xf3, 0xf2, 0xd5, 0xfd, 0xc0])
        #expect(r.ringTime == 275445)
        let d = try! #require(RingDecoders.ibiAndAmplitude(r.payload))
        #expect(d.ibiMs == [1087, 878, 1007, 971, 1030, 1041])
        #expect(Int((d.hrBpm ?? 0).rounded()) == 59)
    }

    @Test func realSpO2() {
        // log: SpO2 rt=387678 ~95%
        let r = record([0x8b, 0x11, 0x5e, 0xea, 0x05, 0x00, 0x00, 0x28, 0x5a, 0x61,
                        0x27, 0x66, 0x61, 0x26, 0xd3, 0x61, 0x25, 0x67, 0x68])
        #expect(r.ringTime == 387678)
        let s = try! #require(RingDecoders.spo2RPI(r.payload))
        #expect(s.count == 4)
        #expect(abs(s[0].rValue - 0.6305) < 0.001)        // u16be(0x285a)/16384
        #expect(Int((s.last!.spo2).rounded()) == 95)
    }

    @Test func realTemp() {
        // log: temp rt=18438 [28.31, 29.04, 23.25]°C
        let r = record([0x46, 0x0a, 0x06, 0x48, 0x00, 0x00, 0x0f, 0x0b, 0x58, 0x0b, 0x15, 0x09])
        #expect(r.ringTime == 18438)
        let t = try! #require(RingDecoders.tempEvent(r.payload))
        #expect(t.channelsC == [28.31, 29.04, 23.25])
    }

    @Test func realOnDemandMeas() {
        let r = record([0x62, 0x0c, 0x08, 0x72, 0x00, 0x00, 0x00, 0x80, 0x00, 0x2d,
                        0x02, 0x00, 0x00, 0x00])
        let m = try! #require(RingDecoders.onDemandMeas(r.payload))
        #expect(m.field0 == 0x8000)
        #expect(abs((m.f1 ?? 0) - 55.7) < 0.01)
    }

    @Test func realFeatureSession() {
        // log: feature spo2_v1 status=0
        let r = record([0x6c, 0x08, 0x7f, 0x64, 0x00, 0x00, 0x02, 0x00, 0x05, 0x00])
        let f = try! #require(RingDecoders.featureSession(r.payload))
        #expect(f.feature == 2)
        #expect(f.kind == "spo2_v1")
        #expect(f.status == 0)
    }

    @Test func realSleepACM() {
        // log: sleepACM ... 0.32,0.96,0.41,0.01,0.01,0.00
        let r = record([0x72, 0x10, 0xc5, 0x34, 0x04, 0x00, 0x52, 0x00, 0xf6, 0x00,
                        0x69, 0x00, 0x1d, 0x00, 0x2f, 0x00, 0x06, 0x00])
        let v = try! #require(RingDecoders.sleepACMPeriod(r.payload)).values
        #expect(v.count == 6)
        #expect(abs(v[0] - 82.0 / 255.0) < 0.001)   // 0x52/255
        #expect(abs(v[1] - 246.0 / 255.0) < 0.001)  // 0xf6/255
    }

    // MARK: RingTimeResolver — the recording-time functionality at issue

    /// Real anchor: rt=18090 → unix 1782064128 (Jun 21 17:48 UTC), 100 ms/tick.
    private func anchored() -> RingTimeResolver {
        let r = RingTimeResolver()
        r.observe(18090)
        r.setAnchor(ringTime: 18090, unixSeconds: 1_782_064_128, tickMs: 100)
        return r
    }

    @Test func resolverBasicMath() {
        let r = anchored()
        #expect(abs((r.unixMs(18090) ?? 0) - 1_782_064_128_000) < 1)
        // 100 ticks later @ 100 ms = +10 s
        #expect(abs((r.unixMs(18190) ?? 0) - 1_782_064_138_000) < 1)
    }

    /// Resolving a far-future ring_time must land within the 256 s anchor
    /// granularity of the ACTUAL time-sync recorded at that ring_time — proves the
    /// single-anchor linear model holds across the whole multi-day buffer.
    @Test func resolverLinearAcrossBuffer() {
        let r = anchored()
        let resolved = try! #require(r.unixMs(2_065_153))   // last time-sync in the log
        let actual = 1_782_268_928_000.0                    // its real unix from the capture
        #expect(abs(resolved - actual) < 300_000)           // < 300 s (granularity)
    }

    @Test func resolverUnanchoredReturnsNil() {
        #expect(RingTimeResolver().unixMs(18090) == nil)
    }

    /// A large backward jump in ring_time = ring restart (new epoch); the stale
    /// anchor must be dropped so old-epoch values don't resolve against it.
    @Test func resolverEpochResetOnRollback() {
        let r = RingTimeResolver()
        r.observe(2_000_000)
        r.setAnchor(ringTime: 2_000_000, unixSeconds: 1_782_260_000, tickMs: 100)
        #expect(r.unixMs(2_000_000) != nil)
        r.observe(18090)                 // rolled back > 65536 → new epoch
        #expect(r.unixMs(18090) == nil)  // stale anchor dropped
        // next time-sync re-anchors the new epoch
        r.setAnchor(ringTime: 18090, unixSeconds: 1_782_064_128, tickMs: 100)
        #expect(r.unixMs(18090) == 1_782_064_128_000)
    }

    /// Normal in-epoch jitter (small backward step) must NOT reset the anchor.
    @Test func resolverKeepsAnchorOnSmallJitter() {
        let r = anchored()
        r.observe(18000)   // tiny step back, well under restartBackstep
        #expect(r.unixMs(18090) != nil)
    }
}
