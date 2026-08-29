import Foundation

/// Everything a transport can tell the radio layer.
public enum TransportEvent: Sendable {
    /// The link is up and ready to carry protobufs.
    case connected
    /// One complete `FromRadio` protobuf, already de-framed.
    case payload(Data)
    /// Free-form device log output (serial debug prints, BLE log characteristic).
    case deviceLog(String)
    /// Transport-level status worth surfacing while connecting.
    case status(String)
    case disconnected(TransportError?)
}

public enum TransportError: Error, Sendable, LocalizedError {
    case portUnavailable(String)
    case openFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case timedOut
    case bluetoothUnavailable(String)
    case serviceNotFound
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .portUnavailable(let detail): "Port unavailable: \(detail)"
        case .openFailed(let detail): "Could not open connection: \(detail)"
        case .writeFailed(let detail): "Write failed: \(detail)"
        case .readFailed(let detail): "Read failed: \(detail)"
        case .timedOut: "The device did not respond in time."
        case .bluetoothUnavailable(let detail): "Bluetooth unavailable: \(detail)"
        case .serviceNotFound: "This device does not expose the Meshtastic BLE service."
        case .cancelled: "The connection was cancelled."
        }
    }
}

/// How to reach a radio. Persisted so MeshDash can reconnect on launch.
public enum DeviceAddress: Sendable, Hashable, Codable {
    case serial(path: String)
    case tcp(host: String, port: UInt16)
    case bluetooth(uuid: UUID)
    /// A Meshpoint gateway's dashboard API, which is not the Meshtastic client
    /// API and so gets its own transport.
    case meshpoint(host: String, port: UInt16)

    public var kind: TransportKind {
        switch self {
        case .serial: .serial
        case .tcp: .tcp
        case .bluetooth: .bluetooth
        case .meshpoint: .meshpoint
        }
    }

    /// Canonical identity for storage. The Codable encoding is not guaranteed to
    /// produce a byte-identical string for the same value, so using it as a
    /// database key silently created duplicate rows for one device.
    public var storageKey: String {
        switch self {
        case .serial(let path): "serial:\(path)"
        case .tcp(let host, let port): "tcp:\(host):\(port)"
        case .bluetooth(let uuid): "ble:\(uuid.uuidString)"
        case .meshpoint(let host, let port): "meshpoint:\(host):\(port)"
        }
    }
}

public enum TransportKind: String, Sendable, CaseIterable, Codable {
    case serial, bluetooth, tcp, meshpoint

    public var displayName: String {
        switch self {
        case .serial: "USB Serial"
        case .bluetooth: "Bluetooth"
        case .tcp: "Network"
        case .meshpoint: "Meshpoint"
        }
    }

    public var symbolName: String {
        switch self {
        case .serial: "cable.connector"
        case .bluetooth: "wave.3.right"
        case .tcp: "network"
        case .meshpoint: "server.rack"
        }
    }
}

/// A radio the user could connect to, as surfaced by discovery.
public struct DiscoveredDevice: Sendable, Identifiable, Hashable {
    public var address: DeviceAddress
    public var name: String
    public var detail: String
    /// BLE advertisement RSSI, when known.
    public var rssi: Int?

    public var id: DeviceAddress { address }

    public init(address: DeviceAddress, name: String, detail: String, rssi: Int? = nil) {
        self.address = address
        self.name = name
        self.detail = detail
        self.rssi = rssi
    }
}

/// A byte pipe to a radio. Implementations hand back whole `FromRadio` protobufs
/// and accept whole `ToRadio` protobufs; framing is the transport's business.
public protocol MeshTransport: AnyObject, Sendable {
    var address: DeviceAddress { get }
    /// Consumed exactly once by `MeshRadio`.
    func events() -> AsyncStream<TransportEvent>
    func connect() async throws
    func send(_ toRadio: Data) async throws
    func disconnect() async
    /// Largest protobuf the link will carry in one go.
    var maximumPayloadSize: Int { get }
}

public extension MeshTransport {
    var maximumPayloadSize: Int { StreamFraming.maxPayload }
}
