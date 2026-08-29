import Foundation
import MeshtasticProtobufs

/// Options shared by every outgoing mesh packet.
public struct SendOptions: Sendable {
    public var destination: UInt32
    public var channelIndex: Int
    public var wantAck: Bool
    public var hopLimit: UInt32?
    public var priority: MeshPacket.Priority?

    public init(destination: UInt32 = broadcastNodeNum,
                channelIndex: Int = 0,
                wantAck: Bool = false,
                hopLimit: UInt32? = nil,
                priority: MeshPacket.Priority? = nil) {
        self.destination = destination
        self.channelIndex = channelIndex
        self.wantAck = wantAck
        self.hopLimit = hopLimit
        self.priority = priority
    }
}

public extension MeshRadio {

    // MARK: - Packet assembly

    /// Wraps a payload in a `MeshPacket` and hands it to the radio.
    @discardableResult
    func send(_ data: DataMessage, options: SendOptions, packetID: UInt32? = nil) async throws -> UInt32 {
        var packet = MeshPacket()
        packet.id = packetID ?? MeshRadio.makePacketID()
        packet.to = options.destination
        packet.channel = UInt32(options.channelIndex)
        packet.wantAck = options.wantAck
        packet.decoded = data
        if let hopLimit = options.hopLimit { packet.hopLimit = hopLimit }
        if let priority = options.priority { packet.priority = priority }
        return try await send(packet: packet)
    }

    // MARK: - Text messaging

    /// Sends a text message. Returns the packet ID so the caller can match ACKs.
    @discardableResult
    func sendText(_ text: String,
                  options: SendOptions,
                  replyTo: UInt32? = nil,
                  packetID: UInt32? = nil) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)
        if let replyTo { data.replyID = replyTo }
        return try await send(data, options: options, packetID: packetID)
    }

    /// Sends an emoji tapback against an existing message. The firmware marks
    /// these with `emoji = 1` so clients render them as reactions, not messages.
    @discardableResult
    func sendReaction(_ emoji: String,
                      to messageID: UInt32,
                      options: SendOptions,
                      packetID: UInt32? = nil) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .textMessageApp
        data.payload = Data(emoji.utf8)
        data.replyID = messageID
        data.emoji = 1
        return try await send(data, options: options, packetID: packetID)
    }

    /// Sends a high-priority alert, which makes receiving devices buzz or beep.
    @discardableResult
    func sendAlert(_ text: String, options: SendOptions) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .alertApp
        data.payload = Data(text.utf8)
        var options = options
        options.priority = .alert
        return try await send(data, options: options)
    }

    // MARK: - Identity and node database

    /// Broadcasts our own `User` record, optionally asking the peer for theirs.
    @discardableResult
    func sendNodeInfo(_ user: User, options: SendOptions, wantResponse: Bool) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .nodeinfoApp
        data.payload = try user.serializedData()
        data.wantResponse = wantResponse
        return try await send(data, options: options)
    }

    /// Asks a specific node to send us its `User` record.
    @discardableResult
    func requestNodeInfo(from node: UInt32, ourUser: User, channelIndex: Int, hopLimit: UInt32?) async throws -> UInt32 {
        try await sendNodeInfo(ourUser,
                               options: SendOptions(destination: node, channelIndex: channelIndex,
                                                    wantAck: true, hopLimit: hopLimit),
                               wantResponse: true)
    }

    // MARK: - Position

    @discardableResult
    func sendPosition(_ position: Position, options: SendOptions, wantResponse: Bool = false) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .positionApp
        data.payload = try position.serializedData()
        data.wantResponse = wantResponse
        return try await send(data, options: options)
    }

    /// Asks a node to report its position.
    @discardableResult
    func requestPosition(from node: UInt32, ourPosition: Position?, channelIndex: Int, hopLimit: UInt32?) async throws -> UInt32 {
        var position = ourPosition ?? Position()
        position.time = UInt32(Date().timeIntervalSince1970)
        return try await sendPosition(position,
                                      options: SendOptions(destination: node, channelIndex: channelIndex,
                                                           wantAck: true, hopLimit: hopLimit),
                                      wantResponse: true)
    }

    // MARK: - Telemetry

    /// Asks a node for a telemetry reading of the given kind.
    @discardableResult
    func requestTelemetry(from node: UInt32, kind: TelemetryKind, channelIndex: Int, hopLimit: UInt32?) async throws -> UInt32 {
        var telemetry = Telemetry()
        telemetry.time = UInt32(Date().timeIntervalSince1970)
        // An empty variant of the requested type is the documented way to ask.
        switch kind {
        case .device: telemetry.deviceMetrics = DeviceMetrics()
        case .environment: telemetry.environmentMetrics = EnvironmentMetrics()
        case .airQuality: telemetry.airQualityMetrics = AirQualityMetrics()
        case .power: telemetry.powerMetrics = PowerMetrics()
        case .localStats: telemetry.localStats = LocalStats()
        case .health: telemetry.healthMetrics = HealthMetrics()
        case .host: telemetry.hostMetrics = HostMetrics()
        case .trafficManagement: telemetry.trafficManagementStats = TrafficManagementStats()
        }
        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = try telemetry.serializedData()
        data.wantResponse = true
        return try await send(data, options: SendOptions(destination: node, channelIndex: channelIndex,
                                                         wantAck: true, hopLimit: hopLimit))
    }

    // MARK: - Traceroute

    /// Asks the mesh to report the path to a node, in both directions.
    @discardableResult
    func traceroute(to node: UInt32, channelIndex: Int, hopLimit: UInt32?) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .tracerouteApp
        data.payload = try RouteDiscovery().serializedData()
        data.wantResponse = true
        return try await send(data, options: SendOptions(destination: node, channelIndex: channelIndex,
                                                         wantAck: true, hopLimit: hopLimit))
    }

    // MARK: - Waypoints

    @discardableResult
    func sendWaypoint(_ waypoint: Waypoint, options: SendOptions) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .waypointApp
        data.payload = try waypoint.serializedData()
        return try await send(data, options: options)
    }

    /// Deleting a waypoint means broadcasting it with an expiry in the past,
    /// which is how every Meshtastic client signals removal.
    @discardableResult
    func deleteWaypoint(_ waypoint: Waypoint, options: SendOptions) async throws -> UInt32 {
        var expired = waypoint
        expired.expire = 1
        return try await sendWaypoint(expired, options: options)
    }

    // MARK: - Store & Forward

    /// Asks a Store & Forward server to replay recent messages.
    @discardableResult
    func requestStoreForwardHistory(from node: UInt32, messageCount: UInt32, window: UInt32, channelIndex: Int) async throws -> UInt32 {
        var request = StoreAndForward()
        request.rr = .clientHistory
        var history = StoreAndForward.History()
        history.historyMessages = messageCount
        history.window = window
        request.history = history
        var data = DataMessage()
        data.portnum = .storeForwardApp
        data.payload = try request.serializedData()
        data.wantResponse = true
        return try await send(data, options: SendOptions(destination: node, channelIndex: channelIndex, wantAck: true))
    }

    // MARK: - Remote hardware

    @discardableResult
    func remoteHardware(_ message: HardwareMessage, to node: UInt32, channelIndex: Int) async throws -> UInt32 {
        var data = DataMessage()
        data.portnum = .remoteHardwareApp
        data.payload = try message.serializedData()
        data.wantResponse = true
        return try await send(data, options: SendOptions(destination: node, channelIndex: channelIndex, wantAck: true))
    }

    // MARK: - MQTT client proxy

    /// Relays an MQTT payload the radio asked us to publish on its behalf.
    func sendMQTTProxy(_ message: MqttClientProxyMessage) async throws {
        var toRadio = ToRadio()
        toRadio.mqttClientProxyMessage = message
        try await sendRaw(toRadio)
    }
}
