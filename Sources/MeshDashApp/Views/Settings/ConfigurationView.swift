import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

enum ConfigPage: String, CaseIterable, Identifiable, Hashable {
    // Device
    case identity, deviceActions
    // Radio
    case device, position, power, network, display, lora, bluetooth, security
    // Modules
    case mqtt, serial, externalNotification, storeForward, rangeTest, telemetryModule,
         cannedMessages, audio, remoteHardware, neighborInfo, ambientLighting,
         detectionSensor, paxcounter, statusMessage, trafficManagement, tak, meshBeacon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity: "Identity"
        case .deviceActions: "Device Tools"
        case .device: "Device"
        case .position: "Position"
        case .power: "Power"
        case .network: "Network"
        case .display: "Display"
        case .lora: "LoRa"
        case .bluetooth: "Bluetooth"
        case .security: "Security"
        case .mqtt: "MQTT"
        case .serial: "Serial"
        case .externalNotification: "External Notification"
        case .storeForward: "Store & Forward"
        case .rangeTest: "Range Test"
        case .telemetryModule: "Telemetry"
        case .cannedMessages: "Canned Messages"
        case .audio: "Audio"
        case .remoteHardware: "Remote Hardware"
        case .neighborInfo: "Neighbor Info"
        case .ambientLighting: "Ambient Lighting"
        case .detectionSensor: "Detection Sensor"
        case .paxcounter: "Paxcounter"
        case .statusMessage: "Status Message"
        case .trafficManagement: "Traffic Management"
        case .tak: "TAK"
        case .meshBeacon: "Mesh Beacon"
        }
    }

    var symbolName: String {
        switch self {
        case .identity: "person.text.rectangle"
        case .deviceActions: "wrench.and.screwdriver"
        case .device: "cpu"
        case .position: "location"
        case .power: "bolt"
        case .network: "wifi"
        case .display: "display"
        case .lora: "antenna.radiowaves.left.and.right"
        case .bluetooth: "wave.3.right"
        case .security: "lock.shield"
        case .mqtt: "network"
        case .serial: "cable.connector"
        case .externalNotification: "bell.badge"
        case .storeForward: "tray.full"
        case .rangeTest: "ruler"
        case .telemetryModule: "chart.xyaxis.line"
        case .cannedMessages: "text.bubble"
        case .audio: "waveform"
        case .remoteHardware: "switch.2"
        case .neighborInfo: "point.3.connected.trianglepath.dotted"
        case .ambientLighting: "lightbulb"
        case .detectionSensor: "sensor"
        case .paxcounter: "person.3"
        case .statusMessage: "quote.bubble"
        case .trafficManagement: "arrow.left.arrow.right"
        case .tak: "shield"
        case .meshBeacon: "dot.radiowaves.up.forward"
        }
    }

    static let deviceGroup: [ConfigPage] = [.identity, .deviceActions]
    static let radioGroup: [ConfigPage] = [.device, .position, .power, .network, .display, .lora, .bluetooth, .security]
    static let moduleGroup: [ConfigPage] = [.mqtt, .serial, .externalNotification, .storeForward, .rangeTest,
                                            .telemetryModule, .cannedMessages, .audio, .remoteHardware,
                                            .neighborInfo, .ambientLighting, .detectionSensor, .paxcounter,
                                            .statusMessage, .trafficManagement, .tak, .meshBeacon]
}

struct ConfigurationView: View {
    @Environment(MeshSession.self) private var session
    @State private var page: ConfigPage? = .identity

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section(session.isMeshpointBackend ? "This Gateway" : "This Radio") {
                    ForEach(deviceGroup) { row($0) }
                }
                Section(session.isMeshpointBackend ? "Gateway Settings" : "Radio Settings") {
                    ForEach(radioGroup) { row($0) }
                }
                if session.supportsModuleConfiguration {
                    Section("Modules") {
                        ForEach(ConfigPage.moduleGroup) { row($0) }
                    }
                } else {
                    Section("Modules") {
                        Text("Module settings live in the radio firmware and are not exposed by a Meshpoint gateway.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Configuration")
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } detail: {
            if !session.isConnected {
                EmptyStateView(title: "Not Connected",
                               message: "Connect to a radio to read and change its settings.",
                               symbol: "antenna.radiowaves.left.and.right.slash")
            } else if let page {
                ConfigDetail(page: page).id(page)
            } else {
                EmptyStateView(title: "Configuration",
                               message: "Pick a section to view or change settings on the connected radio.",
                               symbol: "slider.horizontal.3")
            }
        }
    }

    /// A Meshpoint can change its identity and its radio, and nothing else.
    private var deviceGroup: [ConfigPage] {
        session.supportsDeviceLifecycle ? ConfigPage.deviceGroup : [.identity]
    }

    private var radioGroup: [ConfigPage] {
        session.supportsFullRadioConfiguration ? ConfigPage.radioGroup : [.lora]
    }

    private func row(_ page: ConfigPage) -> some View {
        NavigationLink(value: page) {
            Label(page.title, systemImage: page.symbolName)
        }
    }
}

private struct ConfigDetail: View {
    let page: ConfigPage

    var body: some View {
        switch page {
        case .identity: IdentityForm()
        case .deviceActions: DeviceToolsView()
        case .device: DeviceConfigForm()
        case .position: PositionConfigForm()
        case .power: PowerConfigForm()
        case .network: NetworkConfigForm()
        case .display: DisplayConfigForm()
        case .lora: LoRaConfigForm()
        case .bluetooth: BluetoothConfigForm()
        case .security: SecurityConfigForm()
        case .mqtt: MQTTConfigForm()
        case .serial: SerialConfigForm()
        case .externalNotification: ExternalNotificationConfigForm()
        case .storeForward: StoreForwardConfigForm()
        case .rangeTest: RangeTestConfigForm()
        case .telemetryModule: TelemetryConfigForm()
        case .cannedMessages: CannedMessagesForm()
        case .audio: AudioConfigForm()
        case .remoteHardware: RemoteHardwareConfigForm()
        case .neighborInfo: NeighborInfoConfigForm()
        case .ambientLighting: AmbientLightingConfigForm()
        case .detectionSensor: DetectionSensorConfigForm()
        case .paxcounter: PaxcounterConfigForm()
        case .statusMessage: StatusMessageConfigForm()
        case .trafficManagement: TrafficManagementConfigForm()
        case .tak: TAKConfigForm()
        case .meshBeacon: MeshBeaconConfigForm()
        }
    }
}

/// Shared shell for every settings form: keeps an editable draft, shows a save
/// bar when it differs from the radio, and warns before a change that reboots.
struct ConfigFormShell<Value: Equatable & Sendable, Content: View>: View {
    let title: String
    let subtitle: String?
    let current: Value
    let save: @MainActor (Value) async -> Void
    @ViewBuilder let content: (Binding<Value>) -> Content

    @State private var draft: Value
    @State private var isSaving = false

    init(title: String,
         subtitle: String? = nil,
         current: Value,
         save: @escaping @MainActor (Value) async -> Void,
         @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.current = current
        self.save = save
        self.content = content
        _draft = State(initialValue: current)
    }

    private var isDirty: Bool { draft != current }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                content($draft)
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            if isDirty {
                Divider()
                SaveBar(isDirty: isDirty, isBusy: isSaving) {
                    isSaving = true
                    Task {
                        await save(draft)
                        isSaving = false
                    }
                } revert: {
                    draft = current
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
        .onChange(of: current) { _, new in
            // Adopt what the radio reports unless the user is mid-edit.
            if !isDirty { draft = new }
        }
    }
}

// MARK: - Reusable field controls

/// Duration picker with the intervals the firmware documents, plus "off".
struct IntervalPicker: View {
    let title: String
    @Binding var seconds: UInt32
    var allowsOff = true
    var offLabel = "Default"
    var options: [UInt32] = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 21600, 43200, 86400]

    var body: some View {
        Picker(title, selection: $seconds) {
            if allowsOff { Text(offLabel).tag(UInt32(0)) }
            ForEach(options, id: \.self) { value in
                Text(Format.duration(Double(value))).tag(value)
            }
            // Keep an unusual value set elsewhere visible rather than snapping it.
            if seconds != 0, !options.contains(seconds) {
                Text(Format.duration(Double(seconds))).tag(seconds)
            }
        }
    }
}

/// GPIO pin entry that treats zero as "not connected".
struct PinField: View {
    let title: String
    @Binding var pin: UInt32
    var help: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", value: $pin, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Text(pin == 0 ? "unset" : "GPIO \(pin)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
            }
        }
        .help(help ?? "")
    }
}

/// Explanatory text under a control, styled consistently.
struct FieldNote: View {
    let text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if isWarning { Image(systemName: "exclamationmark.triangle.fill") }
        }
        .font(.caption)
        .foregroundStyle(isWarning ? .orange : .secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
