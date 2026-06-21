import Foundation
import CoreBluetooth
import CassiniCore

/// Errors surfaced by the BLE transport layer.
enum BLEError: Error, LocalizedError {
    case bluetoothUnavailable
    case timeout(String)
    case characteristicsMissing
    case disconnected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is off or unavailable."
        case .timeout(let what): return "Timed out waiting for \(what)."
        case .characteristicsMissing: return "Ring GATT characteristics not found."
        case .disconnected: return "The ring disconnected."
        }
    }
}

/// A discovered peripheral surfaced to the UI.
struct DiscoveredRing: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Thin CoreBluetooth wrapper: scan-by-service / retrieve-by-UUID, connect,
/// encrypted-link setup (subscribing to the notify characteristic triggers the
/// OS pairing dialog — spec §4.2), and a single notify AsyncStream consumed by
/// the connection orchestrator. All state is main-actor; the central uses the
/// main queue so delegate callbacks land here too.
@MainActor
final class BLETransport: NSObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let serviceUUID = CBUUID(string: RingGATT.service)
    private let writeUUID = CBUUID(string: RingGATT.write)
    private let notifyUUID = CBUUID(string: RingGATT.notify)

    // Standard GAP service / Device Name characteristic — carries the model name
    // ("Oura Ring 4" paired, "Oura <serial>" unpaired) readable after connect.
    private let gapServiceUUID = CBUUID(string: "1800")
    private let deviceNameUUID = CBUUID(string: "2A00")

    /// Notifications from the notify characteristic (raw ATT values).
    private var notifyContinuation: AsyncStream<[UInt8]>.Continuation?
    private(set) lazy var notifications: AsyncStream<[UInt8]> = {
        AsyncStream { self.notifyContinuation = $0 }
    }()

    // Continuations awaited by the async connect flow.
    private var powerOnContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    /// Live scan results, observed by the UI.
    var onDiscover: ((DiscoveredRing) -> Void)?
    /// Fired when the link drops unexpectedly.
    var onDisconnect: (() -> Void)?
    /// Fired with the GAP Device Name once read after connecting.
    var onName: ((UUID, String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var currentPeripheralID: UUID? { peripheral?.identifier }

    /// Wait until CoreBluetooth reports powered-on.
    func waitForPoweredOn() async throws {
        if central.state == .poweredOn { return }
        if central.state == .unsupported || central.state == .unauthorized {
            throw BLEError.bluetoothUnavailable
        }
        try await withCheckedThrowingContinuation { powerOnContinuation = $0 }
    }

    func startScanning() {
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func stopScanning() { central.stopScan() }

    /// Reconnect to a previously bonded ring by its stable CoreBluetooth UUID
    /// (spec §3.10 / §4.2). Returns false if the system no longer knows it.
    func retrieve(id: UUID) -> Bool {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        peripheral = p
        p.delegate = self
        return true
    }

    /// Connect to a discovered ring and establish the encrypted link
    /// (discover service + characteristics, subscribe to notify).
    func connect(id: UUID) async throws {
        stopScanning()
        guard let p = peripheral ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw BLEError.disconnected
        }
        peripheral = p
        p.delegate = self

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectContinuation = c
            central.connect(p, options: nil)
        }
        // didConnect → discover services → characteristics → subscribe; ready
        // resolves once the notify subscription is confirmed.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyContinuation = c
            p.discoverServices([serviceUUID, gapServiceUUID])
        }
    }

    /// Write a framed command to the write characteristic.
    func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let ch = writeChar else { return }
        p.writeValue(Data(bytes), for: ch, type: .withoutResponse)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
}

extension BLETransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            powerOnContinuation?.resume()
            powerOnContinuation = nil
        case .unsupported, .unauthorized, .poweredOff:
            powerOnContinuation?.resume(throwing: BLEError.bluetoothUnavailable)
            powerOnContinuation = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown Ring"
        onDiscover?(DiscoveredRing(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? BLEError.disconnected)
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Resolve any in-flight setup with the real error (e.g. CBError code 14,
        // peerRemovedPairingInformation) so the orchestrator can react.
        let failure = error ?? BLEError.disconnected
        readyContinuation?.resume(throwing: failure)
        readyContinuation = nil
        connectContinuation?.resume(throwing: failure)
        connectContinuation = nil
        onDisconnect?()
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard let ringService = services.first(where: { $0.uuid == serviceUUID }) else {
            readyContinuation?.resume(throwing: BLEError.characteristicsMissing)
            readyContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: ringService)
        // Best-effort model-name read; never gates readiness.
        if let gap = services.first(where: { $0.uuid == gapServiceUUID }) {
            peripheral.discoverCharacteristics([deviceNameUUID], for: gap)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // GAP service: read the device name, independent of the ready handshake.
        if service.uuid == gapServiceUUID {
            if let nameChar = service.characteristics?.first(where: { $0.uuid == deviceNameUUID }) {
                peripheral.readValue(for: nameChar)
            }
            return
        }
        guard service.uuid == serviceUUID else { return }
        for ch in service.characteristics ?? [] {
            if ch.uuid == writeUUID { writeChar = ch }
            if ch.uuid == notifyUUID { notifyChar = ch }
        }
        guard let notifyChar else {
            readyContinuation?.resume(throwing: BLEError.characteristicsMissing)
            readyContinuation = nil
            return
        }
        // Subscribing forces link-layer encryption → OS pairing dialog (§4.2).
        peripheral.setNotifyValue(true, for: notifyChar)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        if let name = peripheral.name { onName?(peripheral.identifier, name) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            readyContinuation?.resume(throwing: error)
        } else {
            readyContinuation?.resume()
        }
        readyContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == deviceNameUUID {
            if let data = characteristic.value, let name = String(data: data, encoding: .utf8) {
                onName?(peripheral.identifier, name)
            }
            return
        }
        guard characteristic.uuid == notifyUUID, let data = characteristic.value else { return }
        notifyContinuation?.yield([UInt8](data))
    }
}
