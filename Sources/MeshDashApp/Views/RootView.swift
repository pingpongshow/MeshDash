import MeshtasticCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                detail
                NoticeBanner()
                    .animation(.snappy, value: session.notices.count)
            }
        }
        .toolbar { ConnectionToolbar() }
        .sheet(isPresented: $model.isShowingConnectSheet) {
            ConnectSheet()
                .frame(minWidth: 560, minHeight: 440)
        }
        .alert("MeshDash could not open its database",
               isPresented: .constant(model.storeFailure != nil)) {
            Button("Continue Without History") { model.storeFailure = nil }
        } message: {
            Text(model.storeFailure ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .messages: MessagesView()
        case .nodes: NodesView()
        case .map: MeshMapView()
        case .telemetry: TelemetryView()
        case .channels: ChannelsView()
        case .gateway: MeshpointGatewayView()
        case .configuration: ConfigurationView()
        case .diagnostics: DiagnosticsView()
        case nil:
            EmptyStateView(title: "MeshDash",
                           message: "Pick a section in the sidebar to get started.",
                           symbol: "antenna.radiowaves.left.and.right")
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    /// The Gateway page only makes sense for a Meshpoint connection, and the
    /// Channels editor only for a radio.
    private var visibleSections: [SidebarSection] {
        SidebarSection.allCases.filter { section in
            switch section {
            case .gateway: session.isMeshpointBackend
            case .channels: !session.isMeshpointBackend
            default: true
            }
        }
    }

    var body: some View {
        @Bindable var model = model

        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(visibleSections) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.symbolName)
                            .badge(section == .messages ? session.totalUnreadCount : 0)
                    }
                }
            }

            Section("Radio") {
                ConnectionStatusCard()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MeshDash")
    }
}

/// Compact live status for the connected radio, shown at the foot of the sidebar.
private struct ConnectionStatusCard: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(session.connectionSummary)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let node = session.myNode {
                HStack(spacing: 8) {
                    NodeAvatar(node: node, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.longName).font(.caption.weight(.medium)).lineLimit(1)
                        Text(node.hexID).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    BatteryIndicator(node: node, showLabel: false)
                }
            }

            if session.isConnected {
                HStack(spacing: 12) {
                    if let utilization = session.channelUtilization {
                        MiniStat(label: "Ch", value: "\(Int(utilization))%",
                                 help: "Channel utilization — how busy the airwaves are")
                    }
                    if let airtime = session.airtimeUtilization {
                        MiniStat(label: "TX", value: "\(Int(airtime))%",
                                 help: "Transmit airtime used in the last hour")
                    }
                    MiniStat(label: "Nodes", value: "\(session.onlineNodeCount)",
                             help: "Nodes heard in the last two hours")
                }
            }

            Button(session.isConnected ? "Disconnect" : "Connect…") {
                if session.isConnected {
                    Task { await session.disconnect() }
                } else {
                    model.isShowingConnectSheet = true
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: .green
        case .connecting, .syncing: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    let help: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .help(help)
    }
}

/// Toolbar content shared by every screen.
private struct ConnectionToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if session.connectionState.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(session.connectionSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItemGroup {
            if session.isConnected {
                Button {
                    Task { await session.refreshFromRadio() }
                } label: {
                    Label("Reload Configuration", systemImage: "arrow.clockwise")
                }
                .help("Ask the radio to resend its configuration and node database")
            }

            Button {
                model.isShowingConnectSheet = true
            } label: {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
            }
            .help("Choose a radio to connect to")
        }
    }
}
