import Foundation
import MeshtasticProtobufs

/// Speaks the Meshtastic client API over any transport.
///
/// Owns the `want_config_id` handshake, the heartbeat that keeps the link alive,
/// packet ID allocation, and the send queue. Everything above this layer deals in
/// `RadioEvent` values rather than raw bytes.
public actor MeshRadio {
    public nonisolated let transport: any MeshTransport

    private var eventContinuation: AsyncStream<RadioEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var configNonce: UInt32 = 0
    private var isConfigured = false
    private var isShuttingDown = false
    var adminPasskeys: [UInt32: AdminSession] = [:]

    /// The radio drops idle client connections; the Android/iOS apps ping well
    /// inside that window and so do we.
    private let heartbeatInterval: Duration = .seconds(300)

    public init(transport: any MeshTransport) {
        self.transport = transport
    }

    public nonisolated var address: DeviceAddress { transport.address }

    // MARK: - Lifecycle

    /// Opens the link and starts the configuration handshake. The returned stream
    /// finishes when the connection ends.
    public func connect() throws -> AsyncStream<RadioEvent> {
        let (stream, continuation) = AsyncStream<RadioEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation
        isShuttingDown = false
        isConfigured = false

        let transportEvents = transport.events()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.connect()
            } catch {
                await self.finish(with: error as? TransportError ?? .openFailed(error.localizedDescription))
                return
            }
            await self.pump(transportEvents)
        }
        return stream
    }

    public func disconnect() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        // Best effort: tell the radio we are going away so it frees the session.
        var goodbye = ToRadio()
        goodbye.disconnect = true
        try? await sendRaw(goodbye)

        heartbeatTask?.cancel()
        heartbeatTask = nil
        await transport.disconnect()
        pumpTask?.cancel()
        pumpTask = nil
        eventContinuation?.yield(.disconnected(nil))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func finish(with error: TransportError?) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        eventContinuation?.yield(.disconnected(error))
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func pump(_ events: AsyncStream<TransportEvent>) async {
        for await event in events {
            switch event {
            case .connected:
                emit(.linkUp)
                await beginHandshake()
            case .status(let text):
                emit(.status(text))
            case .deviceLog(let text):
                emit(.deviceLog(text))
            case .payload(let data):
                handle(payload: data)
            case .disconnected(let error):
                finish(with: error)
                return
            }
        }
        // The transport stream ended without an explicit disconnect event.
        if !isShuttingDown { finish(with: nil) }
    }

    // MARK: - Handshake

    private func beginHandshake() async {
        emit(.status("Requesting configuration…"))
        configNonce = UInt32.random(in: 1...UInt32.max)
        var request = ToRadio()
        request.wantConfigID = configNonce
        do {
            try await sendRaw(request)
        } catch {
            finish(with: error as? TransportError ?? .writeFailed(error.localizedDescription))
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        var beat = ToRadio()
        beat.heartbeat = Heartbeat()
        try? await sendRaw(beat)
    }

    // MARK: - Inbound

    private func handle(payload: Data) {
        let message: FromRadio
        do {
            message = try FromRadio(serializedBytes: payload)
        } catch {
            emit(.decodeFailure("Could not decode a \(payload.count)-byte packet from the radio."))
            return
        }

        guard let variant = message.payloadVariant else { return }
        switch variant {
        case .packet(let packet):
            emit(.packet(packet))
        case .myInfo(let info):
            emit(.myInfo(info))
        case .nodeInfo(let info):
            emit(.nodeInfo(info))
        case .config(let config):
            emit(.config(config))
        case .moduleConfig(let config):
            emit(.moduleConfig(config))
        case .channel(let channel):
            emit(.channel(channel))
        case .metadata(let metadata):
            emit(.metadata(metadata))
        case .deviceuiConfig(let config):
            emit(.deviceUIConfig(config))
        case .queueStatus(let status):
            emit(.queueStatus(status))
        case .clientNotification(let notification):
            emit(.clientNotification(notification))
        case .fileInfo(let info):
            emit(.fileInfo(info))
        case .mqttClientProxyMessage(let proxy):
            emit(.mqttProxyMessage(proxy))
        case .regionPresets(let presets):
            emit(.regionPresets(presets))
        case .lockdownStatus(let status):
            emit(.lockdownStatus(status))
        case .xmodemPacket(let packet):
            emit(.xmodem(packet))
        case .logRecord(let record):
            emit(.logRecord(record))
        case .rebooted:
            isConfigured = false
            emit(.rebooted)
            Task { await self.beginHandshake() }
        case .configCompleteID(let nonce):
            guard nonce == configNonce else {
                // A stale reply from a previous handshake; ignore it.
                return
            }
            isConfigured = true
            emit(.configComplete)
            startHeartbeat()
        }
    }

    private func emit(_ event: RadioEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Outbound

    /// Sends an already-built `ToRadio`.
    public func sendRaw(_ message: ToRadio) async throws {
        let bytes = try message.serializedData()
        guard bytes.count <= transport.maximumPayloadSize else {
            throw TransportError.writeFailed("Packet is \(bytes.count) bytes, over the \(transport.maximumPayloadSize)-byte limit for this link.")
        }
        try await transport.send(bytes)
    }

    /// Sends a mesh packet, filling in a random ID if the caller did not set one.
    @discardableResult
    public func send(packet: MeshPacket) async throws -> UInt32 {
        var packet = packet
        if packet.id == 0 { packet.id = Self.makePacketID() }
        var message = ToRadio()
        message.packet = packet
        try await sendRaw(message)
        return packet.id
    }

    /// Packet IDs are only required to be unique within a short window, and the
    /// firmware treats them as opaque, so random values are the standard choice.
    public static func makePacketID() -> UInt32 {
        UInt32.random(in: 1...UInt32.max)
    }

    /// Re-requests the full config and node database without reconnecting.
    public func requestConfiguration() async {
        await beginHandshake()
    }

    public var configured: Bool { isConfigured }
}

// MARK: - Remote administration sessions

public extension MeshRadio {
    /// Remote admin requires echoing back a passkey the target node issues, and
    /// the firmware expires them after a few minutes.
    private static var passkeyLifetime: TimeInterval { 300 }

    /// Records a session passkey received in an admin response.
    func storePasskey(_ passkey: Data, for node: UInt32) {
        guard !passkey.isEmpty else { return }
        adminPasskeys[node] = AdminSession(passkey: passkey, issued: Date())
    }

    func passkey(for node: UInt32) -> Data? {
        guard let session = adminPasskeys[node] else { return nil }
        guard Date().timeIntervalSince(session.issued) < Self.passkeyLifetime else {
            adminPasskeys[node] = nil
            return nil
        }
        return session.passkey
    }

    func clearPasskeys() {
        adminPasskeys.removeAll()
    }
}

struct AdminSession: Sendable {
    var passkey: Data
    var issued: Date
}
