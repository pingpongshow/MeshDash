import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

// MARK: - Generic humanizer

public extension String {
    /// Turns a generated protobuf case name into something readable:
    /// `veryLongSlow` → "Very Long Slow", `clientMute` → "Client Mute".
    var humanizedEnumCase: String {
        guard !isEmpty else { return self }
        var words: [String] = []
        var current = ""
        for character in self {
            if character.isUppercase, !current.isEmpty, !(current.last?.isUppercase ?? false) {
                words.append(current)
                current = String(character)
            } else if character.isNumber, let last = current.last, last.isLetter, !last.isUppercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Falls back to a title-cased version of the Swift case name for any enum we
/// have not given a hand-written label.
public func humanizedName<E: SwiftProtobuf.Enum>(_ value: E) -> String {
    let raw = String(describing: value)
    if raw.hasPrefix("UNRECOGNIZED") {
        return "Unknown (\(value.rawValue))"
    }
    return raw.humanizedEnumCase
}

// MARK: - LoRa

public extension Config.LoRaConfig.ModemPreset {
    var displayName: String {
        switch self {
        case .longFast: "Long Fast"
        case .longSlow: "Long Slow"
        case .veryLongSlow: "Very Long Slow"
        case .mediumSlow: "Medium Slow"
        case .mediumFast: "Medium Fast"
        case .shortSlow: "Short Slow"
        case .shortFast: "Short Fast"
        case .longModerate: "Long Moderate"
        case .shortTurbo: "Short Turbo"
        case .longTurbo: "Long Turbo"
        case .liteFast: "Lite Fast"
        case .liteSlow: "Lite Slow"
        case .narrowFast: "Narrow Fast"
        case .narrowSlow: "Narrow Slow"
        case .tinyFast: "Tiny Fast"
        case .tinySlow: "Tiny Slow"
        case .mediumTurbo: "Medium Turbo"
        case .UNRECOGNIZED(let value): "Preset \(value)"
        }
    }

    /// Rough guidance shown next to the preset picker.
    var rangeHint: String {
        switch self {
        case .longFast: "The network default. Good range, reasonable speed."
        case .longSlow, .veryLongSlow: "Maximum range, very low throughput."
        case .longModerate, .longTurbo: "Long range with a bit more speed."
        case .mediumSlow, .mediumFast, .mediumTurbo: "Balanced range and speed."
        case .shortSlow, .shortFast, .shortTurbo: "Short range, highest throughput."
        case .liteFast, .liteSlow, .narrowFast, .narrowSlow, .tinyFast, .tinySlow: "Narrow-bandwidth preset."
        case .UNRECOGNIZED: "Unknown preset."
        }
    }

    /// `shortTurbo` uses 500 kHz, which is not legal everywhere.
    var isWideband: Bool { self == .shortTurbo }
}

public extension Config.LoRaConfig.RegionCode {
    var displayName: String {
        switch self {
        case .unset: "Not set"
        case .us: "United States (902–928 MHz)"
        case .eu433: "Europe 433 MHz"
        case .eu868: "Europe 868 MHz"
        case .cn: "China (470–510 MHz)"
        case .jp: "Japan (920–923 MHz)"
        case .anz: "Australia / New Zealand (915–928 MHz)"
        case .anz433: "Australia / New Zealand 433 MHz"
        case .kr: "Korea (920–923 MHz)"
        case .tw: "Taiwan (920–925 MHz)"
        case .ru: "Russia (868–870 MHz)"
        case .nz865: "New Zealand 865 MHz"
        case .th: "Thailand (920–925 MHz)"
        case .lora24: "2.4 GHz worldwide"
        case .ua433: "Ukraine 433 MHz"
        case .ua868: "Ukraine 868 MHz"
        case .my433: "Malaysia 433 MHz"
        case .my919: "Malaysia 919 MHz"
        case .sg923: "Singapore 923 MHz"
        case .ph433: "Philippines 433 MHz"
        case .ph868: "Philippines 868 MHz"
        case .ph915: "Philippines 915 MHz"
        case .kz433: "Kazakhstan 433 MHz"
        case .kz863: "Kazakhstan 863 MHz"
        case .np865: "Nepal 865 MHz"
        case .br902: "Brazil 902 MHz"
        case .in: "India (865–867 MHz)"
        case .eu866: "Europe 866 MHz"
        case .eu874: "Europe 874 MHz"
        case .eu917: "Europe 917 MHz"
        case .euN868: "Europe 868 MHz (narrow)"
        case .itu12M: "ITU 12 m band"
        case .itu22M: "ITU 22 m band"
        case .itu32M: "ITU 32 m band"
        case .itu170Cm: "ITU 170 cm band"
        case .itu270Cm: "ITU 270 cm band"
        case .itu370Cm: "ITU 370 cm band"
        case .itu2125Cm: "ITU 2125 cm band"
        case .UNRECOGNIZED(let value): "Region \(value)"
        }
    }

    /// Short code for compact places like the status bar.
    var shortCode: String {
        self == .unset ? "—" : String(describing: self).uppercased()
    }
}

// MARK: - Device role

public extension Config.DeviceConfig.Role {
    var displayName: String {
        switch self {
        case .client: "Client"
        case .clientMute: "Client Mute"
        case .clientHidden: "Client Hidden"
        case .clientBase: "Client Base"
        case .router: "Router"
        case .routerClient: "Router Client"
        case .routerLate: "Router Late"
        case .repeater: "Repeater"
        case .tracker: "Tracker"
        case .sensor: "Sensor"
        case .tak: "TAK"
        case .takTracker: "TAK Tracker"
        case .lostAndFound: "Lost and Found"
        case .UNRECOGNIZED(let value): "Role \(value)"
        }
    }

    var explanation: String {
        switch self {
        case .client: "A normal node. Sends and receives, and rebroadcasts for others."
        case .clientMute: "Sends and receives, but never rebroadcasts other nodes' packets."
        case .clientHidden: "Stays off the air unless you send something. For very low power or privacy."
        case .clientBase: "A stationary client at a fixed home location."
        case .router: "A dedicated infrastructure node in a high spot. Do not use for a node you carry."
        case .routerClient: "Deprecated. Behaves as a router that also acts as a client."
        case .routerLate: "Rebroadcasts after other routers, to fill gaps without adding congestion."
        case .repeater: "Rebroadcasts everything but does not appear in the node list."
        case .tracker: "Sends position frequently. Intended for something you are following."
        case .sensor: "Sends telemetry frequently. Intended for a fixed sensor station."
        case .tak: "Integrates with ATAK clients."
        case .takTracker: "A minimal node feeding position to ATAK."
        case .lostAndFound: "Broadcasts its position on the default channel to be found."
        case .UNRECOGNIZED: "Unrecognized role."
        }
    }

    /// Roles the firmware asks you to think twice about.
    var isInfrastructure: Bool {
        self == .router || self == .repeater || self == .routerClient || self == .routerLate
    }

    var symbolName: String {
        switch self {
        case .client, .clientBase: "person.fill"
        case .clientMute: "speaker.slash.fill"
        case .clientHidden: "eye.slash.fill"
        case .router, .routerClient, .routerLate: "point.3.connected.trianglepath.dotted"
        case .repeater: "antenna.radiowaves.left.and.right"
        case .tracker, .takTracker: "location.fill"
        case .sensor: "sensor.fill"
        case .tak: "shield.fill"
        case .lostAndFound: "questionmark.circle.fill"
        case .UNRECOGNIZED: "questionmark"
        }
    }
}

// MARK: - Hardware

public extension HardwareModel {
    var displayName: String {
        if case .UNRECOGNIZED(let value) = self { return "Unknown hardware (\(value))" }
        if self == .unset { return "Unknown" }
        var name = String(describing: self).humanizedEnumCase
        // Fix up the vendor spellings the generic humanizer cannot know about.
        let replacements: [(String, String)] = [
            ("Tlora", "T-LoRa"), ("Tbeam", "T-Beam"), ("T Echo", "T-Echo"), ("T Deck", "T-Deck"),
            ("T Watch", "T-Watch"), ("T Display", "T-Display"), ("T Eth", "T-Eth"), ("T Impulse", "T-Impulse"),
            ("Rak", "RAK"), ("Nrf", "nRF"), ("Esp", "ESP"), ("Rp", "RP"), ("Rpi", "Raspberry Pi"),
            ("M5 Stack", "M5Stack"), ("Oled", "OLED"), ("Diy", "DIY"), ("Ppr", "PPR"),
            ("Hru", "HRU"), ("Wsl", "WSL"), ("Ht", "HT"), ("Tx", "TX"), ("Wm", "WM"),
        ]
        for (from, to) in replacements where name.contains(from) {
            name = name.replacingOccurrences(of: from, with: to)
        }
        return name
    }
}

// MARK: - Ports

public extension PortNum {
    var displayName: String {
        switch self {
        case .unknownApp: "Unknown"
        case .textMessageApp: "Text Message"
        case .remoteHardwareApp: "Remote Hardware"
        case .positionApp: "Position"
        case .nodeinfoApp: "Node Info"
        case .routingApp: "Routing"
        case .adminApp: "Admin"
        case .textMessageCompressedApp: "Compressed Text"
        case .waypointApp: "Waypoint"
        case .audioApp: "Audio"
        case .detectionSensorApp: "Detection Sensor"
        case .alertApp: "Alert"
        case .keyVerificationApp: "Key Verification"
        case .remoteShellApp: "Remote Shell"
        case .replyApp: "Reply"
        case .ipTunnelApp: "IP Tunnel"
        case .paxcounterApp: "Paxcounter"
        case .storeForwardPlusplusApp: "Store & Forward++"
        case .nodeStatusApp: "Node Status"
        case .meshBeaconApp: "Mesh Beacon"
        case .serialApp: "Serial"
        case .storeForwardApp: "Store & Forward"
        case .rangeTestApp: "Range Test"
        case .telemetryApp: "Telemetry"
        case .zpsApp: "ZPS"
        case .simulatorApp: "Simulator"
        case .tracerouteApp: "Traceroute"
        case .neighborinfoApp: "Neighbor Info"
        case .atakPlugin: "ATAK Plugin"
        case .atakPluginV2: "ATAK Plugin v2"
        case .mapReportApp: "Map Report"
        case .powerstressApp: "Power Stress"
        case .lorawanBridge: "LoRaWAN Bridge"
        case .reticulumTunnelApp: "Reticulum Tunnel"
        case .cayenneApp: "Cayenne"
        case .loraOtaApp: "LoRa OTA"
        case .groupalarmApp: "Group Alarm"
        case .privateApp: "Private"
        case .atakForwarder: "ATAK Forwarder"
        case .max: "Max"
        case .UNRECOGNIZED(let value): "Port \(value)"
        }
    }
}

// MARK: - Routing

public extension Routing.Error {
    var displayName: String {
        switch self {
        case .none: "Delivered"
        case .noRoute: "No route to that node"
        case .gotNak: "The destination rejected the packet"
        case .timeout: "Timed out"
        case .noInterface: "No radio interface available"
        case .maxRetransmit: "Gave up after too many retries"
        case .noChannel: "No matching channel"
        case .tooLarge: "Message is too large"
        case .noResponse: "No response"
        case .dutyCycleLimit: "Blocked by the regional duty-cycle limit"
        case .badRequest: "Bad request"
        case .notAuthorized: "Not authorized"
        case .pkiFailed: "End-to-end encryption failed"
        case .pkiUnknownPubkey: "The destination's public key is unknown"
        case .pkiSendFailPublicKey: "Could not encrypt to the destination's public key"
        case .adminBadSessionKey: "The admin session key was rejected"
        case .adminPublicKeyUnauthorized: "This node is not an authorized admin key"
        case .rateLimitExceeded: "Rate limit exceeded"
        case .UNRECOGNIZED(let value): "Routing error \(value)"
        }
    }

    var isFailure: Bool { self != .none }
}

// MARK: - Misc enums

public extension MeshPacket.Priority {
    var displayName: String { humanizedName(self) }
}

public extension Channel.Role {
    var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .primary: "Primary"
        case .secondary: "Secondary"
        case .UNRECOGNIZED(let value): "Role \(value)"
        }
    }
}

public extension Config.DisplayConfig.DisplayUnits {
    var isMetric: Bool { self == .metric }
}
