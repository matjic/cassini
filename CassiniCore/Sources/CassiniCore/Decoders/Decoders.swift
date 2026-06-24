import Foundation

/// Event-type tags (spec §3.5).
public enum EventTag: UInt8, Sendable {
    case ibiAndAmplitude = 0x60
    case greenIBIQuality = 0x80
    case hrvEvent = 0x5D
    case spo2RPI = 0x8B
    case tempEvent = 0x46
    case tempPeriod = 0x69
    case sleepTemp = 0x75
    case sleepPeriodInfo = 0x6A
    case onDemandMeas = 0x62
    case onDemandSession = 0x65
    case onDemandMotion = 0x66
    case featureSession = 0x6C
    case sleepACMPeriod = 0x72
    case activityInfo = 0x50
    case alertEvent = 0x56
    case motionEvent = 0x47
    case motionPeriod = 0x6B
    case rawPPG = 0x68
    case cvaRawPPG = 0x81
    case timeSyncInd = 0x42
    case ringStartInd = 0x41
    case stateChange = 0x45
    case wearEvent = 0x53
    case bedtimePeriod = 0x76
    case debugData = 0x61
    case debugEvent = 0x43
}

// MARK: - 0x60 IBI_AND_AMPLITUDE (spec §3.9)

public struct IBIAndAmplitude: Equatable, Sendable {
    public let ibiMs: [Int]      // 6 inter-beat intervals (ms), 11-bit packed
    public let amplitude: [Int]  // 6 amplitudes
    public let hrBpm: Double?    // median-derived HR
}

// MARK: - 0x8B SPO2_R_PI (spec §3.7 / §3.9)

public struct SpO2Sample: Equatable, Sendable {
    public let rValue: Double  // ratio-of-ratios
    public let irPi: Double    // IR perfusion index, 0..0.05
    public let spo2: Double    // textbook approximation 110 - 25*R
}

// MARK: - 0x80 GREEN_IBI_QUALITY (spec §3.9)

public struct GreenIBIQuality: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public let valueMs: Int // ~IBI ms (11-bit)
        public let qA: Int
        public let qB: Int      // 0 = clean beat; >=3 = noisy/saturated
    }
    public let pairs: [Pair]
    public let hrBpm: Double?
}

// MARK: - 0x5D HRV_EVENT (spec §3.9)

public struct HRVEvent: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let hrBpm: Int
        public let rmssdMs: Int
    }
    public let windows: [Window] // 5-min windows; last = current
}

// MARK: - 0x46 TEMP_EVENT (spec §3.9)

public struct TempEvent: Equatable, Sendable {
    /// Per-channel °C; nil where the channel is absent (i16 sentinel 0x8000).
    public let channelsC: [Double?]
}

// MARK: - 0x47 MOTION_EVENT (spec §3.9)

public struct MotionEvent: Equatable, Sendable {
    public let flagsHigh: Int
    public let flagsLow: Int
    public let acmX: Int
    public let acmY: Int
    public let acmZ: Int
    public var magnitude: Int { abs(acmX) + abs(acmY) + abs(acmZ) }
}

// MARK: - 0x33 realtime accelerometer (RE finding, not in spec)

public struct ACMSample: Equatable, Sendable {
    public let counter: Int
    public let x: Int  // milli-g
    public let y: Int
    public let z: Int
    public var magnitude: Int { Int((Double(x * x + y * y + z * z)).squareRoot()) }
}

// MARK: - 0x69 TEMP_PERIOD (spec §3.5; layout per open_ring)

public struct TempPeriod: Equatable, Sendable {
    public let raw: Int   // i16 LE; physical units TBD
}

// MARK: - 0x75 SLEEP_TEMP_EVENT (spec §3.9; N×u16 LE centi-°C, ~30 s spacing)

public struct SleepTempEvent: Equatable, Sendable {
    public let tempsC: [Double]   // ends at the record's time, ~30 s apart
    public var lastC: Double? { tempsC.last }
}

// MARK: - 0x6B MOTION_PERIOD (spec §3.5; motion-state per open_ring)

public struct MotionPeriod: Equatable, Sendable {
    public let state: Int         // 30 s motion-state enum (payload[0])
}

// MARK: - 0x76 BEDTIME_PERIOD (spec §3.5; 2×u32 LE ring_time, layout per open_ring)

public struct BedtimePeriod: Equatable, Sendable {
    public let startRingTime: UInt32
    public let endRingTime: UInt32
}

// MARK: - 0x6A SLEEP_PERIOD_INFO_2 (open_ring supplement; not in spec §3.5)

/// Per-period sleep summary the ring buffers overnight: sleep-state, average HR,
/// and breath rate. Fixed-point scales are open_ring's RE'd .rodata constants.
public struct SleepPeriodInfo: Equatable, Sendable {
    public let averageHr: Double   // bpm  (wire u8 × 0.5)
    public let hrTrend: Double     // i8 × 0.0625
    public let mzci: Double        // u8 × 0.0625
    public let dzci: Double        // u8 × 0.0625
    public let breath: Double      // breaths/min (u8 / 8)
    public let breathV: Double     // u8 / 8
    public let motionCount: Int
    public let sleepState: Int     // 0/1/2 enum
    public let cv: Double          // u16 LE / 65536 → [0,1)
}

// MARK: - 0x62/0x65/0x66 ON_DEMAND family (ringverse supplement; field layout per
// ringverse parse.js — semantics not assigned upstream either)

public struct OnDemandMeas: Equatable, Sendable {
    public let field0: Int       // u24 LE
    public let f1: Double?       // u16 LE / 10
    public let b1: Int?
    public let f2: Double?       // u8 / 10
    public let b2: Int?
}

public struct OnDemandSession: Equatable, Sendable {
    public let bytes: [UInt8]    // leading config bytes (constant in practice)
    public let word: Int?        // optional trailing u16 LE
}

// MARK: - 0x6C FEATURE_SESSION (ringverse): which feature toggled + its kind

public struct FeatureSession: Equatable, Sendable {
    public let feature: Int
    public let status: Int
    public let kind: String?     // daytime_hr_v1 / spo2_v1 / exercise_hr / …
}

// MARK: - 0x72 SLEEP_ACM_PERIOD (ringverse): 6 accelerometer-intensity values

public struct SleepACMPeriod: Equatable, Sendable {
    public let values: [Double]
}

// MARK: - 0x50 ACTIVITY_INFO (ringverse/open_ring, partial): activity-class enum

public struct ActivityInfo: Equatable, Sendable {
    public let activityClass: Int
}

// MARK: - 0x56 ALERT_EVENT (ringverse): single alert-type byte

public struct AlertEvent: Equatable, Sendable {
    public let alertType: Int
}

// MARK: - 0x45 STATE_CHANGE / 0x53 WEAR_EVENT (spec §3.9)

public struct StateChange: Equatable, Sendable {
    public let state: Int
    public let text: String        // trailing ASCII narration
    /// Wear/HR state-machine names. spec §3.9 lists a partial enum; the full set
    /// is an open_ring supplement.
    public var stateName: String? {
        switch state {
        case 0: return "UNSPECIFIED"
        case 1: return "NOT_IN_FINGER"
        case 2: return "FINGER_DETECTION"          // probing for finger contact
        case 3: return "FINGER_USER_ACTIVE"
        case 4: return "FINGER_USER_IN_REST"
        case 5: return "FINGER_HR_USER_ACTIVE"
        case 6: return "FINGER_HR_USER_IN_REST"    // ≈ asleep
        case 7: return "OUT_OF_POWER"
        case 8: return "CHARGING"
        case 9: return "HIBERNATE_LOW_POWER"
        case 20: return "PRODUCTION_DIAGNOSTIC"
        case 21: return "PRODUCTION_TESTING"
        case 22: return "PRODUCTION_TESTING_CHARGING"
        case 30: return "HW_TEST"
        default: return nil
        }
    }
    public var isAsleep: Bool { state == 6 }
}

// MARK: - 0x41 RING_START_IND (spec §3.9; u32 timestamp + firmware bytes)

public struct RingStartInd: Equatable, Sendable {
    public let timestamp: UInt32
}

// MARK: - 0x42 TIME_SYNC_IND (spec §3.9)

public struct TimeSyncInd: Equatable, Sendable {
    public let token: UInt8
    public let timeCounter: Int
    public var ringUnixSeconds: Int { timeCounter * 256 }
    /// 1 ms/tick when token == 0xFD, else 100 ms/tick (spec §3.8).
    public var tickMs: Double { token == 0xFD ? 1.0 : 100.0 }
}

// MARK: - Battery (outer frame 0x0D, spec §3.9)

public struct BatteryStatus: Equatable, Sendable {
    public let percent: Int
    public let voltageMv: Int
}

/// Stateless decoders. Each takes the inner-record `payload` (bytes after the
/// 4-byte ctr+sess header) unless noted, and returns nil when the payload is
/// structurally invalid.
public enum RingDecoders {

    /// 0x60 — exactly 14 bytes, 6 bit-packed (IBI, amplitude) pairs.
    public static func ibiAndAmplitude(_ p: [UInt8]) -> IBIAndAmplitude? {
        guard p.count == 14 else { return nil }
        let b12 = Int(p[12]); let b13 = Int(p[13])
        let mid = [(b12 >> 5) & 6, (b12 >> 3) & 6, (b12 >> 1) & 6,
                   (b12 << 1) & 6, (b13 >> 5) & 6, (b13 >> 3) & 6]
        var ibi: [Int] = []
        var amp: [Int] = []
        let nibble = b13 & 0x0F
        let shift = nibble == 7 ? 0 : nibble + 1
        for i in 0..<6 {
            ibi.append((Int(p[i]) << 3) | mid[i] | (Int(p[6 + i]) & 1))
            amp.append((Int(p[6 + i]) >> 1) << shift)
        }
        let clean = ibi.filter { $0 > 300 && $0 < 2000 }
        let hr = ByteMath.median(clean).map { 60000.0 / $0 }
        return IBIAndAmplitude(ibiMs: ibi, amplitude: amp, hrBpm: hr)
    }

    /// 0x8B — 1 header byte (0x00) + N=(len-1)/3 samples at 1 Hz.
    public static func spo2RPI(_ p: [UInt8]) -> [SpO2Sample]? {
        guard p.count >= 1 else { return nil }
        let n = (p.count - 1) / 3
        guard n > 0 else { return [] }
        var samples: [SpO2Sample] = []
        for i in 0..<n {
            let off = 1 + 3 * i
            let r = Double(ByteMath.u16be(p, off)) / 16384.0
            let pi = (Double(p[off + 2]) / 255.0) * 0.05
            samples.append(SpO2Sample(rValue: r, irPi: pi, spo2: 110.0 - 25.0 * r))
        }
        return samples
    }

    /// 0x80 — N=len/2 pairs.
    public static func greenIBIQuality(_ p: [UInt8]) -> GreenIBIQuality? {
        guard p.count >= 2 else { return nil }
        let n = p.count / 2
        var pairs: [GreenIBIQuality.Pair] = []
        var clean: [Int] = []
        for i in 0..<n {
            let lo = Int(p[2 * i]); let hi = Int(p[2 * i + 1])
            let value = (lo << 3) | (hi & 0x07)
            let qA = (hi >> 3) & 0x03
            let qB = (hi >> 5) & 0x07
            pairs.append(.init(valueMs: value, qA: qA, qB: qB))
            if qB == 0 && value >= 500 && value <= 1100 { clean.append(value) }
        }
        let hr = ByteMath.median(clean).map { 60000.0 / $0 }
        return GreenIBIQuality(pairs: pairs, hrBpm: hr)
    }

    /// 0x5D — even len [2..12]; pairs {hr, rmssd}, skip hr==0 padding.
    public static func hrvEvent(_ p: [UInt8]) -> HRVEvent? {
        guard p.count >= 2, p.count % 2 == 0 else { return nil }
        var windows: [HRVEvent.Window] = []
        for i in 0..<(p.count / 2) {
            let hr = Int(p[2 * i]); let rmssd = Int(p[2 * i + 1])
            if hr == 0 { continue }
            windows.append(.init(hrBpm: hr, rmssdMs: rmssd))
        }
        return HRVEvent(windows: windows)
    }

    /// 0x46 — even len [4..14]; offsets 0,2 u16; 4,6,8,10,12 i16. °C = int/100.
    public static func tempEvent(_ p: [UInt8]) -> TempEvent? {
        guard p.count >= 4, p.count % 2 == 0 else { return nil }
        var channels: [Double?] = []
        var o = 0
        while o + 2 <= p.count {
            if o <= 2 {
                channels.append(Double(ByteMath.u16le(p, o)) / 100.0)
            } else {
                let raw = ByteMath.i16le(p, o)
                channels.append(raw == -32768 ? nil : Double(raw) / 100.0)
            }
            o += 2
        }
        return TempEvent(channelsC: channels)
    }

    /// 0x47 — len [4..6]; accelerometer x/y/z (scaled by 8).
    public static func motionEvent(_ p: [UInt8]) -> MotionEvent? {
        guard p.count >= 4 else { return nil }
        return MotionEvent(
            flagsHigh: Int(p[0]) >> 5,
            flagsLow: Int(p[0]) & 0x1F,
            acmX: ByteMath.i8(p[1]) * 8,
            acmY: ByteMath.i8(p[2]) * 8,
            acmZ: ByteMath.i8(p[3]) * 8
        )
    }

    /// 0x42 — 9 bytes: token + u24 LE counter; ring_unix_s = counter*256.
    public static func timeSyncInd(_ p: [UInt8]) -> TimeSyncInd? {
        guard p.count >= 4 else { return nil }
        return TimeSyncInd(token: p[0], timeCounter: ByteMath.u24le(p, 1))
    }

    /// 0x33 realtime accelerometer outer-frame payload: `[0x02, counter, x:i16 LE,
    /// y:i16 LE, z:i16 LE]`, axes in milli-g (~1000 = 1 g at rest).
    public static func acmSample(_ p: [UInt8]) -> ACMSample? {
        guard p.count >= 8 else { return nil }
        return ACMSample(counter: Int(p[1]),
                         x: ByteMath.i16le(p, 2),
                         y: ByteMath.i16le(p, 4),
                         z: ByteMath.i16le(p, 6))
    }

    /// 0x69 — 2 bytes: i16 LE temperature (physical units TBD; spec §3.5).
    public static func tempPeriod(_ p: [UInt8]) -> TempPeriod? {
        guard p.count >= 2 else { return nil }
        return TempPeriod(raw: ByteMath.i16le(p, 0))
    }

    /// 0x75 — N×u16 LE centi-°C; samples ~30 s apart ending at the record time.
    public static func sleepTempEvent(_ p: [UInt8]) -> SleepTempEvent? {
        guard p.count >= 2, p.count % 2 == 0 else { return nil }
        var temps: [Double] = []
        var o = 0
        while o + 2 <= p.count { temps.append(Double(ByteMath.u16le(p, o)) / 100.0); o += 2 }
        return SleepTempEvent(tempsC: temps)
    }

    /// 0x6B — motion-state enum at payload[0] (30 s window); spec §3.5.
    public static func motionPeriod(_ p: [UInt8]) -> MotionPeriod? {
        guard let first = p.first else { return nil }
        return MotionPeriod(state: Int(first))
    }

    /// 0x76 — 8 bytes: start/end ring_time (u32 LE each); spec §3.5.
    public static func bedtimePeriod(_ p: [UInt8]) -> BedtimePeriod? {
        guard p.count >= 8 else { return nil }
        return BedtimePeriod(startRingTime: ByteMath.u32le(p, 0), endRingTime: ByteMath.u32le(p, 4))
    }

    /// 0x6A — 10 bytes; sleep-period summary (open_ring supplement). Fixed-point
    /// scales from open_ring's RE'd firmware constants.
    public static func sleepPeriodInfo(_ p: [UInt8]) -> SleepPeriodInfo? {
        guard p.count >= 10 else { return nil }
        return SleepPeriodInfo(
            averageHr: Double(p[0]) * 0.5,
            hrTrend: Double(ByteMath.i8(p[1])) * 0.0625,
            mzci: Double(p[2]) * 0.0625,
            dzci: Double(p[3]) * 0.0625,
            breath: Double(p[4]) / 8.0,
            breathV: Double(p[5]) / 8.0,
            motionCount: Int(p[6]),
            sleepState: ByteMath.i8(p[7]),
            cv: Double(ByteMath.u16le(p, 8)) / 65536.0
        )
    }

    /// 0x62 — on-demand measurement (ringverse layout): progressive fields as the
    /// payload grows. Field names are ringverse's (semantics unconfirmed upstream).
    public static func onDemandMeas(_ p: [UInt8]) -> OnDemandMeas? {
        guard p.count >= 3 else { return nil }
        return OnDemandMeas(
            field0: ByteMath.u24le(p, 0),
            f1: p.count >= 5 ? Double(ByteMath.u16le(p, 3)) / 10 : nil,
            b1: p.count >= 6 ? Int(p[5]) : nil,
            f2: p.count >= 7 ? Double(p[6]) / 10 : nil,
            b2: p.count >= 8 ? Int(p[7]) : nil
        )
    }

    /// 0x65 — on-demand session descriptor (ringverse): leading bytes + optional
    /// trailing u16. Constant in practice (a config record).
    public static func onDemandSession(_ p: [UInt8]) -> OnDemandSession? {
        guard p.count >= 1 else { return nil }
        let lead = Array(p.prefix(7))
        let word = p.count >= 9 ? ByteMath.u16le(p, 7) : nil
        return OnDemandSession(bytes: lead, word: word)
    }

    /// 0x6C — feature lifecycle: `<feature:u8><status:u8>` + kind (ringverse).
    public static func featureSession(_ p: [UInt8]) -> FeatureSession? {
        guard p.count >= 2 else { return nil }
        let feature = Int(p[0])
        let kind: String?
        switch feature {
        case 0, 1: kind = "daytime_hr_v1"
        case 2: kind = "spo2_v1"
        case 3: kind = "exercise_hr"
        case 0x0B: kind = "real_steps_v1"
        case 0x0C: kind = "passthrough"
        case 0x0D: kind = "cva_ppg_sampler_v1"
        default: kind = nil
        }
        return FeatureSession(feature: feature, status: Int(p[1]), kind: kind)
    }

    /// 0x72 — 6 sleep accelerometer-intensity values (ringverse): three `whole +
    /// frac/255`, three `(hi>>4) + 12-bit-frac/4095`.
    public static func sleepACMPeriod(_ p: [UInt8]) -> SleepACMPeriod? {
        guard p.count >= 12 else { return nil }
        func f255(_ whole: Int, _ num: Int) -> Double { Double(whole) + Double(num) / 255.0 }
        func f12(_ lo: Int, _ hi: Int) -> Double { Double(hi >> 4) + Double(lo | ((hi & 0xF) << 8)) / 4095.0 }
        return SleepACMPeriod(values: [
            f255(Int(p[1]), Int(p[0])), f255(Int(p[3]), Int(p[2])), f255(Int(p[5]), Int(p[4])),
            f12(Int(p[6]), Int(p[7])), f12(Int(p[8]), Int(p[9])), f12(Int(p[10]), Int(p[11])),
        ])
    }

    /// 0x50 — activity-class enum at payload[0] (ringverse/open_ring, partial).
    public static func activityInfo(_ p: [UInt8]) -> ActivityInfo? {
        guard let c = p.first else { return nil }
        return ActivityInfo(activityClass: Int(c))
    }

    /// 0x56 — single alert-type byte (ringverse).
    public static func alertEvent(_ p: [UInt8]) -> AlertEvent? {
        guard let a = p.first else { return nil }
        return AlertEvent(alertType: Int(a))
    }

    /// 0x45 / 0x53 — `<state:u8><text:ASCII>` wear & HR state machine (spec §3.9).
    public static func stateChange(_ p: [UInt8]) -> StateChange? {
        guard let state = p.first else { return nil }
        let text = String(decoding: p.dropFirst(), as: UTF8.self)
        return StateChange(state: Int(state), text: text)
    }

    /// 0x41 — u32 LE timestamp + firmware bytes (spec §3.9). Session boundary.
    public static func ringStartInd(_ p: [UInt8]) -> RingStartInd? {
        guard p.count >= 4 else { return nil }
        return RingStartInd(timestamp: ByteMath.u32le(p, 0))
    }

    /// Battery from the full outer-frame ATT value `[0x0D, len, payload…]`
    /// (spec §3.9 indexes the raw value): pct = raw[2], mv = raw[6]|raw[7]<<8.
    public static func battery(rawValue raw: [UInt8]) -> BatteryStatus? {
        guard raw.count >= 8 else { return nil }
        return BatteryStatus(percent: Int(raw[2]), voltageMv: Int(raw[6]) | (Int(raw[7]) << 8))
    }
}

// MARK: - 0x81 CVA_RAW_PPG (spec §3.5; stateful delta codec per open_ring)

/// Stateful decoder for the `0x81` raw-PPG stream (spec §3.5). The wire format
/// is a delta codec: a `0x80` marker introduces a 3-byte LE absolute sample
/// (sign-extended from 24 bits); any other byte is a signed-int8 delta against
/// the running value. State persists across records within a sampler session —
/// `reset()` on a session boundary (new `sess` / counter discontinuity). Held
/// on the main actor by the controller, so not `Sendable`.
public final class CVARawPPGDecoder {
    private var collectingAbsolute = false
    private var subCounter = 0
    private var accumulator: UInt32 = 0
    private var lastValue: Int = 0
    public private(set) var sampleCount = 0

    public init() {}

    public func reset() {
        collectingAbsolute = false; subCounter = 0; accumulator = 0; lastValue = 0
    }

    /// Feed one `0x81` record payload; returns the samples (24-bit signed ADC
    /// counts) emitted by this record.
    public func feed(_ payload: [UInt8]) -> [Int] {
        var out: [Int] = []
        for b in payload {
            if collectingAbsolute {
                if subCounter <= 2 { accumulator |= UInt32(b) << (subCounter * 8); subCounter += 1 }
                if subCounter == 3 {
                    var sample = Int(accumulator)
                    if b & 0x80 != 0 { sample = Int(accumulator | 0xFF00_0000) - 0x1_0000_0000 }
                    lastValue = sample
                    out.append(sample)
                    collectingAbsolute = false
                }
            } else if b == 0x80 {
                accumulator = 0; subCounter = 0; collectingAbsolute = true
            } else {
                lastValue += Int(ByteMath.i8(b))
                out.append(lastValue)
            }
        }
        sampleCount += out.count
        return out
    }
}
