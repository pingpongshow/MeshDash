import Foundation
import MeshtasticProtobufs

/// Encoding and decoding of `https://meshtastic.org/e/#…` channel links.
///
/// The fragment is a URL-safe base64 `ChannelSet` protobuf, so a link round-trips
/// every channel plus the LoRa settings needed to talk to that mesh.
public enum ChannelSharing {
    public static let webBase = "https://meshtastic.org/e/#"

    public struct ImportResult: Sendable {
        public var channelSet: ChannelSet
        /// True when the link asked to append channels rather than replace them.
        public var addOnly: Bool
    }

    public static func url(for channelSet: ChannelSet, addOnly: Bool = false) throws -> URL {
        let data = try channelSet.serializedData()
        var string = webBase + base64URLEncode(data)
        if addOnly { string += "?add=true" }
        guard let url = URL(string: string) else {
            throw ChannelSharingError.malformed("Could not build a share link.")
        }
        return url
    }

    /// Parses a `meshtastic.org/e/#…`, `meshtastic://e/#…`, or bare-fragment link.
    public static func parse(_ input: String) throws -> ImportResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelSharingError.malformed("The link is empty.") }

        var addOnly = false
        var fragment = trimmed

        if let hashIndex = trimmed.firstIndex(of: "#") {
            fragment = String(trimmed[trimmed.index(after: hashIndex)...])
        }
        // `?add=true` may trail the fragment.
        if let queryIndex = fragment.firstIndex(of: "?") {
            let query = String(fragment[fragment.index(after: queryIndex)...])
            addOnly = query.lowercased().contains("add=true")
            fragment = String(fragment[..<queryIndex])
        }

        guard let data = base64URLDecode(fragment) else {
            throw ChannelSharingError.malformed("The link does not contain valid channel data.")
        }
        do {
            let channelSet = try ChannelSet(serializedBytes: data)
            guard !channelSet.settings.isEmpty else {
                throw ChannelSharingError.malformed("The link does not contain any channels.")
            }
            return ImportResult(channelSet: channelSet, addOnly: addOnly)
        } catch let error as ChannelSharingError {
            throw error
        } catch {
            throw ChannelSharingError.malformed("The link could not be decoded as a Meshtastic channel set.")
        }
    }

    // MARK: - Base64URL

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore the padding base64url strips.
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }
}

public enum ChannelSharingError: Error, LocalizedError {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): detail
        }
    }
}

public extension ChannelSettings {
    /// The name Meshtastic shows for a channel; an empty primary channel is
    /// displayed by its LoRa preset name instead.
    func displayName(preset: Config.LoRaConfig.ModemPreset, isPrimary: Bool) -> String {
        if !name.isEmpty { return name }
        return isPrimary ? preset.displayName : "Channel"
    }

    /// True for the default `AQ==` key that every stock radio ships with.
    var usesDefaultKey: Bool {
        psk.count == 1 && psk.first == 1
    }

    var encryptionSummary: String {
        if psk.isEmpty { return "No encryption" }
        if usesDefaultKey { return "Default key (public)" }
        switch psk.count {
        case 16: return "AES-128"
        case 32: return "AES-256"
        default: return "\(psk.count * 8)-bit key"
        }
    }
}

public extension Channel {
    /// Generates a fresh random pre-shared key of the requested strength.
    static func randomKey(bytes: Int = 32) -> Data {
        var key = Data(count: bytes)
        for index in key.indices { key[index] = UInt8.random(in: 0...255) }
        return key
    }
}
