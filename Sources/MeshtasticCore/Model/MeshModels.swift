import Foundation
import MeshtasticProtobufs

public let broadcastNodeNum: UInt32 = 0xFFFF_FFFF

/// Where a message lives: a channel everybody on that channel sees, or a
/// one-to-one thread with another node.
public enum ConversationKey: Hashable, Sendable, Codable {
    case channel(Int)
    case direct(UInt32)

    public var channelIndex: Int? {
        if case .channel(let index) = self { return index }
        return nil
    }

    public var directNodeNum: UInt32? {
        if case .direct(let num) = self { return num }
        return nil
    }

    /// Stable string form used as the SQLite primary key component.
    public var storageKey: String {
        switch self {
        case .channel(let index): "ch:\(index)"
        case .direct(let num): "dm:\(num)"
        }
    }

    public init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "ch": guard let index = Int(parts[1]) else { return nil }; self = .channel(index)
        case "dm": guard let num = UInt32(parts[1]) else { return nil }; self = .direct(num)
        default: return nil
        }
    }
}

public enum MessageStatus: Int, Sendable, Codable, CaseIterable {
    /// Handed to the radio, not yet confirmed on air.
    case queued = 0
    /// The radio confirmed it transmitted.
    case sent = 1
    /// A routing ACK came back from the destination or an intermediate router.
    case delivered = 2
    /// Routing returned an error, or we gave up waiting.
    case failed = 3
    /// An inbound message; status does not apply.
    case received = 4

    public var isOutgoing: Bool { self != .received }

    public var symbolName: String {
        switch self {
        case .queued: "clock"
        case .sent: "checkmark"
        case .delivered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .received: "arrow.down.circle"
        }
    }

    public var label: String {
        switch self {
        case .queued: "Sending"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .failed: "Failed"
        case .received: "Received"
        }
    }
}

/// A text message, reaction, or alert in a conversation.
public struct MeshMessage: Identifiable, Sendable, Hashable {
    public var id: UInt32
    public var conversation: ConversationKey
    public var fromNode: UInt32
    public var toNode: UInt32
    public var text: String
    public var timestamp: Date
    public var status: MessageStatus
    /// Non-nil when this message is an emoji tapback on another message.
    public var reactionTo: UInt32?
    /// Non-nil when the sender was quoting an earlier message.
    public var replyTo: UInt32?
    public var isEmojiReaction: Bool
    public var snr: Float?
    public var rssi: Int?
    public var hopsAway: Int?
    public var viaMQTT: Bool
    public var channelIndex: Int
    public var portnum: PortNum
    public var failureReason: String?
    /// Set when the radio told us the payload was PKI-encrypted end to end.
    public var isPKIEncrypted: Bool
    public var isRead: Bool

    public init(id: UInt32,
                conversation: ConversationKey,
                fromNode: UInt32,
                toNode: UInt32,
                text: String,
                timestamp: Date,
                status: MessageStatus,
                reactionTo: UInt32? = nil,
                replyTo: UInt32? = nil,
                isEmojiReaction: Bool = false,
                snr: Float? = nil,
                rssi: Int? = nil,
                hopsAway: Int? = nil,
                viaMQTT: Bool = false,
                channelIndex: Int = 0,
                portnum: PortNum = .textMessageApp,
                failureReason: String? = nil,
                isPKIEncrypted: Bool = false,
                isRead: Bool = false) {
        self.id = id
        self.conversation = conversation
        self.fromNode = fromNode
        self.toNode = toNode
        self.text = text
        self.timestamp = timestamp
        self.status = status
        self.reactionTo = reactionTo
        self.replyTo = replyTo
        self.isEmojiReaction = isEmojiReaction
        self.snr = snr
        self.rssi = rssi
        self.hopsAway = hopsAway
        self.viaMQTT = viaMQTT
        self.channelIndex = channelIndex
        self.portnum = portnum
        self.failureReason = failureReason
        self.isPKIEncrypted = isPKIEncrypted
        self.isRead = isRead
    }
}

/// A point on a node's track.
public struct PositionSample: Sendable, Hashable, Identifiable {
    public var id: String { "\(nodeNum)-\(Int(time.timeIntervalSince1970))" }
    public var nodeNum: UInt32
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Int32?
    public var speedKmH: Double?
    public var headingDegrees: Double?
    public var satellites: Int?
    /// Location precision in bits as configured on the sending node; fewer bits
    /// means the position was deliberately fuzzed before transmission.
    public var precisionBits: Int?

    public init(nodeNum: UInt32, time: Date, latitude: Double, longitude: Double,
                altitude: Int32? = nil, speedKmH: Double? = nil, headingDegrees: Double? = nil,
                satellites: Int? = nil, precisionBits: Int? = nil) {
        self.nodeNum = nodeNum
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedKmH = speedKmH
        self.headingDegrees = headingDegrees
        self.satellites = satellites
        self.precisionBits = precisionBits
    }

    /// Radius in metres that the sender's precision setting implies.
    public var precisionRadiusMeters: Double? {
        guard let precisionBits, precisionBits > 0, precisionBits < 32 else { return nil }
        // Each dropped bit doubles the uncertainty of the 32-bit fixed-point degree value.
        let degreeSpan = Double(1 << (32 - precisionBits)) * 1e-7
        return max(10, degreeSpan * 111_320 / 2)
    }
}

public enum TelemetryKind: String, Sendable, Codable, CaseIterable {
    case device, environment, airQuality, power, localStats, health, host, trafficManagement

    public var displayName: String {
        switch self {
        case .device: "Device"
        case .environment: "Environment"
        case .airQuality: "Air Quality"
        case .power: "Power"
        case .localStats: "Local Stats"
        case .health: "Health"
        case .host: "Host"
        case .trafficManagement: "Traffic"
        }
    }

    public var symbolName: String {
        switch self {
        case .device: "cpu"
        case .environment: "thermometer.medium"
        case .airQuality: "aqi.medium"
        case .power: "bolt"
        case .localStats: "chart.bar"
        case .health: "heart"
        case .host: "server.rack"
        case .trafficManagement: "arrow.left.arrow.right"
        }
    }
}

/// One decoded telemetry packet, flattened into named metrics so charts and the
/// database do not need to know about every protobuf field individually.
public struct TelemetrySample: Sendable, Hashable, Identifiable {
    public var id: String { "\(nodeNum)-\(kind.rawValue)-\(Int(time.timeIntervalSince1970))" }
    public var nodeNum: UInt32
    public var kind: TelemetryKind
    public var time: Date
    public var metrics: [String: Double]

    public init(nodeNum: UInt32, kind: TelemetryKind, time: Date, metrics: [String: Double]) {
        self.nodeNum = nodeNum
        self.kind = kind
        self.time = time
        self.metrics = metrics
    }
}

/// A node in the mesh, as we understand it right now.
public struct MeshNode: Identifiable, Sendable, Hashable {
    public var num: UInt32
    public var user: User?
    public var position: Position?
    public var deviceMetrics: DeviceMetrics?
    public var environmentMetrics: EnvironmentMetrics?
    public var airQualityMetrics: AirQualityMetrics?
    public var powerMetrics: PowerMetrics?
    public var healthMetrics: HealthMetrics?
    public var lastHeard: Date?
    public var snr: Float?
    public var rssi: Int?
    public var hopsAway: Int?
    public var channel: Int
    public var viaMQTT: Bool
    public var isFavorite: Bool
    public var isIgnored: Bool
    public var isMuted: Bool
    public var isKeyManuallyVerified: Bool
    /// Populated from the Neighbor Info module.
    public var neighbors: [Neighbor]
    public var neighborsUpdated: Date?
    /// Last seen paxcounter reading, if this node runs that module.
    public var paxWifi: UInt32?
    public var paxBle: UInt32?
    public var paxUptime: UInt32?

    public var id: UInt32 { num }

    public init(num: UInt32) {
        self.num = num
        self.channel = 0
        self.viaMQTT = false
        self.isFavorite = false
        self.isIgnored = false
        self.isMuted = false
        self.isKeyManuallyVerified = false
        self.neighbors = []
    }

    // MARK: - Presentation

    /// Meshtastic's canonical `!aabbccdd` node identifier.
    public var hexID: String { String(format: "!%08x", num) }

    public var longName: String {
        if let name = user?.longName, !name.isEmpty { return name }
        return "Meshtastic \(String(format: "%04x", num & 0xFFFF))"
    }

    public var shortName: String {
        if let name = user?.shortName, !name.isEmpty { return name }
        return String(format: "%04x", num & 0xFFFF)
    }

    public var role: Config.DeviceConfig.Role { user?.role ?? .client }
    public var hardwareModel: HardwareModel { user?.hwModel ?? .unset }

    /// A node can carry a public key without being reachable over PKI if the key
    /// slot is empty, so check the payload rather than the flag.
    public var hasPublicKey: Bool { !(user?.publicKey.isEmpty ?? true) }

    public var isUnmessagable: Bool {
        guard let user else { return false }
        return user.hasIsUnmessagable ? user.isUnmessagable : false
    }

    public var batteryLevel: Int? {
        guard let level = deviceMetrics?.batteryLevel, level > 0 else { return nil }
        // The firmware reports 101 for "plugged in, no battery".
        return level > 100 ? nil : Int(level)
    }

    public var isPluggedIn: Bool { (deviceMetrics?.batteryLevel ?? 0) > 100 }

    public var coordinate: (latitude: Double, longitude: Double)? {
        guard let position, position.latitudeI != 0 || position.longitudeI != 0 else { return nil }
        return (Double(position.latitudeI) * 1e-7, Double(position.longitudeI) * 1e-7)
    }

    public var isOnline: Bool {
        guard let lastHeard else { return false }
        // The apps treat two hours of silence as offline.
        return Date().timeIntervalSince(lastHeard) < 2 * 60 * 60
    }
}

/// Result of a traceroute request, in both directions.
public struct TracerouteResult: Sendable, Identifiable, Hashable {
    public struct Hop: Sendable, Hashable {
        public var nodeNum: UInt32
        public var snr: Float?
        public init(nodeNum: UInt32, snr: Float?) {
            self.nodeNum = nodeNum
            self.snr = snr
        }
    }

    public var id: UInt32
    public var target: UInt32
    public var requestedAt: Date
    public var completedAt: Date?
    /// Hops from us to the target, excluding both endpoints.
    public var forwardRoute: [Hop]
    /// Hops on the reply path, excluding both endpoints.
    public var returnRoute: [Hop]
    public var failureReason: String?

    public init(id: UInt32, target: UInt32, requestedAt: Date) {
        self.id = id
        self.target = target
        self.requestedAt = requestedAt
        self.forwardRoute = []
        self.returnRoute = []
    }

    public var isComplete: Bool { completedAt != nil }
}

/// A raw packet retained for the packet inspector.
public struct PacketLogEntry: Sendable, Identifiable {
    public var id: UUID = UUID()
    public var time: Date
    public var direction: Direction
    public var summary: String
    public var detail: String
    public var portnum: PortNum?
    public var fromNode: UInt32?
    public var toNode: UInt32?

    public enum Direction: String, Sendable { case inbound, outbound, system }

    public init(time: Date, direction: Direction, summary: String, detail: String,
                portnum: PortNum? = nil, fromNode: UInt32? = nil, toNode: UInt32? = nil) {
        self.time = time
        self.direction = direction
        self.summary = summary
        self.detail = detail
        self.portnum = portnum
        self.fromNode = fromNode
        self.toNode = toNode
    }
}
