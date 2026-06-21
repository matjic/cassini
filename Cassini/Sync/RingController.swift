import Foundation
import Observation
import CoreBluetooth
import UIKit
import CassiniCore

/// High-level connection state surfaced to the UI.
enum RingPhase: Equatable {
    case idle
    case bluetoothOff
    case scanning
    case connecting
    case onboarding          // first-time: pairing + SetAuthKey
    case authenticating
    case streaming
    case error(String)
}

/// Live metrics shown on the dashboard tiles.
struct LiveMetrics: Equatable {
    var hrBpm: Double?
    var spo2: Double?
    var batteryPct: Int?
    var batteryMv: Int?
    var temperatureC: Double?
    var acmX: Int?
    var acmY: Int?
    var acmZ: Int?
    var motionMagnitude: Int?
    var lastUpdate: Date?
}

/// Orchestrates the full connect → authenticate → stream flow (spec §3.2/§3.3/
/// §3.7/§3.8). A single consume task reads the BLE notify stream and routes
/// every value; handshake steps register a one-shot frame matcher against that
/// same loop. A second task drives the keep-alive flush loop.
@MainActor
@Observable
final class RingController {
    private let transport = BLETransport()
    private let keyStore = AuthKeyStore()

    // Observed by the UI.
    private(set) var phase: RingPhase = .idle
    private(set) var discovered: [DiscoveredRing] = []
    private(set) var metrics = LiveMetrics()
    /// Translated log — human-readable interpretation per our best understanding.
    private(set) var log: [String] = []
    /// Raw log — every frame as `ms<TAB>RX/TX<TAB>hex`.
    private(set) var rawLog: [String] = []
    /// Model name read from GAP after connecting (e.g. "Oura Ring 4").
    private(set) var connectedRingName: String?
    /// nil until known; true if the GAP name matches the paired model name.
    private(set) var ringIsPaired: Bool?

    // Debug / investigation knobs.
    /// Fire an on-demand HR burst automatically after connecting. The burst is
    /// per-session (param SET values don't persist), so this is a convenience.
    var autoMeasureOnConnect: Bool {
        didSet { UserDefaults.standard.set(autoMeasureOnConnect, forKey: "cassini.autoMeasure") }
    }
    /// Per-frame-type counts (e.g. "i:60" inner type 0x60, "o:2f.28" outer 2F sub-op 0x28).
    private(set) var frameStats: [String: Int] = [:]
    private var logStart: Date?

    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?

    // One-shot frame matcher used by the handshake steps.
    private var pendingMatcher: ((OuterFrame) -> Bool)?
    private var pendingContinuation: CheckedContinuation<OuterFrame, Error>?

    // Persistence keys.
    private let knownRingKey = "cassini.knownRingID"
    private let cursorKey = "cassini.lastRingTime"

    // UTC anchor (spec §3.8).
    private var anchorRingTime: UInt32?
    private var anchorUnixMs: Double?
    private var anchorTickMs: Double = 100.0

    init() {
        autoMeasureOnConnect = UserDefaults.standard.object(forKey: "cassini.autoMeasure") as? Bool ?? true
        transport.onDiscover = { [weak self] ring in
            guard let self else { return }
            if !self.discovered.contains(where: { $0.id == ring.id }) {
                self.discovered.append(ring)
            }
        }
        transport.onDisconnect = { [weak self] in
            self?.handleDisconnect()
        }
        transport.onName = { [weak self] id, name in
            guard let self else { return }
            self.connectedRingName = name
            self.ringIsPaired = name == RingGATT.pairedName
            if let idx = self.discovered.firstIndex(where: { $0.id == id }) {
                let old = self.discovered[idx]
                self.discovered[idx] = DiscoveredRing(id: old.id, name: name, rssi: old.rssi)
            }
            self.addLog("Model: \(name)")
        }
    }

    // MARK: Public entry points

    /// Bring Bluetooth up; auto-reconnect to a known ring or start scanning.
    func start() {
        setupTask = Task { @MainActor in
            do {
                try await transport.waitForPoweredOn()
            } catch {
                phase = .bluetoothOff
                return
            }
            if let id = knownRingID, keyStore.load(ringID: id.uuidString) != nil,
               transport.retrieve(id: id) {
                await connect(id: id, onboarding: false)
            } else {
                beginScan()
            }
        }
    }

    func beginScan() {
        discovered = []
        phase = .scanning
        transport.startScanning()
    }

    /// First-time onboarding for a freshly selected ring (pairs, then SetAuthKey).
    func onboard(_ ring: DiscoveredRing) {
        teardownTasks()
        setupTask = Task { @MainActor in await connect(id: ring.id, onboarding: true) }
    }

    /// Connect to an already-onboarded ring.
    func connect(_ ring: DiscoveredRing) {
        teardownTasks()
        setupTask = Task { @MainActor in await connect(id: ring.id, onboarding: false) }
    }

    /// Decide onboard vs reconnect for a tapped scan result: if we already hold
    /// an auth key for this ring, reconnect with it — don't re-provision.
    func selectRing(_ ring: DiscoveredRing) {
        if keyStore.load(ringID: ring.id.uuidString) != nil {
            connect(ring)
        } else {
            onboard(ring)
        }
    }

    var hasKnownRing: Bool { knownRingID != nil }

    /// Reconnect to the last onboarded ring using the stored key (no pairing,
    /// no re-onboard).
    func reconnectKnown() {
        guard let id = knownRingID else { return }
        teardownTasks()
        setupTask = Task { @MainActor in
            _ = transport.retrieve(id: id)
            await connect(id: id, onboarding: false)
        }
    }

    /// Full factory reset (wipes auth key + onboarding); clears local key too.
    func factoryReset() {
        sendNamed("factory reset", RingCommand.factoryReset)
        addLog("Watch for the blue charger LED to confirm the reset.")
        if let id = knownRingID { keyStore.delete(ringID: id.uuidString) }
        UserDefaults.standard.removeObject(forKey: knownRingKey)
    }

    func stop() {
        teardownTasks()
        transport.disconnect()
        phase = .idle
    }

    // MARK: Connection flow

    private func connect(id: UUID, onboarding: Bool) async {
        do {
            phase = onboarding ? .onboarding : .connecting
            addLog("Connecting to \(id.uuidString)…")
            try await transport.connect(id: id)
            addLog("Encrypted link up.")

            // Start the single consume loop before any handshake writes so the
            // responses are captured by the pending matcher.
            startConsumeLoop()

            if onboarding {
                try await provisionAuthKey(id: id)
            }
            guard let key = keyStore.load(ringID: id.uuidString) else {
                throw BLEError.timeout("auth key (not onboarded)")
            }

            phase = .authenticating
            try await runHandshake(key: key, ringID: id)
            addLog("Authenticated.")

            UserDefaults.standard.set(id.uuidString, forKey: knownRingKey)
            enableFeaturesIfNeeded(id: id)
            runConnectSequence()
            phase = .streaming
            startFlushLoop()
        } catch is CancellationError {
            // expected on teardown
        } catch {
            handleConnectionError(error, id: id)
        }
    }

    /// Map a connect/handshake failure to user-actionable state. The stale-bond
    /// case (CBError 14) can't be cleared programmatically — drop our side and
    /// route the user to Forget + re-onboard.
    private func handleConnectionError(_ error: Error, id: UUID) {
        teardownTasks()
        if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
            // The ring no longer recognizes this Mac's bond. Clear our stored
            // bond + key so we don't auto-retry into the same failure.
            keyStore.delete(ringID: id.uuidString)
            UserDefaults.standard.removeObject(forKey: knownRingKey)
            addLog("Stale pairing. Forget the ring in System Settings → Bluetooth, then re-add it here.")
            phase = .error("Pairing is stale. In System Settings → Bluetooth, Forget this ring, then scan to re-onboard.")
        } else {
            phase = .error(error.localizedDescription)
            addLog("Error: \(error.localizedDescription)")
        }
    }

    /// SetAuthKey onboarding step (spec §3.2): generate, write, persist on success.
    private func provisionAuthKey(id: UUID) async throws {
        let key = AuthCrypto.generateAuthKey()
        addLog("Provisioning new auth key (SetAuthKey)…")
        txRaw(RingCommand.setAuthKey(key))
        // Response: outer frame 0x25, payload[0] = status (0 = success).
        let frame = try await awaitFrame(opcode: 0x25, timeout: 5)
        let status = frame.payload.first ?? 0xFF
        guard status == 0 else { throw BLEError.timeout("SetAuthKey failed (status \(status))") }
        keyStore.save(key, ringID: id.uuidString)
        addLog("Auth key stored in Keychain.")
    }

    /// Per-connection auth handshake (spec §3.3).
    private func runHandshake(key: [UInt8], ringID: UUID) async throws {
        txRaw(RingCommand.getAuthNonce)
        // notify [0x2F, len, 0x2C, nonce:15] → payload = [0x2C, nonce15]
        let nonceFrame = try await awaitFrame(opcode: 0x2F, subOp: 0x2C, timeout: 5)
        let nonce = Array(nonceFrame.payload.dropFirst())
        guard nonce.count == 15, let proof = AuthCrypto.proof(authKey: key, nonce: nonce) else {
            throw BLEError.timeout("valid 15-byte nonce")
        }
        txRaw(RingCommand.authenticate(proof: proof))
        // notify [0x2F, len, 0x2E, status] → payload = [0x2E, status]
        let authFrame = try await awaitFrame(opcode: 0x2F, subOp: 0x2E, timeout: 5)
        let status = AuthStatus(rawValue: authFrame.payload.count > 1 ? authFrame.payload[1] : 0xFF)
        switch status {
        case .success:
            return
        case .inFactoryReset, .notOriginalOnboardedDevice:
            keyStore.delete(ringID: ringID.uuidString)   // stale key (§3.10)
            throw BLEError.timeout("auth (stale key — re-onboard)")
        default:
            throw BLEError.timeout("auth (status \(String(describing: status)))")
        }
    }

    /// One-time, persistent feature enables (SpO2 + activity-HR). They survive
    /// reconnects and are wiped only by factory reset, so we send them once per
    /// ring identity — tracked by UUID, and a re-onboarded (post-reset) ring gets
    /// a new CoreBluetooth UUID, so this naturally re-fires after a reset.
    private func enableFeaturesIfNeeded(id: UUID) {
        let key = "cassini.featuresEnabled.\(id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        txRaw(RingCommand.paramSetByte0(id: RingCommand.paramActivityHR, value: 1))
        txRaw(RingCommand.paramSetByte0(id: RingCommand.paramSpO2, value: 1))
        UserDefaults.standard.set(true, forKey: key)
        addLog("Enabled activity-HR + SpO2 (one-time; persists on the ring).")
    }

    /// The ordered post-auth setup writes (spec §3.7).
    private func runConnectSequence() {
        let w = txRaw
        w([0x08, 0x03, 0x00, 0x00, 0x00])
        w([0x2F, 0x02, 0x01, 0x00])
        w([0x2F, 0x02, 0x01, 0x01])
        w(RingCommand.subscribeEnable)               // 16 01 02

        let counter = UInt32(Date().timeIntervalSince1970) / 256
        w(RingCommand.timeSync(token: 0x01, counter: counter))

        w([0x1C, 0x01, 0xBF])                         // mid poll

        w(RingCommand.categorySubscribe(category: 0x14, flags: 0x0010))
        w(RingCommand.categorySubscribe(category: 0x18, flags: 0x0010))
        w(RingCommand.categorySubscribe(category: 0x28, flags: 0x0009))
        w(RingCommand.categorySubscribe(category: 0x34, flags: 0x0004))
        w(RingCommand.categorySubscribe(category: 0x04, flags: 0x0010))
        w(RingCommand.categorySubscribe(category: 0x08, flags: 0x0010))

        w(RingCommand.battery)                        // 0c 00

        for id: UInt8 in [0x02, 0x04, 0x0B, 0x0D, 0x03, 0x0B, 0x10] {
            w(RingCommand.paramRead(id: id))
        }

        // (SpO2 + activity-HR are enabled once after pair — see enableFeaturesIfNeeded.)

        // DHR (02) defaults ON (b0=1). b0=3 is a TRANSIENT burst trigger that the
        // ring auto-reverts to 1 — so it must be re-fired each session / on demand.
        if autoMeasureOnConnect {
            triggerMeasurement()
        } else {
            addLog("Auto-measure OFF — connect without forcing HR.")
        }

        // Read the feature params back so we can observe their current values.
        readFeatureParams()

        w(RingCommand.dataFlush)
        w(RingCommand.getEvent(ringTime: lastCursor, max: 255))
        addLog("Connect sequence sent; streaming.")
    }

    /// Keep-alive flush loop (spec §3.6/§3.8): drains buffered events and stops
    /// the ~16 s idle disconnect.
    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                txRaw(RingCommand.dataFlush)
                txRaw(RingCommand.getEvent(ringTime: lastCursor, max: 255))
            }
        }
    }

    // MARK: Single consume loop

    private func startConsumeLoop() {
        consumeTask?.cancel()
        consumeTask = Task { @MainActor in
            for await value in transport.notifications {
                if Task.isCancelled { break }
                rawAppend("RX", value)
                let parsed = RingFraming.parse(value)
                updateStats(parsed)
                switch parsed {
                case .outer(let frames):
                    for f in frames {
                        if !tryResolvePending(f) {
                            addLog(describeOuter(f))
                            handleOuter(f)
                        }
                    }
                case .inner(let records):
                    for r in records {
                        addLog(describeInner(r))
                        handleInner(r)
                    }
                }
            }
        }
    }

    private func handleOuter(_ frame: OuterFrame) {
        switch frame.opcode {
        case 0x0D:
            // Reconstruct the raw value for the battery decoder's indexing.
            let raw = [frame.opcode, UInt8(frame.payload.count)] + frame.payload
            if let b = RingDecoders.battery(rawValue: raw) {
                metrics.batteryPct = b.percent
                metrics.batteryMv = b.voltageMv
                touch()
            }
        case 0x33:
            if let a = RingDecoders.acmSample(frame.payload) {
                metrics.acmX = a.x; metrics.acmY = a.y; metrics.acmZ = a.z
                metrics.motionMagnitude = a.magnitude; touch()
            }
        default:
            break   // described in the translated log; metrics handled above
        }
    }

    private func handleInner(_ r: InnerRecord) {
        guard !r.isSuspect else { return }
        switch r.type {
        case EventTag.ibiAndAmplitude.rawValue:
            if let d = RingDecoders.ibiAndAmplitude(r.payload), let hr = d.hrBpm {
                metrics.hrBpm = hr; touch()
            }
        case EventTag.greenIBIQuality.rawValue:
            if let d = RingDecoders.greenIBIQuality(r.payload), let hr = d.hrBpm {
                metrics.hrBpm = hr; touch()
            }
        case EventTag.spo2RPI.rawValue:
            if let s = RingDecoders.spo2RPI(r.payload), let last = s.last {
                metrics.spo2 = last.spo2; touch()
            }
        case EventTag.tempEvent.rawValue:
            if let t = RingDecoders.tempEvent(r.payload),
               let first = t.channelsC.compactMap({ $0 }).first {
                metrics.temperatureC = first; touch()
            }
        case EventTag.motionEvent.rawValue:
            if let m = RingDecoders.motionEvent(r.payload) {
                metrics.acmX = m.acmX; metrics.acmY = m.acmY; metrics.acmZ = m.acmZ
                metrics.motionMagnitude = m.magnitude; touch()
            }
        case EventTag.timeSyncInd.rawValue:
            if let ts = RingDecoders.timeSyncInd(r.payload) {
                anchorRingTime = r.ringTime
                anchorUnixMs = Double(ts.ringUnixSeconds) * 1000.0
                anchorTickMs = ts.tickMs
            }
        case EventTag.ringStartInd.rawValue:
            if let anchor = anchorRingTime, r.ringTime < anchor {
                anchorRingTime = nil; anchorUnixMs = nil   // ring restarted (§3.8)
            }
        default:
            break
        }
        advanceCursor(to: r.ringTime)
    }

    // MARK: One-shot frame matcher (handshake)

    /// Await the next outer frame with the given opcode (and optional sub-op),
    /// racing a timeout. Resolved by the consume loop.
    private func awaitFrame(opcode: UInt8, subOp: UInt8? = nil, timeout: TimeInterval) async throws -> OuterFrame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OuterFrame, Error>) in
            pendingMatcher = { $0.opcode == opcode && (subOp == nil || $0.subOp == subOp) }
            pendingContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard pendingContinuation != nil else { return }
                pendingMatcher = nil
                let c = pendingContinuation
                pendingContinuation = nil
                c?.resume(throwing: BLEError.timeout("frame 0x\(String(opcode, radix: 16))"))
            }
        }
    }

    /// If a frame satisfies the pending matcher, resolve it and return true.
    private func tryResolvePending(_ frame: OuterFrame) -> Bool {
        guard let matcher = pendingMatcher, matcher(frame) else { return false }
        pendingMatcher = nil
        let c = pendingContinuation
        pendingContinuation = nil
        c?.resume(returning: frame)
        return true
    }

    // MARK: Helpers

    private var knownRingID: UUID? {
        UserDefaults.standard.string(forKey: knownRingKey).flatMap(UUID.init)
    }

    private var lastCursor: UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: cursorKey))
    }

    private func advanceCursor(to ringTime: UInt32) {
        if ringTime > lastCursor {
            UserDefaults.standard.set(Int(ringTime), forKey: cursorKey)
        }
    }

    private func handleDisconnect() {
        flushTask?.cancel()
        if case .streaming = phase {
            addLog("Disconnected — will retry.")
            phase = .idle
        }
    }

    private func teardownTasks() {
        flushTask?.cancel(); flushTask = nil
        consumeTask?.cancel(); consumeTask = nil
        setupTask?.cancel(); setupTask = nil
    }

    // MARK: Debug helpers

    /// Fire an on-demand HR measurement: DHR burst (mode 3 / sub 2) + a realtime
    /// measurement request. Per-session — these don't persist across reconnects.
    func triggerMeasurement() {
        triggerDHRBurst()
        triggerRealtimeRaw()
    }

    /// DHR burst only (param 02 mode 3 / sub 2) — tests whether this alone yields
    /// computed 0x60 IBI events (vs the raw PPG stream from realtime).
    func triggerDHRBurst() {
        sendNamed("DHR byte0=3", RingCommand.paramSetByte0(id: RingCommand.paramDHR, value: 3))
        sendNamed("DHR byte2=2", RingCommand.paramSetByte2(id: RingCommand.paramDHR, value: 2))
    }

    /// Raw realtime measurement only (ON_DEMAND) — this is what streams raw PPG (2F 28).
    func triggerRealtimeRaw() {
        sendNamed("realtime raw (ON_DEMAND 120s)",
                  RingCommand.setRealtimeMeasurements(typeMask: RingCommand.maskOnDemand, maxDuration: 120, delay: 0))
    }

    /// Realtime accelerometer measurement (ACM mask). Motion arrives as 0x47
    /// MOTION_EVENT records (x/y/z) — or watch the raw log if it streams over 2F.
    func triggerAccelerometer() {
        sendNamed("realtime ACM (120s)",
                  RingCommand.setRealtimeMeasurements(typeMask: RingCommand.maskACM, maxDuration: 120, delay: 0))
    }

    /// Test what TWO_HERTZ does: ON_DEMAND | TWO_HERTZ — watch raw-log inter-sample timing.
    func triggerOnDemand2Hz() {
        sendNamed("realtime ON_DEMAND+2Hz",
                  RingCommand.setRealtimeMeasurements(typeMask: RingCommand.maskOnDemand | RingCommand.maskTwoHertz,
                                                      maxDuration: 120, delay: 0))
    }

    /// Test what TWO_HERTZ does: ACM | TWO_HERTZ.
    func triggerACM2Hz() {
        sendNamed("realtime ACM+2Hz",
                  RingCommand.setRealtimeMeasurements(typeMask: RingCommand.maskACM | RingCommand.maskTwoHertz,
                                                      maxDuration: 120, delay: 0))
    }

    /// Read the DHR / activity-HR / SpO2 params; responses surface as `2F:` log lines.
    func readFeatureParams() {
        sendNamed("read DHR", RingCommand.paramRead(id: RingCommand.paramDHR))
        sendNamed("read activityHR", RingCommand.paramRead(id: RingCommand.paramActivityHR))
        sendNamed("read SpO2", RingCommand.paramRead(id: RingCommand.paramSpO2))
    }

    /// Write a command and record it in the raw log.
    private func txRaw(_ bytes: [UInt8]) {
        transport.write(bytes)
        rawAppend("TX", bytes)
    }

    private func elapsedMs() -> Int {
        if logStart == nil { logStart = Date() }
        return Int(Date().timeIntervalSince(logStart!) * 1000)
    }

    private func rawAppend(_ dir: String, _ bytes: [UInt8]) {
        rawLog.append("\(Self.pad(elapsedMs(), 7))  \(dir)  \(Self.hex(bytes))")
        if rawLog.count > 1200 { rawLog.removeFirst(rawLog.count - 1200) }
    }

    /// Right-align an integer to a fixed width for monospaced column alignment.
    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func updateStats(_ parsed: ParsedValue) {
        switch parsed {
        case .outer(let frames):
            for f in frames {
                if f.opcode == 0x2F, let s = f.subOp {
                    bump(String(format: "o:2f.%02x", s))
                } else {
                    bump(String(format: "o:%02x", f.opcode))
                }
            }
        case .inner(let records):
            for r in records { bump(String(format: "i:%02x", r.type)) }
        }
    }

    private func bump(_ key: String) { frameStats[key, default: 0] += 1 }

    /// Copy the raw log (`ms<TAB>RX/TX<TAB>hex`) to the clipboard.
    func copyRawLog() { UIPasteboard.general.string = rawLog.joined(separator: "\n") }
    /// Copy the translated log to the clipboard.
    func copyTranslatedLog() { UIPasteboard.general.string = log.joined(separator: "\n") }
    /// Copy the frame-type counts to the clipboard.
    func copyFrameStats() {
        UIPasteboard.general.string = frameStats
            .sorted { $0.key < $1.key }
            .map { "\($0.key)  ×\($0.value)" }
            .joined(separator: "\n")
    }

    /// Clear both logs and the frame-type stats.
    func resetLogsAndStats() {
        rawLog.removeAll(); log.removeAll(); frameStats.removeAll(); logStart = nil
    }

    // MARK: Frame translation (best-understanding decode)

    private func hx(_ b: UInt8) -> String { String(format: "%02x", b) }

    private func describeOuter(_ f: OuterFrame) -> String {
        let p = f.payload
        switch f.opcode {
        case 0x0D:
            let raw = [f.opcode, UInt8(p.count)] + p
            if let b = RingDecoders.battery(rawValue: raw) { return "battery \(b.percent)% \(b.voltageMv)mV" }
            return "battery (short)"
        case 0x11:
            let status = p.first ?? 0
            if status == 0 { return "GetEvent → empty" }
            let rt = p.count >= 6 ? UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24 : 0
            return "GetEvent → data (status \(status), last_rt=\(rt))"
        case 0x29: return "flush ack"
        case 0x07: return "realtime-measure ack (status \(p.count > 1 ? p[1] : (p.first ?? 0)))"
        case 0x17: return "subscribe-enable ack"
        case 0x13: return "time-sync ack"
        case 0x1B: return "factory-reset ack (status \(p.count > 1 ? p[1] : 0))"
        case 0x25: return "SetAuthKey resp (status \(p.first ?? 0))"
        case 0x33:
            if let a = RingDecoders.acmSample(p) {
                return "ACM #\(a.counter) x=\(a.x) y=\(a.y) z=\(a.z) |g|=\(a.magnitude)mg"
            }
            return "ACM (short)"
        case 0x2F: return describe2F(p)
        default: return "outer 0x\(hx(f.opcode)): \(Self.hex(p))"
        }
    }

    private func describe2F(_ p: [UInt8]) -> String {
        guard let sub = p.first else { return "2F (empty)" }
        switch sub {
        case 0x21:
            if p.count >= 6 { return "param 0x\(hx(p[1])) = [\(p[2]) \(p[3]) \(p[4]) \(p[5])]" }
            return "param read: \(Self.hex(p))"
        case 0x23: return "set-ack byte0 param 0x\(p.count > 1 ? hx(p[1]) : "?")"
        case 0x27: return "set-ack byte2 param 0x\(p.count > 1 ? hx(p[1]) : "?")"
        case 0x28: return describePPG(p)
        case 0x02: return "param bulk dump (\(p.count)b)"
        case 0x2C: return "auth nonce"
        case 0x2E: return "auth status \(p.count > 1 ? p[1] : 0)"
        default: return "2F sub 0x\(hx(sub)): \(Self.hex(p))"
        }
    }

    private func describePPG(_ p: [UInt8]) -> String {
        guard p.count >= 8 else { return "PPG (short)" }
        let ch = p[2] == 0x11 ? 2 : 1
        let val = Int(p[6]) | (Int(p[7]) << 8)
        let ctr = p.count >= 13 ? p[12] : 0
        return "PPG ch\(ch) raw=\(val) ctr=\(ctr)"
    }

    private func describeInner(_ r: InnerRecord) -> String {
        func hr(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        switch r.type {
        case EventTag.ibiAndAmplitude.rawValue:
            if let d = RingDecoders.ibiAndAmplitude(r.payload) {
                return "IBI/HR rt=\(r.ringTime) hr=\(hr(d.hrBpm)) ibi=\(d.ibiMs)"
            }
            return "IBI rt=\(r.ringTime) (decode failed)"
        case EventTag.greenIBIQuality.rawValue:
            return "greenIBI rt=\(r.ringTime) hr=\(hr(RingDecoders.greenIBIQuality(r.payload)?.hrBpm))"
        case EventTag.hrvEvent.rawValue:
            let n = RingDecoders.hrvEvent(r.payload)?.windows.count ?? 0
            return "HRV rt=\(r.ringTime) windows=\(n)"
        case EventTag.spo2RPI.rawValue:
            let s = RingDecoders.spo2RPI(r.payload)?.last
            return "SpO2 rt=\(r.ringTime) ~\(s.map { String(format: "%.0f", $0.spo2) } ?? "—")%"
        case EventTag.tempEvent.rawValue:
            let t = RingDecoders.tempEvent(r.payload)?.channelsC.compactMap { $0 } ?? []
            return "temp rt=\(r.ringTime) \(t)°C"
        case EventTag.motionEvent.rawValue:
            return "motion rt=\(r.ringTime) mag=\(RingDecoders.motionEvent(r.payload)?.magnitude ?? 0)"
        case EventTag.timeSyncInd.rawValue: return "time-sync rt=\(r.ringTime)"
        case EventTag.ringStartInd.rawValue: return "ring-start rt=\(r.ringTime)"
        case EventTag.stateChange.rawValue, EventTag.wearEvent.rawValue:
            return "state/wear rt=\(r.ringTime) state=\(r.payload.first ?? 0)"
        case 0x1F: return "marker(0x1f) rt=\(r.ringTime)"
        default: return "inner 0x\(hx(r.type)) rt=\(r.ringTime): \(Self.hex(r.payload))"
        }
    }

    // MARK: Manual command actions (debug Actions panel)

    func requestBattery() { sendNamed("battery", RingCommand.battery) }
    func flushNow() { sendNamed("data_flush", RingCommand.dataFlush) }
    func getEventDrain() { sendNamed("GetEvent drain", RingCommand.getEvent(ringTime: lastCursor, max: 255)) }
    func getEventAck() { sendNamed("GetEvent ack", RingCommand.getEvent(ringTime: lastCursor, max: 0)) }
    func sendSubscribeEnable() { sendNamed("subscribe-enable", RingCommand.subscribeEnable) }
    func sendTimeSync() {
        let counter = UInt32(Date().timeIntervalSince1970) / 256
        sendNamed("time-sync", RingCommand.timeSync(token: 0x01, counter: counter))
    }
    func setSpO2(_ on: Bool) {
        sendNamed("SpO2=\(on ? 1 : 0)", RingCommand.paramSetByte0(id: RingCommand.paramSpO2, value: on ? 1 : 0))
    }
    func setActivityHR(_ on: Bool) {
        sendNamed("activityHR=\(on ? 1 : 0)", RingCommand.paramSetByte0(id: RingCommand.paramActivityHR, value: on ? 1 : 0))
    }
    func setDHR(_ on: Bool) {
        sendNamed("DHR=\(on ? 1 : 0)", RingCommand.paramSetByte0(id: RingCommand.paramDHR, value: on ? 1 : 0))
    }
    /// BLE-bond-only reset (`1A 01 01`) — forces re-pair but KEEPS the auth key.
    func bondOnlyReset() { sendNamed("BLE-bond reset (keeps key)", [0x1A, 0x01, 0x01]) }

    private func sendNamed(_ name: String, _ bytes: [UInt8]) {
        txRaw(bytes)
        addLog("TX \(name): \(Self.hex(bytes))")
    }

    /// Parse a hex string ("0c 00", "0x0c 0x00", or "0c00") and send it raw.
    func sendRawHex(_ string: String) {
        var bytes: [UInt8] = []
        let tokens = string.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
        if tokens.count > 1 {
            for t in tokens {
                let s = t.hasPrefix("0x") ? String(t.dropFirst(2)) : String(t)
                if let b = UInt8(s, radix: 16) { bytes.append(b) }
            }
        } else {
            let s = Array(string.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit })
            var i = 0
            while i + 1 < s.count {
                if let b = UInt8(String(s[i...(i + 1)]), radix: 16) { bytes.append(b) }
                i += 2
            }
        }
        guard !bytes.isEmpty else { addLog("Raw: no valid hex bytes."); return }
        sendNamed("raw", bytes)
    }

    private func touch() { metrics.lastUpdate = Date() }

    private func addLog(_ line: String) {
        log.append("\(Self.pad(elapsedMs(), 7))  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
