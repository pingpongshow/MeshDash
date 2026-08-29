import Foundation
import MeshtasticProtobufs

/// One row in the conversation list.
public struct Conversation: Identifiable, Sendable {
    public var key: ConversationKey
    public var title: String
    public var subtitle: String
    public var lastMessage: MeshMessage?
    public var unreadCount: Int
    /// Non-nil for direct messages.
    public var node: MeshNode?
    public var channel: Channel?

    public var id: ConversationKey { key }
}

public extension MeshSession {

    // MARK: - Nodes

    /// Every node except ignored ones, newest contact first.
    var visibleNodes: [MeshNode] {
        nodes.values
            .filter { !$0.isIgnored }
            .sorted { lhs, rhs in
                if lhs.num == myNodeNum { return true }
                if rhs.num == myNodeNum { return false }
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
                return (lhs.lastHeard ?? .distantPast) > (rhs.lastHeard ?? .distantPast)
            }
    }

    var ignoredNodes: [MeshNode] {
        nodes.values.filter(\.isIgnored).sorted { $0.longName < $1.longName }
    }

    var onlineNodeCount: Int {
        nodes.values.filter { $0.isOnline && !$0.isIgnored }.count
    }

    var nodesWithPosition: [MeshNode] {
        nodes.values.filter { $0.coordinate != nil && !$0.isIgnored }
    }

    /// Nodes we can start a direct conversation with.
    var messagableNodes: [MeshNode] {
        visibleNodes.filter { $0.num != myNodeNum && !$0.isUnmessagable }
    }

    func node(_ num: UInt32) -> MeshNode? { nodes[num] }

    // MARK: - Channels

    /// Channels the radio has enabled, in index order.
    var activeChannels: [Channel] {
        channels.filter { $0.role != .disabled }.sorted { $0.index < $1.index }
    }

    func channelName(_ index: Int) -> String {
        guard index < channels.count else { return "Channel \(index)" }
        let channel = channels[index]
        return channel.settings.displayName(preset: loraConfig.modemPreset, isPrimary: channel.role == .primary)
    }

    // MARK: - Conversations

    var conversations: [Conversation] {
        var grouped: [ConversationKey: [MeshMessage]] = [:]
        for message in messages where !message.isEmojiReaction {
            grouped[message.conversation, default: []].append(message)
        }

        var result: [Conversation] = []

        // Every enabled channel gets a row even before it has traffic.
        for channel in activeChannels {
            let key = ConversationKey.channel(Int(channel.index))
            let thread = grouped[key] ?? []
            result.append(Conversation(key: key,
                                       title: channelName(Int(channel.index)),
                                       subtitle: channel.settings.encryptionSummary,
                                       lastMessage: thread.last,
                                       unreadCount: thread.count(where: { !$0.isRead }),
                                       node: nil,
                                       channel: channel))
            grouped[key] = nil
        }

        // Then direct threads, plus any channel thread whose channel is gone.
        for (key, thread) in grouped {
            switch key {
            case .direct(let num):
                let node = nodes[num]
                result.append(Conversation(key: key,
                                           title: node?.longName ?? name(of: num),
                                           subtitle: node?.hexID ?? String(format: "!%08x", num),
                                           lastMessage: thread.last,
                                           unreadCount: thread.count(where: { !$0.isRead }),
                                           node: node,
                                           channel: nil))
            case .channel(let index):
                result.append(Conversation(key: key,
                                           title: "Channel \(index)",
                                           subtitle: "This channel is no longer configured",
                                           lastMessage: thread.last,
                                           unreadCount: thread.count(where: { !$0.isRead }),
                                           node: nil,
                                           channel: nil))
            }
        }

        return result.sorted { lhs, rhs in
            let lhsTime = lhs.lastMessage?.timestamp ?? .distantPast
            let rhsTime = rhs.lastMessage?.timestamp ?? .distantPast
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Messages in one thread, oldest first, with reactions folded out.
    func thread(for conversation: ConversationKey) -> [MeshMessage] {
        messages
            .filter { $0.conversation == conversation && !$0.isEmojiReaction }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Emoji tapbacks attached to a given message.
    func reactions(for messageID: UInt32) -> [MeshMessage] {
        messages.filter { $0.isEmojiReaction && $0.reactionTo == messageID }
    }

    func message(_ id: UInt32) -> MeshMessage? {
        messages.first { $0.id == id }
    }

    var totalUnreadCount: Int {
        messages.count { !$0.isRead && $0.status == .received }
    }

    // MARK: - Waypoints

    var sortedWaypoints: [(waypoint: Waypoint, from: UInt32)] {
        waypoints.values.sorted { $0.waypoint.name < $1.waypoint.name }
    }

    // MARK: - Status summary

    /// One-line description of the link, for the toolbar.
    var connectionSummary: String {
        switch connectionState {
        case .disconnected: "Not connected"
        case .connecting(let detail): detail
        case .syncing(let count): "Syncing… \(count) node\(count == 1 ? "" : "s")"
        case .connected:
            if let device = connectedDevice {
                "\(device.name) · \(device.address.kind.displayName)"
            } else {
                "Connected"
            }
        case .failed(let reason): reason
        }
    }

    var firmwareSummary: String? {
        guard let metadata, !metadata.firmwareVersion.isEmpty else { return nil }
        return metadata.firmwareVersion
    }

    /// Channel utilization from the most recent local statistics or device metrics.
    var channelUtilization: Double? {
        if let stats = localStats, stats.channelUtilization > 0 { return Double(stats.channelUtilization) }
        if let metrics = myNode?.deviceMetrics, metrics.hasChannelUtilization { return Double(metrics.channelUtilization) }
        return nil
    }

    var airtimeUtilization: Double? {
        if let stats = localStats, stats.airUtilTx > 0 { return Double(stats.airUtilTx) }
        if let metrics = myNode?.deviceMetrics, metrics.hasAirUtilTx { return Double(metrics.airUtilTx) }
        return nil
    }
}


// MARK: - Backend capabilities

public extension MeshSession {
    /// What kind of thing we are connected to. A Meshpoint gateway accepts a
    /// much smaller set of operations than a radio does, and the UI needs to
    /// know rather than letting writes fail silently.
    var backendKind: TransportKind? { connectedDevice?.address.kind }

    var isMeshpointBackend: Bool { backendKind == .meshpoint }

    /// Longest text payload the backend will carry. Meshpoint enforces 228
    /// bytes server-side; a radio's own limit is 233.
    var maximumMessageBytes: Int { isMeshpointBackend ? 228 : 233 }

    /// Settings a Meshpoint's dashboard API can actually change.
    var supportsFullRadioConfiguration: Bool { !isMeshpointBackend }

    /// Module configuration is firmware-side and has no Meshpoint equivalent.
    var supportsModuleConfiguration: Bool { !isMeshpointBackend }

    /// Reboot, shutdown, factory reset and the rest are firmware operations.
    var supportsDeviceLifecycle: Bool { !isMeshpointBackend }

    var supportsTraceroute: Bool { !isMeshpointBackend }
    var supportsChannelEditing: Bool { !isMeshpointBackend }

    /// The live client, when the current connection is a Meshpoint gateway.
    /// Used by the gateway-only screens, which talk to it directly rather than
    /// pretending their data came off a radio.
    var meshpointClient: MeshpointClient? {
        (activeRadio?.transport as? MeshpointTransport)?.client
    }

    /// Explains, in one line, why a screen is unavailable.
    var unsupportedReason: String {
        isMeshpointBackend
            ? "A Meshpoint gateway exposes only its own dashboard settings, so this is not available while connected to one."
            : "This is not available for the current connection."
    }
}
