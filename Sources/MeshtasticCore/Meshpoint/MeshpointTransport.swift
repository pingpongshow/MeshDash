import Foundation
import MeshtasticProtobufs
import Synchronization

/// Presents a Meshpoint gateway as if it were a Meshtastic radio.
///
/// A Meshpoint speaks a REST + WebSocket dashboard API, not the client API, so
/// this adapter answers the `want_config_id` handshake by synthesizing the same
/// `FromRadio` messages a radio would send, and turns outgoing `ToRadio`
/// packets back into REST calls. Everything above the transport — the session,
/// the store, the whole UI — is unchanged.
public final class MeshpointTransport: MeshTransport, @unchecked Sendable {
    public let address: DeviceAddress
    public let client: MeshpointClient

    private struct State {
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var isClosing = false
        /// Node number of the gateway itself.
        var myNodeNum: UInt32 = 0
        /// Display name → node number, for attributing historical broadcasts.
        var namesToNodes: [String: UInt32] = [:]
        var channelNames: [Int: String] = [:]
    }

    private let state = Mutex(State())
    private var socketTask: Task<Void, Never>?

    public init(host: String, port: UInt16 = MeshpointClient.defaultPort) {
        self.client = MeshpointClient(host: host, port: port)
        self.address = .meshpoint(host: host, port: port)
    }

    /// Meshpoint enforces its own 228-byte text limit server-side; this is the
    /// ceiling for a synthesized protobuf, which never goes over the air.
    public var maximumPayloadSize: Int { 4096 }

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            state.withLock { $0.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.disconnect() }
            }
        }
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        state.withLock { $0.isClosing = false }
        emit(.status("Contacting the Meshpoint…"))
        try await client.probe()

        guard await client.hasStoredToken else {
            throw MeshpointError.authenticationRequired
        }
        // Prove the stored token still works before declaring the link up, so an
        // expired session surfaces as a sign-in prompt rather than an empty app.
        emit(.status("Signing in…"))
        _ = try await client.deviceStatus()

        emit(.connected)
        startSocket()
    }

    public func disconnect() async {
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        socketTask?.cancel()
        socketTask = nil
        guard let stream else { return }
        stream.yield(.disconnected(nil))
        stream.finish()
    }

    // MARK: - Outbound

    public func send(_ toRadio: Data) async throws {
        guard let message = try? ToRadio(serializedBytes: toRadio),
              let variant = message.payloadVariant else { return }

        switch variant {
        case .wantConfigID(let nonce):
            await bootstrap(nonce: nonce)
        case .packet(let packet):
            await handleOutgoing(packet)
        case .heartbeat, .disconnect:
            break
        default:
            emit(.status("This Meshpoint does not support that request."))
        }
    }

    private func handleOutgoing(_ packet: MeshPacket) async {
        guard case .decoded(let data) = packet.payloadVariant else { return }
        switch data.portnum {
        case .textMessageApp:
            await sendText(packet: packet, data: data)
        case .adminApp:
            await handleAdmin(data: data)
        default:
            emit(.status("A Meshpoint cannot send \(data.portnum.displayName) packets."))
        }
    }

    private func sendText(packet: MeshPacket, data: DataMessage) async {
        let text = String(decoding: data.payload, as: UTF8.self)
        let channel = Int(packet.channel)
        let destination = packet.to == broadcastNodeNum
            ? "broadcast"
            : String(format: "!%08x", packet.to)
        do {
            let result = try await client.send(text: text, destination: destination,
                                               channel: channel, wantAck: packet.wantAck)
            if result.success {
                // Mirror the radio's own acknowledgement so the message stops
                // showing as pending in the UI.
                emitRouting(requestID: packet.id, error: .none, from: state.withLock { $0.myNodeNum })
            } else {
                emitRouting(requestID: packet.id, error: .noResponse, from: state.withLock { $0.myNodeNum })
                emit(.status(result.error ?? "The Meshpoint could not transmit that message."))
            }
        } catch {
            emitRouting(requestID: packet.id, error: .noResponse, from: state.withLock { $0.myNodeNum })
            emit(.status(error.localizedDescription))
        }
    }

    /// Maps the admin messages a Meshpoint can actually honour onto its config
    /// endpoints, and says so plainly for the ones it cannot.
    private func handleAdmin(data: DataMessage) async {
        guard let admin = try? AdminMessage(serializedBytes: data.payload),
              let variant = admin.payloadVariant else { return }
        do {
            switch variant {
            case .setOwner(let user):
                try await client.updateIdentity(longName: user.longName.isEmpty ? nil : user.longName,
                                                shortName: user.shortName.isEmpty ? nil : user.shortName)
                emit(.status("Identity updated."))
            case .setConfig(let config):
                guard case .lora(let lora) = config.payloadVariant else {
                    emit(.status("A Meshpoint only accepts LoRa and identity settings."))
                    return
                }
                let region = lora.region == .unset ? nil : String(describing: lora.region).uppercased()
                let preset = lora.usePreset ? MeshpointMapping.presetName(lora.modemPreset) : nil
                try await client.updateRadio(region: region, preset: preset)
                try await client.updateTransmit(enabled: lora.txEnabled,
                                                txPowerDBm: lora.txPower == 0 ? nil : Int(lora.txPower),
                                                hopLimit: lora.hopLimit == 0 ? nil : Int(lora.hopLimit),
                                                relayEnabled: nil, routerMode: nil)
                emit(.status("Radio settings updated. The Meshpoint may need a restart to apply them."))
            case .beginEditSettings, .commitEditSettings:
                break
            default:
                emit(.status("A Meshpoint does not support that setting."))
            }
        } catch {
            emit(.status(error.localizedDescription))
        }
    }

    // MARK: - Bootstrap

    /// Answers `want_config_id` with the same sequence a radio would send.
    ///
    /// Each step degrades on its own. A field this adapter reads wrongly — the
    /// dashboard API evolves independently of MeshDash — should cost that one
    /// piece of data, never the whole connection.
    private func bootstrap(nonce: UInt32) async {
        emit(.status("Loading gateway configuration…"))

        var configuration = MeshpointAPI.Configuration()
        do {
            configuration = try await client.configuration()
        } catch let error as MeshpointError {
            if case .decodingFailed(let detail) = error {
                emit(.status("Could not read the gateway configuration: \(detail)"))
            } else {
                // Auth or connectivity failures are fatal; nothing else will work.
                await failBootstrap(error)
                return
            }
        } catch {
            await failBootstrap(error)
            return
        }

        let myNodeNum = UInt32(configuration.transmit?.node_id ?? 0)
        state.withLock { $0.myNodeNum = myNodeNum }

        // 1. Identity and metadata.
        var info = MyNodeInfo()
        info.myNodeNum = myNodeNum
        emit(from: { $0.myInfo = info })

        var metadata = DeviceMetadata()
        metadata.firmwareVersion = (try? await client.deviceStatus().firmware_version) ?? ""
        metadata.role = .router
        metadata.hasWifi_p = true
        emit(from: { $0.metadata = metadata })

        // 2. LoRa configuration, so the radio page shows real values.
        emit(from: { $0.config = MeshpointMapping.loRaConfig(from: configuration) })
        emit(from: { $0.moduleConfig = ModuleConfig() })

        // 3. Channels.
        let channels = MeshpointMapping.channels(from: configuration)
        state.withLock {
            $0.channelNames = Dictionary(uniqueKeysWithValues: channels.map {
                (Int($0.index), $0.settings.name)
            })
        }
        for channel in channels {
            emit(from: { $0.channel = channel })
        }

        // 4. The gateway itself, then every node it has heard.
        emit(from: { $0.nodeInfo = MeshpointMapping.selfNodeInfo(from: configuration, num: myNodeNum) })

        var nameIndex: [String: UInt32] = [:]
        do {
            let nodes = try await client.nodes()
            emit(.status("Loading \(nodes.count) nodes…"))
            for node in nodes where (node.protocolName ?? "meshtastic") == "meshtastic" {
                guard let nodeInfo = MeshpointMapping.nodeInfo(from: node) else { continue }
                if nodeInfo.num == myNodeNum { continue }
                if let name = node.display_name ?? node.long_name, !name.isEmpty {
                    nameIndex[name] = nodeInfo.num
                }
                if let short = node.short_name, !short.isEmpty {
                    nameIndex[short] = nodeInfo.num
                }
                emit(from: { $0.nodeInfo = nodeInfo })

                if let telemetry = node.effectiveTelemetry,
                   let packet = MeshpointMapping.telemetryPacket(telemetry, from: nodeInfo.num) {
                    emit(from: { $0.packet = packet })
                }
            }
        } catch let error as MeshpointError {
            if case .decodingFailed(let detail) = error {
                emit(.status("Could not read the node list: \(detail)"))
            } else {
                await failBootstrap(error)
                return
            }
        } catch {
            emit(.status("Could not read the node list: \(error.localizedDescription)"))
        }
        state.withLock { $0.namesToNodes = nameIndex }

        // 5. Message history, replayed as packets so conversations populate.
        emit(.status("Loading message history…"))
        await replayConversations(myNodeNum: myNodeNum, names: nameIndex)

        // 6. Done — this is what unblocks the session.
        emit(from: { $0.configCompleteID = nonce })
    }

    /// Ends the session when the gateway is unreachable or the token is stale.
    private func failBootstrap(_ error: Error) async {
        let stream: AsyncStream<TransportEvent>.Continuation? = state.withLock {
            guard !$0.isClosing else { return nil }
            $0.isClosing = true
            let stream = $0.continuation
            $0.continuation = nil
            return stream
        }
        let transportError: TransportError = (error as? MeshpointError)
            .map { .openFailed($0.localizedDescription) } ?? .readFailed(error.localizedDescription)
        stream?.yield(.disconnected(transportError))
        stream?.finish()
    }

    private func replayConversations(myNodeNum: UInt32, names: [String: UInt32]) async {
        guard let conversations = try? await client.conversations() else { return }
        for conversation in conversations {
            guard (conversation.protocolName ?? "meshtastic") == "meshtastic" else { continue }
            guard let messages = try? await client.messages(in: conversation.node_id) else { continue }
            for message in messages {
                guard let packet = MeshpointMapping.messagePacket(message,
                                                                  conversationID: conversation.node_id,
                                                                  myNodeNum: myNodeNum,
                                                                  names: names,
                                                                  sourceID: nil) else { continue }
                emit(from: { $0.packet = packet })
            }
        }
    }

    // MARK: - Live stream

    private func startSocket() {
        socketTask?.cancel()
        socketTask = Task { [weak self] in
            guard let self else { return }
            // Reconnect the feed on its own; a dropped websocket should not tear
            // down the whole session when REST still works.
            var backoff: UInt64 = 1
            while !Task.isCancelled, !self.state.withLock({ $0.isClosing }) {
                await self.runSocket()
                if Task.isCancelled || self.state.withLock({ $0.isClosing }) { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func runSocket() async {
        guard let token = await client.currentToken() else { return }
        let request = client.socketRequest(token: token)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        while !Task.isCancelled, !state.withLock({ $0.isClosing }) {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let value): text = String(decoding: value, as: UTF8.self)
                @unknown default: continue
                }
                handleSocket(text: text)
            } catch {
                return
            }
        }
    }

    private func handleSocket(text: String) {
        guard let envelope = try? JSONDecoder().decode(MeshpointAPI.SocketEnvelope.self, from: Data(text.utf8)),
              let payload = envelope.data else { return }

        switch envelope.type {
        case "message_received":
            let (myNodeNum, names) = state.withLock { ($0.myNodeNum, $0.namesToNodes) }
            guard let packet = MeshpointMapping.messagePacket(fromSocket: payload,
                                                             myNodeNum: myNodeNum,
                                                             names: names) else { return }
            emit(from: { $0.packet = packet })
        case "packet":
            // Raw packet feed — surfaced in Diagnostics rather than as a message.
            if let summary = MeshpointMapping.packetLogLine(payload) {
                emit(.deviceLog(summary))
            }
        case "noise_floor":
            if let value = payload["noise_floor"]?.doubleValue ?? payload["value"]?.doubleValue {
                emit(.deviceLog("Noise floor: \(Int(value)) dBm\n"))
            }
        default:
            break
        }
    }

    // MARK: - Emission helpers

    private func emit(_ event: TransportEvent) {
        state.withLock { $0.continuation }?.yield(event)
    }

    /// Builds a `FromRadio`, serializes it, and pushes it as a transport payload.
    private func emit(from build: (inout FromRadio) -> Void) {
        var message = FromRadio()
        build(&message)
        guard let data = try? message.serializedData() else { return }
        emit(.payload(data))
    }

    /// Synthesizes the routing ACK that a radio would produce for a sent packet.
    private func emitRouting(requestID: UInt32, error: Routing.Error, from node: UInt32) {
        var routing = Routing()
        routing.errorReason = error

        var data = DataMessage()
        data.portnum = .routingApp
        data.requestID = requestID
        data.payload = (try? routing.serializedData()) ?? Data()

        var packet = MeshPacket()
        packet.id = MeshRadio.makePacketID()
        packet.from = node
        packet.to = node
        packet.decoded = data
        emit(from: { $0.packet = packet })
    }
}
