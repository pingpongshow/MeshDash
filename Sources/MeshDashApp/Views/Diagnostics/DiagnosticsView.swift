import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Environment(MeshSession.self) private var session
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview, packets, deviceLog, traceroutes, waypoints
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .packets: "Packet Log"
            case .deviceLog: "Device Log"
            case .traceroutes: "Traceroutes"
            case .waypoints: "Waypoints"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .overview: DiagnosticsOverview()
            case .packets: PacketLogView()
            case .deviceLog: DeviceLogView()
            case .traceroutes: TracerouteListView()
            case .waypoints: WaypointListView()
            }
        }
        .navigationTitle("Diagnostics")
    }
}

private struct DiagnosticsOverview: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section2("Connection", symbol: "antenna.radiowaves.left.and.right") {
                    DetailRow("Status", session.connectionSummary)
                    if let device = session.connectedDevice {
                        DetailRow("Transport", device.address.kind.displayName)
                        DetailRow("Address", device.detail)
                    }
                    if let info = session.myInfo {
                        DetailRow("My Node Number", "\(info.myNodeNum)", monospaced: true)
                        DetailRow("Reboot Count", "\(info.rebootCount)")
                        DetailRow("Nodes in Device Database", "\(info.nodedbCount)")
                        DetailRow("Minimum App Version", "\(info.minAppVersion)")
                        if !info.pioEnv.isEmpty { DetailRow("Firmware Build Target", info.pioEnv, monospaced: true) }
                    }
                    if let metadata = session.metadata {
                        DetailRow("Firmware Version", metadata.firmwareVersion, monospaced: true)
                        DetailRow("Device State Version", "\(metadata.deviceStateVersion)")
                        DetailRow("Can Shut Down Remotely", metadata.canShutdown ? "Yes" : "No")
                    }
                }

                if let stats = session.localStats {
                    Section2("Radio Statistics", symbol: "chart.bar") {
                        DetailRow("Uptime", Format.duration(Double(stats.uptimeSeconds)))
                        DetailRow("Channel Utilization",
                                  "\(stats.channelUtilization.formatted(.number.precision(.fractionLength(1))))%")
                        DetailRow("Transmit Airtime",
                                  "\(stats.airUtilTx.formatted(.number.precision(.fractionLength(1))))%")
                        DetailRow("Packets Sent", "\(stats.numPacketsTx)")
                        DetailRow("Packets Received", "\(stats.numPacketsRx)")
                        DetailRow("Bad Packets", "\(stats.numPacketsRxBad)")
                        DetailRow("Duplicates Received", "\(stats.numRxDupe)")
                        DetailRow("Packets Relayed", "\(stats.numTxRelay)")
                        DetailRow("Relays Canceled", "\(stats.numTxRelayCanceled)")
                        DetailRow("Transmits Dropped", "\(stats.numTxDropped)")
                        DetailRow("Nodes Online", "\(stats.numOnlineNodes) of \(stats.numTotalNodes)")
                        if stats.heapTotalBytes > 0 {
                            DetailRow("Free Memory",
                                      "\(Format.bytes(Double(stats.heapFreeBytes))) of \(Format.bytes(Double(stats.heapTotalBytes)))")
                        }
                        if stats.noiseFloor != 0 {
                            DetailRow("Noise Floor", "\(stats.noiseFloor) dBm")
                        }
                    }
                }

                if let queue = session.queueStatus {
                    Section2("Transmit Queue", symbol: "tray") {
                        DetailRow("Free Slots", "\(queue.free) of \(queue.maxlen)")
                        if queue.res != 0 {
                            DetailRow("Last Result", "\(queue.res)")
                        }
                    }
                }

                if let presets = session.regionPresets {
                    Section2("Region Presets Supported by This Firmware", symbol: "globe") {
                        DetailRow("Preset Groups", "\(presets.groups.count)")
                        DetailRow("Regions Described", "\(presets.regionGroups.count)")
                        FieldNote("The firmware reports which preset and region combinations it supports, which is how MeshDash knows what is safe to offer.")
                    }
                }

                Section2("Radio Settings Summary", symbol: "slider.horizontal.3") {
                    DetailRow("Region", session.loraConfig.region.displayName)
                    DetailRow("Modem Preset", session.loraConfig.usePreset
                        ? session.loraConfig.modemPreset.displayName
                        : "Custom (SF\(session.loraConfig.spreadFactor), \(session.loraConfig.bandwidth) kHz)")
                    DetailRow("Hop Limit", "\(session.loraConfig.hopLimit)")
                    DetailRow("Transmit Power",
                              session.loraConfig.txPower == 0 ? "Region maximum" : "\(session.loraConfig.txPower) dBm")
                    DetailRow("Role", session.deviceConfig.role.displayName)
                    DetailRow("Active Channels", "\(session.activeChannels.count)")
                }
            }
            .padding(20)
        }
    }
}

private struct PacketLogView: View {
    @Environment(MeshSession.self) private var session
    @State private var search = ""
    @State private var directionFilter: PacketLogEntry.Direction?

    private var entries: [PacketLogEntry] {
        var result = session.packetLog.reversed().map { $0 }
        if let directionFilter { result = result.filter { $0.direction == directionFilter } }
        if !search.isEmpty {
            result = result.filter {
                $0.summary.localizedCaseInsensitiveContains(search)
                    || $0.detail.localizedCaseInsensitiveContains(search)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Picker("Direction", selection: $directionFilter) {
                    Text("All").tag(PacketLogEntry.Direction?.none)
                    Text("Received").tag(PacketLogEntry.Direction?.some(.inbound))
                    Text("Sent").tag(PacketLogEntry.Direction?.some(.outbound))
                    Text("System").tag(PacketLogEntry.Direction?.some(.system))
                }
                .frame(maxWidth: 150)
                Spacer()
                Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Button("Copy All") { copyAll() }
                Button("Clear") { session.clearPacketLog() }
            }
            .padding(10)
            Divider()

            if entries.isEmpty {
                EmptyStateView(title: "No Packets Logged",
                               message: "Packets the app cannot fold into a conversation or node update land here — routing replies, range tests, remote hardware, and anything on an unrecognized port.",
                               symbol: "doc.text.magnifyingglass")
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: symbol(for: entry.direction))
                                .font(.caption)
                                .foregroundStyle(color(for: entry.direction))
                            Text(entry.summary).font(.callout.weight(.medium))
                            Spacer()
                            if let port = entry.portnum {
                                Text(port.displayName).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(entry.time.formatted(date: .omitted, time: .standard))
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private func symbol(for direction: PacketLogEntry.Direction) -> String {
        switch direction {
        case .inbound: "arrow.down.circle"
        case .outbound: "arrow.up.circle"
        case .system: "gearshape"
        }
    }

    private func color(for direction: PacketLogEntry.Direction) -> Color {
        switch direction {
        case .inbound: .blue
        case .outbound: .green
        case .system: .secondary
        }
    }

    private func copyAll() {
        let text = entries.map { entry in
            "\(entry.time.formatted(date: .numeric, time: .standard))\t\(entry.direction.rawValue)\t\(entry.summary)\t\(entry.detail)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct DeviceLogView: View {
    @Environment(MeshSession.self) private var session
    @State private var search = ""
    @State private var autoScroll = true

    private var lines: [String] {
        search.isEmpty ? session.deviceLogLines
            : session.deviceLogLines.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Toggle("Follow", isOn: $autoScroll)
                Spacer()
                Text("\(lines.count) lines").font(.caption).foregroundStyle(.secondary)
                Button("Save…") { save() }
                Button("Clear") { session.clearDeviceLog() }
            }
            .padding(10)
            Divider()

            if lines.isEmpty {
                EmptyStateView(title: "No Device Log",
                               message: "Serial connections show the radio's debug output here. Over Bluetooth or the network, turn on \"Debug log over the client API\" in Security settings.",
                               symbol: "terminal")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: lines.count) {
                        if autoScroll, !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }

    /// The firmware tags lines by level; colour them so problems stand out.
    private func color(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("CRIT") { return .red }
        if line.contains("WARN") { return .orange }
        if line.contains("DEBUG") { return .secondary }
        return .primary
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MeshDash device log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TracerouteListView: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        if session.traceroutes.isEmpty {
            EmptyStateView(title: "No Traceroutes",
                           message: "Run a traceroute from a node's page to see the path packets take through the mesh, hop by hop, with the signal strength at each step.",
                           symbol: "point.topleft.down.to.point.bottomright.curvepath")
        } else {
            List(session.traceroutes) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name(of: result.target)).font(.body.weight(.medium))
                    TracerouteRow(result: result)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
    }
}

private struct WaypointListView: View {
    @Environment(MeshSession.self) private var session
    @State private var isShowingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("New Waypoint…") { isShowingEditor = true }
                    .disabled(!session.isConnected)
            }
            .padding(10)
            Divider()

            if session.sortedWaypoints.isEmpty {
                EmptyStateView(title: "No Waypoints",
                               message: "Waypoints are shared markers everyone on a channel can see — a trailhead, a meeting point, a hazard.",
                               symbol: "mappin.slash")
            } else {
                List(session.sortedWaypoints, id: \.waypoint.id) { entry in
                    WaypointRow(waypoint: entry.waypoint, from: entry.from)
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            WaypointEditor().frame(width: 440, height: 460)
        }
    }
}

private struct WaypointRow: View {
    @Environment(MeshSession.self) private var session
    let waypoint: Waypoint
    let from: UInt32

    var body: some View {
        HStack(spacing: 10) {
            Text(glyph).font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(waypoint.name.isEmpty ? "Untitled waypoint" : waypoint.name)
                    .font(.body.weight(.medium))
                if !waypoint.description_p.isEmpty {
                    Text(waypoint.description_p).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(Format.coordinate(Double(waypoint.latitudeI) * 1e-7, Double(waypoint.longitudeI) * 1e-7)) · shared by \(session.name(of: from))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if waypoint.expire > 0 {
                Text("Expires \(Format.timestamp(Date(timeIntervalSince1970: TimeInterval(waypoint.expire))))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task { await session.deleteWaypoint(waypoint, channelIndex: 0) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!session.isConnected)
            .help("Delete this waypoint for everyone on the channel")
        }
        .padding(.vertical, 3)
    }

    private var glyph: String {
        guard waypoint.icon != 0, let scalar = Unicode.Scalar(waypoint.icon) else { return "📍" }
        return String(Character(scalar))
    }
}

private struct WaypointEditor: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var icon = "📍"
    @State private var channelIndex = 0
    @State private var expires = false
    @State private var expiryDate = Date().addingTimeInterval(86_400)

    private let icons = ["📍", "⛺️", "🚗", "🏠", "⚠️", "💧", "🔥", "🏥", "🅿️", "🚻", "⛽️", "🎯", "🚩", "⛰️"]

    private var isValid: Bool {
        Double(latitude) != nil && Double(longitude) != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Waypoint").font(.title3.weight(.semibold)).padding(16)
            Divider()

            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)

                Section("Location") {
                    TextField("Latitude", text: $latitude)
                    TextField("Longitude", text: $longitude)
                    if let node = session.myNode, node.coordinate != nil {
                        Button("Use My Radio's Position") {
                            if let coordinate = node.coordinate {
                                latitude = String(coordinate.latitude)
                                longitude = String(coordinate.longitude)
                            }
                        }
                    }
                }

                Section("Icon") {
                    Picker("Icon", selection: $icon) {
                        ForEach(icons, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Sharing") {
                    Picker("Channel", selection: $channelIndex) {
                        ForEach(session.activeChannels, id: \.index) { channel in
                            Text(session.channelName(Int(channel.index))).tag(Int(channel.index))
                        }
                    }
                    Toggle("Expires", isOn: $expires)
                    if expires {
                        DatePicker("Expiry", selection: $expiryDate)
                    }
                    FieldNote("Everyone on the channel receives this waypoint and can see it on their map.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Share Waypoint") { share() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(12)
        }
    }

    private func share() {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return }
        var waypoint = Waypoint()
        waypoint.id = UInt32.random(in: 1...UInt32.max)
        waypoint.name = name
        waypoint.description_p = description
        waypoint.latitudeI = Int32(lat * 1e7)
        waypoint.longitudeI = Int32(lon * 1e7)
        waypoint.icon = icon.unicodeScalars.first?.value ?? 0x1F4CD
        if expires { waypoint.expire = UInt32(expiryDate.timeIntervalSince1970) }
        Task {
            await session.sendWaypoint(waypoint, channelIndex: channelIndex)
            dismiss()
        }
    }
}
