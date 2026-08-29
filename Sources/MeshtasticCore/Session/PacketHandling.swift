import Foundation
import MeshtasticProtobufs

extension MeshSession {

    /// Routes one mesh packet to the right decoder and updates state.
    func handle(packet: MeshPacket) async {
        let now = Date()
        let receivedAt = packet.rxTime > 0 ? Date(timeIntervalSince1970: TimeInterval(packet.rxTime)) : now
        let sender = packet.from == 0 ? myNodeNum : packet.from

        // Any packet is evidence the sender is alive and how well we hear it.
        if sender != 0, sender != myNodeNum {
            touchNode(sender, receivedAt: receivedAt, packet: packet)
        }

        guard let variant = packet.payloadVariant else { return }
        switch variant {
        case .encrypted(let bytes):
            logPacket(direction: .inbound,
                      summary: "Encrypted packet on channel \(packet.channel)",
                      detail: "\(bytes.count) bytes we do not hold the key for.",
                      from: sender, to: packet.to)
        case .decoded(let data):
            await handle(data: data, packet: packet, sender: sender, receivedAt: receivedAt)
        }
    }

    private func handle(data: DataMessage, packet: MeshPacket, sender: UInt32, receivedAt: Date) async {
        switch data.portnum {
        case .textMessageApp, .alertApp, .detectionSensorApp:
            await handleText(data: data, packet: packet, sender: sender, receivedAt: receivedAt)
        case .positionApp:
            await handlePosition(data: data, sender: sender, receivedAt: receivedAt)
        case .nodeinfoApp:
            await handleNodeInfo(data: data, packet: packet, sender: sender, receivedAt: receivedAt)
        case .telemetryApp:
            await handleTelemetry(data: data, sender: sender, receivedAt: receivedAt)
        case .routingApp:
            await handleRouting(data: data, packet: packet, sender: sender)
        case .adminApp:
            await handleAdmin(data: data, sender: sender)
        case .tracerouteApp:
            await handleTraceroute(data: data, packet: packet, sender: sender)
        case .waypointApp:
            await handleWaypoint(data: data, sender: sender)
        case .neighborinfoApp:
            await handleNeighborInfo(data: data, sender: sender, receivedAt: receivedAt)
        case .paxcounterApp:
            await handlePaxcounter(data: data, sender: sender, receivedAt: receivedAt)
        case .storeForwardApp:
            await handleStoreForward(data: data, packet: packet, sender: sender, receivedAt: receivedAt)
        case .rangeTestApp:
            handleRangeTest(data: data, packet: packet, sender: sender)
        case .remoteHardwareApp:
            handleRemoteHardware(data: data, sender: sender)
        case .mapReportApp:
            handleMapReport(data: data, sender: sender)
        default:
            logPacket(direction: .inbound,
                      summary: "\(data.portnum.displayName) from \(name(of: sender))",
                      detail: "\(data.payload.count)-byte payload on port \(data.portnum.rawValue).",
                      portnum: data.portnum, from: sender, to: packet.to)
        }
    }

    // MARK: - Text, alerts and reactions

    private func handleText(data: DataMessage, packet: MeshPacket, sender: UInt32, receivedAt: Date) async {
        let text = String(decoding: data.payload, as: UTF8.self)
        guard !text.isEmpty else { return }

        let conversation = conversationKey(packet: packet, sender: sender)
        let isReaction = data.emoji == 1
        var message = MeshMessage(id: packet.id == 0 ? MeshRadio.makePacketID() : packet.id,
                                  conversation: conversation,
                                  fromNode: sender,
                                  toNode: packet.to,
                                  text: text,
                                  timestamp: receivedAt,
                                  status: sender == myNodeNum ? .sent : .received,
                                  reactionTo: isReaction ? (data.replyID == 0 ? nil : data.replyID) : nil,
                                  replyTo: isReaction ? nil : (data.replyID == 0 ? nil : data.replyID),
                                  isEmojiReaction: isReaction,
                                  snr: packet.rxSnr == 0 ? nil : packet.rxSnr,
                                  rssi: packet.hasRxRssi && packet.rxRssi != 0 ? Int(packet.rxRssi) : nil,
                                  hopsAway: hopsAway(for: packet),
                                  viaMQTT: packet.viaMqtt,
                                  channelIndex: Int(packet.channel),
                                  portnum: data.portnum,
                                  isPKIEncrypted: packet.pkiEncrypted,
                                  isRead: sender == myNodeNum)

        if data.portnum == .detectionSensorApp {
            // Detection events are informational, not part of a chat thread.
            logPacket(direction: .inbound, summary: "Detection sensor: \(text)",
                      detail: "Reported by \(name(of: sender)).",
                      portnum: data.portnum, from: sender, to: packet.to)
        }
        if data.portnum == .alertApp {
            post(title: "Alert from \(name(of: sender))", detail: text, isError: false)
        }

        // A message we already know about (a Store & Forward replay, or the
        // radio echoing back something we sent) should update rather than
        // duplicate.
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            let existing = messages[index]
            message.isRead = existing.isRead
            // The echo of our own packet says only "sent". If a routing ACK has
            // already marked it delivered, do not walk that back.
            if existing.status.rawValue > message.status.rawValue, existing.status != .received {
                message.status = existing.status
                message.failureReason = existing.failureReason
            }
            var updated = messages
            updated[index] = message
            setMessages(updated)
        } else {
            var updated = messages
            updated.append(message)
            updated.sort { $0.timestamp < $1.timestamp }
            setMessages(updated)
            if sender != myNodeNum {
                onIncomingMessage?(message, nodes[sender])
            }
        }
        try? await persistentStore.saveMessage(message, radioID: radioID)
    }

    // MARK: - Position

    private func handlePosition(data: DataMessage, sender: UInt32, receivedAt: Date) async {
        guard let position = try? Position(serializedBytes: data.payload) else { return }
        guard position.latitudeI != 0 || position.longitudeI != 0 else {
            // An empty position is a request for ours, which the firmware answers.
            return
        }

        var node = nodes[sender] ?? MeshNode(num: sender)
        node.position = position
        node.lastHeard = receivedAt
        setNode(node)

        let time = position.time > 0 ? Date(timeIntervalSince1970: TimeInterval(position.time)) : receivedAt
        let sample = PositionSample(nodeNum: sender,
                                    time: time,
                                    latitude: Double(position.latitudeI) * 1e-7,
                                    longitude: Double(position.longitudeI) * 1e-7,
                                    altitude: position.altitude == 0 ? nil : position.altitude,
                                    speedKmH: position.groundSpeed == 0 ? nil : Double(position.groundSpeed) * 3.6,
                                    headingDegrees: position.groundTrack == 0 ? nil : Double(position.groundTrack) * 1e-5,
                                    satellites: position.satsInView == 0 ? nil : Int(position.satsInView),
                                    precisionBits: position.precisionBits == 0 ? nil : Int(position.precisionBits))
        try? await persistentStore.savePosition(sample, radioID: radioID)
        try? await persistentStore.saveNode(node, radioID: radioID)
    }

    // MARK: - Node info

    private func handleNodeInfo(data: DataMessage, packet: MeshPacket, sender: UInt32, receivedAt: Date) async {
        guard let user = try? User(serializedBytes: data.payload) else { return }
        var node = nodes[sender] ?? MeshNode(num: sender)
        node.user = user
        node.lastHeard = receivedAt
        node.channel = Int(packet.channel)
        setNode(node)
        try? await persistentStore.saveNode(node, radioID: radioID)
    }

    // MARK: - Telemetry

    private func handleTelemetry(data: DataMessage, sender: UInt32, receivedAt: Date) async {
        guard let telemetry = try? Telemetry(serializedBytes: data.payload) else { return }
        guard let sample = TelemetryMetrics.sample(from: telemetry, nodeNum: sender, fallbackTime: receivedAt) else {
            return // An empty telemetry packet is a request, not a reading.
        }

        var node = nodes[sender] ?? MeshNode(num: sender)
        node.lastHeard = receivedAt
        switch telemetry.variant {
        case .deviceMetrics(let metrics): node.deviceMetrics = metrics
        case .environmentMetrics(let metrics): node.environmentMetrics = metrics
        case .airQualityMetrics(let metrics): node.airQualityMetrics = metrics
        case .powerMetrics(let metrics): node.powerMetrics = metrics
        case .healthMetrics(let metrics): node.healthMetrics = metrics
        case .localStats(let stats):
            if sender == myNodeNum { setLocalStats(stats) }
        case .hostMetrics, .trafficManagementStats, .none:
            break
        }
        setNode(node)
        try? await persistentStore.saveTelemetry(sample, radioID: radioID)
        try? await persistentStore.saveNode(node, radioID: radioID)
    }

    // MARK: - Routing (ACKs and errors)

    private func handleRouting(data: DataMessage, packet: MeshPacket, sender: UInt32) async {
        guard let routing = try? Routing(serializedBytes: data.payload) else { return }
        let requestID = data.requestID
        guard requestID != 0 else { return }

        var errorReason: Routing.Error = .none
        if case .errorReason(let reason) = routing.variant { errorReason = reason }

        // Traceroute failures come back as routing errors against our request.
        if isPendingTraceroute(requestID), errorReason.isFailure {
            clearPendingTraceroute(requestID)
            if var result = traceroutes.first(where: { $0.id == requestID }) {
                result.completedAt = Date()
                result.failureReason = errorReason.displayName
                await save(traceroute: result)
            }
        }

        guard let index = messages.firstIndex(where: { $0.id == requestID }) else {
            _ = takePendingAck(requestID)
            logPacket(direction: .inbound,
                      summary: errorReason.isFailure ? "Routing error: \(errorReason.displayName)" : "Acknowledged",
                      detail: "For packet \(String(format: "0x%08x", requestID)) from \(name(of: sender)).",
                      portnum: .routingApp, from: sender, to: packet.to)
            return
        }

        var updated = messages
        if errorReason.isFailure {
            updated[index].status = .failed
            updated[index].failureReason = errorReason.displayName
        } else {
            // An ACK relayed by an intermediate node still means it got through.
            updated[index].status = .delivered
            updated[index].failureReason = nil
        }
        setMessages(updated)
        _ = takePendingAck(requestID)
        try? await persistentStore.saveMessage(updated[index], radioID: radioID)
    }

    // MARK: - Admin responses

    private func handleAdmin(data: DataMessage, sender: UInt32) async {
        guard let message = try? AdminMessage(serializedBytes: data.payload) else { return }
        if !message.sessionPasskey.isEmpty, let radio = activeRadio {
            await radio.storePasskey(message.sessionPasskey, for: sender)
        }

        switch message.payloadVariant {
        case .getConfigResponse(let config):
            applyIncoming(config: config)
        case .getModuleConfigResponse(let config):
            applyIncoming(moduleConfig: config)
        case .getChannelResponse(let channel):
            applyIncoming(channel: channel)
        case .getOwnerResponse(let user):
            var node = nodes[sender] ?? MeshNode(num: sender)
            node.user = user
            setNode(node)
            try? await persistentStore.saveNode(node, radioID: radioID)
        case .getDeviceMetadataResponse(let metadata):
            if sender == myNodeNum || sender == 0 {
                setMetadata(metadata)
            }
            logPacket(direction: .inbound, summary: "Device metadata from \(name(of: sender))",
                      detail: "Firmware \(metadata.firmwareVersion), \(metadata.hwModel.displayName).",
                      portnum: .adminApp, from: sender)
        case .getCannedMessageModuleMessagesResponse(let messages):
            setCannedMessages(messages)
        case .getRingtoneResponse(let ringtone):
            setRingtone(ringtone)
        case .getDeviceConnectionStatusResponse(let status):
            setConnectionStatus(status)
        case .getNodeRemoteHardwarePinsResponse(let pins):
            setRemoteHardwarePins(pins)
        case .getUiConfigResponse(let config):
            applyIncoming(config: {
                var wrapper = Config()
                wrapper.deviceUi = config
                return wrapper
            }())
        default:
            logPacket(direction: .inbound, summary: "Admin response from \(name(of: sender))",
                      detail: String(describing: message.payloadVariant ?? .getOwnerRequest(false)),
                      portnum: .adminApp, from: sender)
        }
    }

    // MARK: - Traceroute

    private func handleTraceroute(data: DataMessage, packet: MeshPacket, sender: UInt32) async {
        guard let discovery = try? RouteDiscovery(serializedBytes: data.payload) else { return }
        let requestID = data.requestID != 0 ? data.requestID : packet.id

        func hops(_ nodes: [UInt32], _ snrs: [Int32]) -> [TracerouteResult.Hop] {
            nodes.enumerated().map { index, node in
                // SNR arrives scaled by 4; the sentinel -128 means "not measured".
                let raw = index < snrs.count ? snrs[index] : -128
                return TracerouteResult.Hop(nodeNum: node, snr: raw == -128 ? nil : Float(raw) / 4)
            }
        }

        var result = traceroutes.first(where: { $0.id == requestID })
            ?? TracerouteResult(id: requestID, target: sender, requestedAt: Date())
        result.forwardRoute = hops(discovery.route, discovery.snrTowards)
        result.returnRoute = hops(discovery.routeBack, discovery.snrBack)
        result.completedAt = Date()
        result.failureReason = nil
        clearPendingTraceroute(requestID)
        await save(traceroute: result)

        logPacket(direction: .inbound, summary: "Traceroute reply from \(name(of: sender))",
                  detail: describeRoute(result), portnum: .tracerouteApp, from: sender)
    }

    private func save(traceroute result: TracerouteResult) async {
        var list = traceroutes
        if let index = list.firstIndex(where: { $0.id == result.id }) {
            list[index] = result
        } else {
            list.insert(result, at: 0)
        }
        setTraceroutes(list)
        try? await persistentStore.saveTraceroute(result, radioID: radioID)
    }

    private func describeRoute(_ result: TracerouteResult) -> String {
        let outbound = ([myNodeNum] + result.forwardRoute.map(\.nodeNum) + [result.target])
            .map { name(of: $0) }.joined(separator: " → ")
        guard !result.returnRoute.isEmpty else { return outbound }
        let inbound = ([result.target] + result.returnRoute.map(\.nodeNum) + [myNodeNum])
            .map { name(of: $0) }.joined(separator: " → ")
        return "\(outbound)\nBack: \(inbound)"
    }

    // MARK: - Waypoints

    private func handleWaypoint(data: DataMessage, sender: UInt32) async {
        guard let waypoint = try? Waypoint(serializedBytes: data.payload) else { return }
        // An expiry in the past is how Meshtastic signals a deletion.
        let expiry = waypoint.expire
        if expiry != 0, Date(timeIntervalSince1970: TimeInterval(expiry)) < Date() {
            removeWaypointLocally(waypoint.id)
            try? await persistentStore.deleteWaypoint(waypoint.id, radioID: radioID)
            return
        }
        setWaypoint(waypoint, from: sender)
        try? await persistentStore.saveWaypoint(waypoint, from: sender, radioID: radioID)
    }

    // MARK: - Neighbor info

    private func handleNeighborInfo(data: DataMessage, sender: UInt32, receivedAt: Date) async {
        guard let info = try? NeighborInfo(serializedBytes: data.payload) else { return }
        let owner = info.nodeID != 0 ? info.nodeID : sender
        var node = nodes[owner] ?? MeshNode(num: owner)
        node.neighbors = info.neighbors
        node.neighborsUpdated = receivedAt
        node.lastHeard = receivedAt
        setNode(node)
        try? await persistentStore.saveNode(node, radioID: radioID)
    }

    // MARK: - Paxcounter

    private func handlePaxcounter(data: DataMessage, sender: UInt32, receivedAt: Date) async {
        guard let count = try? Paxcount(serializedBytes: data.payload) else { return }
        var node = nodes[sender] ?? MeshNode(num: sender)
        node.paxWifi = count.wifi
        node.paxBle = count.ble
        node.paxUptime = count.uptime
        node.lastHeard = receivedAt
        setNode(node)
        try? await persistentStore.saveNode(node, radioID: radioID)
        logPacket(direction: .inbound, summary: "Paxcounter from \(name(of: sender))",
                  detail: "\(count.wifi) WiFi and \(count.ble) Bluetooth devices nearby.",
                  portnum: .paxcounterApp, from: sender)
    }

    // MARK: - Store & Forward

    private func handleStoreForward(data: DataMessage, packet: MeshPacket, sender: UInt32, receivedAt: Date) async {
        guard let message = try? StoreAndForward(serializedBytes: data.payload) else { return }
        switch message.variant {
        case .text(let bytes):
            // A replayed text message; feed it through the normal text path.
            var replay = data
            replay.portnum = .textMessageApp
            replay.payload = bytes
            await handleText(data: replay, packet: packet, sender: sender, receivedAt: receivedAt)
        case .stats(let stats):
            logPacket(direction: .inbound, summary: "Store & Forward statistics from \(name(of: sender))",
                      detail: "\(stats.messagesSaved) saved of \(stats.messagesMax) capacity, \(stats.requests) requests.",
                      portnum: .storeForwardApp, from: sender)
        case .history(let history):
            post(title: "Store & Forward",
                 detail: "\(name(of: sender)) is replaying \(history.historyMessages) messages from the last \(history.window / 60_000) minutes.",
                 isError: false)
        case .heartbeat, .none:
            break
        }
    }

    // MARK: - Range test

    private func handleRangeTest(data: DataMessage, packet: MeshPacket, sender: UInt32) {
        let payload = String(decoding: data.payload, as: UTF8.self)
        var detail = "Sequence \(payload) from \(name(of: sender))."
        if packet.rxSnr != 0 { detail += " SNR \(String(format: "%.1f", packet.rxSnr)) dB." }
        if packet.hasRxRssi { detail += " RSSI \(packet.rxRssi) dBm." }
        logPacket(direction: .inbound, summary: "Range test \(payload)", detail: detail,
                  portnum: .rangeTestApp, from: sender, to: packet.to)
    }

    // MARK: - Remote hardware

    private func handleRemoteHardware(data: DataMessage, sender: UInt32) {
        guard let message = try? HardwareMessage(serializedBytes: data.payload) else { return }
        logPacket(direction: .inbound, summary: "Remote hardware \(humanizedName(message.type)) from \(name(of: sender))",
                  detail: "GPIO mask \(String(format: "0x%llx", message.gpioMask)), value \(String(format: "0x%llx", message.gpioValue)).",
                  portnum: .remoteHardwareApp, from: sender)
    }

    // MARK: - Map report

    private func handleMapReport(data: DataMessage, sender: UInt32) {
        guard let report = try? MapReport(serializedBytes: data.payload) else { return }
        logPacket(direction: .inbound, summary: "Map report from \(report.longName.isEmpty ? name(of: sender) : report.longName)",
                  detail: "Firmware \(report.firmwareVersion), region \(report.region.shortCode), \(report.numOnlineLocalNodes) nodes online.",
                  portnum: .mapReportApp, from: sender)
    }

    // MARK: - Helpers

    private func touchNode(_ num: UInt32, receivedAt: Date, packet: MeshPacket) {
        var node = nodes[num] ?? MeshNode(num: num)
        node.lastHeard = receivedAt
        if packet.rxSnr != 0 { node.snr = packet.rxSnr }
        if packet.hasRxRssi, packet.rxRssi != 0 { node.rssi = Int(packet.rxRssi) }
        if let hops = hopsAway(for: packet) { node.hopsAway = hops }
        node.viaMQTT = packet.viaMqtt
        setNode(node)
    }

    /// The firmware encodes distance as the difference between the starting and
    /// remaining hop limits.
    private func hopsAway(for packet: MeshPacket) -> Int? {
        guard packet.hopStart > 0, packet.hopStart >= packet.hopLimit else { return nil }
        return Int(packet.hopStart - packet.hopLimit)
    }

    func conversationKey(packet: MeshPacket, sender: UInt32) -> ConversationKey {
        if packet.to == broadcastNodeNum { return .channel(Int(packet.channel)) }
        if sender == myNodeNum { return .direct(packet.to) }
        return .direct(sender)
    }

    /// Friendly name for a node number, falling back to its hex ID.
    public func name(of num: UInt32) -> String {
        if num == broadcastNodeNum { return "Everyone" }
        if let node = nodes[num] { return node.longName }
        return String(format: "!%08x", num)
    }

    public func shortName(of num: UInt32) -> String {
        if num == broadcastNodeNum { return "ALL" }
        if let node = nodes[num] { return node.shortName }
        return String(format: "%04x", num & 0xFFFF)
    }
}
