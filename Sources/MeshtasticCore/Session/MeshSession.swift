import Foundation
import MeshtasticProtobufs
import Observation
import SwiftProtobuf

/// The application's live view of one radio and the mesh it can see.
///
/// Owns the connection, decodes every packet the radio hands up, keeps the node
/// database and conversations in memory, and mirrors all of it to `MeshStore`
/// so history survives a restart.
@MainActor
@Observable
public final class MeshSession {

    // MARK: - Connection

    public private(set) var connectionState: RadioConnectionState = .disconnected
    public private(set) var connectedDevice: DiscoveredDevice?
    public var isConnected: Bool { connectionState.isConnected }

    /// Reconnect automatically when a link drops unexpectedly.
    public var automaticallyReconnects = true
    public private(set) var reconnectAttempt = 0

    // MARK: - Identity

    public private(set) var myNodeNum: UInt32 = 0
    public private(set) var myInfo: MyNodeInfo?
    public private(set) var metadata: DeviceMetadata?
    public var myNode: MeshNode? { nodes[myNodeNum] }

    // MARK: - Configuration

    public private(set) var deviceConfig = Config.DeviceConfig()
    public private(set) var positionConfig = Config.PositionConfig()
    public private(set) var powerConfig = Config.PowerConfig()
    public private(set) var networkConfig = Config.NetworkConfig()
    public private(set) var displayConfig = Config.DisplayConfig()
    public private(set) var loraConfig = Config.LoRaConfig()
    public private(set) var bluetoothConfig = Config.BluetoothConfig()
    public private(set) var securityConfig = Config.SecurityConfig()
    public private(set) var deviceUIConfig = DeviceUIConfig()

    public private(set) var mqttConfig = ModuleConfig.MQTTConfig()
    public private(set) var serialModuleConfig = ModuleConfig.SerialConfig()
    public private(set) var externalNotificationConfig = ModuleConfig.ExternalNotificationConfig()
    public private(set) var storeForwardConfig = ModuleConfig.StoreForwardConfig()
    public private(set) var rangeTestConfig = ModuleConfig.RangeTestConfig()
    public private(set) var telemetryConfig = ModuleConfig.TelemetryConfig()
    public private(set) var cannedMessageConfig = ModuleConfig.CannedMessageConfig()
    public private(set) var audioConfig = ModuleConfig.AudioConfig()
    public private(set) var remoteHardwareConfig = ModuleConfig.RemoteHardwareConfig()
    public private(set) var neighborInfoConfig = ModuleConfig.NeighborInfoConfig()
    public private(set) var ambientLightingConfig = ModuleConfig.AmbientLightingConfig()
    public private(set) var detectionSensorConfig = ModuleConfig.DetectionSensorConfig()
    public private(set) var paxcounterConfig = ModuleConfig.PaxcounterConfig()
    public private(set) var statusMessageConfig = ModuleConfig.StatusMessageConfig()
    public private(set) var trafficManagementConfig = ModuleConfig.TrafficManagementConfig()
    public private(set) var takConfig = ModuleConfig.TAKConfig()
    public private(set) var meshBeaconConfig = ModuleConfig.MeshBeaconConfig()

    /// Present only after an explicit read, since the radio does not stream them.
    public private(set) var cannedMessages: String?
    public private(set) var ringtone: String?
    public private(set) var connectionStatus: DeviceConnectionStatus?
    public private(set) var remoteHardwarePins: NodeRemoteHardwarePinsResponse?
    public private(set) var regionPresets: LoRaRegionPresetMap?
    public private(set) var lockdownStatus: LockdownStatus?

    // MARK: - Mesh contents

    public private(set) var nodes: [UInt32: MeshNode] = [:]
    public private(set) var channels: [Channel] = []
    public private(set) var messages: [MeshMessage] = []
    public private(set) var waypoints: [UInt32: (waypoint: Waypoint, from: UInt32)] = [:]
    public private(set) var traceroutes: [TracerouteResult] = []
    public private(set) var packetLog: [PacketLogEntry] = []
    public private(set) var deviceLogLines: [String] = []

    /// Latest local statistics from the connected radio.
    public private(set) var localStats: LocalStats?
    public private(set) var queueStatus: QueueStatus?

    /// Surfaced to the UI as a transient banner.
    public struct Notice: Identifiable, Sendable {
        public var id = UUID()
        public var title: String
        public var detail: String
        public var isError: Bool
        public var time = Date()
    }
    public private(set) var notices: [Notice] = []

    /// Fires for each newly received message so the app can post a notification.
    public var onIncomingMessage: (@MainActor (MeshMessage, MeshNode?) -> Void)?

    // MARK: - Internals

    private let store: MeshStore
    private var radio: MeshRadio?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Packet IDs we are waiting on ACKs for, so routing replies can be matched.
    private var pendingAcks: [UInt32: ConversationKey] = [:]
    private var pendingTraceroutes: Set<UInt32> = []
    /// Admin requests we sent, so responses can be attributed to the right node.
    private var pendingAdminRequests: [UInt32: UInt32] = [:]
    private var storeLoaded = false
    /// Whether this device has ever reached a usable link. A device that has
    /// never worked is probably misconfigured, so we stop retrying it.
    private var hasEverLinked = false

    /// Cap the in-memory packet log; the UI only ever shows a window of it.
    private let packetLogLimit = 2000
    private let deviceLogLimit = 2000

    public var radioID: String { myNodeNum == 0 ? "unidentified" : String(myNodeNum) }

    public init(store: MeshStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    public func connect(to device: DiscoveredDevice) async {
        await teardown(keepingDevice: device)
        connectedDevice = device
        reconnectAttempt = 0
        hasEverLinked = false
        await openLink(to: device)
    }

    private func openLink(to device: DiscoveredDevice) async {
        connectionState = .connecting(device.name)
        let transport: any MeshTransport
        switch device.address {
        case .serial(let path): transport = SerialTransport(path: path)
        case .tcp(let host, let port): transport = TCPTransport(host: host, port: port)
        case .bluetooth(let uuid): transport = BLETransport(peripheralID: uuid)
        case .meshpoint(let host, let port): transport = MeshpointTransport(host: host, port: port)
        }

        let radio = MeshRadio(transport: transport)
        self.radio = radio
        do {
            let events = try await radio.connect()
            eventTask = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
            post(title: "Could not connect", detail: error.localizedDescription, isError: true)
            scheduleReconnectIfNeeded()
        }
    }

    public func disconnect() async {
        automaticallyReconnectsSuspended = true
        await teardown(keepingDevice: nil)
        connectionState = .disconnected
        automaticallyReconnectsSuspended = false
    }

    /// Set while an intentional disconnect is in flight so the drop does not
    /// trigger the reconnect timer.
    private var automaticallyReconnectsSuspended = false

    private func teardown(keepingDevice device: DiscoveredDevice?) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventTask?.cancel()
        eventTask = nil
        if let radio { await radio.disconnect() }
        radio = nil
        pendingAcks.removeAll()
        pendingAdminRequests.removeAll()
        pendingTraceroutes.removeAll()
        if device == nil { connectedDevice = nil }
    }

    /// How many times to retry a device that has never once linked, before
    /// concluding the address or the device itself is wrong.
    private let coldRetryLimit = 3

    private func scheduleReconnectIfNeeded() {
        guard automaticallyReconnects, !automaticallyReconnectsSuspended,
              let device = connectedDevice else { return }
        guard hasEverLinked || reconnectAttempt < coldRetryLimit else {
            post(title: "Gave up connecting to \(device.name)",
                 detail: "MeshDash could not reach it after \(reconnectAttempt) attempts and has stopped retrying. Check the address, or pick a different device.",
                 isError: true)
            return
        }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        // Back off gently, capped so a radio that comes back is picked up quickly.
        let delay = min(30, Int(pow(2.0, Double(min(reconnectAttempt, 5)))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.openLink(to: device)
        }
    }

    // MARK: - Event handling

    private var isSyncing: Bool {
        if case .syncing = connectionState { return true }
        return false
    }

    private func handle(_ event: RadioEvent) async {
        switch event {
        case .status(let text):
            // Only a progress note; never let it undo a more advanced state.
            if connectionState.isBusy, !isSyncing {
                connectionState = .connecting(text)
            }
        case .linkUp:
            connectionState = .syncing(nodesReceived: 0)
            reconnectAttempt = 0
            hasEverLinked = true
            // Remember the radio as soon as the link is usable. Waiting for a
            // full sync would lose the device from Recents whenever the
            // handshake is interrupted, which is exactly when reconnecting
            // matters most.
            if let device = connectedDevice {
                try? await persistentStore.rememberDevice(device)
            }
        case .configComplete:
            connectionState = .connected
            await finishSync()
        case .myInfo(let info):
            myInfo = info
            myNodeNum = info.myNodeNum
            await loadPersistedStateIfNeeded()
        case .metadata(let data):
            metadata = data
        case .nodeInfo(let info):
            await apply(nodeInfo: info)
            if case .syncing(let count) = connectionState {
                connectionState = .syncing(nodesReceived: count + 1)
            }
        case .config(let config):
            apply(config: config)
        case .moduleConfig(let config):
            apply(moduleConfig: config)
        case .deviceUIConfig(let config):
            deviceUIConfig = config
        case .channel(let channel):
            apply(channel: channel)
        case .packet(let packet):
            await handle(packet: packet)
        case .queueStatus(let status):
            queueStatus = status
        case .clientNotification(let notification):
            handle(notification: notification)
        case .regionPresets(let presets):
            regionPresets = presets
        case .lockdownStatus(let status):
            lockdownStatus = status
        case .fileInfo, .xmodem:
            break
        case .mqttProxyMessage(let message):
            logPacket(direction: .system, summary: "MQTT proxy → \(message.topic)",
                      detail: "The radio asked the app to relay \(message.payloadVariant != nil ? "a payload" : "an empty message") to its MQTT broker.")
        case .rebooted:
            post(title: "Radio rebooted", detail: "Reloading configuration…", isError: false)
            connectionState = .syncing(nodesReceived: 0)
        case .deviceLog(let text):
            appendDeviceLog(text)
        case .logRecord(let record):
            appendDeviceLog(record.message + "\n")
        case .decodeFailure(let text):
            logPacket(direction: .system, summary: "Decode failure", detail: text)
        case .disconnected(let error):
            await teardown(keepingDevice: connectedDevice)
            if let error {
                connectionState = .failed(error.localizedDescription)
                post(title: "Connection lost", detail: error.localizedDescription, isError: true)
            } else {
                connectionState = .disconnected
            }
            scheduleReconnectIfNeeded()
        }
    }

    private func loadPersistedStateIfNeeded() async {
        guard !storeLoaded, myNodeNum != 0 else { return }
        storeLoaded = true
        let id = radioID
        do {
            let saved = try await store.loadNodes(radioID: id)
            for node in saved where nodes[node.num] == nil {
                nodes[node.num] = node
            }
            messages = try await store.loadMessages(radioID: id)
            for entry in try await store.loadWaypoints(radioID: id) {
                waypoints[entry.waypoint.id] = entry
            }
            traceroutes = try await store.loadTraceroutes(radioID: id)
        } catch {
            post(title: "Could not load history", detail: error.localizedDescription, isError: true)
        }
    }

    private func finishSync() async {
        await loadPersistedStateIfNeeded()
        // Persist whatever the radio just told us about its node database.
        let id = radioID
        for node in nodes.values {
            try? await store.saveNode(node, radioID: id)
        }
        // Drop history the user has said they do not want to keep.
        if historyRetentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(historyRetentionDays) * 86_400)
            try? await store.pruneHistory(olderThan: cutoff)
        }
    }

    /// How long position and telemetry history is kept. Zero keeps everything.
    public var historyRetentionDays: Int = 90

    // MARK: - Config application

    private func apply(config: Config) {
        guard let variant = config.payloadVariant else { return }
        switch variant {
        case .device(let value): deviceConfig = value
        case .position(let value): positionConfig = value
        case .power(let value): powerConfig = value
        case .network(let value): networkConfig = value
        case .display(let value): displayConfig = value
        case .lora(let value): loraConfig = value
        case .bluetooth(let value): bluetoothConfig = value
        case .security(let value): securityConfig = value
        case .sessionkey: break
        case .deviceUi(let value): deviceUIConfig = value
        }
    }

    private func apply(moduleConfig: ModuleConfig) {
        guard let variant = moduleConfig.payloadVariant else { return }
        switch variant {
        case .mqtt(let value): mqttConfig = value
        case .serial(let value): serialModuleConfig = value
        case .externalNotification(let value): externalNotificationConfig = value
        case .storeForward(let value): storeForwardConfig = value
        case .rangeTest(let value): rangeTestConfig = value
        case .telemetry(let value): telemetryConfig = value
        case .cannedMessage(let value): cannedMessageConfig = value
        case .audio(let value): audioConfig = value
        case .remoteHardware(let value): remoteHardwareConfig = value
        case .neighborInfo(let value): neighborInfoConfig = value
        case .ambientLighting(let value): ambientLightingConfig = value
        case .detectionSensor(let value): detectionSensorConfig = value
        case .paxcounter(let value): paxcounterConfig = value
        case .statusmessage(let value): statusMessageConfig = value
        case .trafficManagement(let value): trafficManagementConfig = value
        case .tak(let value): takConfig = value
        case .meshBeacon(let value): meshBeaconConfig = value
        }
    }

    private func apply(channel: Channel) {
        let index = Int(channel.index)
        while channels.count <= index {
            var placeholder = Channel()
            placeholder.index = Int32(channels.count)
            placeholder.role = .disabled
            channels.append(placeholder)
        }
        channels[index] = channel
    }

    private func apply(nodeInfo: NodeInfo) async {
        var node = nodes[nodeInfo.num] ?? MeshNode(num: nodeInfo.num)
        if nodeInfo.hasUser { node.user = nodeInfo.user }
        if nodeInfo.hasPosition, nodeInfo.position.latitudeI != 0 || nodeInfo.position.longitudeI != 0 {
            node.position = nodeInfo.position
        }
        if nodeInfo.hasDeviceMetrics { node.deviceMetrics = nodeInfo.deviceMetrics }
        if nodeInfo.lastHeard > 0 { node.lastHeard = Date(timeIntervalSince1970: TimeInterval(nodeInfo.lastHeard)) }
        if nodeInfo.snr != 0 { node.snr = nodeInfo.snr }
        if nodeInfo.hasHopsAway { node.hopsAway = Int(nodeInfo.hopsAway) }
        node.channel = Int(nodeInfo.channel)
        node.viaMQTT = nodeInfo.viaMqtt
        node.isFavorite = nodeInfo.isFavorite
        node.isIgnored = nodeInfo.isIgnored
        node.isMuted = nodeInfo.isMuted
        node.isKeyManuallyVerified = nodeInfo.isKeyManuallyVerified
        nodes[nodeInfo.num] = node
        try? await store.saveNode(node, radioID: radioID)
    }

    // MARK: - Notices and logs

    public func post(title: String, detail: String, isError: Bool) {
        notices.append(Notice(title: title, detail: detail, isError: isError))
        if notices.count > 50 { notices.removeFirst(notices.count - 50) }
    }

    public func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    public func clearNotices() {
        notices.removeAll()
    }

    func logPacket(direction: PacketLogEntry.Direction, summary: String, detail: String,
                   portnum: PortNum? = nil, from: UInt32? = nil, to: UInt32? = nil) {
        packetLog.append(PacketLogEntry(time: Date(), direction: direction, summary: summary,
                                        detail: detail, portnum: portnum, fromNode: from, toNode: to))
        if packetLog.count > packetLogLimit {
            packetLog.removeFirst(packetLog.count - packetLogLimit)
        }
    }

    public func clearPacketLog() { packetLog.removeAll() }
    public func clearDeviceLog() { deviceLogLines.removeAll() }

    private func appendDeviceLog(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            deviceLogLines.append(line)
        }
        if deviceLogLines.count > deviceLogLimit {
            deviceLogLines.removeFirst(deviceLogLines.count - deviceLogLimit)
        }
    }

    private func handle(notification: ClientNotification) {
        let isError = notification.level == .error || notification.level == .critical
        post(title: notification.message.isEmpty ? "Radio notification" : notification.message,
             detail: notificationDetail(notification), isError: isError)
    }

    private func notificationDetail(_ notification: ClientNotification) -> String {
        switch notification.payloadVariant {
        case .duplicatedPublicKey:
            "Another node is advertising a public key that is already in use. Treat messages from it with suspicion."
        case .lowEntropyKey:
            "This node's key was generated with weak randomness. Regenerate it from the Security settings."
        case .keyVerificationNumberInform(let inform):
            "Key verification code: \(inform.securityNumber)"
        case .keyVerificationNumberRequest:
            "A node asked to verify keys with you."
        case .keyVerificationFinal:
            "Key verification finished."
        case .none:
            ""
        }
    }

    // MARK: - Store access for the UI

    public func positionHistory(for node: UInt32, since: Date? = nil) async -> [PositionSample] {
        (try? await store.positions(for: node, radioID: radioID, since: since)) ?? []
    }

    public func telemetryHistory(for node: UInt32, kind: TelemetryKind, since: Date? = nil) async -> [TelemetrySample] {
        (try? await store.telemetry(for: node, kind: kind, radioID: radioID, since: since)) ?? []
    }

    public func knownDevices() async -> [DiscoveredDevice] {
        (try? await store.knownDevices()) ?? []
    }

    public func forgetDevice(_ address: DeviceAddress) async {
        try? await store.forgetDevice(address)
    }

    // MARK: - Access for the packet handling extension

    var activeRadio: MeshRadio? { radio }
    var persistentStore: MeshStore { store }

    func note(pendingAck packetID: UInt32, conversation: ConversationKey) {
        pendingAcks[packetID] = conversation
    }

    func takePendingAck(_ packetID: UInt32) -> ConversationKey? {
        pendingAcks.removeValue(forKey: packetID)
    }

    func note(pendingTraceroute packetID: UInt32) {
        pendingTraceroutes.insert(packetID)
    }

    func isPendingTraceroute(_ packetID: UInt32) -> Bool {
        pendingTraceroutes.contains(packetID)
    }

    func clearPendingTraceroute(_ packetID: UInt32) {
        pendingTraceroutes.remove(packetID)
    }

    func note(pendingAdmin packetID: UInt32, node: UInt32) {
        pendingAdminRequests[packetID] = node
    }

    func setChannels(_ list: [Channel]) { channels = list }
    func setNode(_ node: MeshNode) { nodes[node.num] = node }
    func removeNodeLocally(_ num: UInt32) { nodes[num] = nil }
    func setMessages(_ list: [MeshMessage]) { messages = list }
    func setLocalStats(_ stats: LocalStats) { localStats = stats }
    func setMetadata(_ value: DeviceMetadata) { metadata = value }
    func setWaypoint(_ waypoint: Waypoint, from node: UInt32) { waypoints[waypoint.id] = (waypoint, node) }
    func removeWaypointLocally(_ id: UInt32) { waypoints[id] = nil }
    func setTraceroutes(_ list: [TracerouteResult]) { traceroutes = list }
    func setCannedMessages(_ value: String) { cannedMessages = value }
    func setRingtone(_ value: String) { ringtone = value }
    func setConnectionStatus(_ value: DeviceConnectionStatus) { connectionStatus = value }
    func setRemoteHardwarePins(_ value: NodeRemoteHardwarePinsResponse) { remoteHardwarePins = value }
    func applyIncoming(config: Config) { apply(config: config) }
    func applyIncoming(moduleConfig: ModuleConfig) { apply(moduleConfig: moduleConfig) }
    func applyIncoming(channel: Channel) { apply(channel: channel) }
}
