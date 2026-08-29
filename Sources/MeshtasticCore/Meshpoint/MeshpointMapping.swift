import Foundation
import MeshtasticProtobufs

/// Translates Meshpoint's JSON into the protobufs the rest of MeshDash speaks.
enum MeshpointMapping {

    // MARK: - Identifiers

    /// Parses the node id forms Meshpoint emits: `!4358aef0`, `0x4358aef0`,
    /// or a bare decimal number.
    static func nodeNum(from identifier: String?) -> UInt32? {
        guard var text = identifier?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("!") { text.removeFirst() }
        if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
        if let hex = UInt32(text, radix: 16) { return hex }
        if let decimal = UInt32(text) { return decimal }
        return nil
    }

    /// Meshpoint keys broadcast conversations as `broadcast:meshtastic:<index>`.
    static func channelIndex(fromConversation identifier: String) -> Int? {
        guard identifier.hasPrefix("broadcast:") else { return nil }
        let parts = identifier.split(separator: ":")
        guard parts.count >= 2, parts[1] == "meshtastic" else { return nil }
        return parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
    }

    /// Packet ids arrive as strings and are sometimes hex, sometimes decimal.
    /// A stable fallback keeps replayed history from colliding in the store.
    static func packetID(_ raw: String?, fallbackSeed: String) -> UInt32 {
        if let raw, !raw.isEmpty, let parsed = nodeNum(from: raw), parsed != 0 {
            return parsed
        }
        // FNV-1a over the seed: deterministic, so re-syncing does not duplicate.
        var hash: UInt32 = 2_166_136_261
        for byte in fallbackSeed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    // MARK: - Configuration

    static func loRaConfig(from configuration: MeshpointAPI.Configuration) -> Config {
        var lora = Config.LoRaConfig()
        if let region = configuration.radio?.region, let code = regionCode(region) {
            lora.region = code
        }
        if let preset = configuration.radio?.current_preset, let modem = modemPreset(preset) {
            lora.usePreset = true
            lora.modemPreset = modem
        } else {
            lora.usePreset = false
            lora.spreadFactor = UInt32(configuration.radio?.spreading_factor ?? 0)
            lora.bandwidth = UInt32(configuration.radio?.bandwidth_khz ?? 0)
        }
        lora.txEnabled = configuration.transmit?.enabled ?? false
        lora.txPower = Int32(configuration.transmit?.tx_power_dbm ?? 0)
        lora.hopLimit = UInt32(configuration.transmit?.hop_limit ?? 3)
        if let frequency = configuration.radio?.frequency_mhz {
            lora.overrideFrequency = Float(frequency)
        }
        var config = Config()
        config.lora = lora
        return config
    }

    /// Meshpoint uses the Meshtastic region identifiers verbatim ("US", "EU_868",
    /// "TH"), which map onto the generated enum's case names.
    static func regionCode(_ raw: String) -> Config.LoRaConfig.RegionCode? {
        let normalized = raw.replacingOccurrences(of: "_", with: "").lowercased()
        for code in Config.LoRaConfig.RegionCode.allCases {
            if case .UNRECOGNIZED = code { continue }
            if String(describing: code).lowercased() == normalized { return code }
        }
        return nil
    }

    static func modemPreset(_ raw: String) -> Config.LoRaConfig.ModemPreset? {
        let normalized = raw.replacingOccurrences(of: "_", with: "").lowercased()
        for preset in Config.LoRaConfig.ModemPreset.allCases {
            if case .UNRECOGNIZED = preset { continue }
            if String(describing: preset).lowercased() == normalized { return preset }
        }
        return nil
    }

    /// The reverse mapping, for writing a preset back to the gateway.
    static func presetName(_ preset: Config.LoRaConfig.ModemPreset) -> String {
        // Meshpoint expects the firmware's SCREAMING_SNAKE spelling.
        var result = ""
        for character in String(describing: preset) {
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(Character(character.uppercased()))
        }
        return result
    }

    static func channels(from configuration: MeshpointAPI.Configuration) -> [Channel] {
        let entries = configuration.channels ?? []
        guard !entries.isEmpty else {
            var channel = Channel()
            channel.index = 0
            channel.role = .primary
            return [channel]
        }
        return entries.enumerated().map { offset, entry in
            var settings = ChannelSettings()
            settings.name = entry.name ?? ""
            if let key = entry.psk_b64, let data = Data(base64Encoded: key) {
                settings.psk = data
            }
            var channel = Channel()
            channel.index = Int32(entry.index ?? offset)
            channel.settings = settings
            channel.role = (entry.index ?? offset) == 0 ? .primary : .secondary
            return channel
        }
    }

    // MARK: - Nodes

    static func selfNodeInfo(from configuration: MeshpointAPI.Configuration, num: UInt32) -> NodeInfo {
        var user = User()
        user.id = String(format: "!%08x", num)
        user.longName = configuration.transmit?.long_name ?? "Meshpoint"
        user.shortName = configuration.transmit?.short_name ?? "MP"
        // A gateway that relays is a router; otherwise it is an observer.
        user.role = (configuration.relay?.enabled ?? false) ? .router : .clientMute

        var info = NodeInfo()
        info.num = num
        info.user = user
        info.lastHeard = UInt32(Date().timeIntervalSince1970)
        return info
    }

    static func nodeInfo(from node: MeshpointAPI.Node) -> NodeInfo? {
        guard let num = nodeNum(from: node.node_id), num != 0 else { return nil }

        var user = User()
        user.id = String(format: "!%08x", num)
        user.longName = node.long_name ?? node.display_name ?? ""
        user.shortName = node.short_name ?? ""
        if let role = node.role, let parsed = deviceRole(role) { user.role = parsed }
        if let hardware = node.hardware_model, let model = hardwareModel(hardware) { user.hwModel = model }
        if let key = node.public_key, let data = Data(base64Encoded: key) { user.publicKey = data }

        var info = NodeInfo()
        info.num = num
        info.user = user
        if let heard = MeshpointDate.parse(node.last_heard) {
            info.lastHeard = UInt32(max(0, heard.timeIntervalSince1970))
        }
        if let latitude = node.latitude, let longitude = node.longitude,
           latitude != 0 || longitude != 0 {
            var position = Position()
            position.latitudeI = Int32(latitude * 1e7)
            position.longitudeI = Int32(longitude * 1e7)
            if let altitude = node.altitude { position.altitude = Int32(altitude) }
            position.time = info.lastHeard
            info.position = position
        }
        if let snr = node.effectiveSNR { info.snr = Float(snr) }
        if let hops = node.latest_hops { info.hopsAway = UInt32(max(0, hops)) }
        if let telemetry = node.effectiveTelemetry, let metrics = deviceMetrics(telemetry) {
            info.deviceMetrics = metrics
        }
        return info
    }

    private static func deviceRole(_ raw: String) -> Config.DeviceConfig.Role? {
        let normalized = raw.replacingOccurrences(of: "_", with: "").lowercased()
        for role in Config.DeviceConfig.Role.allCases {
            if case .UNRECOGNIZED = role { continue }
            if String(describing: role).lowercased() == normalized { return role }
        }
        return nil
    }

    private static func hardwareModel(_ raw: String) -> HardwareModel? {
        let normalized = raw.replacingOccurrences(of: "_", with: "").lowercased()
        for model in HardwareModel.allCases {
            if case .UNRECOGNIZED = model { continue }
            if String(describing: model).lowercased() == normalized { return model }
        }
        return nil
    }

    // MARK: - Telemetry

    static func deviceMetrics(_ telemetry: MeshpointAPI.Telemetry) -> DeviceMetrics? {
        var metrics = DeviceMetrics()
        var populated = false
        if let battery = telemetry.battery_level { metrics.batteryLevel = UInt32(max(0, battery)); populated = true }
        if let voltage = telemetry.voltage { metrics.voltage = Float(voltage); populated = true }
        if let utilization = telemetry.channel_utilization { metrics.channelUtilization = Float(utilization); populated = true }
        if let airtime = telemetry.air_util_tx { metrics.airUtilTx = Float(airtime); populated = true }
        if let uptime = telemetry.uptime_seconds { metrics.uptimeSeconds = UInt32(max(0, uptime)); populated = true }
        return populated ? metrics : nil
    }

    static func environmentMetrics(_ telemetry: MeshpointAPI.Telemetry) -> EnvironmentMetrics? {
        var metrics = EnvironmentMetrics()
        var populated = false
        if let temperature = telemetry.temperature { metrics.temperature = Float(temperature); populated = true }
        if let humidity = telemetry.humidity { metrics.relativeHumidity = Float(humidity); populated = true }
        if let pressure = telemetry.barometric_pressure { metrics.barometricPressure = Float(pressure); populated = true }
        return populated ? metrics : nil
    }

    /// Wraps a telemetry reading as a mesh packet so it flows through the normal
    /// decoding path and lands in the history store.
    static func telemetryPacket(_ reading: MeshpointAPI.Telemetry, from node: UInt32) -> MeshPacket? {
        var telemetry = Telemetry()
        let time = MeshpointDate.parse(reading.timestamp) ?? Date()
        telemetry.time = UInt32(max(0, time.timeIntervalSince1970))

        if let environment = environmentMetrics(reading) {
            telemetry.environmentMetrics = environment
        } else if let device = deviceMetrics(reading) {
            telemetry.deviceMetrics = device
        } else {
            return nil
        }

        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = (try? telemetry.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = packetID(nil, fallbackSeed: "tel-\(node)-\(telemetry.time)")
        packet.from = node
        packet.to = broadcastNodeNum
        packet.rxTime = telemetry.time
        packet.decoded = data
        return packet
    }

    // MARK: - Messages

    /// Builds a packet from a stored message row.
    ///
    /// Stored broadcasts keep only the sender's display name, so the sender is
    /// resolved against the node list; a name we cannot match is attributed to
    /// the unknown-node id rather than inventing a node.
    static func messagePacket(_ message: MeshpointAPI.Message,
                              conversationID: String,
                              myNodeNum: UInt32,
                              names: [String: UInt32],
                              sourceID: String?) -> MeshPacket? {
        guard let text = message.text, !text.isEmpty else { return nil }
        let isOutgoing = (message.direction ?? "received") == "sent"
        let time = MeshpointDate.parse(message.timestamp) ?? Date()

        let channelIndex = channelIndex(fromConversation: conversationID)
        let destination: UInt32
        let sender: UInt32

        if let channelIndex {
            destination = broadcastNodeNum
            _ = channelIndex
            if isOutgoing {
                sender = myNodeNum
            } else {
                sender = nodeNum(from: sourceID)
                    ?? message.node_name.flatMap { names[$0] }
                    ?? 0
            }
        } else {
            let peer = nodeNum(from: conversationID) ?? nodeNum(from: message.node_id) ?? 0
            destination = isOutgoing ? peer : myNodeNum
            sender = isOutgoing ? myNodeNum : peer
        }

        var data = DataMessage()
        data.portnum = .textMessageApp
        data.payload = Data(text.utf8)

        var packet = MeshPacket()
        packet.id = packetID(message.packet_id,
                             fallbackSeed: "msg-\(message.id ?? 0)-\(conversationID)-\(time.timeIntervalSince1970)")
        packet.from = sender
        packet.to = destination
        packet.channel = UInt32(channelIndex ?? message.channel ?? 0)
        packet.rxTime = UInt32(max(0, time.timeIntervalSince1970))
        if let snr = message.snr { packet.rxSnr = Float(snr) }
        if let rssi = message.rssi { packet.rxRssi = Int32(rssi) }
        packet.decoded = data
        return packet
    }

    /// Builds a packet from a live `message_received` websocket event, which —
    /// unlike stored history — carries the real sender id.
    static func messagePacket(fromSocket payload: MeshpointAPI.JSONValue,
                              myNodeNum: UInt32,
                              names: [String: UInt32]) -> MeshPacket? {
        guard (payload["protocol"]?.stringValue ?? "meshtastic") == "meshtastic" else { return nil }
        guard let text = payload["text"]?.stringValue, !text.isEmpty else { return nil }

        let conversationID = payload["node_id"]?.stringValue ?? ""
        var message = MeshpointAPI.Message(id: nil, direction: nil, text: nil, node_id: nil,
                                            node_name: nil, protocolName: nil, channel: nil,
                                            timestamp: nil, status: nil, packet_id: nil,
                                            rx_count: nil, rssi: nil, snr: nil)
        message.text = text
        message.direction = payload["direction"]?.stringValue
        message.node_id = conversationID
        message.node_name = payload["node_name"]?.stringValue
        message.packet_id = payload["packet_id"]?.stringValue
        message.snr = payload["snr"]?.doubleValue
        message.rssi = payload["rssi"]?.doubleValue
        message.timestamp = ISO8601DateFormatter().string(from: Date())

        return messagePacket(message,
                             conversationID: conversationID,
                             myNodeNum: myNodeNum,
                             names: names,
                             sourceID: payload["source_id"]?.stringValue)
    }

    /// One line for the diagnostics log from a raw packet event.
    static func packetLogLine(_ payload: MeshpointAPI.JSONValue) -> String? {
        let type = payload["packet_type"]?.stringValue ?? payload["type"]?.stringValue ?? "packet"
        let source = payload["source_id"]?.stringValue ?? "unknown"
        var line = "\(type) from \(source)"
        if let rssi = payload["rssi"]?.doubleValue { line += " RSSI \(Int(rssi))" }
        if let snr = payload["snr"]?.doubleValue { line += " SNR \(String(format: "%.1f", snr))" }
        return line + "\n"
    }
}

