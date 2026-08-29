import MapKit
import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

struct MeshMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var showsPrecisionCircles = true
    @State private var showsWaypoints = true
    @State private var showsTracks = false
    @State private var showsOfflineNodes = true
    @State private var selectedNodeNum: UInt32?
    @State private var tracks: [UInt32: [PositionSample]] = [:]
    @State private var newWaypointCoordinate: CLLocationCoordinate2D?
    @State private var hasFramedNodes = false

    enum MapStyleChoice: String, CaseIterable, Identifiable {
        case standard, hybrid, imagery
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "Standard"
            case .hybrid: "Hybrid"
            case .imagery: "Satellite"
            }
        }
        var style: MapStyle {
            switch self {
            case .standard: .standard(elevation: .realistic)
            case .hybrid: .hybrid(elevation: .realistic)
            case .imagery: .imagery(elevation: .realistic)
            }
        }
    }

    private var mappedNodes: [MeshNode] {
        session.nodesWithPosition.filter { showsOfflineNodes || $0.isOnline }
    }

    var body: some View {
        Map(position: $camera, selection: $selectedNodeNum) {
            ForEach(mappedNodes) { node in
                if let coordinate = node.coordinate {
                    let point = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)

                    Annotation(node.shortName, coordinate: point) {
                        NodeMapPin(node: node, isSelf: node.num == session.myNodeNum)
                    }
                    .annotationTitles(.hidden)
                    .tag(node.num)

                    if showsPrecisionCircles, let radius = precisionRadius(for: node) {
                        MapCircle(center: point, radius: radius)
                            .foregroundStyle(.orange.opacity(0.10))
                            .stroke(.orange.opacity(0.5), lineWidth: 1)
                    }
                }
            }

            if showsTracks {
                ForEach(Array(tracks.keys), id: \.self) { num in
                    if let samples = tracks[num], samples.count > 1 {
                        MapPolyline(coordinates: samples.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }

            if showsWaypoints {
                ForEach(session.sortedWaypoints, id: \.waypoint.id) { entry in
                    let waypoint = entry.waypoint
                    if waypoint.latitudeI != 0 || waypoint.longitudeI != 0 {
                        Annotation(waypoint.name.isEmpty ? "Waypoint" : waypoint.name,
                                   coordinate: CLLocationCoordinate2D(latitude: Double(waypoint.latitudeI) * 1e-7,
                                                                      longitude: Double(waypoint.longitudeI) * 1e-7)) {
                            WaypointPin(waypoint: waypoint)
                        }
                    }
                }
            }
        }
        .mapStyle(style.style)
        .mapControls {
            MapCompass()
            MapScaleView()
            MapPitchToggle()
        }
        .navigationTitle("Map")
        .navigationSubtitle("\(mappedNodes.count) node\(mappedNodes.count == 1 ? "" : "s") with a position")
        .toolbar { toolbar }
        .overlay(alignment: .bottomLeading) { selectionCard }
        .overlay {
            if mappedNodes.isEmpty && session.sortedWaypoints.isEmpty {
                EmptyStateView(title: "Nothing to Map",
                               message: "Nodes appear once they report a position. Nodes without GPS can be given a fixed position in Configuration › Position.",
                               symbol: "mappin.slash")
                .background(.regularMaterial)
            }
        }
        .task(id: mappedNodes.count) {
            // Frame the mesh once, then leave the camera under the user's control.
            guard !hasFramedNodes, !mappedNodes.isEmpty else { return }
            hasFramedNodes = true
            camera = .automatic
        }
        .onChange(of: showsTracks) { _, enabled in
            guard enabled else {
                tracks = [:]
                return
            }
            Task { await loadTracks() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Style", selection: $style) {
                ForEach(MapStyleChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)

            Menu {
                Toggle("Position Precision Circles", isOn: $showsPrecisionCircles)
                Toggle("Waypoints", isOn: $showsWaypoints)
                Toggle("Movement Tracks", isOn: $showsTracks)
                Toggle("Offline Nodes", isOn: $showsOfflineNodes)
                Divider()
                Button("Fit All Nodes", systemImage: "arrow.up.left.and.arrow.down.right") {
                    camera = .automatic
                }
            } label: {
                Label("Display", systemImage: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder
    private var selectionCard: some View {
        if let selectedNodeNum, let node = session.node(selectedNodeNum) {
            MapSelectionCard(node: node) { self.selectedNodeNum = nil }
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The radius implied by a node's configured position precision, so the map
    /// does not imply more accuracy than the sender shared.
    private func precisionRadius(for node: MeshNode) -> Double? {
        guard let position = node.position, position.precisionBits > 0, position.precisionBits < 32,
              let coordinate = node.coordinate else { return nil }
        return PositionSample(nodeNum: node.num, time: .now,
                              latitude: coordinate.latitude, longitude: coordinate.longitude,
                              precisionBits: Int(position.precisionBits)).precisionRadiusMeters
    }

    private func loadTracks() async {
        var result: [UInt32: [PositionSample]] = [:]
        let since = Date().addingTimeInterval(-24 * 3600)
        for node in mappedNodes {
            let samples = await session.positionHistory(for: node.num, since: since)
            if samples.count > 1 { result[node.num] = samples }
        }
        tracks = result
    }
}

private struct NodeMapPin: View {
    let node: MeshNode
    let isSelf: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelf ? Color.accentColor : (node.isOnline ? Color.green : Color.secondary))
                .frame(width: 30, height: 30)
                .shadow(radius: 2, y: 1)
            Text(node.shortName.prefix(4))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .padding(1)
        }
        .overlay(alignment: .topTrailing) {
            if node.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: 3, y: -3)
            }
        }
        .help("\(node.longName) · \(Format.relative(node.lastHeard))")
    }
}

private struct WaypointPin: View {
    let waypoint: Waypoint

    /// The firmware stores the icon as a Unicode scalar.
    private var glyph: String {
        guard waypoint.icon != 0, let scalar = Unicode.Scalar(waypoint.icon) else { return "📍" }
        return String(Character(scalar))
    }

    var body: some View {
        Text(glyph)
            .font(.title3)
            .padding(4)
            .background(.regularMaterial, in: Circle())
            .shadow(radius: 1)
            .help(waypoint.description_p.isEmpty ? waypoint.name : "\(waypoint.name)\n\(waypoint.description_p)")
    }
}

private struct MapSelectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    let node: MeshNode
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                NodeAvatar(node: node, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.longName).font(.body.weight(.medium))
                    Text("\(node.hexID) · \(Format.relative(node.lastHeard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            if let coordinate = node.coordinate {
                Text(Format.coordinate(coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if node.num != session.myNodeNum, !node.isUnmessagable {
                    Button("Message") {
                        model.selectedConversation = .direct(node.num)
                        model.sidebarSelection = .messages
                    }
                }
                Button("Details") {
                    model.selectedNode = node.num
                    model.sidebarSelection = .nodes
                }
                if node.num != session.myNodeNum {
                    Button("Request Position") {
                        Task { await session.requestPosition(from: node.num) }
                    }
                    .disabled(!session.isConnected)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
    }
}
