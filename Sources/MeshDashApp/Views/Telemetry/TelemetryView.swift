import Charts
import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Time windows offered on every chart.
enum ChartRange: String, CaseIterable, Identifiable {
    case sixHours, day, week, month, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        case .all: "All"
        }
    }

    var since: Date? {
        switch self {
        case .sixHours: Date().addingTimeInterval(-6 * 3600)
        case .day: Date().addingTimeInterval(-86_400)
        case .week: Date().addingTimeInterval(-7 * 86_400)
        case .month: Date().addingTimeInterval(-30 * 86_400)
        case .all: nil
        }
    }
}

struct TelemetryView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    @State private var selectedNode: UInt32?
    @State private var kind: TelemetryKind = .device
    @State private var range: ChartRange = .day
    @State private var samples: [TelemetrySample] = []
    @State private var isLoading = false

    private var nodeChoices: [MeshNode] {
        session.visibleNodes
    }

    private var effectiveNode: UInt32? {
        selectedNode ?? (session.myNodeNum == 0 ? nodeChoices.first?.num : session.myNodeNum)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .navigationTitle("Telemetry")
        .navigationSubtitle(effectiveNode.map { session.name(of: $0) } ?? "No node selected")
        .task(id: reloadKey) { await reload() }
    }

    private var reloadKey: String {
        "\(effectiveNode ?? 0)-\(kind.rawValue)-\(range.rawValue)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Node", selection: $selectedNode) {
                ForEach(nodeChoices) { node in
                    Text(node.longName).tag(Optional(node.num))
                }
            }
            .frame(maxWidth: 260)

            Picker("Metrics", selection: $kind) {
                ForEach(TelemetryKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                }
            }
            .frame(maxWidth: 200)

            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            if let node = effectiveNode, node != session.myNodeNum {
                Button("Request Now") {
                    Task { await session.requestTelemetry(from: node, kind: kind) }
                }
                .disabled(!session.isConnected)
                .help("Ask this node to send a fresh reading")
            }
        }
        .padding(12)
        .onAppear {
            if selectedNode == nil { selectedNode = effectiveNode }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if samples.isEmpty {
            EmptyStateView(title: "No \(kind.displayName) Data",
                           message: emptyMessage,
                           symbol: kind.symbolName)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(availableMetrics) { descriptor in
                        MetricChart(descriptor: descriptor,
                                    samples: samples,
                                    kind: kind,
                                    useMetric: model.useMetricUnits)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .device:
            "Device metrics arrive automatically once the Telemetry module is enabled. Check Configuration › Telemetry."
        case .environment, .airQuality, .health:
            "This node has not reported \(kind.displayName.lowercased()) readings. It needs a supported sensor wired up and the matching telemetry option enabled."
        case .localStats:
            "Local statistics come from the radio you are connected to."
        default:
            "No readings have arrived in this time range."
        }
    }

    /// Only chart metrics that actually appear in the loaded samples.
    private var availableMetrics: [MetricDescriptor] {
        let present = Set(samples.flatMap { $0.metrics.keys })
        return TelemetryMetrics.descriptors(for: kind).filter { present.contains($0.key) }
    }

    private func reload() async {
        guard let node = effectiveNode else {
            samples = []
            return
        }
        isLoading = true
        samples = await session.telemetryHistory(for: node, kind: kind, since: range.since)
        isLoading = false
    }
}

private struct MetricChart: View {
    let descriptor: MetricDescriptor
    let samples: [TelemetrySample]
    let kind: TelemetryKind
    let useMetric: Bool

    private struct Point: Identifiable {
        let id = UUID()
        let time: Date
        let value: Double
    }

    private var points: [Point] {
        samples.compactMap { sample in
            guard let raw = sample.metrics[descriptor.key] else { return nil }
            return Point(time: sample.time, value: convert(raw))
        }
    }

    /// Temperatures are stored in Celsius; convert for display only.
    private func convert(_ value: Double) -> Double {
        guard !useMetric, descriptor.unit == "°C" else { return value }
        return value * 9 / 5 + 32
    }

    private var displayUnit: String {
        (!useMetric && descriptor.unit == "°C") ? "°F" : descriptor.unit
    }

    private var latest: Point? { points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(descriptor.label, systemImage: descriptor.symbolName)
                    .font(.headline)
                Spacer()
                if let latest {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(formatted(latest.value))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text(Format.relative(latest.time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Chart(points) { point in
                AreaMark(x: .value("Time", point.time), y: .value(descriptor.label, point.value))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.time), y: .value(descriptor.label, point.value))
                    .foregroundStyle(.tint)
                    .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(formatted(number))
                        }
                    }
                }
            }
            .chartXAxis { AxisMarks(preset: .aligned) }
            .frame(height: 170)

            HStack(spacing: 16) {
                Stat("Min", points.map(\.value).min())
                Stat("Max", points.map(\.value).max())
                Stat("Average", points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count))
                Spacer()
                Text("\(points.count) reading\(points.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatted(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...descriptor.fractionDigits)))
        guard !displayUnit.isEmpty else { return number }
        let spacer = (displayUnit.hasPrefix("°") || displayUnit == "%") ? "" : " "
        return "\(number)\(spacer)\(displayUnit)"
    }

    @ViewBuilder
    private func Stat(_ label: String, _ value: Double?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(formatted(value)).font(.caption.weight(.medium)).monospacedDigit()
            }
        }
    }
}

/// Telemetry for one node, reachable from the node detail pane.
struct NodeTelemetryDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    let node: MeshNode

    @State private var kind: TelemetryKind = .device
    @State private var range: ChartRange = .week
    @State private var samples: [TelemetrySample] = []

    private var availableMetrics: [MetricDescriptor] {
        let present = Set(samples.flatMap { $0.metrics.keys })
        return TelemetryMetrics.descriptors(for: kind).filter { present.contains($0.key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Metrics", selection: $kind) {
                    ForEach(TelemetryKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 200)
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
            }
            .padding(12)
            Divider()

            if samples.isEmpty {
                EmptyStateView(title: "No Data",
                               message: "No \(kind.displayName.lowercased()) readings from this node in this range.",
                               symbol: kind.symbolName)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(availableMetrics) { descriptor in
                            MetricChart(descriptor: descriptor, samples: samples,
                                        kind: kind, useMetric: model.useMetricUnits)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("\(node.longName) Telemetry")
        .task(id: "\(kind.rawValue)-\(range.rawValue)") {
            samples = await session.telemetryHistory(for: node.num, kind: kind, since: range.since)
        }
    }
}
