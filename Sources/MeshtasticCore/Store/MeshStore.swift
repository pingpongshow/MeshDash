import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

/// On-disk history: nodes, conversations, position tracks, telemetry, waypoints
/// and traceroutes, scoped per connected radio so two radios do not blend.
///
/// Protobuf-shaped values are stored as their serialized bytes alongside a few
/// derived columns for sorting and filtering, which keeps the schema stable as
/// the upstream protobufs gain fields.
public actor MeshStore {
    private let database: SQLiteDatabase
    public nonisolated let fileURL: URL

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        self.fileURL = fileURL
        self.database = try SQLiteDatabase(path: fileURL.path)
        try Self.createSchema(in: database)
    }

    /// Default location under Application Support.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appending(path: "MeshDash/MeshDash.sqlite")
    }

    private static func createSchema(in database: SQLiteDatabase) throws {
        try migrateKnownDevices(in: database)

        try database.execute("""
        CREATE TABLE IF NOT EXISTS nodes (
            radio_id     TEXT NOT NULL,
            num          INTEGER NOT NULL,
            user_proto   BLOB,
            position_proto BLOB,
            device_metrics_proto BLOB,
            environment_proto BLOB,
            air_quality_proto BLOB,
            power_proto  BLOB,
            health_proto BLOB,
            last_heard   REAL,
            snr          REAL,
            rssi         INTEGER,
            hops_away    INTEGER,
            channel      INTEGER NOT NULL DEFAULT 0,
            via_mqtt     INTEGER NOT NULL DEFAULT 0,
            is_favorite  INTEGER NOT NULL DEFAULT 0,
            is_ignored   INTEGER NOT NULL DEFAULT 0,
            is_muted     INTEGER NOT NULL DEFAULT 0,
            key_verified INTEGER NOT NULL DEFAULT 0,
            neighbors_proto BLOB,
            neighbors_updated REAL,
            pax_wifi     INTEGER,
            pax_ble      INTEGER,
            pax_uptime   INTEGER,
            PRIMARY KEY (radio_id, num)
        );

        CREATE TABLE IF NOT EXISTS messages (
            radio_id     TEXT NOT NULL,
            id           INTEGER NOT NULL,
            conversation TEXT NOT NULL,
            from_node    INTEGER NOT NULL,
            to_node      INTEGER NOT NULL,
            text         TEXT NOT NULL,
            timestamp    REAL NOT NULL,
            status       INTEGER NOT NULL,
            reaction_to  INTEGER,
            reply_to     INTEGER,
            is_emoji     INTEGER NOT NULL DEFAULT 0,
            snr          REAL,
            rssi         INTEGER,
            hops_away    INTEGER,
            via_mqtt     INTEGER NOT NULL DEFAULT 0,
            channel_index INTEGER NOT NULL DEFAULT 0,
            portnum      INTEGER NOT NULL DEFAULT 1,
            failure_reason TEXT,
            pki          INTEGER NOT NULL DEFAULT 0,
            is_read      INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (radio_id, id)
        );
        CREATE INDEX IF NOT EXISTS messages_conversation
            ON messages (radio_id, conversation, timestamp);

        CREATE TABLE IF NOT EXISTS positions (
            radio_id  TEXT NOT NULL,
            node_num  INTEGER NOT NULL,
            time      REAL NOT NULL,
            latitude  REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude  INTEGER,
            speed     REAL,
            heading   REAL,
            satellites INTEGER,
            precision_bits INTEGER,
            PRIMARY KEY (radio_id, node_num, time)
        );

        CREATE TABLE IF NOT EXISTS telemetry (
            radio_id TEXT NOT NULL,
            node_num INTEGER NOT NULL,
            kind     TEXT NOT NULL,
            time     REAL NOT NULL,
            metrics  TEXT NOT NULL,
            PRIMARY KEY (radio_id, node_num, kind, time)
        );

        CREATE TABLE IF NOT EXISTS waypoints (
            radio_id TEXT NOT NULL,
            id       INTEGER NOT NULL,
            proto    BLOB NOT NULL,
            from_node INTEGER NOT NULL,
            received REAL NOT NULL,
            PRIMARY KEY (radio_id, id)
        );

        CREATE TABLE IF NOT EXISTS traceroutes (
            radio_id TEXT NOT NULL,
            id       INTEGER NOT NULL,
            target   INTEGER NOT NULL,
            requested REAL NOT NULL,
            completed REAL,
            forward_json TEXT NOT NULL DEFAULT '[]',
            return_json  TEXT NOT NULL DEFAULT '[]',
            failure  TEXT,
            PRIMARY KEY (radio_id, id)
        );

        CREATE TABLE IF NOT EXISTS known_devices (
            address_key  TEXT PRIMARY KEY,
            address_json TEXT NOT NULL,
            name         TEXT NOT NULL,
            detail       TEXT NOT NULL,
            last_connected REAL NOT NULL
        );
        """)
    }

    /// Earlier builds keyed known devices on the Codable JSON, which is not
    /// guaranteed to encode identically for the same value and so produced
    /// duplicate rows. Rebuild the table on a canonical key, carrying the
    /// user's saved devices across rather than making them pair again.
    private static func migrateKnownDevices(in database: SQLiteDatabase) throws {
        let isLegacy = !((try? database.query(
            """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name='known_devices' AND sql LIKE '%address_json TEXT PRIMARY KEY%'
            """) { $0.string(0) }) ?? []).isEmpty
        guard isLegacy else { return }

        struct Saved {
            var address: DeviceAddress
            var json: String
            var name: String
            var detail: String
            var lastConnected: Date
        }
        let saved: [Saved] = ((try? database.query(
            "SELECT address_json, name, detail, last_connected FROM known_devices ORDER BY last_connected ASC") { row in
                (row.string(0), row.string(1), row.string(2), row.date(3))
        }) ?? []).compactMap { entry in
            guard let address = try? JSONDecoder().decode(DeviceAddress.self, from: Data(entry.0.utf8)) else { return nil }
            return Saved(address: address, json: entry.0, name: entry.1, detail: entry.2, lastConnected: entry.3)
        }

        try database.execute("DROP TABLE known_devices;")
        try database.execute("""
            CREATE TABLE known_devices (
                address_key  TEXT PRIMARY KEY,
                address_json TEXT NOT NULL,
                name         TEXT NOT NULL,
                detail       TEXT NOT NULL,
                last_connected REAL NOT NULL
            );
            """)
        // Oldest first, so duplicates collapse onto the most recent entry.
        for device in saved {
            try database.run("""
                INSERT OR REPLACE INTO known_devices
                    (address_key, address_json, name, detail, last_connected)
                VALUES (?1,?2,?3,?4,?5)
                """, [.text(device.address.storageKey), .text(device.json),
                      .text(device.name), .text(device.detail), SQLValue(device.lastConnected)])
        }
    }

    // MARK: - Nodes

    public func saveNode(_ node: MeshNode, radioID: String) throws {
        try database.run("""
            INSERT INTO nodes (radio_id, num, user_proto, position_proto, device_metrics_proto,
                environment_proto, air_quality_proto, power_proto, health_proto,
                last_heard, snr, rssi, hops_away, channel, via_mqtt, is_favorite, is_ignored,
                is_muted, key_verified, neighbors_proto, neighbors_updated, pax_wifi, pax_ble, pax_uptime)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24)
            ON CONFLICT(radio_id, num) DO UPDATE SET
                user_proto=COALESCE(excluded.user_proto, user_proto),
                position_proto=COALESCE(excluded.position_proto, position_proto),
                device_metrics_proto=COALESCE(excluded.device_metrics_proto, device_metrics_proto),
                environment_proto=COALESCE(excluded.environment_proto, environment_proto),
                air_quality_proto=COALESCE(excluded.air_quality_proto, air_quality_proto),
                power_proto=COALESCE(excluded.power_proto, power_proto),
                health_proto=COALESCE(excluded.health_proto, health_proto),
                last_heard=COALESCE(excluded.last_heard, last_heard),
                snr=COALESCE(excluded.snr, snr),
                rssi=COALESCE(excluded.rssi, rssi),
                hops_away=COALESCE(excluded.hops_away, hops_away),
                channel=excluded.channel,
                via_mqtt=excluded.via_mqtt,
                is_favorite=excluded.is_favorite,
                is_ignored=excluded.is_ignored,
                is_muted=excluded.is_muted,
                key_verified=excluded.key_verified,
                neighbors_proto=COALESCE(excluded.neighbors_proto, neighbors_proto),
                neighbors_updated=COALESCE(excluded.neighbors_updated, neighbors_updated),
                pax_wifi=COALESCE(excluded.pax_wifi, pax_wifi),
                pax_ble=COALESCE(excluded.pax_ble, pax_ble),
                pax_uptime=COALESCE(excluded.pax_uptime, pax_uptime)
            """, [
                .text(radioID), SQLValue(node.num),
                blob(node.user), blob(node.position), blob(node.deviceMetrics),
                blob(node.environmentMetrics), blob(node.airQualityMetrics),
                blob(node.powerMetrics), blob(node.healthMetrics),
                SQLValue(node.lastHeard), SQLValue(node.snr), SQLValue(node.rssi),
                SQLValue(node.hopsAway), SQLValue(node.channel), SQLValue(node.viaMQTT),
                SQLValue(node.isFavorite), SQLValue(node.isIgnored), SQLValue(node.isMuted),
                SQLValue(node.isKeyManuallyVerified),
                neighborBlob(node.neighbors), SQLValue(node.neighborsUpdated),
                SQLValue(node.paxWifi), SQLValue(node.paxBle), SQLValue(node.paxUptime),
            ])
    }

    public func loadNodes(radioID: String) throws -> [MeshNode] {
        try database.query("""
            SELECT num, user_proto, position_proto, device_metrics_proto, environment_proto,
                   air_quality_proto, power_proto, health_proto, last_heard, snr, rssi, hops_away,
                   channel, via_mqtt, is_favorite, is_ignored, is_muted, key_verified,
                   neighbors_proto, neighbors_updated, pax_wifi, pax_ble, pax_uptime
            FROM nodes WHERE radio_id = ?1
            """, [.text(radioID)]) { row in
            var node = MeshNode(num: row.uint32(0))
            node.user = decode(User.self, row, 1)
            node.position = decode(Position.self, row, 2)
            node.deviceMetrics = decode(DeviceMetrics.self, row, 3)
            node.environmentMetrics = decode(EnvironmentMetrics.self, row, 4)
            node.airQualityMetrics = decode(AirQualityMetrics.self, row, 5)
            node.powerMetrics = decode(PowerMetrics.self, row, 6)
            node.healthMetrics = decode(HealthMetrics.self, row, 7)
            node.lastHeard = row.dateOptional(8)
            node.snr = row.floatOptional(9)
            node.rssi = row.intOptional(10).map(Int.init)
            node.hopsAway = row.intOptional(11).map(Int.init)
            node.channel = Int(row.int(12))
            node.viaMQTT = row.bool(13)
            node.isFavorite = row.bool(14)
            node.isIgnored = row.bool(15)
            node.isMuted = row.bool(16)
            node.isKeyManuallyVerified = row.bool(17)
            if !row.isNull(18), let list = try? NeighborInfo(serializedBytes: row.data(18)) {
                node.neighbors = list.neighbors
            }
            node.neighborsUpdated = row.dateOptional(19)
            node.paxWifi = row.intOptional(20).map { UInt32(truncatingIfNeeded: $0) }
            node.paxBle = row.intOptional(21).map { UInt32(truncatingIfNeeded: $0) }
            node.paxUptime = row.intOptional(22).map { UInt32(truncatingIfNeeded: $0) }
            return node
        }
    }

    public func deleteNode(_ num: UInt32, radioID: String) throws {
        try database.transaction {
            try database.run("DELETE FROM nodes WHERE radio_id = ?1 AND num = ?2", [.text(radioID), SQLValue(num)])
            try database.run("DELETE FROM positions WHERE radio_id = ?1 AND node_num = ?2", [.text(radioID), SQLValue(num)])
            try database.run("DELETE FROM telemetry WHERE radio_id = ?1 AND node_num = ?2", [.text(radioID), SQLValue(num)])
        }
    }

    // MARK: - Messages

    public func saveMessage(_ message: MeshMessage, radioID: String) throws {
        try database.run("""
            INSERT INTO messages (radio_id, id, conversation, from_node, to_node, text, timestamp,
                status, reaction_to, reply_to, is_emoji, snr, rssi, hops_away, via_mqtt,
                channel_index, portnum, failure_reason, pki, is_read)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)
            ON CONFLICT(radio_id, id) DO UPDATE SET
                status=excluded.status,
                failure_reason=excluded.failure_reason,
                is_read=excluded.is_read,
                text=excluded.text
            """, [
                .text(radioID), SQLValue(message.id), .text(message.conversation.storageKey),
                SQLValue(message.fromNode), SQLValue(message.toNode), .text(message.text),
                SQLValue(message.timestamp), SQLValue(message.status.rawValue),
                SQLValue(message.reactionTo), SQLValue(message.replyTo),
                SQLValue(message.isEmojiReaction), SQLValue(message.snr), SQLValue(message.rssi),
                SQLValue(message.hopsAway), SQLValue(message.viaMQTT),
                SQLValue(message.channelIndex), SQLValue(message.portnum.rawValue),
                SQLValue(message.failureReason), SQLValue(message.isPKIEncrypted), SQLValue(message.isRead),
            ])
    }

    public func loadMessages(radioID: String, limit: Int = 5000) throws -> [MeshMessage] {
        try database.query("""
            SELECT id, conversation, from_node, to_node, text, timestamp, status, reaction_to,
                   reply_to, is_emoji, snr, rssi, hops_away, via_mqtt, channel_index, portnum,
                   failure_reason, pki, is_read
            FROM messages WHERE radio_id = ?1 ORDER BY timestamp DESC LIMIT ?2
            """, [.text(radioID), SQLValue(limit)]) { row in
            MeshMessage(id: row.uint32(0),
                        conversation: ConversationKey(storageKey: row.string(1)) ?? .channel(0),
                        fromNode: row.uint32(2),
                        toNode: row.uint32(3),
                        text: row.string(4),
                        timestamp: row.date(5),
                        status: MessageStatus(rawValue: Int(row.int(6))) ?? .received,
                        reactionTo: row.intOptional(7).map { UInt32(truncatingIfNeeded: $0) },
                        replyTo: row.intOptional(8).map { UInt32(truncatingIfNeeded: $0) },
                        isEmojiReaction: row.bool(9),
                        snr: row.floatOptional(10),
                        rssi: row.intOptional(11).map(Int.init),
                        hopsAway: row.intOptional(12).map(Int.init),
                        viaMQTT: row.bool(13),
                        channelIndex: Int(row.int(14)),
                        portnum: PortNum(rawValue: Int(row.int(15))) ?? .textMessageApp,
                        failureReason: row.stringOptional(16),
                        isPKIEncrypted: row.bool(17),
                        isRead: row.bool(18))
        }.reversed()
    }

    public func markConversationRead(_ conversation: ConversationKey, radioID: String) throws {
        try database.run("UPDATE messages SET is_read = 1 WHERE radio_id = ?1 AND conversation = ?2",
                         [.text(radioID), .text(conversation.storageKey)])
    }

    public func deleteMessage(_ id: UInt32, radioID: String) throws {
        try database.run("DELETE FROM messages WHERE radio_id = ?1 AND id = ?2", [.text(radioID), SQLValue(id)])
    }

    public func deleteConversation(_ conversation: ConversationKey, radioID: String) throws {
        try database.run("DELETE FROM messages WHERE radio_id = ?1 AND conversation = ?2",
                         [.text(radioID), .text(conversation.storageKey)])
    }

    // MARK: - Positions

    public func savePosition(_ sample: PositionSample, radioID: String) throws {
        try database.run("""
            INSERT OR REPLACE INTO positions
                (radio_id, node_num, time, latitude, longitude, altitude, speed, heading, satellites, precision_bits)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
            """, [
                .text(radioID), SQLValue(sample.nodeNum), SQLValue(sample.time),
                SQLValue(sample.latitude), SQLValue(sample.longitude),
                SQLValue(sample.altitude.map(Int.init)), SQLValue(sample.speedKmH),
                SQLValue(sample.headingDegrees), SQLValue(sample.satellites),
                SQLValue(sample.precisionBits),
            ])
    }

    public func positions(for node: UInt32, radioID: String, since: Date? = nil, limit: Int = 2000) throws -> [PositionSample] {
        let cutoff = since?.timeIntervalSince1970 ?? 0
        return try database.query("""
            SELECT node_num, time, latitude, longitude, altitude, speed, heading, satellites, precision_bits
            FROM positions WHERE radio_id = ?1 AND node_num = ?2 AND time >= ?3
            ORDER BY time DESC LIMIT ?4
            """, [.text(radioID), SQLValue(node), .real(cutoff), SQLValue(limit)]) { row in
            PositionSample(nodeNum: row.uint32(0),
                           time: row.date(1),
                           latitude: row.double(2),
                           longitude: row.double(3),
                           altitude: row.intOptional(4).map { Int32(truncatingIfNeeded: $0) },
                           speedKmH: row.doubleOptional(5),
                           headingDegrees: row.doubleOptional(6),
                           satellites: row.intOptional(7).map(Int.init),
                           precisionBits: row.intOptional(8).map(Int.init))
        }.reversed()
    }

    // MARK: - Telemetry

    public func saveTelemetry(_ sample: TelemetrySample, radioID: String) throws {
        let json = (try? JSONSerialization.data(withJSONObject: sample.metrics)) ?? Data("{}".utf8)
        try database.run("""
            INSERT OR REPLACE INTO telemetry (radio_id, node_num, kind, time, metrics)
            VALUES (?1,?2,?3,?4,?5)
            """, [.text(radioID), SQLValue(sample.nodeNum), .text(sample.kind.rawValue),
                  SQLValue(sample.time), .text(String(decoding: json, as: UTF8.self))])
    }

    public func telemetry(for node: UInt32, kind: TelemetryKind, radioID: String,
                          since: Date? = nil, limit: Int = 2000) throws -> [TelemetrySample] {
        let cutoff = since?.timeIntervalSince1970 ?? 0
        return try database.query("""
            SELECT node_num, kind, time, metrics FROM telemetry
            WHERE radio_id = ?1 AND node_num = ?2 AND kind = ?3 AND time >= ?4
            ORDER BY time DESC LIMIT ?5
            """, [.text(radioID), SQLValue(node), .text(kind.rawValue), .real(cutoff), SQLValue(limit)]) { row in
            let metrics = (try? JSONSerialization.jsonObject(with: Data(row.string(3).utf8))) as? [String: Double] ?? [:]
            return TelemetrySample(nodeNum: row.uint32(0),
                                   kind: TelemetryKind(rawValue: row.string(1)) ?? .device,
                                   time: row.date(2),
                                   metrics: metrics)
        }.reversed()
    }

    // MARK: - Waypoints

    public func saveWaypoint(_ waypoint: Waypoint, from node: UInt32, radioID: String) throws {
        try database.run("""
            INSERT OR REPLACE INTO waypoints (radio_id, id, proto, from_node, received)
            VALUES (?1,?2,?3,?4,?5)
            """, [.text(radioID), SQLValue(waypoint.id), .blob(try waypoint.serializedData()),
                  SQLValue(node), SQLValue(Date())])
    }

    public func deleteWaypoint(_ id: UInt32, radioID: String) throws {
        try database.run("DELETE FROM waypoints WHERE radio_id = ?1 AND id = ?2", [.text(radioID), SQLValue(id)])
    }

    public func loadWaypoints(radioID: String) throws -> [(waypoint: Waypoint, from: UInt32)] {
        try database.query("SELECT proto, from_node FROM waypoints WHERE radio_id = ?1", [.text(radioID)]) { row in
            (try? Waypoint(serializedBytes: row.data(0)), row.uint32(1))
        }.compactMap { pair in
            pair.0.map { ($0, pair.1) }
        }
    }

    // MARK: - Traceroutes

    public func saveTraceroute(_ result: TracerouteResult, radioID: String) throws {
        func encode(_ hops: [TracerouteResult.Hop]) -> String {
            let array = hops.map { ["node": Double($0.nodeNum), "snr": Double($0.snr ?? 0)] }
            let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        try database.run("""
            INSERT OR REPLACE INTO traceroutes
                (radio_id, id, target, requested, completed, forward_json, return_json, failure)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
            """, [.text(radioID), SQLValue(result.id), SQLValue(result.target),
                  SQLValue(result.requestedAt), SQLValue(result.completedAt),
                  .text(encode(result.forwardRoute)), .text(encode(result.returnRoute)),
                  SQLValue(result.failureReason)])
    }

    public func loadTraceroutes(radioID: String, limit: Int = 200) throws -> [TracerouteResult] {
        func decodeHops(_ json: String) -> [TracerouteResult.Hop] {
            guard let array = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Double]] else { return [] }
            return array.map { entry in
                TracerouteResult.Hop(nodeNum: UInt32(entry["node"] ?? 0),
                                     snr: entry["snr"].flatMap { $0 == 0 ? nil : Float($0) })
            }
        }
        return try database.query("""
            SELECT id, target, requested, completed, forward_json, return_json, failure
            FROM traceroutes WHERE radio_id = ?1 ORDER BY requested DESC LIMIT ?2
            """, [.text(radioID), SQLValue(limit)]) { row in
            var result = TracerouteResult(id: row.uint32(0), target: row.uint32(1), requestedAt: row.date(2))
            result.completedAt = row.dateOptional(3)
            result.forwardRoute = decodeHops(row.string(4))
            result.returnRoute = decodeHops(row.string(5))
            result.failureReason = row.stringOptional(6)
            return result
        }
    }

    // MARK: - Known devices

    public func rememberDevice(_ device: DiscoveredDevice) throws {
        let encoder = JSONEncoder()
        // Deterministic output, so a value always encodes to the same string.
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(device.address) else { return }
        try database.run("""
            INSERT OR REPLACE INTO known_devices (address_key, address_json, name, detail, last_connected)
            VALUES (?1,?2,?3,?4,?5)
            """, [.text(device.address.storageKey), .text(String(decoding: json, as: UTF8.self)),
                  .text(device.name), .text(device.detail), SQLValue(Date())])
    }

    public func knownDevices() throws -> [DiscoveredDevice] {
        try database.query("SELECT address_json, name, detail FROM known_devices ORDER BY last_connected DESC") { row in
            (row.string(0), row.string(1), row.string(2))
        }.compactMap { entry in
            guard let address = try? JSONDecoder().decode(DeviceAddress.self, from: Data(entry.0.utf8)) else { return nil }
            return DiscoveredDevice(address: address, name: entry.1, detail: entry.2)
        }
    }

    public func forgetDevice(_ address: DeviceAddress) throws {
        try database.run("DELETE FROM known_devices WHERE address_key = ?1", [.text(address.storageKey)])
    }

    // MARK: - Maintenance

    /// Drops history older than the retention window, keeping the file bounded.
    public func pruneHistory(olderThan cutoff: Date) throws {
        let stamp = SQLValue(cutoff)
        try database.transaction {
            try database.run("DELETE FROM positions WHERE time < ?1", [stamp])
            try database.run("DELETE FROM telemetry WHERE time < ?1", [stamp])
            try database.run("DELETE FROM traceroutes WHERE requested < ?1", [stamp])
        }
    }

    public func eraseAll(radioID: String) throws {
        try database.transaction {
            for table in ["nodes", "messages", "positions", "telemetry", "waypoints", "traceroutes"] {
                try database.run("DELETE FROM \(table) WHERE radio_id = ?1", [.text(radioID)])
            }
        }
    }

    public func vacuum() throws {
        try database.execute("VACUUM;")
    }

    // MARK: - Helpers

    private func blob<T: SwiftProtobuf.Message>(_ value: T?) -> SQLValue {
        guard let value, let data = try? value.serializedData() else { return .null }
        return .blob(data)
    }

    private func neighborBlob(_ neighbors: [Neighbor]) -> SQLValue {
        guard !neighbors.isEmpty else { return .null }
        var info = NeighborInfo()
        info.neighbors = neighbors
        guard let data = try? info.serializedData() else { return .null }
        return .blob(data)
    }
}


private func decode<T: SwiftProtobuf.Message>(_ type: T.Type, _ row: SQLRow, _ index: Int32) -> T? {
    guard !row.isNull(index) else { return nil }
    let data = row.data(index)
    guard !data.isEmpty else { return nil }
    return try? T(serializedBytes: data)
}
