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

    /// Battery from the full outer-frame ATT value `[0x0D, len, payload…]`
    /// (spec §3.9 indexes the raw value): pct = raw[2], mv = raw[6]|raw[7]<<8.
    public static func battery(rawValue raw: [UInt8]) -> BatteryStatus? {
        guard raw.count >= 8 else { return nil }
        return BatteryStatus(percent: Int(raw[2]), voltageMv: Int(raw[6]) | (Int(raw[7]) << 8))
    }
}
