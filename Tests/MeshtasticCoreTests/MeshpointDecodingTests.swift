import Foundation
import Testing
@testable import MeshtasticCore

/// Decoding tests for the Meshpoint dashboard API.
///
/// The fixtures below are copied from the shapes the gateway's Python actually
/// emits (`Node.to_dict`, `_enrich_row`, `Message.to_dict`, `get_config`), not
/// from what this adapter wishes it emitted. A `JSONDecoder` fails the whole
/// object on a single type mismatch, so one wrong field here means a connection
/// that dies at the handshake — which is exactly what these guard against.
struct MeshpointDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Configuration

    /// `all_presets_list()` returns a list of objects, not strings. Declaring it
    /// as `[String]` made the entire config response undecodable and stalled the
    /// connection right after sign-in.
    @Test func configurationDecodesWithObjectPresets() throws {
        let json = """
        {
          "radio": {"region": "US", "frequency_mhz": 906.875, "spreading_factor": 11,
                    "bandwidth_khz": 250.0, "coding_rate": "4/5", "sync_word": "0x2B",
                    "preamble_length": 16, "current_preset": "LONG_FAST"},
          "transmit": {"enabled": true, "node_id": 1129467120, "node_id_hex": "!4358aef0",
                       "node_id_source": "config", "tx_power_dbm": 22,
                       "max_duty_cycle_percent": 10.0, "max_duty_cycle_source": "auto",
                       "long_name": "Meshpoint Mesh915", "short_name": "MESH",
                       "hop_limit": 3,
                       "relay": {"enabled": true, "max_relay_per_minute": 10, "router_mode": false}},
          "relay": {"enabled": true, "max_relay_per_minute": 10, "router_mode": false},
          "channels": [{"index": 0, "name": "LongFast", "hash_name": "LongFast",
                        "psk_b64": "AQ==", "hash": "0x08", "enabled": true}],
          "duty_cycle": {"used_percent": 0.42, "remaining_ms": 3567000},
          "meshcore": {"connected": false, "companion_name": "", "radio": {},
                       "companion_expected": false, "status_note": "",
                       "channel_keys": []},
          "presets": [{"name": "LONG_FAST", "display_name": "Long Fast", "sf": 11,
                       "bw_khz": 250.0, "cr": "4/5", "tx_capable": true}],
          "regions": [{"id": "US", "name": "United States", "frequency_mhz": 906.875}],
          "serial": [], "nodeinfo": {}, "position": {}, "telemetry": {}, "mqtt": {}
        }
        """
        let configuration = try decode(MeshpointAPI.Configuration.self, json)
        #expect(configuration.transmit?.node_id == 1_129_467_120)
        #expect(configuration.radio?.current_preset == "LONG_FAST")
        #expect(configuration.relay?.router_mode == false)
        #expect(configuration.channels?.count == 1)
        #expect(configuration.duty_cycle?.used_percent == 0.42)
    }

    @Test func loRaConfigMapsRegionAndPreset() throws {
        let json = """
        {"radio": {"region": "EU_868", "current_preset": "LONG_FAST", "frequency_mhz": 869.525},
         "transmit": {"enabled": true, "tx_power_dbm": 27, "hop_limit": 4}}
        """
        let configuration = try decode(MeshpointAPI.Configuration.self, json)
        let config = MeshpointMapping.loRaConfig(from: configuration)
        #expect(config.lora.region == .eu868)
        #expect(config.lora.modemPreset == .longFast)
        #expect(config.lora.usePreset)
        #expect(config.lora.txPower == 27)
        #expect(config.lora.hopLimit == 4)
    }

    // MARK: - Nodes

    /// `GET /api/nodes` defaults to `enrich=true`, which flattens signal and
    /// telemetry into `latest_*` columns rather than nesting them.
    @Test func enrichedNodeRowDecodes() throws {
        let json = """
        {"node_id": "!a1b2c3d4", "long_name": "Ridge Repeater", "short_name": "RIDG",
         "hardware_model": "RAK4631", "firmware_version": "2.7.4", "protocol": "meshtastic",
         "role": "ROUTER", "public_key": null, "latitude": 37.7749, "longitude": -122.4194,
         "altitude": 120.0, "last_heard": "2026-08-27T18:20:00.123456+00:00",
         "first_seen": "2026-08-01T10:00:00+00:00", "packet_count": 812,
         "display_name": "Ridge Repeater", "has_position": true,
         "latest_rssi": -96.5, "latest_snr": 6.25, "latest_capture_source": "concentrator",
         "latest_battery": 87.0, "latest_voltage": 4.02, "latest_temperature": 21.5,
         "latest_humidity": 44.0, "latest_channel_util": 3.5, "latest_air_util": 1.25,
         "latest_hops": 2}
        """
        let node = try decode(MeshpointAPI.Node.self, json)
        #expect(node.effectiveSNR == 6.25)
        #expect(node.effectiveRSSI == -96.5)
        #expect(node.effectiveTelemetry?.battery_level == 87.0)
        #expect(node.latest_hops == 2)

        let info = try #require(MeshpointMapping.nodeInfo(from: node))
        #expect(info.num == 0xA1B2_C3D4)
        #expect(info.user.longName == "Ridge Repeater")
        #expect(info.user.role == .router)
        #expect(info.snr == 6.25)
        #expect(info.hopsAway == 2)
        #expect(info.position.latitudeI == 377_749_000)
        #expect(info.deviceMetrics.batteryLevel == 87)
    }

    /// The un-enriched shape (`enrich=false`) nests the same data instead.
    @Test func nestedNodeRowDecodes() throws {
        let json = """
        {"node_id": "!00ff00ff", "long_name": "Nested", "short_name": "NST",
         "protocol": "meshtastic", "last_heard": "2026-08-27T18:20:00+00:00",
         "first_seen": "2026-08-01T10:00:00+00:00", "packet_count": 3,
         "display_name": "Nested", "has_position": false,
         "latest_signal": {"rssi": -80.0, "snr": 9.0, "timestamp": "2026-08-27T18:20:00+00:00"},
         "latest_telemetry": {"node_id": "!00ff00ff", "battery_level": 55.0,
                              "timestamp": "2026-08-27T18:20:00+00:00"}}
        """
        let node = try decode(MeshpointAPI.Node.self, json)
        #expect(node.effectiveSNR == 9.0)
        #expect(node.effectiveTelemetry?.battery_level == 55.0)
    }

    @Test func nodeIdParsingHandlesEveryForm() {
        #expect(MeshpointMapping.nodeNum(from: "!4358aef0") == 0x4358_AEF0)
        #expect(MeshpointMapping.nodeNum(from: "0x4358aef0") == 0x4358_AEF0)
        #expect(MeshpointMapping.nodeNum(from: "4358aef0") == 0x4358_AEF0)
        #expect(MeshpointMapping.nodeNum(from: "") == nil)
        #expect(MeshpointMapping.nodeNum(from: nil) == nil)
        // MeshCore contact ids are not node numbers and must not be coerced.
        #expect(MeshpointMapping.nodeNum(from: "meshcore-contact") == nil)
    }

    // MARK: - Messages

    @Test func conversationAndMessagesDecode() throws {
        let conversationJSON = """
        [{"node_id": "broadcast:meshtastic:0", "node_name": "LongFast",
          "protocol": "meshtastic", "last_message": "hello",
          "last_timestamp": "2026-08-27T18:20:00+00:00", "unread_count": 2,
          "is_broadcast": true}]
        """
        let conversations = try decode([MeshpointAPI.Conversation].self, conversationJSON)
        #expect(conversations.first?.unread_count == 2)
        #expect(MeshpointMapping.channelIndex(fromConversation: "broadcast:meshtastic:0") == 0)
        #expect(MeshpointMapping.channelIndex(fromConversation: "broadcast:meshtastic:3") == 3)
        #expect(MeshpointMapping.channelIndex(fromConversation: "!4358aef0") == nil)

        let messageJSON = """
        [{"id": 91, "direction": "received", "text": "SL boulevard",
          "node_id": "broadcast:meshtastic:0", "node_name": "Ridge Repeater",
          "protocol": "meshtastic", "channel": 0,
          "timestamp": "2026-08-27T18:20:00.500000+00:00", "status": "received",
          "packet_id": "0x1a2b3c4d", "rx_count": 2, "rssi": -95.5, "snr": 5.5}]
        """
        let messages = try decode([MeshpointAPI.Message].self, messageJSON)
        let message = try #require(messages.first)

        let packet = try #require(MeshpointMapping.messagePacket(
            message, conversationID: "broadcast:meshtastic:0",
            myNodeNum: 0x4358_AEF0, names: ["Ridge Repeater": 0xA1B2_C3D4], sourceID: nil))
        #expect(packet.to == broadcastNodeNum)
        // Stored broadcasts carry only the sender's name, so it is resolved here.
        #expect(packet.from == 0xA1B2_C3D4)
        #expect(packet.id == 0x1A2B_3C4D)
        #expect(packet.rxSnr == 5.5)
    }

    /// A direct message resolves its peer from the conversation id.
    @Test func directMessageMapsBothDirections() throws {
        let json = """
        {"id": 4, "direction": "sent", "text": "on my way", "node_id": "!a1b2c3d4",
         "protocol": "meshtastic", "channel": 0, "timestamp": "2026-08-27T18:20:00+00:00",
         "status": "sent", "packet_id": "12345"}
        """
        let message = try decode(MeshpointAPI.Message.self, json)
        let outgoing = try #require(MeshpointMapping.messagePacket(
            message, conversationID: "!a1b2c3d4", myNodeNum: 0x4358_AEF0, names: [:], sourceID: nil))
        #expect(outgoing.from == 0x4358_AEF0)
        #expect(outgoing.to == 0xA1B2_C3D4)
    }

    /// The live websocket payload carries the real sender, unlike stored history.
    @Test func websocketMessageUsesSourceID() throws {
        let json = """
        {"text": "live one", "node_id": "broadcast:meshtastic:0", "node_name": "Somebody",
         "protocol": "meshtastic", "direction": "received", "packet_id": "0xdeadbeef",
         "source_id": "!00c0ffee", "destination_id": "^all", "rssi": -101.0, "snr": -2.5}
        """
        let payload = try decode(MeshpointAPI.JSONValue.self, json)
        let packet = try #require(MeshpointMapping.messagePacket(
            fromSocket: payload, myNodeNum: 0x4358_AEF0, names: [:]))
        #expect(packet.from == 0x00C0_FFEE)
        #expect(packet.to == broadcastNodeNum)
        #expect(packet.id == 0xDEAD_BEEF)
    }

    /// MeshCore traffic shares the feed but is a different protocol; it must not
    /// be presented as a Meshtastic message.
    @Test func websocketIgnoresMeshCore() throws {
        let json = """
        {"text": "mc", "node_id": "broadcast:meshcore:0", "protocol": "meshcore",
         "direction": "received", "packet_id": "1"}
        """
        let payload = try decode(MeshpointAPI.JSONValue.self, json)
        #expect(MeshpointMapping.messagePacket(fromSocket: payload, myNodeNum: 1, names: [:]) == nil)
    }

    // MARK: - Misc

    @Test func packetIDFallbackIsStable() {
        let first = MeshpointMapping.packetID(nil, fallbackSeed: "msg-91-broadcast:meshtastic:0")
        let second = MeshpointMapping.packetID("", fallbackSeed: "msg-91-broadcast:meshtastic:0")
        #expect(first == second)
        #expect(first != 0)
        #expect(first != MeshpointMapping.packetID(nil, fallbackSeed: "msg-92-broadcast:meshtastic:0"))
    }

    @Test func timestampsParseInEveryFormTheAPIEmits() {
        #expect(MeshpointDate.parse("2026-08-27T18:20:00+00:00") != nil)
        #expect(MeshpointDate.parse("2026-08-27T18:20:00.123456+00:00") != nil)
        // `datetime.utcnow().isoformat()` emits no timezone at all.
        #expect(MeshpointDate.parse("2026-08-27T18:20:00.123456") != nil)
        #expect(MeshpointDate.parse("2026-08-27T18:20:00") != nil)
        #expect(MeshpointDate.parse(nil) == nil)
    }

    @Test func presetNameRoundTripsToFirmwareSpelling() {
        #expect(MeshpointMapping.presetName(.longFast) == "LONG_FAST")
        #expect(MeshpointMapping.presetName(.veryLongSlow) == "VERY_LONG_SLOW")
        #expect(MeshpointMapping.modemPreset("LONG_FAST") == .longFast)
        #expect(MeshpointMapping.regionCode("EU_868") == .eu868)
        #expect(MeshpointMapping.regionCode("US") == .us)
    }
}

/// Migration of the remembered-device table.
struct KnownDeviceMigrationTests {

    /// The old schema keyed rows on the Codable JSON, which could encode the
    /// same address two different ways and so store one device twice. The
    /// migration must collapse those without losing the user's devices.
    @Test func legacyRowsAreCarriedOverAndDeduplicated() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "meshdash-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build the legacy table by hand, including the duplicate pair.
        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.execute("""
            CREATE TABLE known_devices (
                address_json TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                detail TEXT NOT NULL,
                last_connected REAL NOT NULL
            );
            """)
        let rows = [
            ("{\"meshpoint\":{\"host\":\"10.1.1.62\",\"port\":8080}}", "10.1.1.62", "older", 1000.0),
            ("{\"meshpoint\":{\"port\":8080,\"host\":\"10.1.1.62\"}}", "10.1.1.62", "newer", 2000.0),
            ("{\"bluetooth\":{\"uuid\":\"F046DA7B-0000-0000-0000-000000000000\"}}", "Meshtastic_aef0", "ble", 1500.0),
        ]
        for row in rows {
            try legacy.run("INSERT INTO known_devices VALUES (?1,?2,?3,?4)",
                           [.text(row.0), .text(row.1), .text(row.2), .real(row.3)])
        }

        // Opening a store runs the migration.
        let store = try MeshStore(fileURL: url)
        let devices = try await store.knownDevices()

        #expect(devices.count == 2, "the duplicate pair should collapse to one device")
        let meshpoints = devices.filter { $0.address.kind == .meshpoint }
        #expect(meshpoints.count == 1)
        // The newer of the two duplicates wins.
        #expect(meshpoints.first?.detail == "newer")
        #expect(devices.contains { $0.address.kind == .bluetooth })
    }

    @Test func storageKeysAreCanonical() {
        #expect(DeviceAddress.meshpoint(host: "10.1.1.62", port: 8080).storageKey
                == DeviceAddress.meshpoint(host: "10.1.1.62", port: 8080).storageKey)
        #expect(DeviceAddress.tcp(host: "10.1.1.62", port: 4403).storageKey
                != DeviceAddress.meshpoint(host: "10.1.1.62", port: 4403).storageKey)
    }
}
