import Foundation

/// Wire types for the Meshpoint dashboard API. Field names mirror the FastAPI
/// responses exactly; anything optional there is optional here, because a
/// gateway with no GPS, no MeshCore companion or no telemetry will omit them.
public enum MeshpointAPI {

    // MARK: - Nodes

    public struct Signal: Decodable, Sendable {
        public var rssi: Double?
        public var snr: Double?
        public var frequency_mhz: Double?
        public var spreading_factor: Int?
        public var bandwidth_khz: Double?
        public var signal_quality_percent: Double?
        public var timestamp: String?
    }

    public struct Telemetry: Decodable, Sendable {
        public var node_id: String?
        public var battery_level: Double?
        public var voltage: Double?
        public var temperature: Double?
        public var humidity: Double?
        public var barometric_pressure: Double?
        public var channel_utilization: Double?
        public var air_util_tx: Double?
        public var uptime_seconds: Double?
        public var timestamp: String?
    }

    public struct Node: Decodable, Sendable {
        public var node_id: String
        public var long_name: String?
        public var short_name: String?
        public var hardware_model: String?
        public var firmware_version: String?
        public var protocolName: String?
        public var role: String?
        public var public_key: String?
        public var latitude: Double?
        public var longitude: Double?
        public var altitude: Double?
        public var last_heard: String?
        public var first_seen: String?
        public var packet_count: Int?
        public var display_name: String?
        public var has_position: Bool?
        public var latest_signal: Signal?
        public var latest_telemetry: Telemetry?

        // `GET /api/nodes` defaults to enrich=true, which flattens the latest
        // signal and telemetry into these columns instead of nesting them.
        public var latest_rssi: Double?
        public var latest_snr: Double?
        public var latest_battery: Double?
        public var latest_voltage: Double?
        public var latest_temperature: Double?
        public var latest_humidity: Double?
        public var latest_channel_util: Double?
        public var latest_air_util: Double?
        public var latest_hops: Int?

        // `protocol` is a Swift keyword, so it needs an explicit mapping.
        private enum CodingKeys: String, CodingKey {
            case node_id, long_name, short_name, hardware_model, firmware_version
            case protocolName = "protocol"
            case role, public_key, latitude, longitude, altitude, last_heard
            case first_seen, packet_count, display_name, has_position
            case latest_signal, latest_telemetry
            case latest_rssi, latest_snr, latest_battery, latest_voltage
            case latest_temperature, latest_humidity, latest_channel_util
            case latest_air_util, latest_hops
        }

        /// Signal from whichever form this response used.
        public var effectiveSNR: Double? { latest_signal?.snr ?? latest_snr }
        public var effectiveRSSI: Double? { latest_signal?.rssi ?? latest_rssi }

        /// Telemetry from whichever form this response used.
        public var effectiveTelemetry: Telemetry? {
            if let nested = latest_telemetry { return nested }
            let flat = Telemetry(node_id: node_id,
                                 battery_level: latest_battery,
                                 voltage: latest_voltage,
                                 temperature: latest_temperature,
                                 humidity: latest_humidity,
                                 barometric_pressure: nil,
                                 channel_utilization: latest_channel_util,
                                 air_util_tx: latest_air_util,
                                 uptime_seconds: nil,
                                 timestamp: last_heard)
            let hasAny = [latest_battery, latest_voltage, latest_temperature,
                          latest_humidity, latest_channel_util, latest_air_util]
                .contains { $0 != nil }
            return hasAny ? flat : nil
        }
    }

    public struct MetricsHistory: Decodable, Sendable {
        public var node_id: String
        public var telemetry: [Telemetry]
    }

    // MARK: - Messages

    public struct Conversation: Decodable, Sendable {
        public var node_id: String
        public var node_name: String?
        public var protocolName: String?
        public var last_message: String?
        public var last_timestamp: String?
        public var unread_count: Int?
        public var is_broadcast: Bool?

        private enum CodingKeys: String, CodingKey {
            case node_id, node_name
            case protocolName = "protocol"
            case last_message, last_timestamp, unread_count, is_broadcast
        }
    }

    public struct Message: Decodable, Sendable {
        public var id: Int?
        /// "sent" or "received".
        public var direction: String?
        public var text: String?
        public var node_id: String?
        public var node_name: String?
        public var protocolName: String?
        public var channel: Int?
        public var timestamp: String?
        public var status: String?
        public var packet_id: String?
        public var rx_count: Int?
        public var rssi: Double?
        public var snr: Double?

        private enum CodingKeys: String, CodingKey {
            case id, direction, text, node_id, node_name
            case protocolName = "protocol"
            case channel, timestamp, status, packet_id, rx_count, rssi, snr
        }
    }

    public struct ChannelEntry: Decodable, Sendable {
        public var index: Int?
        public var name: String?
        public var psk_b64: String?
        public var hash: String?
        public var enabled: Bool?
    }

    public struct SendResult: Decodable, Sendable {
        public var success: Bool
        public var packet_id: String?
        public var error: String?
        public var airtime_ms: Double?
    }

    // MARK: - Configuration

    public struct RadioConfig: Decodable, Sendable {
        public var region: String?
        public var frequency_mhz: Double?
        public var spreading_factor: Int?
        public var bandwidth_khz: Double?
        public var coding_rate: String?
        public var sync_word: String?
        public var current_preset: String?
    }

    public struct RelayConfig: Decodable, Sendable {
        public var enabled: Bool?
        public var max_relay_per_minute: Int?
        public var router_mode: Bool?
    }

    public struct TransmitConfig: Decodable, Sendable {
        public var enabled: Bool?
        public var node_id: Int?
        public var node_id_hex: String?
        public var tx_power_dbm: Int?
        public var max_duty_cycle_percent: Double?
        public var long_name: String?
        public var short_name: String?
        public var hop_limit: Int?
        public var relay: RelayConfig?
    }

    public struct DutyCycle: Decodable, Sendable {
        public var used_percent: Double?
        public var remaining_ms: Double?
    }

    public struct MeshCoreStatus: Decodable, Sendable {
        public var connected: Bool?
        public var companion_name: String?
        public var companion_expected: Bool?
        public var status_note: String?
    }

    public struct RegionOption: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String?
        public var frequency_mhz: Double?
    }

    public struct Configuration: Decodable, Sendable {
        public var radio: RadioConfig?
        public var transmit: TransmitConfig?
        public var relay: RelayConfig?
        public var channels: [ChannelEntry]?
        public var duty_cycle: DutyCycle?
        public var meshcore: MeshCoreStatus?
        public var regions: [RegionOption]?
    }

    public struct DeviceStatus: Decodable, Sendable {
        public var status: String?
        public var uptime_seconds: Double?
        public var websocket_clients: Int?
        public var device_id: String?
        public var firmware_version: String?
    }

    // MARK: - WebSocket envelope

    public struct SocketEnvelope: Decodable, Sendable {
        public var type: String
        /// Left raw so each event type can decode its own payload.
        public var data: JSONValue?
    }

    /// Minimal dynamic JSON value, so the websocket can hand payloads around
    /// without a concrete type per event.
    public enum JSONValue: Decodable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .null
            }
        }

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var doubleValue: Double? {
            switch self {
            case .number(let value): value
            case .string(let value): Double(value)
            default: nil
            }
        }

        public var intValue: Int? { doubleValue.map(Int.init) }

        public subscript(key: String) -> JSONValue? {
            if case .object(let dictionary) = self { return dictionary[key] }
            return nil
        }
    }
}

/// Parses the ISO-8601 timestamps the API returns, with or without fractional
/// seconds and with or without a timezone (the repositories emit both).
enum MeshpointDate {
    // Foundation's date formatters are safe to share for parsing once
    // configured; these are never mutated after construction.
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Naive timestamps (no zone) are emitted by `datetime.utcnow().isoformat()`,
    /// so they are UTC even though they do not say so.
    private static let naive: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter
    }()

    private static let naiveNoFraction: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return withFraction.date(from: text)
            ?? plain.date(from: text)
            ?? naive.date(from: text)
            ?? naiveNoFraction.date(from: text)
    }
}
