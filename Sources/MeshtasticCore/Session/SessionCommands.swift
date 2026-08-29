import Foundation
import MeshtasticProtobufs

public extension MeshSession {

    // MARK: - Targets

    /// Builds the admin target for a node, marking the connected radio as local
    /// so it does not need a session passkey.
    func adminTarget(for nodeNum: UInt32) -> AdminTarget {
        AdminTarget(nodeNum: nodeNum,
                    isLocal: nodeNum == myNodeNum,
                    channelIndex: nodes[nodeNum]?.channel ?? 0)
    }

    var localAdminTarget: AdminTarget { adminTarget(for: myNodeNum) }

    /// The configured hop limit, so outgoing packets match the radio's setting.
    var defaultHopLimit: UInt32? {
        loraConfig.hopLimit == 0 ? nil : loraConfig.hopLimit
    }

    private func requireRadio() throws -> MeshRadio {
        guard let radio = activeRadio, isConnected else {
            throw SessionError.notConnected
        }
        return radio
    }

    private func report(_ error: Error, whileDoing action: String) {
        post(title: "Could not \(action)", detail: error.localizedDescription, isError: true)
    }

    // MARK: - Messaging

    /// Sends a text message and inserts it locally as pending straight away.
    @discardableResult
    func sendMessage(_ text: String, to conversation: ConversationKey, replyTo: UInt32? = nil) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let radio = try requireRadio()
            let packetID = MeshRadio.makePacketID()
            let options = sendOptions(for: conversation, wantAck: true)

            var message = MeshMessage(id: packetID,
                                      conversation: conversation,
                                      fromNode: myNodeNum,
                                      toNode: options.destination,
                                      text: trimmed,
                                      timestamp: Date(),
                                      status: .queued,
                                      replyTo: replyTo,
                                      channelIndex: options.channelIndex,
                                      isRead: true)
            insertOrUpdate(message)
            note(pendingAck: packetID, conversation: conversation)

            try await radio.sendText(trimmed, options: options, replyTo: replyTo, packetID: packetID)
            message.status = .sent
            insertOrUpdate(message)
            try? await persistentStore.saveMessage(message, radioID: radioID)
            return true
        } catch {
            report(error, whileDoing: "send that message")
            return false
        }
    }

    /// Sends an emoji tapback against a message.
    @discardableResult
    func sendReaction(_ emoji: String, to messageID: UInt32, in conversation: ConversationKey) async -> Bool {
        do {
            let radio = try requireRadio()
            let packetID = MeshRadio.makePacketID()
            let options = sendOptions(for: conversation, wantAck: false)
            let message = MeshMessage(id: packetID,
                                      conversation: conversation,
                                      fromNode: myNodeNum,
                                      toNode: options.destination,
                                      text: emoji,
                                      timestamp: Date(),
                                      status: .queued,
                                      reactionTo: messageID,
                                      isEmojiReaction: true,
                                      channelIndex: options.channelIndex,
                                      isRead: true)
            insertOrUpdate(message)
            try await radio.sendReaction(emoji, to: messageID, options: options, packetID: packetID)
            var sent = message
            sent.status = .sent
            insertOrUpdate(sent)
            try? await persistentStore.saveMessage(sent, radioID: radioID)
            return true
        } catch {
            report(error, whileDoing: "send that reaction")
            return false
        }
    }

    /// Sends a high-priority alert that makes receiving devices buzz.
    @discardableResult
    func sendAlert(_ text: String, to conversation: ConversationKey) async -> Bool {
        do {
            let radio = try requireRadio()
            try await radio.sendAlert(text, options: sendOptions(for: conversation, wantAck: true))
            return true
        } catch {
            report(error, whileDoing: "send that alert")
            return false
        }
    }

    /// Retries a message that failed, as a brand new packet.
    @discardableResult
    func resend(_ message: MeshMessage) async -> Bool {
        await deleteMessage(message.id)
        return await sendMessage(message.text, to: message.conversation, replyTo: message.replyTo)
    }

    func markRead(_ conversation: ConversationKey) async {
        var updated = messages
        var changed = false
        for index in updated.indices where updated[index].conversation == conversation && !updated[index].isRead {
            updated[index].isRead = true
            changed = true
        }
        guard changed else { return }
        setMessages(updated)
        try? await persistentStore.markConversationRead(conversation, radioID: radioID)
    }

    func deleteMessage(_ id: UInt32) async {
        setMessages(messages.filter { $0.id != id })
        try? await persistentStore.deleteMessage(id, radioID: radioID)
    }

    func deleteConversation(_ conversation: ConversationKey) async {
        setMessages(messages.filter { $0.conversation != conversation })
        try? await persistentStore.deleteConversation(conversation, radioID: radioID)
    }

    private func sendOptions(for conversation: ConversationKey, wantAck: Bool) -> SendOptions {
        switch conversation {
        case .channel(let index):
            SendOptions(destination: broadcastNodeNum, channelIndex: index,
                        wantAck: wantAck, hopLimit: defaultHopLimit)
        case .direct(let node):
            SendOptions(destination: node, channelIndex: nodes[node]?.channel ?? 0,
                        wantAck: wantAck, hopLimit: defaultHopLimit)
        }
    }

    private func insertOrUpdate(_ message: MeshMessage) {
        var updated = messages
        if let index = updated.firstIndex(where: { $0.id == message.id }) {
            updated[index] = message
        } else {
            updated.append(message)
            updated.sort { $0.timestamp < $1.timestamp }
        }
        setMessages(updated)
    }

    // MARK: - Node interrogation

    func requestNodeInfo(from node: UInt32) async {
        do {
            let radio = try requireRadio()
            let user = myNode?.user ?? User()
            try await radio.requestNodeInfo(from: node, ourUser: user,
                                            channelIndex: nodes[node]?.channel ?? 0,
                                            hopLimit: defaultHopLimit)
            post(title: "Requested node info", detail: "Asked \(name(of: node)) to identify itself.", isError: false)
        } catch {
            report(error, whileDoing: "request node info")
        }
    }

    func requestPosition(from node: UInt32) async {
        do {
            let radio = try requireRadio()
            try await radio.requestPosition(from: node, ourPosition: myNode?.position,
                                            channelIndex: nodes[node]?.channel ?? 0,
                                            hopLimit: defaultHopLimit)
            post(title: "Requested position", detail: "Asked \(name(of: node)) where it is.", isError: false)
        } catch {
            report(error, whileDoing: "request a position")
        }
    }

    func requestTelemetry(from node: UInt32, kind: TelemetryKind) async {
        do {
            let radio = try requireRadio()
            try await radio.requestTelemetry(from: node, kind: kind,
                                             channelIndex: nodes[node]?.channel ?? 0,
                                             hopLimit: defaultHopLimit)
            post(title: "Requested telemetry",
                 detail: "Asked \(name(of: node)) for \(kind.displayName.lowercased()) metrics.", isError: false)
        } catch {
            report(error, whileDoing: "request telemetry")
        }
    }

    /// Starts a traceroute and records it as pending so the reply can be matched.
    func traceroute(to node: UInt32) async {
        do {
            let radio = try requireRadio()
            let packetID = try await radio.traceroute(to: node,
                                                      channelIndex: nodes[node]?.channel ?? 0,
                                                      hopLimit: defaultHopLimit)
            note(pendingTraceroute: packetID)
            var list = traceroutes
            list.insert(TracerouteResult(id: packetID, target: node, requestedAt: Date()), at: 0)
            setTraceroutes(list)
        } catch {
            report(error, whileDoing: "start a traceroute")
        }
    }

    func requestStoreForwardHistory(from node: UInt32, messageCount: UInt32 = 50, windowMinutes: UInt32 = 240) async {
        do {
            let radio = try requireRadio()
            try await radio.requestStoreForwardHistory(from: node, messageCount: messageCount,
                                                       window: windowMinutes * 60_000,
                                                       channelIndex: nodes[node]?.channel ?? 0)
        } catch {
            report(error, whileDoing: "request message history")
        }
    }

    // MARK: - Node database management

    func setFavorite(_ node: UInt32, isFavorite: Bool) async {
        await mutateNode(node) { $0.isFavorite = isFavorite }
        await runAdmin("update favorites") { radio in
            try await radio.setFavorite(node, isFavorite: isFavorite, on: self.localAdminTarget)
        }
    }

    func setIgnored(_ node: UInt32, isIgnored: Bool) async {
        await mutateNode(node) { $0.isIgnored = isIgnored }
        await runAdmin("update the ignore list") { radio in
            try await radio.setIgnored(node, isIgnored: isIgnored, on: self.localAdminTarget)
        }
    }

    func toggleMuted(_ node: UInt32) async {
        let newValue = !(nodes[node]?.isMuted ?? false)
        await mutateNode(node) { $0.isMuted = newValue }
        await runAdmin("mute that node") { radio in
            try await radio.toggleMuted(node, on: self.localAdminTarget)
        }
    }

    func removeNode(_ node: UInt32) async {
        await runAdmin("remove that node") { radio in
            try await radio.removeNode(node, on: self.localAdminTarget)
        }
        removeNodeLocally(node)
        try? await persistentStore.deleteNode(node, radioID: radioID)
    }

    private func mutateNode(_ num: UInt32, _ change: (inout MeshNode) -> Void) async {
        guard var node = nodes[num] else { return }
        change(&node)
        setNode(node)
        try? await persistentStore.saveNode(node, radioID: radioID)
    }

    // MARK: - Owner and identity

    func setOwner(longName: String, shortName: String, isLicensed: Bool, isUnmessagable: Bool?) async {
        var user = myNode?.user ?? User()
        user.id = String(format: "!%08x", myNodeNum)
        user.longName = longName
        user.shortName = shortName
        user.isLicensed = isLicensed
        if let isUnmessagable { user.isUnmessagable = isUnmessagable }
        await runAdmin("save the device name") { radio in
            try await radio.setOwner(user, on: self.localAdminTarget)
        }
        await mutateNode(myNodeNum) { $0.user = user }
    }

    // MARK: - Configuration writes

    /// Wraps a config write in the firmware's begin/commit pair so the radio
    /// reboots once at the end rather than after each field.
    func save(config: Config, to target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("save those settings") { radio in
            try await radio.beginEditSettings(on: target)
            try await radio.setConfig(config, on: target)
            try await radio.commitEditSettings(on: target)
        }
        applyIncoming(config: config)
    }

    func save(moduleConfig: ModuleConfig, to target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("save those module settings") { radio in
            try await radio.beginEditSettings(on: target)
            try await radio.setModuleConfig(moduleConfig, on: target)
            try await radio.commitEditSettings(on: target)
        }
        applyIncoming(moduleConfig: moduleConfig)
    }

    func saveDeviceConfig(_ value: Config.DeviceConfig) async {
        var config = Config(); config.device = value; await save(config: config)
    }
    func savePositionConfig(_ value: Config.PositionConfig) async {
        var config = Config(); config.position = value; await save(config: config)
    }
    func savePowerConfig(_ value: Config.PowerConfig) async {
        var config = Config(); config.power = value; await save(config: config)
    }
    func saveNetworkConfig(_ value: Config.NetworkConfig) async {
        var config = Config(); config.network = value; await save(config: config)
    }
    func saveDisplayConfig(_ value: Config.DisplayConfig) async {
        var config = Config(); config.display = value; await save(config: config)
    }
    func saveLoRaConfig(_ value: Config.LoRaConfig) async {
        var config = Config(); config.lora = value; await save(config: config)
    }
    func saveBluetoothConfig(_ value: Config.BluetoothConfig) async {
        var config = Config(); config.bluetooth = value; await save(config: config)
    }
    func saveSecurityConfig(_ value: Config.SecurityConfig) async {
        var config = Config(); config.security = value; await save(config: config)
    }

    func saveModule(_ build: (inout ModuleConfig) -> Void) async {
        var config = ModuleConfig()
        build(&config)
        await save(moduleConfig: config)
    }

    // MARK: - Channels

    /// Writes the whole channel set, which is how the apps apply an imported link.
    func saveChannels(_ list: [Channel], to target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("save the channels") { radio in
            try await radio.beginEditSettings(on: target)
            for channel in list {
                try await radio.setChannel(channel, on: target)
            }
            try await radio.commitEditSettings(on: target)
        }
        setChannels(list)
    }

    /// Builds a share link for the current channel set and LoRa configuration.
    func channelShareURL(includeAllChannels: Bool = true) throws -> URL {
        var set = ChannelSet()
        set.settings = channels
            .filter { $0.role != .disabled }
            .filter { includeAllChannels || $0.role == .primary }
            .map(\.settings)
        set.loraConfig = loraConfig
        return try ChannelSharing.url(for: set)
    }

    /// Applies a `meshtastic.org/e/#…` link. Replaces the channel set unless the
    /// link asked to append.
    func importChannels(from link: String, applyLoRaConfig: Bool) async {
        do {
            let result = try ChannelSharing.parse(link)
            var updated: [Channel] = result.addOnly ? channels.filter { $0.role != .disabled } : []

            for settings in result.channelSet.settings {
                if updated.count >= 8 { break }
                // Skip a channel we already carry under the same name and key.
                if result.addOnly, updated.contains(where: { $0.settings.name == settings.name && $0.settings.psk == settings.psk }) {
                    continue
                }
                var channel = Channel()
                channel.index = Int32(updated.count)
                channel.settings = settings
                channel.role = updated.isEmpty ? .primary : .secondary
                updated.append(channel)
            }
            // Pad the remaining slots as disabled so old channels are cleared.
            while updated.count < 8 {
                var channel = Channel()
                channel.index = Int32(updated.count)
                channel.role = .disabled
                updated.append(channel)
            }

            await saveChannels(updated)
            if applyLoRaConfig, result.channelSet.hasLoraConfig {
                await saveLoRaConfig(result.channelSet.loraConfig)
            }
            post(title: "Channels imported",
                 detail: "Applied \(result.channelSet.settings.count) channel\(result.channelSet.settings.count == 1 ? "" : "s") from the link.",
                 isError: false)
        } catch {
            report(error, whileDoing: "import that channel link")
        }
    }

    // MARK: - Waypoints

    func sendWaypoint(_ waypoint: Waypoint, channelIndex: Int) async {
        do {
            let radio = try requireRadio()
            var waypoint = waypoint
            if waypoint.id == 0 { waypoint.id = UInt32.random(in: 1...UInt32.max) }
            try await radio.sendWaypoint(waypoint, options: SendOptions(destination: broadcastNodeNum,
                                                                        channelIndex: channelIndex,
                                                                        wantAck: true,
                                                                        hopLimit: defaultHopLimit))
            setWaypoint(waypoint, from: myNodeNum)
            try? await persistentStore.saveWaypoint(waypoint, from: myNodeNum, radioID: radioID)
        } catch {
            report(error, whileDoing: "share that waypoint")
        }
    }

    func deleteWaypoint(_ waypoint: Waypoint, channelIndex: Int) async {
        do {
            let radio = try requireRadio()
            try await radio.deleteWaypoint(waypoint, options: SendOptions(destination: broadcastNodeNum,
                                                                          channelIndex: channelIndex,
                                                                          wantAck: true,
                                                                          hopLimit: defaultHopLimit))
        } catch {
            report(error, whileDoing: "delete that waypoint")
        }
        removeWaypointLocally(waypoint.id)
        try? await persistentStore.deleteWaypoint(waypoint.id, radioID: radioID)
    }

    // MARK: - Position

    func setFixedPosition(latitude: Double, longitude: Double, altitude: Int32?) async {
        var position = Position()
        position.latitudeI = Int32(latitude * 1e7)
        position.longitudeI = Int32(longitude * 1e7)
        if let altitude { position.altitude = altitude }
        position.time = UInt32(Date().timeIntervalSince1970)
        await runAdmin("set the fixed position") { radio in
            try await radio.setFixedPosition(position, on: self.localAdminTarget)
        }
    }

    func clearFixedPosition() async {
        await runAdmin("clear the fixed position") { radio in
            try await radio.removeFixedPosition(on: self.localAdminTarget)
        }
    }

    /// Shares the Mac's own position with the mesh.
    func sendOurPosition(latitude: Double, longitude: Double, altitude: Int32?, channelIndex: Int = 0) async {
        do {
            let radio = try requireRadio()
            var position = Position()
            position.latitudeI = Int32(latitude * 1e7)
            position.longitudeI = Int32(longitude * 1e7)
            if let altitude { position.altitude = altitude }
            position.time = UInt32(Date().timeIntervalSince1970)
            position.locationSource = .locManual
            try await radio.sendPosition(position, options: SendOptions(destination: broadcastNodeNum,
                                                                        channelIndex: channelIndex,
                                                                        wantAck: false,
                                                                        hopLimit: defaultHopLimit))
        } catch {
            report(error, whileDoing: "share your position")
        }
    }

    // MARK: - Device lifecycle

    func reboot(after seconds: Int32 = 5, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("reboot the radio") { radio in try await radio.reboot(afterSeconds: seconds, on: target) }
        post(title: "Rebooting", detail: "\(name(of: target.nodeNum)) will restart in \(seconds) seconds.", isError: false)
    }

    func shutdown(after seconds: Int32 = 5, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("shut down the radio") { radio in try await radio.shutdown(afterSeconds: seconds, on: target) }
    }

    func rebootToOTA(after seconds: Int32 = 5, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("start OTA update mode") { radio in try await radio.rebootToOTA(afterSeconds: seconds, on: target) }
    }

    func factoryReset(keepNodeDatabase: Bool, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("factory reset the radio") { radio in
            if keepNodeDatabase {
                try await radio.factoryResetConfig(on: target)
            } else {
                try await radio.factoryResetDevice(on: target)
            }
        }
    }

    func resetNodeDatabase(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("reset the node database") { radio in try await radio.resetNodeDatabase(on: target) }
    }

    func enterDFUMode(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("enter DFU mode") { radio in try await radio.enterDFUMode(on: target) }
    }

    func setTime(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("set the clock") { radio in try await radio.setTime(on: target) }
    }

    func setHamMode(callSign: String, txPower: Int32, frequency: Float, shortName: String) async {
        var parameters = HamParameters()
        parameters.callSign = callSign
        parameters.txPower = txPower
        parameters.frequency = frequency
        parameters.shortName = shortName
        await runAdmin("enable licensed operator mode") { radio in
            try await radio.setHamMode(parameters, on: self.localAdminTarget)
        }
    }

    // MARK: - Module data reads

    func refreshCannedMessages(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("read the canned messages") { radio in try await radio.requestCannedMessages(from: target) }
    }

    func saveCannedMessages(_ text: String, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("save the canned messages") { radio in try await radio.setCannedMessages(text, on: target) }
        setCannedMessages(text)
    }

    func refreshRingtone(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("read the ringtone") { radio in try await radio.requestRingtone(from: target) }
    }

    func saveRingtone(_ text: String, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("save the ringtone") { radio in try await radio.setRingtone(text, on: target) }
        setRingtone(text)
    }

    func refreshConnectionStatus() async {
        await runAdmin("read the connection status") { radio in
            try await radio.requestConnectionStatus(from: self.localAdminTarget)
        }
    }

    func refreshRemoteHardwarePins(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("read the remote hardware pins") { radio in try await radio.requestRemoteHardwarePins(from: target) }
    }

    func refreshDeviceMetadata(target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        await runAdmin("read the device metadata") { radio in try await radio.requestDeviceMetadata(from: target) }
    }

    // MARK: - Remote administration

    /// Opens an admin session with a remote node by reading one of its settings,
    /// which is what makes it hand back a session passkey.
    func beginRemoteAdminSession(with node: UInt32) async {
        let target = adminTarget(for: node)
        await runAdmin("start a remote admin session") { radio in
            try await radio.requestConfig(.deviceConfig, from: target)
            try await radio.requestDeviceMetadata(from: target)
        }
        post(title: "Requested admin session",
             detail: "Waiting for \(name(of: node)) to reply. Remote admin needs your public key listed on that node.",
             isError: false)
    }

    func refreshAllSettings(for node: UInt32) async {
        let target = adminTarget(for: node)
        await runAdmin("read the settings") { radio in
            for type in [AdminMessage.ConfigType.deviceConfig, .positionConfig, .powerConfig, .networkConfig,
                         .displayConfig, .loraConfig, .bluetoothConfig, .securityConfig] {
                try await radio.requestConfig(type, from: target)
            }
            for type in [AdminMessage.ModuleConfigType.mqttConfig, .serialConfig, .extnotifConfig, .storeforwardConfig,
                         .rangetestConfig, .telemetryConfig, .cannedmsgConfig, .audioConfig, .remotehardwareConfig,
                         .neighborinfoConfig, .ambientlightingConfig, .detectionsensorConfig, .paxcounterConfig,
                         .statusmessageConfig, .trafficmanagementConfig, .takConfig, .meshbeaconConfig] {
                try await radio.requestModuleConfig(type, from: target)
            }
        }
    }

    /// Re-runs the configuration handshake with the connected radio.
    func refreshFromRadio() async {
        guard let radio = activeRadio else { return }
        await radio.requestConfiguration()
    }

    // MARK: - Remote hardware GPIO

    func remoteGPIO(_ type: HardwareMessage.TypeEnum, mask: UInt64, value: UInt64, on node: UInt32) async {
        do {
            let radio = try requireRadio()
            var message = HardwareMessage()
            message.type = type
            message.gpioMask = mask
            message.gpioValue = value
            try await radio.remoteHardware(message, to: node, channelIndex: nodes[node]?.channel ?? 0)
        } catch {
            report(error, whileDoing: "send that GPIO command")
        }
    }

    // MARK: - Helper

    private func runAdmin(_ description: String, _ body: (MeshRadio) async throws -> Void) async {
        do {
            let radio = try requireRadio()
            try await body(radio)
        } catch {
            report(error, whileDoing: description)
        }
    }
}

public enum SessionError: Error, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a radio."
        }
    }
}

public extension MeshSession {
    /// Saves the radio's settings into its own flash, which survives a settings
    /// reset (but not a full factory erase).
    func backupSettings(to location: AdminMessage.BackupLocation = .flash, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        guard let radio = activeRadio, isConnected else {
            post(title: "Not connected", detail: "Connect to a radio first.", isError: true)
            return
        }
        do {
            try await radio.backupPreferences(to: location, on: target)
            post(title: "Backup requested", detail: "The radio is saving its settings.", isError: false)
        } catch {
            post(title: "Could not back up the settings", detail: error.localizedDescription, isError: true)
        }
    }

    func restoreSettings(from location: AdminMessage.BackupLocation = .flash, target: AdminTarget? = nil) async {
        let target = target ?? localAdminTarget
        guard let radio = activeRadio, isConnected else {
            post(title: "Not connected", detail: "Connect to a radio first.", isError: true)
            return
        }
        do {
            try await radio.restorePreferences(from: location, on: target)
            post(title: "Restore requested", detail: "The radio is restoring its settings and will reboot.", isError: false)
        } catch {
            post(title: "Could not restore the settings", detail: error.localizedDescription, isError: true)
        }
    }
}
