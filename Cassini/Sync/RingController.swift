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
    // Sleep / autonomic (mostly from the overnight buffer drain).
    var hrvRmssd: Int?
    var breathRate: Double?
    var sleepState: Int?
    var sleepTempC: Double?
    var wearStateName: String?
    var bedtimeStart: UInt32?
    var bedtimeEnd: UInt32?
    var ppgSampleCount: Int?
    var lastUpdate: Date?
    // Per-tile "time reported" — the event's wall-clock time (from the ring_time
    // anchor when available, else arrival time).
    var hrAt: Date?
    var hrvAt: Date?
    var breathAt: Date?
    var spo2At: Date?
    var tempAt: Date?
    var batteryAt: Date?
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
    /// Persisted sync cursor (highest drained `ring_time`), surfaced for the UI.
    private(set) var cursor: UInt32 = 0
    /// Human-readable result of the last GetEvent (e.g. "data → last_rt=…", "empty").
    private(set) var lastDrainInfo = "—"
    /// Whether the most recent GetEvent delivered data — drives adaptive drain speed.
    private var lastDrainHadData = false

    // Live feature state read back from the ring (nil = not yet known). These drive
    // the Feature toggles so they reflect the ring, not just what we last sent.
    private(set) var featureDHR: Bool?
    private(set) var featureActivityHR: Bool?
    private(set) var featureSpO2: Bool?
    /// Translated log — human-readable interpretation per our best understanding.
    private(set) var log: [String] = []
    /// Raw log — every frame as `ms<TAB>RX/TX<TAB>hex`.
    private(set) var rawLog: [String] = []
    /// Absolute path of the current session's on-disk log file (full, uncapped).
    private(set) var logFilePath: String?
    private var logFileHandle: FileHandle?
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
    /// Reset the sync cursor to 0 on every connect so the full buffer always drains.
    /// `ring_time` is per-session and rolls back when the ring reboots, which leaves
    /// a persisted high cursor stale (GetEvent returns empty) — draining from 0
    /// avoids that. Off = incremental sync from the saved cursor (spec.md §3.8).
    var drainFromStartOnConnect: Bool {
        didSet { UserDefaults.standard.set(drainFromStartOnConnect, forKey: "cassini.drainFromStart") }
    }
    /// Per-frame-type counts (e.g. "i:60" inner type 0x60, "o:2f.28" outer 2F sub-op 0x28).
    private(set) var frameStats: [String: Int] = [:]
    private var logStart: Date?

    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?

    /// When set, the flush loop periodically re-arms the DHR burst (mode 3/sub 2),
    /// which the ring auto-reverts ~20 s after each trigger. Keeping it armed is
    /// what makes the ring keep computing + streaming live 0x60 IBI (HR) events.
    private var keepHRAlive = false
    private var flushTick = 0

    // One-shot frame matcher used by the handshake steps.
    private var pendingMatcher: ((OuterFrame) -> Bool)?
    private var pendingContinuation: CheckedContinuation<OuterFrame, Error>?

    // Persistence keys.
    private let knownRingKey = "cassini.knownRingID"
    private let cursorKey = "cassini.lastRingTime"

    /// Stateful raw-PPG (0x81) decoder; reset on session boundary.
    private let ppgDecoder = CVARawPPGDecoder()

    // UTC anchor (spec §3.8).
    private var anchorRingTime: UInt32?
    private var anchorUnixMs: Double?
    private var anchorTickMs: Double = 100.0

    init() {
        autoMeasureOnConnect = UserDefaults.standard.object(forKey: "cassini.autoMeasure") as? Bool ?? true
        drainFromStartOnConnect = UserDefaults.standard.object(forKey: "cassini.drainFromStart") as? Bool ?? true
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
            logStart = nil          // reset the elapsed-time origin for this run
            startLogFile()          // one fresh timestamped file per connection
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
        // ring_time is per-session and rolls back on ring reboot, so a persisted
        // high cursor goes stale (GetEvent returns empty → no readings). Default to
        // draining from 0 each connect so data always flows.
        if drainFromStartOnConnect { setCursor(0) }
        cursor = lastCursor   // surface the (possibly reset) per-ring cursor
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
                // Issue a flush + GetEvent from the current cursor, then wait a
                // short beat for the 0x11 response + records to land.
                lastDrainHadData = false
                txRaw(RingCommand.dataFlush)
                txRaw(RingCommand.getEvent(ringTime: lastCursor, max: 255))
                flushTick += 1
                // Re-arm the DHR burst every ~12 s of idle cycles — it auto-reverts
                // ~20 s after each trigger, and a dropped burst stalls live HR (0x60).
                if keepHRAlive && flushTick % 3 == 0 {
                    txRaw(RingCommand.paramSetByte0(id: RingCommand.paramDHR, value: 3))
                    txRaw(RingCommand.paramSetByte2(id: RingCommand.paramDHR, value: 2))
                }
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { break }
                // Adaptive cadence: if that GetEvent delivered data there's more in
                // the buffer — drain again immediately. Otherwise idle at ~4 s to
                // keep the link alive (spec.md §3.6/§3.8).
                if lastDrainHadData {
                    flushTick -= 1   // don't let fast drains spam the DHR re-arm
                } else {
                    try? await Task.sleep(for: .seconds(3))
                }
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
                metrics.batteryAt = Date()
                touch()
            }
        case 0x33:
            if let a = RingDecoders.acmSample(frame.payload) {
                metrics.acmX = a.x; metrics.acmY = a.y; metrics.acmZ = a.z
                metrics.motionMagnitude = a.magnitude; touch()
            }
        case 0x11:
            // GetEvent response (spec.md §3.8): payload[0]=status (0=empty, 0xFF=data).
            let status = frame.payload.first ?? 0
            lastDrainHadData = status != 0
            if status == 0 {
                lastDrainInfo = "empty (cursor \(cursor))"
            } else {
                let p = frame.payload
                let rt = p.count >= 6
                    ? UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24
                    : 0
                lastDrainInfo = "data → last_rt=\(rt)"
            }
        case 0x2F:
            // Secure-session param get/set replies drive the feature toggles.
            handleParamReply(frame.payload)
        default:
            break   // described in the translated log; metrics handled above
        }
    }

    /// Track feature-param values reported by the ring so the UI toggles reflect
    /// real on-ring state. `2F … 21 <id> b0 b1 b2 b3` = read reply; `23`/`27` are
    /// set-acks (we re-read after a set to confirm).
    private func handleParamReply(_ p: [UInt8]) {
        guard let sub = p.first else { return }
        switch sub {
        case 0x21 where p.count >= 6:
            let id = p[1], b0 = p[2]
            switch id {
            case RingCommand.paramDHR: featureDHR = b0 != 0
            case RingCommand.paramActivityHR: featureActivityHR = b0 != 0
            case RingCommand.paramSpO2: featureSpO2 = b0 != 0
            default: break
            }
        case 0x23, 0x27 where p.count >= 2:
            // set-ack: confirm by re-reading that param.
            txRaw(RingCommand.paramRead(id: p[1]))
        default:
            break
        }
    }

    private func handleInner(_ r: InnerRecord) {
        guard !r.isSuspect else { return }
        // Prefer the ring's actual RECORDING time, resolved from ring_time via the
        // §3.8 anchor. ring_time is a single continuous 100 ms/tick timeline (verified
        // linear across days), so one anchor resolves the whole history. Fall back to
        // arrival time only when no anchor is established yet.
        let at = eventTime(forRingTime: r.ringTime) ?? Date()
        switch r.type {
        case EventTag.ibiAndAmplitude.rawValue:
            if let d = RingDecoders.ibiAndAmplitude(r.payload), let hr = d.hrBpm {
                metrics.hrBpm = hr; metrics.hrAt = at; touch()
            }
        case EventTag.greenIBIQuality.rawValue:
            if let d = RingDecoders.greenIBIQuality(r.payload), let hr = d.hrBpm {
                metrics.hrBpm = hr; metrics.hrAt = at; touch()
            }
        case EventTag.hrvEvent.rawValue:
            if let h = RingDecoders.hrvEvent(r.payload), let w = h.windows.last {
                metrics.hrBpm = Double(w.hrBpm); metrics.hrAt = at
                metrics.hrvRmssd = w.rmssdMs; metrics.hrvAt = at; touch()
            }
        case EventTag.spo2RPI.rawValue:
            if let s = RingDecoders.spo2RPI(r.payload), let last = s.last {
                metrics.spo2 = min(100, max(0, last.spo2))   // clamp the approximation
                metrics.spo2At = at; touch()
            }
        case EventTag.tempEvent.rawValue:
            if let t = RingDecoders.tempEvent(r.payload),
               let first = t.channelsC.compactMap({ $0 }).first {
                metrics.temperatureC = first; metrics.tempAt = at; touch()
            }
        case EventTag.sleepTemp.rawValue:
            if let st = RingDecoders.sleepTempEvent(r.payload), let last = st.lastC {
                metrics.sleepTempC = last; touch()
            }
        case EventTag.sleepPeriodInfo.rawValue:
            if let sp = RingDecoders.sleepPeriodInfo(r.payload) {
                if sp.averageHr > 0 { metrics.hrBpm = sp.averageHr; metrics.hrAt = at }
                metrics.breathRate = sp.breath; metrics.breathAt = at
                metrics.sleepState = sp.sleepState
                touch()
            }
        case EventTag.bedtimePeriod.rawValue:
            if let b = RingDecoders.bedtimePeriod(r.payload) {
                metrics.bedtimeStart = b.startRingTime; metrics.bedtimeEnd = b.endRingTime; touch()
            }
        case EventTag.motionEvent.rawValue:
            if let m = RingDecoders.motionEvent(r.payload) {
                metrics.acmX = m.acmX; metrics.acmY = m.acmY; metrics.acmZ = m.acmZ
                metrics.motionMagnitude = m.magnitude; touch()
            }
        case EventTag.stateChange.rawValue, EventTag.wearEvent.rawValue:
            if let s = RingDecoders.stateChange(r.payload) {
                metrics.wearStateName = s.stateName ?? "state \(s.state)"; touch()
            }
        case EventTag.cvaRawPPG.rawValue:
            _ = ppgDecoder.feed(r.payload)
            metrics.ppgSampleCount = ppgDecoder.sampleCount; touch()
        case EventTag.timeSyncInd.rawValue:
            if let ts = RingDecoders.timeSyncInd(r.payload) {
                anchorRingTime = r.ringTime
                anchorUnixMs = Double(ts.ringUnixSeconds) * 1000.0
                anchorTickMs = ts.tickMs
            }
        case EventTag.ringStartInd.rawValue:
            if let anchor = anchorRingTime, r.ringTime < anchor {
                anchorRingTime = nil; anchorUnixMs = nil   // ring restarted (§3.8)
                ppgDecoder.reset()                          // new sampler session
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

    /// Per-ring cursor key so switching rings never reuses a stale cursor.
    private var perRingCursorKey: String {
        knownRingID.map { "\(cursorKey).\($0.uuidString)" } ?? cursorKey
    }

    private var lastCursor: UInt32 {
        UInt32(UserDefaults.standard.integer(forKey: perRingCursorKey))
    }

    private func advanceCursor(to ringTime: UInt32) {
        if ringTime > lastCursor {
            UserDefaults.standard.set(Int(ringTime), forKey: perRingCursorKey)
            cursor = ringTime
        }
    }

    /// Set the cursor to an absolute value (used by reset + ring-restart rollback).
    private func setCursor(_ value: UInt32) {
        UserDefaults.standard.set(Int(value), forKey: perRingCursorKey)
        cursor = value
    }

    /// Wall-clock time for a `ring_time`, via the §3.8 anchor. nil until a `0x42`
    /// time-sync has established the anchor.
    func eventTime(forRingTime rt: UInt32) -> Date? {
        guard let art = anchorRingTime, let aunix = anchorUnixMs else { return nil }
        let ms = aunix + Double(Int64(rt) - Int64(art)) * anchorTickMs
        return Date(timeIntervalSince1970: ms / 1000.0)
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
        keepHRAlive = false; flushTick = 0
        ppgDecoder.reset()
        closeLogFile()
    }

    // MARK: Debug helpers

    /// Fire on-demand HR the clean way: just the DHR burst (mode 3 / sub 2), and
    /// keep it armed via the flush loop. This is open_ring's HR path — it makes the
    /// ring compute + stream live 0x60 IBI events. (Deliberately NOT paired with the
    /// realtime-raw 06 07 request, which floods raw PPG instead of computed IBI.)
    func triggerMeasurement() {
        triggerDHRBurst()
    }

    /// DHR burst (param 02 mode 3 / sub 2) and arm the keep-alive so the flush loop
    /// re-fires it before the ring's ~20 s auto-revert, sustaining the IBI stream.
    func triggerDHRBurst() {
        keepHRAlive = true
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

    /// Write a command and record it in the raw log + the TX (output) stats.
    private func txRaw(_ bytes: [UInt8]) {
        transport.write(bytes)
        rawAppend("TX", bytes)
        guard let op = bytes.first else { return }
        if op == 0x2F, bytes.count > 2 {
            bump(String(format: "t:2f.%02x", bytes[2]))   // sub-op after opcode+len
        } else {
            bump(String(format: "t:%02x", op))
        }
    }

    private func elapsedMs() -> Int {
        if logStart == nil { logStart = Date() }
        return Int(Date().timeIntervalSince(logStart!) * 1000)
    }

    private func rawAppend(_ dir: String, _ bytes: [UInt8]) {
        let stamped = "\(Self.pad(elapsedMs(), 7))  \(dir)  \(Self.hex(bytes))"
        rawLog.append(stamped)
        if rawLog.count > 1200 { rawLog.removeFirst(rawLog.count - 1200) }
        fileLog(stamped)
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

    /// Human label for a frame-stat key ("o:2f.28", "i:60"). ASCII only so it
    /// survives copy/paste into any context.
    private static func frameLabel(_ key: String) -> String {
        switch key {
        case "i:60": return "IBI+amp (HR)"
        case "i:80": return "green IBI (HR)"
        case "i:5d": return "HRV"
        case "i:8b": return "SpO2"
        case "i:46": return "temp"
        case "i:69": return "temp period"
        case "i:75": return "sleep temp"
        case "i:6a": return "sleep info (HR/breath)"
        case "i:72": return "sleep ACM period"
        case "i:6c": return "feature session"
        case "i:50": return "activity info"
        case "i:82": return "scan start"
        case "i:83": return "scan end"
        case "i:85": return "RTC beacon"
        // On-demand measurement family (ringverse).
        case "i:62": return "on-demand meas"
        case "i:65": return "on-demand session"
        case "i:66": return "on-demand motion"
        case "i:47": return "motion"
        case "i:6b": return "motion period"
        case "i:81": return "raw PPG (CVA)"
        case "i:68": return "raw PPG"
        case "i:76": return "bedtime"
        case "i:42": return "time-sync"
        case "i:41": return "ring-start"
        case "i:45", "i:53": return "state/wear"
        case "i:43": return "debug event"
        case "i:61": return "debug data"
        case "i:5b": return "ble connection"
        case "i:56": return "alert event"
        // Documented in ringverse/open_ring but not emitted by this firmware —
        // named so frame counts have no blanks (surfaced raw; not decoded).
        case "i:44": return "ibi event"
        case "i:48": return "sleep period info"
        case "i:49": return "sleep summary 1"
        case "i:4a": return "ppg amplitude"
        case "i:4b": return "sleep phase info"
        case "i:4c": return "sleep summary 2"
        case "i:4d": return "ring sleep feature"
        case "i:4e": return "sleep phase details"
        case "i:4f": return "sleep summary 3"
        case "i:51": return "activity summary 1"
        case "i:52": return "activity summary 2"
        case "i:54": return "recovery summary"
        case "i:58": return "sleep summary 4"
        case "i:5a": return "sleep phase details"
        case "i:5c": return "user info"
        case "i:5e": return "selftest"
        case "i:67": return "raw PPG summary"
        case "i:6d": return "meas quality"
        case "i:6e": return "SpO2 IBI+amp"
        case "i:6f": return "SpO2 event"
        case "i:71": return "green IBI+amp"
        case "i:73": return "EHR trace"
        case "i:74": return "EHR ACM intensity"
        case "i:77": return "SpO2 DC"
        case "i:79": return "selftest data/tag"
        case "i:7b": return "SpO2 stable"
        case "i:7c": return "SpO2 combo"
        case "i:7e": return "real steps 1"
        case "i:7f": return "real steps 2"
        case "o:09": return "firmware/id resp"
        case "o:0f": return "soft-reset ack"
        case "o:19": return "event resp"
        case "o:1d": return "state-cmd resp"
        case "o:1e": return "state query"
        case "o:1f": return "state-query resp"
        case "o:0d": return "battery"
        case "o:11": return "GetEvent resp"
        case "o:13": return "time-sync ack"
        case "o:17": return "subscribe ack"
        case "o:07": return "realtime ack"
        case "o:25": return "SetAuthKey resp"
        case "o:29": return "flush ack"
        case "o:33": return "accelerometer"
        case "o:2f.21": return "param read resp"
        case "o:2f.23": return "set-ack b0"
        case "o:2f.27": return "set-ack b2"
        case "o:2f.28": return "raw PPG"
        case "o:2f.02": return "param bulk dump"
        case "o:2f.2c": return "auth nonce"
        case "o:2f.2e": return "auth status"
        // TX commands we send (outputs).
        case "t:08": return "id/time probe"
        case "t:0c": return "battery req"
        case "t:10": return "GetEvent"
        case "t:12": return "time-sync req"
        case "t:16": return "subscribe-enable"
        case "t:18": return "category subscribe"
        case "t:1a": return "reset"
        case "t:1c": return "state cmd"
        case "t:24": return "SetAuthKey"
        case "t:28": return "data flush"
        case "t:06": return "realtime measure"
        case "t:2f.01": return "nonce req"
        case "t:2f.11": return "auth proof"
        case "t:2f.20": return "param read"
        case "t:2f.22": return "param set b0"
        case "t:2f.26": return "param set b2"
        default: return ""
        }
    }

    /// Format a subset of frameStats as aligned, annotated, count-sorted lines.
    private func statLines(_ entries: [(String, Int)]) -> [String] {
        let sorted = entries.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let keyW = sorted.map(\.0.count).max() ?? 0
        let cntW = sorted.map { String($0.1).count }.max() ?? 0
        return sorted.map { k, v in
            let left = k.padding(toLength: keyW, withPad: " ", startingAt: 0)
            let cnt = Self.pad(v, cntW)
            let label = Self.frameLabel(k)
            return label.isEmpty ? "\(left)  x\(cnt)" : "\(left)  x\(cnt)  \(label)"
        }
    }

    /// Inputs — frames received from the ring (inner events `i:` + outer control `o:`).
    var inputStatLines: [String] {
        statLines(frameStats.filter { !$0.key.hasPrefix("t:") }.map { ($0.key, $0.value) })
    }
    /// Outputs — commands we sent to the ring (`t:`).
    var outputStatLines: [String] {
        statLines(frameStats.filter { $0.key.hasPrefix("t:") }.map { ($0.key, $0.value) })
    }
    var inputStatTotal: Int { frameStats.filter { !$0.key.hasPrefix("t:") }.values.reduce(0, +) }
    var outputStatTotal: Int { frameStats.filter { $0.key.hasPrefix("t:") }.values.reduce(0, +) }

    /// Copy the raw log (`ms<TAB>RX/TX<TAB>hex`) to the clipboard.
    func copyRawLog() { UIPasteboard.general.string = rawLog.joined(separator: "\n") }
    /// Copy the translated log to the clipboard.
    func copyTranslatedLog() { UIPasteboard.general.string = log.joined(separator: "\n") }
    /// Copy both frame-count tables (inputs + outputs) to the clipboard in one go.
    func copyFrameStats() {
        var lines = ["== Inputs — received (\(inputStatTotal)) =="]
        lines += inputStatLines
        lines += ["", "== Outputs — sent (\(outputStatTotal)) =="]
        lines += outputStatLines
        UIPasteboard.general.string = lines.joined(separator: "\n")
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
        case 0x09: return "firmware/id resp: \(Self.hex(p))"          // time_or_id_resp
        case 0x0F: return "soft-reset ack (status \(p.first ?? 0))"
        case 0x17: return "subscribe-enable ack"
        case 0x19: return "event resp"                                // event_resp
        case 0x1D: return "state-cmd resp"                            // state_cmd_resp
        case 0x1F: return "state-query resp: \(Self.hex(p))"          // state_query_resp
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
            let w = RingDecoders.hrvEvent(r.payload)?.windows.last
            return "HRV rt=\(r.ringTime) hr=\(w.map { "\($0.hrBpm)" } ?? "—") rmssd=\(w.map { "\($0.rmssdMs)" } ?? "—")ms"
        case EventTag.spo2RPI.rawValue:
            if let s = RingDecoders.spo2RPI(r.payload)?.last {
                let pct = min(100.0, max(0.0, s.spo2))
                // Log the raw R + perfusion too — R is the real measurement and is
                // what a calibration fit needs (the % is only the textbook approx).
                return "SpO2 rt=\(r.ringTime) ~\(String(format: "%.0f", pct))% approx (R=\(String(format: "%.3f", s.rValue)) PI=\(String(format: "%.3f", s.irPi)))"
            }
            return "SpO2 rt=\(r.ringTime) —"
        case EventTag.tempEvent.rawValue:
            let t = RingDecoders.tempEvent(r.payload)?.channelsC.compactMap { $0 } ?? []
            return "temp rt=\(r.ringTime) \(t)°C"
        case EventTag.tempPeriod.rawValue:
            return "tempPeriod rt=\(r.ringTime) raw=\(RingDecoders.tempPeriod(r.payload)?.raw ?? 0)"
        case EventTag.sleepTemp.rawValue:
            let st = RingDecoders.sleepTempEvent(r.payload)
            return "sleepTemp rt=\(r.ringTime) n=\(st?.tempsC.count ?? 0) last=\(st?.lastC.map { String(format: "%.2f", $0) } ?? "—")°C"
        case EventTag.sleepPeriodInfo.rawValue:
            if let sp = RingDecoders.sleepPeriodInfo(r.payload) {
                return "sleepInfo rt=\(r.ringTime) hr=\(hr(sp.averageHr)) breath=\(String(format: "%.1f", sp.breath)) state=\(sp.sleepState) motion=\(sp.motionCount)"
            }
            return "sleepInfo rt=\(r.ringTime) (short)"
        case EventTag.bedtimePeriod.rawValue:
            let b = RingDecoders.bedtimePeriod(r.payload)
            return "bedtime rt=\(r.ringTime) start=\(b?.startRingTime ?? 0) end=\(b?.endRingTime ?? 0)"
        case EventTag.motionEvent.rawValue:
            return "motion rt=\(r.ringTime) mag=\(RingDecoders.motionEvent(r.payload)?.magnitude ?? 0)"
        case EventTag.motionPeriod.rawValue:
            return "motionPeriod rt=\(r.ringTime) state=\(RingDecoders.motionPeriod(r.payload)?.state ?? 0)"
        case EventTag.onDemandMeas.rawValue:
            if let m = RingDecoders.onDemandMeas(r.payload) {
                return "onDemandMeas rt=\(r.ringTime) f0=\(m.field0) f1=\(m.f1.map { String(format: "%.1f", $0) } ?? "—") f2=\(m.f2.map { String(format: "%.1f", $0) } ?? "—")"
            }
            return "onDemandMeas rt=\(r.ringTime): \(Self.hex(r.payload))"
        case EventTag.onDemandSession.rawValue:
            let s = RingDecoders.onDemandSession(r.payload)
            return "onDemandSession rt=\(r.ringTime) cfg=\(s.map { Self.hex($0.bytes) } ?? "?") word=\(s?.word.map(String.init) ?? "—")"
        case EventTag.onDemandMotion.rawValue:
            return "onDemandMotion rt=\(r.ringTime): \(Self.hex(r.payload))"
        case EventTag.featureSession.rawValue:
            if let f = RingDecoders.featureSession(r.payload) {
                return "feature rt=\(r.ringTime) \(f.kind ?? "feat\(f.feature)") status=\(f.status)"
            }
            return "feature rt=\(r.ringTime): \(Self.hex(r.payload))"
        case EventTag.sleepACMPeriod.rawValue:
            let v = RingDecoders.sleepACMPeriod(r.payload)?.values
            return "sleepACM rt=\(r.ringTime) \(v.map { $0.map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? Self.hex(r.payload))"
        case EventTag.activityInfo.rawValue:
            return "activity rt=\(r.ringTime) class=\(RingDecoders.activityInfo(r.payload)?.activityClass ?? 0)"
        case EventTag.alertEvent.rawValue:
            return "alert rt=\(r.ringTime) type=\(RingDecoders.alertEvent(r.payload)?.alertType ?? 0)"
        case EventTag.cvaRawPPG.rawValue:   // feeding happens in handleInner (stateful)
            return "rawPPG(0x81) rt=\(r.ringTime) \(r.payload.count)B"
        case EventTag.rawPPG.rawValue:
            return "rawPPG(0x68) rt=\(r.ringTime): \(Self.hex(r.payload))"
        case EventTag.timeSyncInd.rawValue: return "time-sync rt=\(r.ringTime)"
        case EventTag.ringStartInd.rawValue:
            return "ring-start rt=\(r.ringTime) ts=\(RingDecoders.ringStartInd(r.payload)?.timestamp ?? 0)"
        case EventTag.stateChange.rawValue, EventTag.wearEvent.rawValue:
            let s = RingDecoders.stateChange(r.payload)
            return "state rt=\(r.ringTime) \(s?.stateName ?? "state \(s?.state ?? 0)") \(s?.text ?? "")"
        case EventTag.debugEvent.rawValue:   // 0x43 — firmware log line (ASCII)
            return "dbg rt=\(r.ringTime): \(Self.ascii(r.payload))"
        case EventTag.debugData.rawValue:    // 0x61 — debug data; often ASCII (cat byte + text)
            return "dbg rt=\(r.ringTime): \(Self.asciiOrHex(r.payload))"
        case 0x5B:   // ble_connection_ind (ringverse/open_ring) — raw body
            return "bleConn rt=\(r.ringTime): \(Self.hex(r.payload))"
        case 0x82: return "scanStart rt=\(r.ringTime): \(Self.hex(r.payload))"
        case 0x83: return "scanEnd rt=\(r.ringTime): \(Self.hex(r.payload))"
        case 0x85: return "rtcBeacon rt=\(r.ringTime): \(Self.hex(r.payload))"
        case 0x5C: return "userInfo rt=\(r.ringTime): \(Self.hex(r.payload))"
        default: return "inner 0x\(hx(r.type)) rt=\(r.ringTime): \(Self.hex(r.payload))"
        }
    }

    /// Render bytes as printable ASCII (non-printable → '.').
    private static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    /// ASCII if the payload is mostly printable, else hex. The first byte is often
    /// a non-printable category tag, so it's checked from offset 1.
    private static func asciiOrHex(_ bytes: [UInt8]) -> String {
        guard bytes.count > 1 else { return hex(bytes) }
        let body = Array(bytes.dropFirst())
        let printable = body.filter { (0x20...0x7E).contains($0) }.count
        return printable * 100 >= body.count * 70 ? ascii(body) : "(bin) \(hex(bytes))"
    }

    // MARK: Manual command actions (debug Actions panel)

    func requestBattery() { sendNamed("battery", RingCommand.battery) }
    func flushNow() { sendNamed("data_flush", RingCommand.dataFlush) }
    func getEventDrain() { sendNamed("GetEvent drain", RingCommand.getEvent(ringTime: lastCursor, max: 255)) }
    func getEventAck() { sendNamed("GetEvent ack", RingCommand.getEvent(ringTime: lastCursor, max: 0)) }

    /// Drain the ring's full flash history from the start (cursor = 0). Replays
    /// stored 0x60 IBI + 0x5D HRV (5-min HR) records the ring buffered while
    /// disconnected — this is the historical-HR path. The consume loop advances
    /// the persisted cursor as records arrive, so re-runs only fetch what's new.
    func drainHistory() {
        sendNamed("data_flush", RingCommand.dataFlush)
        sendNamed("GetEvent history (from 0)", RingCommand.getEvent(ringTime: 0, max: 255))
    }

    /// Reset the persisted sync cursor to 0 so the next drain starts from the
    /// earliest buffered event again.
    func resetCursor() {
        setCursor(0)
        addLog("Sync cursor reset to 0.")
    }
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
        if !on { keepHRAlive = false }   // stop the flush loop re-arming the burst
        sendNamed("DHR=\(on ? 1 : 0)", RingCommand.paramSetByte0(id: RingCommand.paramDHR, value: on ? 1 : 0))
    }
    /// BLE-bond-only reset (`1A 01 01`) — forces re-pair but KEEPS the auth key.
    func bondOnlyReset() { sendNamed("BLE-bond reset (keeps key)", [0x1A, 0x01, 0x01]) }

    /// Export the stored auth key (hex) for the known ring to the clipboard, so an
    /// external clean-room client (e.g. open_ring) can reuse the key Cassini
    /// provisioned via SetAuthKey — no rooted-phone Realm extraction needed. The
    /// key is in the app's data-protection keychain, unreadable outside the app.
    func copyAuthKey() {
        guard let id = knownRingID, let key = keyStore.load(ringID: id.uuidString) else {
            addLog("No stored auth key to export (onboard a ring first).")
            return
        }
        let hex = key.map { String(format: "%02x", $0) }.joined()
        UIPasteboard.general.string = hex
        addLog("Auth key copied (\(key.count)B) for ring \(id.uuidString):")
        addLog(hex)
    }

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
        let stamped = "\(Self.pad(elapsedMs(), 7))  \(line)"
        log.append(stamped)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        fileLog(stamped)
    }

    // MARK: Session file log (full, uncapped — one timestamped file per run)

    /// Open a fresh timestamped log file in the app's Documents container. Both the
    /// raw frame stream and the translated lines are appended here as they happen,
    /// so the on-disk file keeps the full history the in-memory buffers cap off.
    private func startLogFile() {
        closeLogFile()
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let stamp = Self.fileStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("cassini-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
        logFilePath = url.path
        let header = "# Cassini session log \(stamp)\n# columns: <ms>  <RX/TX or text>\n"
        if let d = header.data(using: .utf8) { try? logFileHandle?.write(contentsOf: d) }
        addLog("Logging to file: \(url.path)")
    }

    private func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
    }

    private func fileLog(_ line: String) {
        guard let h = logFileHandle, let d = (line + "\n").data(using: .utf8) else { return }
        try? h.write(contentsOf: d)
    }

    /// Copy the current session log file path to the clipboard.
    func copyLogFilePath() {
        guard let p = logFilePath else { addLog("No log file yet (connect first)."); return }
        UIPasteboard.general.string = p
        addLog("Log file path copied.")
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
