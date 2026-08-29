import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

struct NodesView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    @State private var search = ""
    @State private var sortOrder: SortOrder = .lastHeard
    @State private var filter: Filter = .all

    enum SortOrder: String, CaseIterable, Identifiable {
        case lastHeard, name, signal, hops, battery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lastHeard: "Last Heard"
            case .name: "Name"
            case .signal: "Signal"
            case .hops: "Hops Away"
            case .battery: "Battery"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, online, favorites, withPosition, routers, ignored
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All Nodes"
            case .online: "Online"
            case .favorites: "Favorites"
            case .withPosition: "With Position"
            case .routers: "Routers & Repeaters"
            case .ignored: "Ignored"
            }
        }
    }

    private var nodes: [MeshNode] {
        var result = filter == .ignored ? session.ignoredNodes : session.visibleNodes

        switch filter {
        case .all, .ignored: break
        case .online: result = result.filter(\.isOnline)
        case .favorites: result = result.filter(\.isFavorite)
        case .withPosition: result = result.filter { $0.coordinate != nil }
        case .routers: result = result.filter { $0.role.isInfrastructure }
        }

        if !search.isEmpty {
            result = result.filter {
                $0.longName.localizedCaseInsensitiveContains(search)
                    || $0.shortName.localizedCaseInsensitiveContains(search)
                    || $0.hexID.localizedCaseInsensitiveContains(search)
            }
        }

        switch sortOrder {
        case .lastHeard: break // visibleNodes is already in this order.
        case .name: result.sort { $0.longName.localizedCaseInsensitiveCompare($1.longName) == .orderedAscending }
        case .signal: result.sort { ($0.snr ?? -100) > ($1.snr ?? -100) }
        case .hops: result.sort { ($0.hopsAway ?? 99) < ($1.hopsAway ?? 99) }
        case .battery: result.sort { ($0.batteryLevel ?? -1) > ($1.batteryLevel ?? -1) }
        }
        return result
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selectedNode) {
                ForEach(nodes) { node in
                    NavigationLink(value: node.num) {
                        NodeRow(node: node)
                    }
                    .contextMenu { NodeContextMenu(node: node) }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search nodes")
            .navigationTitle("Nodes")
            .navigationSubtitle("\(nodes.count) shown · \(session.onlineNodeCount) online")
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            .toolbar {
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Picker("Sort By", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            .overlay {
                if nodes.isEmpty {
                    EmptyStateView(title: "No Nodes",
                                   message: session.isConnected
                                       ? "Nodes appear as the radio hears from them."
                                       : "Connect to a radio to see the mesh.",
                                   symbol: "person.slash")
                }
            }
        } detail: {
            if let selected = model.selectedNode, let node = session.node(selected) {
                NodeDetailView(node: node)
                    .id(selected)
            } else {
                EmptyStateView(title: "No Node Selected",
                               message: "Choose a node to see its details, signal history, and telemetry.",
                               symbol: "point.3.filled.connected.trianglepath.dotted")
            }
        }
    }
}

struct NodeRow: View {
    @Environment(MeshSession.self) private var session
    let node: MeshNode

    var body: some View {
        HStack(spacing: 10) {
            NodeAvatar(node: node)
                .opacity(node.isOnline ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(node.longName).font(.body.weight(.medium)).lineLimit(1)
                    if node.num == session.myNodeNum {
                        Text("This Mac's radio")
                            .font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    if node.isMuted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: node.role.symbolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(node.role.displayName)
                    Text(Format.relative(node.lastHeard))
                        .font(.caption)
                        .foregroundStyle(node.isOnline ? .secondary : .tertiary)
                    if let hops = node.hopsAway {
                        Text(hops == 0 ? "· direct" : "· \(hops) hop\(hops == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if node.viaMQTT {
                        Image(systemName: "network").font(.caption2).foregroundStyle(.tertiary)
                            .help("Heard over MQTT, not directly by radio")
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                SignalBars(quality: SignalQuality(snr: node.snr, rssi: node.rssi))
                BatteryIndicator(node: node)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The shared right-click menu for a node, used by the list and the map.
struct NodeContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    let node: MeshNode

    var body: some View {
        if node.num != session.myNodeNum, !node.isUnmessagable {
            Button("Send Message", systemImage: "bubble.left") {
                model.selectedConversation = .direct(node.num)
                model.sidebarSelection = .messages
            }
        }
        Button(node.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: node.isFavorite ? "star.slash" : "star") {
            Task { await session.setFavorite(node.num, isFavorite: !node.isFavorite) }
        }
        Button(node.isMuted ? "Unmute" : "Mute Notifications",
               systemImage: node.isMuted ? "bell" : "bell.slash") {
            Task { await session.toggleMuted(node.num) }
        }

        Divider()

        if node.num != session.myNodeNum {
            Button("Request Position", systemImage: "location") {
                Task { await session.requestPosition(from: node.num) }
            }
            Button("Request Node Info", systemImage: "person.text.rectangle") {
                Task { await session.requestNodeInfo(from: node.num) }
            }
            Menu("Request Telemetry") {
                ForEach(TelemetryKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) {
                        Task { await session.requestTelemetry(from: node.num, kind: kind) }
                    }
                }
            }
            Button("Trace Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                Task { await session.traceroute(to: node.num) }
            }

            Divider()

            Button(node.isIgnored ? "Stop Ignoring" : "Ignore Node",
                   systemImage: node.isIgnored ? "eye" : "eye.slash") {
                Task { await session.setIgnored(node.num, isIgnored: !node.isIgnored) }
            }
            Button("Remove from Node Database", systemImage: "trash", role: .destructive) {
                Task { await session.removeNode(node.num) }
            }
        }

        Divider()
        Button("Copy Node ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.hexID, forType: .string)
        }
    }
}
