import Charts
import MapKit
import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

struct NodeDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    let node: MeshNode

    @State private var positionHistory: [PositionSample] = []
    @State private var isShowingRemoteAdmin = false

    private var isSelf: Bool { node.num == session.myNodeNum }
    private var metric: Bool { model.useMetricUnits }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                if node.coordinate != nil { locationSection }
                signalSection
                if node.deviceMetrics != nil { deviceMetricsSection }
                if hasEnvironment { environmentSection }
                if node.paxWifi != nil || node.paxBle != nil { paxcounterSection }
                if !node.neighbors.isEmpty { neighborSection }
                tracerouteSection
                if !isSelf { actionsSection }
            }
            .padding(20)
        }
        .navigationTitle(node.longName)
        .navigationSubtitle(node.hexID)
        .toolbar {
            Menu {
                NodeContextMenu(node: node)
                if !isSelf {
                    Divider()
                    Button("Remote Administration…", systemImage: "gearshape.2") {
                        isShowingRemoteAdmin = true
                    }
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $isShowingRemoteAdmin) {
            RemoteAdminSheet(node: node).frame(minWidth: 520, minHeight: 420)
        }
        .task(id: node.num) {
            positionHistory = await session.positionHistory(for: node.num,
                                                            since: Date().addingTimeInterval(-7 * 86_400))
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            NodeAvatar(node: node, size: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.longName).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Label(node.role.displayName, systemImage: node.role.symbolName)
                    Text("·")
                    Text(node.hardwareModel.displayName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    StatusPill(text: node.isOnline ? "Online" : "Offline",
                               color: node.isOnline ? .green : .secondary)
                    if node.hasPublicKey {
                        StatusPill(text: node.isKeyManuallyVerified ? "Key Verified" : "Encrypted",
                                   color: node.isKeyManuallyVerified ? .green : .blue,
                                   symbol: "lock.fill")
                    }
                    if node.isFavorite { StatusPill(text: "Favorite", color: .yellow, symbol: "star.fill") }
                    if node.viaMQTT { StatusPill(text: "Via MQTT", color: .purple, symbol: "network") }
                    if node.isUnmessagable { StatusPill(text: "Cannot Receive Messages", color: .orange) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                SignalBars(quality: SignalQuality(snr: node.snr, rssi: node.rssi))
                BatteryIndicator(node: node)
                Text(Format.relative(node.lastHeard)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var identitySection: some View {
        Section2("Identity", symbol: "person.text.rectangle") {
            DetailRow("Node Number", "\(node.num)", monospaced: true)
            DetailRow("Node ID", node.hexID, monospaced: true)
            DetailRow("Short Name", node.shortName)
            DetailRow("Hardware", node.hardwareModel.displayName)
            DetailRow("Role", node.role.displayName)
            if let user = node.user {
                if user.isLicensed {
                    DetailRow("Licensed Operator", "Yes — transmissions are unencrypted under an amateur licence")
                }
                if !user.publicKey.isEmpty {
                    DetailRow("Public Key", user.publicKey.base64EncodedString(), monospaced: true)
                }
            }
            DetailRow("Channel", session.channelName(node.channel))
            if let hops = node.hopsAway {
                DetailRow("Distance", hops == 0 ? "Direct radio contact" : "\(hops) hop\(hops == 1 ? "" : "s") away")
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if let coordinate = node.coordinate, let position = node.position {
            Section2("Location", symbol: "location.fill") {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                    Marker(node.shortName, coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                                              longitude: coordinate.longitude))
                    if positionHistory.count > 1 {
                        MapPolyline(coordinates: positionHistory.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.tint, lineWidth: 2)
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                DetailRow("Coordinates", Format.coordinate(coordinate.latitude, coordinate.longitude), monospaced: true)
                if position.altitude != 0 {
                    DetailRow("Altitude", Format.altitude(meters: position.altitude, metric: metric))
                }
                if position.groundSpeed > 0 {
                    DetailRow("Speed", Format.speed(kmh: Double(position.groundSpeed) * 3.6, metric: metric))
                }
                if position.satsInView > 0 {
                    DetailRow("Satellites", "\(position.satsInView)")
                }
                if position.precisionBits > 0, position.precisionBits < 32 {
                    DetailRow("Position Precision",
                              "\(position.precisionBits) bits — deliberately imprecise to about \(Int(PositionSample(nodeNum: node.num, time: .now, latitude: 0, longitude: 0, precisionBits: Int(position.precisionBits)).precisionRadiusMeters ?? 0)) m")
                }
                if position.time > 0 {
                    DetailRow("Reported", Format.timestamp(Date(timeIntervalSince1970: TimeInterval(position.time))))
                }
                if positionHistory.count > 1 {
                    DetailRow("Track", "\(positionHistory.count) points in the last 7 days")
                }
            }
        }
    }

    private var signalSection: some View {
        Section2("Signal", symbol: "antenna.radiowaves.left.and.right") {
            let quality = SignalQuality(snr: node.snr, rssi: node.rssi)
            DetailRow("Quality", quality.label)
            DetailRow("Signal-to-Noise Ratio", Format.snr(node.snr))
            DetailRow("Received Signal Strength", Format.rssi(node.rssi))
            if node.snr != nil {
                Text("Meshtastic decodes reliably down to about −7 dB SNR on the long-range presets. Below that, packets start to drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deviceMetricsSection: some View {
        Section2("Device", symbol: "cpu") {
            if let metrics = node.deviceMetrics {
                if metrics.hasBatteryLevel {
                    DetailRow("Battery", node.isPluggedIn ? "External power" : "\(metrics.batteryLevel)%")
                }
                if metrics.hasVoltage {
                    DetailRow("Voltage", "\(metrics.voltage.formatted(.number.precision(.fractionLength(2)))) V")
                }
                if metrics.hasChannelUtilization {
                    DetailRow("Channel Utilization",
                              "\(metrics.channelUtilization.formatted(.number.precision(.fractionLength(1))))%")
                }
                if metrics.hasAirUtilTx {
                    DetailRow("Transmit Airtime",
                              "\(metrics.airUtilTx.formatted(.number.precision(.fractionLength(1))))%")
                }
                if metrics.hasUptimeSeconds {
                    DetailRow("Uptime", Format.duration(Double(metrics.uptimeSeconds)))
                }
            }
            NavigationLink {
                NodeTelemetryDetail(node: node)
            } label: {
                Label("Telemetry History", systemImage: "chart.xyaxis.line")
            }
        }
    }

    private var hasEnvironment: Bool {
        node.environmentMetrics != nil || node.airQualityMetrics != nil || node.healthMetrics != nil
    }

    private var environmentSection: some View {
        Section2("Sensors", symbol: "thermometer.medium") {
            if let environment = node.environmentMetrics {
                if environment.hasTemperature {
                    DetailRow("Temperature", Format.temperature(celsius: Double(environment.temperature), metric: metric))
                }
                if environment.hasRelativeHumidity {
                    DetailRow("Humidity", "\(environment.relativeHumidity.formatted(.number.precision(.fractionLength(1))))%")
                }
                if environment.hasBarometricPressure {
                    DetailRow("Pressure", "\(environment.barometricPressure.formatted(.number.precision(.fractionLength(1)))) hPa")
                }
                if environment.hasIaq {
                    DetailRow("Air Quality Index", "\(environment.iaq)")
                }
                if environment.hasLux {
                    DetailRow("Illuminance", "\(environment.lux.formatted(.number.precision(.fractionLength(0)))) lx")
                }
            }
            if let air = node.airQualityMetrics {
                if air.hasPm25Standard { DetailRow("PM2.5", "\(air.pm25Standard) µg/m³") }
                if air.hasPm100Standard { DetailRow("PM10", "\(air.pm100Standard) µg/m³") }
                if air.hasCo2 { DetailRow("CO₂", "\(air.co2) ppm") }
            }
            if let health = node.healthMetrics {
                if health.hasHeartBpm { DetailRow("Heart Rate", "\(health.heartBpm) bpm") }
                if health.hasSpO2 { DetailRow("Blood Oxygen", "\(health.spO2)%") }
            }
        }
    }

    private var paxcounterSection: some View {
        Section2("Paxcounter", symbol: "person.3") {
            DetailRow("WiFi Devices Nearby", "\(node.paxWifi ?? 0)")
            DetailRow("Bluetooth Devices Nearby", "\(node.paxBle ?? 0)")
            if let uptime = node.paxUptime {
                DetailRow("Counting For", Format.duration(Double(uptime)))
            }
        }
    }

    private var neighborSection: some View {
        Section2("Direct Neighbors", symbol: "point.3.connected.trianglepath.dotted") {
            if let updated = node.neighborsUpdated {
                Text("Reported \(Format.relative(updated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(node.neighbors, id: \.nodeID) { neighbor in
                DetailRow(session.name(of: neighbor.nodeID),
                          neighbor.snr == 0 ? "—" : "\(neighbor.snr.formatted(.number.precision(.fractionLength(1)))) dB SNR")
            }
        }
    }

    @ViewBuilder
    private var tracerouteSection: some View {
        let results = session.traceroutes.filter { $0.target == node.num }
        if !results.isEmpty {
            Section2("Route History", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
                ForEach(results.prefix(5)) { result in
                    TracerouteRow(result: result)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section2("Actions", symbol: "bolt") {
            HStack {
                Button("Trace Route") { Task { await session.traceroute(to: node.num) } }
                Button("Request Position") { Task { await session.requestPosition(from: node.num) } }
                Button("Request Telemetry") { Task { await session.requestTelemetry(from: node.num, kind: .device) } }
            }
            .disabled(!session.isConnected)
            Button("Ask for Missed Messages (Store & Forward)") {
                Task { await session.requestStoreForwardHistory(from: node.num) }
            }
            .disabled(!session.isConnected)
        }
    }
}

/// A titled card used throughout the detail panes.
struct Section2<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}

struct TracerouteRow: View {
    @Environment(MeshSession.self) private var session
    let result: TracerouteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Format.timestamp(result.requestedAt)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let failure = result.failureReason {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                } else if !result.isComplete {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(result.forwardRoute.count) intermediate hop\(result.forwardRoute.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if result.isComplete, result.failureReason == nil {
                routePath(from: session.myNodeNum, hops: result.forwardRoute, to: result.target, label: "There")
                if !result.returnRoute.isEmpty {
                    routePath(from: result.target, hops: result.returnRoute, to: session.myNodeNum, label: "Back")
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func routePath(from start: UInt32, hops: [TracerouteResult.Hop], to end: UInt32, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
            Text(pathDescription(from: start, hops: hops, to: end))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathDescription(from start: UInt32, hops: [TracerouteResult.Hop], to end: UInt32) -> String {
        var parts = [session.shortName(of: start)]
        for hop in hops {
            let snr = hop.snr.map { " (\($0.formatted(.number.precision(.fractionLength(1)))) dB)" } ?? ""
            parts.append(session.shortName(of: hop.nodeNum) + snr)
        }
        parts.append(session.shortName(of: end))
        return parts.joined(separator: " → ")
    }
}
