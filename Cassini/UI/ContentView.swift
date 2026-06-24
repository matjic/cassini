import SwiftUI

struct ContentView: View {
    @Environment(RingController.self) private var controller

    var body: some View {
        NavigationStack {
            Group {
                switch controller.phase {
                case .idle, .scanning, .bluetoothOff, .error:
                    ScanView()
                default:
                    DashboardView()
                }
            }
            .navigationTitle("Cassini")
        }
    }
}

// MARK: - Scan / onboarding

struct ScanView: View {
    @Environment(RingController.self) private var controller

    var body: some View {
        List {
            Section {
                statusRow
            }
            if controller.hasKnownRing {
                Section {
                    Button {
                        controller.reconnectKnown()
                    } label: {
                        Label("Reconnect last ring", systemImage: "arrow.clockwise")
                    }
                }
            }
            Section("Rings nearby") {
                if controller.discovered.isEmpty {
                    Text("Scanning for a ring advertising the service…")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.discovered) { ring in
                    Button {
                        controller.selectRing(ring)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ring.name)
                                Text(ring.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(ring.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Rescan") { controller.beginScan() }
            } footer: {
                Text("A new ring is paired + onboarded (accept the system Bluetooth dialog). A ring you've already onboarded just reconnects with its stored key.")
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch controller.phase {
        case .bluetoothOff:
            Label("Bluetooth is off or unauthorized", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .scanning:
            Label("Scanning…", systemImage: "dot.radiowaves.left.and.right")
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        default:
            Label("Idle", systemImage: "circle")
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @Environment(RingController.self) private var controller

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let name = controller.connectedRingName {
                    Text(name).font(.title2.weight(.semibold))
                }
                phaseBanner

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricTile(title: "Heart Rate",
                               value: controller.metrics.hrBpm.map { "\(Int($0))" } ?? "—",
                               unit: "bpm", systemImage: "heart.fill", tint: .red,
                               time: controller.metrics.hrAt)
                    MetricTile(title: "HRV",
                               value: controller.metrics.hrvRmssd.map { "\($0)" } ?? "—",
                               unit: "ms", systemImage: "waveform.path.ecg", tint: .pink,
                               time: controller.metrics.hrvAt)
                    MetricTile(title: "Breath",
                               value: controller.metrics.breathRate.map { String(format: "%.1f", $0) } ?? "—",
                               unit: "br/min", systemImage: "wind", tint: .teal,
                               time: controller.metrics.breathAt)
                    MetricTile(title: "SpO₂ (est.)",
                               value: controller.metrics.spo2.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "%", systemImage: "lungs.fill", tint: .blue,
                               time: controller.metrics.spo2At)
                    MetricTile(title: "Temperature",
                               value: controller.metrics.temperatureC.map { String(format: "%.1f", $0 * 9 / 5 + 32) } ?? "—",
                               unit: "°F", systemImage: "thermometer.medium", tint: .orange,
                               time: controller.metrics.tempAt)
                    MetricTile(title: "Battery",
                               value: controller.metrics.batteryPct.map { "\($0)" } ?? "—",
                               unit: controller.metrics.batteryMv.map { "% · \($0)mV" } ?? "%",
                               systemImage: "battery.100", tint: .green,
                               time: controller.metrics.batteryAt)
                }

                SleepStatusView()

                if let last = controller.metrics.lastUpdate {
                    Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ActionsPanel()
                DebugPanel()

                LogView(title: "Translated log", lines: controller.log, monospaced: true) {
                    controller.copyTranslatedLog()
                }
                LogView(title: "Raw log", lines: controller.rawLog, monospaced: true) {
                    controller.copyRawLog()
                }

                HStack {
                    Spacer()
                    Button("Disconnect") { controller.stop() }
                }
                .padding(.top, 8)
            }
            .padding()
        }
    }

    @ViewBuilder private var phaseBanner: some View {
        let (text, image, tint): (String, String, Color) = {
            switch controller.phase {
            case .connecting: return ("Connecting…", "antenna.radiowaves.left.and.right", .secondary)
            case .onboarding: return ("Onboarding (accept the pairing dialog)", "key.fill", .orange)
            case .authenticating: return ("Authenticating…", "lock.fill", .secondary)
            case .streaming: return ("Streaming", "dot.radiowaves.up.forward", .green)
            case .error(let m): return (m, "exclamationmark.triangle.fill", .red)
            default: return ("", "", .secondary)
            }
        }()
        if !text.isEmpty {
            Label(text, systemImage: image)
                .font(.subheadline)
                .foregroundStyle(tint)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let systemImage: String
    let tint: Color
    var time: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(time.map { $0.formatted(date: .omitted, time: .standard) } ?? " ")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Sleep & status (populated mainly after a history drain)

struct SleepStatusView: View {
    @Environment(RingController.self) private var controller

    var body: some View {
        let m = controller.metrics
        let rows: [(String, String)] = {
            var r: [(String, String)] = []
            if let s = m.wearStateName { r.append(("Wear state", s)) }
            if let st = m.sleepState { r.append(("Sleep state", sleepStateLabel(st))) }
            if let t = m.sleepTempC { r.append(("Sleep temp", String(format: "%.1f °F", t * 9 / 5 + 32))) }
            if let a = m.bedtimeStart, let b = m.bedtimeEnd { r.append(("Bedtime window", bedtime(a, b))) }
            if let n = m.ppgSampleCount { r.append(("Raw PPG samples", "\(n)")) }
            return r
        }()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sleep & status", systemImage: "bed.double.fill")
                    .font(.caption).foregroundStyle(.indigo)
                ForEach(rows, id: \.0) { key, value in
                    HStack {
                        Text(key).foregroundStyle(.secondary)
                        Spacer()
                        Text(value).fontWeight(.medium)
                    }
                    .font(.caption)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Bedtime window duration. start/end are per-session ring_time (~10 ticks/s),
    /// so the span is valid even though absolute wall-clock isn't reconstructable
    /// across sessions.
    private func bedtime(_ start: UInt32, _ end: UInt32) -> String {
        let mins = Int(end > start ? end - start : 0) / 10 / 60
        return "~\(mins) min (rt \(start)→\(end))"
    }

    /// 0x6A sleep_state enum (0/1/2; open_ring leaves exact stage naming open).
    private func sleepStateLabel(_ s: Int) -> String {
        switch s {
        case 0: return "0 (awake/restless)"
        case 1: return "1 (light?)"
        case 2: return "2 (deep?)"
        default: return "\(s)"
        }
    }
}

// MARK: - Actions panel (every command as a button)

private struct RingAction: Identifiable {
    var id: String { title }
    let title: String
    var role: ButtonRole?
    let perform: () -> Void
    init(_ title: String, role: ButtonRole? = nil, _ perform: @escaping () -> Void) {
        self.title = title; self.role = role; self.perform = perform
    }
}

struct ActionsPanel: View {
    @Environment(RingController.self) private var controller
    @State private var rawHex = ""

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 8)]

    var body: some View {
        DisclosureGroup("Actions") {
            VStack(alignment: .leading, spacing: 14) {
                // Live heart rate — the headline path (clean DHR burst, auto re-armed).
                group("Heart rate", [
                    RingAction("Measure HR") { controller.triggerMeasurement() },
                    RingAction("Stop HR") { controller.setDHR(false) },
                ])
                // Other on-demand sensor streams (raw, for debugging/RE).
                group("Sensor streams", [
                    RingAction("Raw PPG") { controller.triggerRealtimeRaw() },
                    RingAction("Accelerometer") { controller.triggerAccelerometer() },
                    RingAction("PPG @2Hz") { controller.triggerOnDemand2Hz() },
                    RingAction("ACM @2Hz") { controller.triggerACM2Hz() },
                ])
                // Persisted feature toggles — reflect real on-ring state (read back
                // from the ring; "?" until the first param read lands).
                VStack(alignment: .leading, spacing: 6) {
                    Text("Features (persist, from ring)").font(.caption).foregroundStyle(.secondary)
                    featureToggle("SpO₂", controller.featureSpO2) { controller.setSpO2($0) }
                    featureToggle("Activity HR", controller.featureActivityHR) { controller.setActivityHR($0) }
                    featureToggle("Daytime HR (DHR)", controller.featureDHR) { controller.setDHR($0) }
                }
                // Pull stored/overnight data off the ring.
                group("History & sync", [
                    RingAction("Drain history") { controller.drainHistory() },
                    RingAction("Reset cursor") { controller.resetCursor() },
                    RingAction("Flush now") { controller.flushNow() },
                    RingAction("GetEvent drain") { controller.getEventDrain() },
                    RingAction("GetEvent ack") { controller.getEventAck() },
                    RingAction("Time-sync") { controller.sendTimeSync() },
                ])
                // Low-level / one-off control.
                group("Connection", [
                    RingAction("Battery") { controller.requestBattery() },
                    RingAction("Subscribe-enable") { controller.sendSubscribeEnable() },
                    RingAction("Read params") { controller.readFeatureParams() },
                    RingAction("Copy auth key") { controller.copyAuthKey() },
                ])
                // Destructive — bottom, out of the way.
                group("Reset", [
                    RingAction("BLE-bond reset") { controller.bondOnlyReset() },
                    RingAction("Factory reset", role: .destructive) { controller.factoryReset() },
                ])
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw command (hex)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. 0c 00", text: $rawHex)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Send") { controller.sendRawHex(rawHex) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    @ViewBuilder private func featureToggle(_ title: String, _ state: Bool?,
                                            _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { state ?? false }, set: { set($0) })) {
            HStack(spacing: 6) {
                Text(title)
                if state == nil {
                    Text("?").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(.green)
    }

    @ViewBuilder private func group(_ title: String, _ actions: [RingAction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(actions) { a in
                    Button(a.title, role: a.role, action: a.perform)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct DebugPanel: View {
    @Environment(RingController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        DisclosureGroup("Debug") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-measure HR on connect", isOn: $controller.autoMeasureOnConnect)
                Toggle("Drain from start each connect", isOn: $controller.drainFromStartOnConnect)

                // Sync cursor + last drain status (spec.md §3.8).
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Sync cursor").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(controller.cursor)").fontWeight(.medium)
                    }
                    HStack {
                        Text("Last GetEvent").foregroundStyle(.secondary)
                        Spacer()
                        Text(controller.lastDrainInfo).fontWeight(.medium)
                    }
                }
                .font(.caption)

                // Session log file (full, uncapped).
                if let path = controller.logFilePath {
                    HStack {
                        Button("Copy log path", systemImage: "doc.on.doc") { controller.copyLogFilePath() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                    }
                    Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .textSelection(.enabled).lineLimit(2)
                }

                Button("Reset logs + stats") { controller.resetLogsAndStats() }
                    .buttonStyle(.bordered)
                if !controller.frameStats.isEmpty {
                    HStack {
                        Text("Frame counts").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { controller.copyFrameStats() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    frameTable("Inputs — received (\(controller.inputStatTotal))", controller.inputStatLines)
                    frameTable("Outputs — sent (\(controller.outputStatTotal))", controller.outputStatLines)
                }
            }
            .padding(.vertical, 4)
        }
        .font(.subheadline)
    }

    @ViewBuilder private func frameTable(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}

struct LogView: View {
    let title: String
    let lines: [String]
    var monospaced: Bool = false
    let onCopy: () -> Void

    var body: some View {
        DisclosureGroup("\(title) (\(lines.count))") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Copy", systemImage: "doc.on.doc") { onCopy() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(monospaced ? .caption2.monospaced() : .caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView().environment(RingController())
}
