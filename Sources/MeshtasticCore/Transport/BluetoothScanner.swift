import CoreBluetooth
import Foundation
import Observation

/// Live scan for advertising Meshtastic radios, driving the connect sheet.
@MainActor
@Observable
public final class BluetoothScanner: NSObject {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false

    /// True once the user has granted Bluetooth access and a radio is powered on.
    public var isAvailable: Bool { state == .poweredOn }

    public var unavailableReason: String? {
        switch state {
        case .poweredOn: nil
        case .poweredOff: "Bluetooth is turned off."
        case .unauthorized: "MeshDash is not allowed to use Bluetooth. Grant access in System Settings › Privacy & Security › Bluetooth."
        case .unsupported: "This Mac does not support Bluetooth Low Energy."
        case .resetting: "The Bluetooth system is restarting…"
        case .unknown: "Starting Bluetooth…"
        @unknown default: "Bluetooth is unavailable."
        }
    }

    private var central: CBCentralManager?
    private var lastSeen: [UUID: Date] = [:]
    private var pruneTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        beginScanIfPossible()
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.pruneStale()
            }
        }
    }

    public func stop() {
        pruneTask?.cancel()
        pruneTask = nil
        central?.stopScan()
        isScanning = false
    }

    private func beginScanIfPossible() {
        guard let central, central.state == .poweredOn else { return }
        // Radios already bonded to this Mac may not be advertising; surface them anyway.
        for peripheral in central.retrieveConnectedPeripherals(withServices: [MeshtasticBLE.serviceUUID]) {
            record(id: peripheral.identifier, name: peripheral.name, rssi: nil)
        }
        central.scanForPeripherals(withServices: [MeshtasticBLE.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
    }

    private func record(id: UUID, name: String?, rssi: Int?) {
        lastSeen[id] = Date()
        let device = DiscoveredDevice(address: .bluetooth(uuid: id),
                                      name: name ?? "Meshtastic Radio",
                                      detail: id.uuidString.prefix(8).lowercased() + "…",
                                      rssi: rssi)
        if let index = devices.firstIndex(where: { $0.address == device.address }) {
            // Keep the last known RSSI when a refresh arrives without one.
            devices[index].name = device.name
            if let rssi { devices[index].rssi = rssi }
        } else {
            devices.append(device)
            devices.sort { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
        }
    }

    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-12)
        let expired = lastSeen.filter { $0.value < cutoff }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired { lastSeen[id] = nil }
        devices.removeAll { device in
            if case .bluetooth(let uuid) = device.address { return expired.contains(uuid) }
            return false
        }
    }
}

extension BluetoothScanner: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let managerState = central.state
        MainActor.assumeIsolated {
            self.state = managerState
            if managerState == .poweredOn {
                self.beginScanIfPossible()
            } else {
                self.isScanning = false
                self.devices.removeAll()
                self.lastSeen.removeAll()
            }
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager,
                                           didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any],
                                           rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        let id = peripheral.identifier
        // Prefer the advertised local name: a freshly flashed radio often has no
        // cached GAP name until after the first connection.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        MainActor.assumeIsolated {
            self.record(id: id, name: name, rssi: rssi == 127 ? nil : rssi)
        }
    }
}
