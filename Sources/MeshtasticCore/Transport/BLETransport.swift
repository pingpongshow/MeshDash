import CoreBluetooth
import MeshtasticProtobufs
import Foundation
import Synchronization

/// Bluetooth Low Energy link to a radio.
///
/// Unlike Serial and TCP there is no stream framing here: each characteristic
/// write carries exactly one `ToRadio`, and each successful read of FROMRADIO
/// returns exactly one `FromRadio`. A zero-length read means the device queue is
/// drained, which is our cue to stop reading until FROMNUM fires again.
public final class BLETransport: NSObject, MeshTransport, @unchecked Sendable {
    public let address: DeviceAddress
    private let peripheralID: UUID

    private struct State {
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var isClosing = false
        var isDraining = false
        /// Set when FROMNUM fires mid-drain, so we sweep again once the current read lands.
        var drainAgain = false
        var pendingWrites: [Data] = []
        var isWriting = false
        /// Set once the FROMNUM subscription is confirmed by the peripheral.
        var isSubscribed = false
        var didAnnounceReady = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "MeshDash.BLE")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var scanDeadline: DispatchWorkItem?

    public init(peripheralID: UUID) {
        self.peripheralID = peripheralID
        self.address = .bluetooth(uuid: peripheralID)
        super.init()
    }

    public var maximumPayloadSize: Int {
        peripheral?.maximumWriteValueLength(for: .withResponse) ?? 512
    }

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
    }

    public func connect() async throws {
        state.withLock {
            $0.isClosing = false
            $0.isSubscribed = false
            $0.didAnnounceReady = false
        }
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connectContinuation = resume
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: true])
            }
        }
    }

    public func send(_ toRadioBytes: Data) async throws {
        guard !state.withLock({ $0.isClosing }) else {
            throw TransportError.writeFailed("Bluetooth connection is closed.")
        }
        state.withLock { $0.pendingWrites.append(toRadioBytes) }
        queue.async { self.pumpWrites() }
    }

    public func disconnect() async {
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        queue.async {
            self.scanDeadline?.cancel()
            self.central?.stopScan()
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.central = nil
        }
        stream?.yield(.disconnected(nil))
        stream?.finish()
    }

    // MARK: - Internals

    private func emit(_ event: TransportEvent) {
        state.withLock { $0.continuation }?.yield(event)
    }

    private func failConnect(_ error: TransportError) {
        if let resume = connectContinuation {
            connectContinuation = nil
            resume.resume(throwing: error)
        } else {
            let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
                guard !$0.isClosing else { return nil }
                $0.isClosing = true
                let stream = $0.continuation
                $0.continuation = nil
                return stream
            }
            stream?.yield(.disconnected(error))
            stream?.finish()
        }
    }

    private func locatePeripheral() {
        guard let central else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            attach(known)
            central.connect(known, options: nil)
            return
        }
        if let connected = central.retrieveConnectedPeripherals(withServices: [MeshtasticBLE.serviceUUID])
            .first(where: { $0.identifier == peripheralID }) {
            attach(connected)
            central.connect(connected, options: nil)
            return
        }
        // Not in the system cache — fall back to a bounded scan for it.
        emit(.status("Looking for the radio…"))
        central.scanForPeripherals(withServices: [MeshtasticBLE.serviceUUID], options: nil)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.failConnect(.timedOut)
        }
        scanDeadline = deadline
        queue.asyncAfter(deadline: .now() + 15, execute: deadline)
    }

    private func attach(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
    }

    private func pumpWrites() {
        guard let peripheral, let toRadio else { return }
        let next: Data? = state.withLock {
            guard !$0.isWriting, !$0.pendingWrites.isEmpty else { return nil }
            $0.isWriting = true
            return $0.pendingWrites.removeFirst()
        }
        guard let next else { return }
        peripheral.writeValue(next, for: toRadio, type: .withResponse)
    }

    /// Read FROMRADIO until it comes back empty.
    private func startDrain() {
        guard let peripheral, let fromRadio else { return }
        let shouldStart: Bool = state.withLock {
            if $0.isDraining {
                $0.drainAgain = true
                return false
            }
            $0.isDraining = true
            return true
        }
        guard shouldStart else { return }
        peripheral.readValue(for: fromRadio)
    }

    private func continueDrain(gotData: Bool) {
        guard let peripheral, let fromRadio, !state.withLock({ $0.isClosing }) else {
            state.withLock { $0.isDraining = false }
            return
        }
        if gotData {
            peripheral.readValue(for: fromRadio)
            return
        }
        let sweepAgain: Bool = state.withLock {
            if $0.drainAgain {
                $0.drainAgain = false
                return true
            }
            $0.isDraining = false
            return false
        }
        if sweepAgain { peripheral.readValue(for: fromRadio) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            locatePeripheral()
        case .poweredOff:
            failConnect(.bluetoothUnavailable("Bluetooth is turned off."))
        case .unauthorized:
            failConnect(.bluetoothUnavailable("MeshDash is not allowed to use Bluetooth. Grant access in System Settings › Privacy & Security › Bluetooth."))
        case .unsupported:
            failConnect(.bluetoothUnavailable("This Mac does not support Bluetooth Low Energy."))
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == peripheralID else { return }
        scanDeadline?.cancel()
        central.stopScan()
        attach(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.status("Discovering services…"))
        peripheral.discoverServices([MeshtasticBLE.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failConnect(.openFailed(error?.localizedDescription ?? "Could not connect to the radio."))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let transportError: TransportError? = error.map { .readFailed($0.localizedDescription) }
        if connectContinuation != nil {
            failConnect(transportError ?? .openFailed("The radio disconnected during setup."))
            return
        }
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        stream?.yield(.disconnected(transportError))
        stream?.finish()
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failConnect(.openFailed(error.localizedDescription))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == MeshtasticBLE.serviceUUID }) else {
            failConnect(.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics(MeshtasticBLE.allCharacteristics, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            failConnect(.openFailed(error.localizedDescription))
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case MeshtasticBLE.toRadioUUID: toRadio = characteristic
            case MeshtasticBLE.fromRadioUUID: fromRadio = characteristic
            case MeshtasticBLE.fromNumUUID:
                fromNum = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case MeshtasticBLE.logRadioUUID, MeshtasticBLE.legacyLogRadioUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        guard toRadio != nil, fromRadio != nil, fromNum != nil else {
            failConnect(.serviceNotFound)
            return
        }
        emit(.status("Subscribing to radio updates…"))
        // Readiness is announced from didUpdateNotificationStateFor, once the
        // FROMNUM subscription is live. Announcing here would let the config
        // request go out before the radio could notify us of the reply.
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == MeshtasticBLE.fromNumUUID else { return }
        if let error {
            failConnect(.openFailed("Could not subscribe to the radio: \(error.localizedDescription)"))
            return
        }
        state.withLock { $0.isSubscribed = true }
        announceReadyIfNeeded()
    }

    /// Resumes the connect continuation and tells the radio layer the link is
    /// usable. Safe to call more than once.
    private func announceReadyIfNeeded() {
        let shouldAnnounce = state.withLock { state -> Bool in
            guard state.isSubscribed, !state.didAnnounceReady else { return false }
            state.didAnnounceReady = true
            return true
        }
        guard shouldAnnounce else { return }
        if let resume = connectContinuation {
            connectContinuation = nil
            resume.resume()
        }
        emit(.connected)
        // Clear anything the radio queued before we attached.
        startDrain()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // A pairing failure surfaces here; it is fatal for this session.
            if characteristic.uuid == MeshtasticBLE.fromRadioUUID {
                state.withLock { $0.isDraining = false }
                emit(.status("Read failed: \(error.localizedDescription)"))
            }
            return
        }
        switch characteristic.uuid {
        case MeshtasticBLE.fromRadioUUID:
            let payload = characteristic.value ?? Data()
            if !payload.isEmpty { emit(.payload(payload)) }
            continueDrain(gotData: !payload.isEmpty)
        case MeshtasticBLE.fromNumUUID:
            startDrain()
        case MeshtasticBLE.logRadioUUID, MeshtasticBLE.legacyLogRadioUUID:
            if let value = characteristic.value {
                emit(.deviceLog(decodeLog(value, structured: characteristic.uuid == MeshtasticBLE.logRadioUUID)))
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == MeshtasticBLE.toRadioUUID else { return }
        state.withLock { $0.isWriting = false }
        if let error {
            emit(.status("Write failed: \(error.localizedDescription)"))
        }
        pumpWrites()
        // Every ToRadio produces a reply the radio queues for us to read. Do not
        // rely solely on FROMNUM: a notification that arrives before we finish
        // subscribing, or is coalesced with another, would otherwise strand the
        // session waiting for data that is already sitting there.
        startDrain()
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startDrain() }
    }

    private func decodeLog(_ value: Data, structured: Bool) -> String {
        if structured, let record = try? LogRecord(serializedBytes: value) {
            return record.message.hasSuffix("\n") ? record.message : record.message + "\n"
        }
        let text = String(decoding: value, as: UTF8.self)
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}
