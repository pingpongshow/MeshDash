import MeshtasticCore
import SwiftUI

/// Gateway-only screen: the things a Meshpoint does that a radio cannot, and
/// the transmit settings its dashboard API can change.
struct MeshpointGatewayView: View {
    @Environment(MeshSession.self) private var session

    @State private var status: MeshpointAPI.DeviceStatus?
    @State private var configuration: MeshpointAPI.Configuration?
    @State private var errorText: String?
    @State private var isLoading = true

    // Editable transmit settings.
    @State private var txEnabled = false
    @State private var txPower = 0
    @State private var hopLimit = 3
    @State private var relayEnabled = false
    @State private var routerMode = false
    @State private var isSaving = false

    private var isDirty: Bool {
        guard let transmit = configuration?.transmit else { return false }
        return txEnabled != (transmit.enabled ?? false)
            || txPower != (transmit.tx_power_dbm ?? 0)
            || hopLimit != (transmit.hop_limit ?? 3)
            || relayEnabled != (transmit.relay?.enabled ?? false)
            || routerMode != (transmit.relay?.router_mode ?? false)
    }

    var body: some View {
        Group {
            if isLoading && configuration == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText, configuration == nil {
                EmptyStateView(title: "Could Not Read the Gateway",
                               message: errorText,
                               symbol: "exclamationmark.triangle",
                               action: ("Try Again", { Task { await reload() } }))
            } else {
                content
            }
        }
        .navigationTitle("Gateway")
        .navigationSubtitle(session.connectedDevice?.name ?? "")
        .toolbar {
            Button { Task { await reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .task { await reload() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Form {
                statusSection
                radioSection
                transmitSection
                relaySection
                meshcoreSection
                limitationsSection
            }
            .formStyle(.grouped)

            if isDirty {
                Divider()
                SaveBar(isDirty: isDirty, isBusy: isSaving) {
                    Task { await save() }
                } revert: { loadEditableValues() }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if let status {
                DetailRow("State", status.status?.capitalized ?? "Unknown")
                if let uptime = status.uptime_seconds {
                    DetailRow("Uptime", Format.duration(uptime))
                }
                if let version = status.firmware_version {
                    DetailRow("Meshpoint Version", version, monospaced: true)
                }
                if let deviceID = status.device_id {
                    DetailRow("Device ID", deviceID, monospaced: true)
                }
                if let clients = status.websocket_clients {
                    DetailRow("Dashboard Clients", "\(clients)")
                }
            }
            if let duty = configuration?.duty_cycle, let used = duty.used_percent {
                DetailRow("Duty Cycle Used", "\(used.formatted(.number.precision(.fractionLength(0...2))))%")
                FieldNote("Regional rules cap how much airtime the gateway may use. When this reaches the limit, transmissions are deferred.")
            }
        }
    }

    @ViewBuilder
    private var radioSection: some View {
        if let radio = configuration?.radio {
            Section("Concentrator") {
                if let region = radio.region { DetailRow("Region", region) }
                if let preset = radio.current_preset { DetailRow("Preset", preset) }
                if let frequency = radio.frequency_mhz {
                    DetailRow("Frequency", "\(frequency.formatted(.number.precision(.fractionLength(0...3)))) MHz")
                }
                if let sf = radio.spreading_factor { DetailRow("Spreading Factor", "SF\(sf)") }
                if let bandwidth = radio.bandwidth_khz {
                    DetailRow("Bandwidth", "\(Int(bandwidth)) kHz")
                }
                if let coding = radio.coding_rate { DetailRow("Coding Rate", coding) }
                FieldNote("The SX1302 concentrator decodes SF7 to SF12 in parallel, which is why this gateway hears traffic a single-radio node would miss. Change the region or preset from the LoRa page.")
            }
        }
    }

    private var transmitSection: some View {
        Section("Transmit") {
            Toggle("Transmit enabled", isOn: $txEnabled)
            FieldNote("With this off the gateway listens only — it will not send your messages or relay anything.",
                      isWarning: !txEnabled)
            Stepper("Transmit power: \(txPower) dBm", value: $txPower, in: 0...30)
            Stepper("Hop limit: \(hopLimit)", value: $hopLimit, in: 1...7)
            FieldNote("The concentrator transmits at up to 27 dBm, well above a typical node. Use only what you need.")
        }
    }

    private var relaySection: some View {
        Section("Relay") {
            Toggle("Smart relay", isOn: $relayEnabled)
            FieldNote("Rebroadcasts captured packets through the same concentrator, preserving the original sender and packet ID.")
            Toggle("Router mode", isOn: $routerMode)
                .disabled(!relayEnabled)
            FieldNote("Promotes the relay to full ROUTER behaviour: the role is advertised in NodeInfo, rebroadcasts are SNR-weighted, and it backs off when another node beats it to the relay. Only enable this if the gateway is a good, well-sited router for your mesh.",
                      isWarning: routerMode)
        }
    }

    @ViewBuilder
    private var meshcoreSection: some View {
        if let meshcore = configuration?.meshcore, (meshcore.companion_expected ?? false) || (meshcore.connected ?? false) {
            Section("MeshCore Companion") {
                DetailRow("Connected", (meshcore.connected ?? false) ? "Yes" : "No")
                if let name = meshcore.companion_name, !name.isEmpty {
                    DetailRow("Companion", name)
                }
                FieldNote("MeshCore is a separate protocol. Its traffic is visible in the Meshpoint dashboard, but MeshDash shows only the Meshtastic side of the gateway.")
            }
        }
    }

    private var limitationsSection: some View {
        Section("What MeshDash Shows") {
            FieldNote("Messages, nodes, the map and telemetry come from the gateway's own database, so you see everything its concentrator has heard — not just what one radio picked up.")
            FieldNote("Traceroute, module settings, and device operations such as reboot or factory reset are firmware features with no Meshpoint equivalent, so they are hidden while connected here.")
            if let node = session.myNode {
                DetailRow("Gateway Node", "\(node.longName) · \(node.hexID)")
            }
        }
    }

    // MARK: - Data

    private func reload() async {
        guard let client = session.meshpointClient else {
            errorText = "This screen is only available while connected to a Meshpoint gateway."
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        do {
            async let statusTask = client.deviceStatus()
            async let configurationTask = client.configuration()
            status = try await statusTask
            configuration = try await configurationTask
            loadEditableValues()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func loadEditableValues() {
        guard let transmit = configuration?.transmit else { return }
        txEnabled = transmit.enabled ?? false
        txPower = transmit.tx_power_dbm ?? 0
        hopLimit = transmit.hop_limit ?? 3
        relayEnabled = transmit.relay?.enabled ?? false
        routerMode = transmit.relay?.router_mode ?? false
    }

    private func save() async {
        guard let client = session.meshpointClient else { return }
        isSaving = true
        do {
            try await client.updateTransmit(enabled: txEnabled,
                                            txPowerDBm: txPower,
                                            hopLimit: hopLimit,
                                            relayEnabled: relayEnabled,
                                            routerMode: routerMode)
            session.post(title: "Gateway updated",
                         detail: "Transmit settings saved. Some changes need a Meshpoint restart to take effect.",
                         isError: false)
            await reload()
        } catch {
            session.post(title: "Could not save", detail: error.localizedDescription, isError: true)
        }
        isSaving = false
    }
}
