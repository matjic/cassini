import Foundation

/// Control-plane command builders (spec §3.6 / §3.7). Each returns the raw
/// bytes to write to the write characteristic. These are functional facts
/// (opcode + byte layout); the names are our own.
public enum RingCommand {
    // MARK: Onboarding / auth (§3.2, §3.3)

    /// `0x24 0x10 <key:16>` — provision a host-generated 16-byte auth key.
    public static func setAuthKey(_ key: [UInt8]) -> [UInt8] {
        precondition(key.count == 16, "auth key must be 16 bytes")
        return [0x24, 0x10] + key
    }

    /// `0x2F 0x01 0x2B` — request a 15-byte auth nonce.
    public static let getAuthNonce: [UInt8] = [0x2F, 0x01, 0x2B]

    /// `0x2F 0x11 0x2D <proof:16>` — answer the auth challenge.
    public static func authenticate(proof: [UInt8]) -> [UInt8] {
        precondition(proof.count == 16, "proof must be 16 bytes")
        return [0x2F, 0x11, 0x2D] + proof
    }

    // MARK: Subscription / streaming (§3.6, §3.7)

    /// `0x16 0x01 0x02` — subscribe-enable; ring acks `0x17 0x01 0x02`.
    public static let subscribeEnable: [UInt8] = [0x16, 0x01, 0x02]

    /// `0x18 0x03 <cat> <flags:u16 LE>` — per-category event subscribe.
    public static func categorySubscribe(category: UInt8, flags: UInt16) -> [UInt8] {
        [0x18, 0x03, category, UInt8(flags & 0xFF), UInt8(flags >> 8)]
    }

    /// `0x28 0x01 0x00` — release flash-buffered events to BLE; precede every GetEvent.
    public static let dataFlush: [UInt8] = [0x28, 0x01, 0x00]

    /// `0x10 0x09 <ring_ts:u32 LE> <max:u8> <flags:u32 LE>` — history / catch-up fetch.
    /// `max = 0` is an ack (advance cursor, no data); `flags` is always `0xFFFFFFFF`.
    public static func getEvent(ringTime: UInt32, max: UInt8, flags: UInt32 = 0xFFFFFFFF) -> [UInt8] {
        [0x10, 0x09] + le32(ringTime) + [max] + le32(flags)
    }

    /// `0x0C 0x00` — battery request; reply `0x0D … <mv:u16 LE>`.
    public static let battery: [UInt8] = [0x0C, 0x00]

    /// `0x12 0x09 <token> <counter:3 LE> 00 00 00 00 0xF6` — time-sync request.
    /// `counter = floor(unix_s / 256)`.
    public static func timeSync(token: UInt8, counter: UInt32) -> [UInt8] {
        let c = le32(counter)
        return [0x12, 0x09, token, c[0], c[1], c[2], 0x00, 0x00, 0x00, 0x00, 0xF6]
    }

    /// `0x06 0x07 <typeMask:u32 LE> <maxDur:u16 LE> <delay:u8>` — on-demand measurement.
    public static func setRealtimeMeasurements(typeMask: UInt32, maxDuration: UInt16, delay: UInt8) -> [UInt8] {
        [0x06, 0x07] + le32(typeMask) + [UInt8(maxDuration & 0xFF), UInt8(maxDuration >> 8), delay]
    }

    // MARK: Parameters (§3.7)

    // Known parameter IDs (§3.7).
    public static let paramDHR: UInt8 = 0x02         // daytime HR
    public static let paramActivityHR: UInt8 = 0x03  // HR during activity
    public static let paramSpO2: UInt8 = 0x04        // SpO2 (sleep-gated)

    /// `0x2F 0x02 0x20 <id>` — read a parameter.
    public static func paramRead(id: UInt8) -> [UInt8] { [0x2F, 0x02, 0x20, id] }
    /// `0x2F 0x03 0x22 <id> <val>` — set parameter byte 0.
    public static func paramSetByte0(id: UInt8, value: UInt8) -> [UInt8] { [0x2F, 0x03, 0x22, id, value] }
    /// `0x2F 0x03 0x26 <id> <val>` — set parameter byte 2.
    public static func paramSetByte2(id: UInt8, value: UInt8) -> [UInt8] { [0x2F, 0x03, 0x26, id, value] }

    // MARK: Reset (§3.6)

    /// `0x1A 0x00` — full factory reset (wipes auth key + onboarding). Blue
    /// charger LED confirms. `0x1A 0x01 0x01` is bond-only and keeps the key.
    public static let factoryReset: [UInt8] = [0x1A, 0x00]

    // MARK: Realtime measurement type-mask bits (§3.6)

    public static let maskOnDemand: UInt32 = 0x200
    public static let maskACM: UInt32 = 0x20
    public static let maskTwoHertz: UInt32 = 0x400

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}

/// Auth handshake status (spec §3.3).
public enum AuthStatus: UInt8, Sendable {
    case success = 0
    case authError = 1
    case inFactoryReset = 2
    case notOriginalOnboardedDevice = 3
}
