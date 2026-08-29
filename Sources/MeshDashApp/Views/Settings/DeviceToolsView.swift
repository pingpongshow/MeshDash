import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Destructive and one-shot device operations, kept away from the settings forms.
struct DeviceToolsView: View {
    @Environment(MeshSession.self) private var session

    @State private var pendingAction: DangerousAction?
    @State private var isShowingHamMode = false
    @State private var ringtoneText = ""

    enum DangerousAction: Identifiable {
        case reboot, shutdown, otaUpdate, factoryResetKeepNodes, factoryResetAll, resetNodeDatabase, dfu

        var id: String { String(describing: self) }

        var title: String {
            switch self {
            case .reboot: "Reboot the radio?"
            case .shutdown: "Shut the radio down?"
            case .otaUpdate: "Restart into update mode?"
            case .factoryResetKeepNodes: "Reset all settings?"
            case .factoryResetAll: "Erase everything on the radio?"
            case .resetNodeDatabase: "Clear the node database?"
            case .dfu: "Enter firmware update mode?"
            }
        }

        var message: String {
            switch self {
            case .reboot:
                "The radio restarts in five seconds and MeshDash reconnects on its own."
            case .shutdown:
                "The radio powers off. You will need to press its button to turn it back on — this cannot be done remotely."
            case .otaUpdate:
                "The radio restarts into its over-the-air update mode."
            case .factoryResetKeepNodes:
                "Every setting returns to its default, including your channels and region. The list of known nodes is kept. This cannot be undone."
            case .factoryResetAll:
                "Every setting, channel, key, Bluetooth pairing and known node is erased. The radio comes back as if it were newly flashed. This cannot be undone."
            case .resetNodeDatabase:
                "The radio forgets every node it has heard. They will reappear as it hears from them again."
            case .dfu:
                "The radio presents itself as a USB drive for firmware flashing and stops responding to MeshDash until you reset it."
            }
        }

        var confirmTitle: String {
            switch self {
            case .reboot: "Reboot"
            case .shutdown: "Shut Down"
            case .otaUpdate: "Restart"
            case .factoryResetKeepNodes, .factoryResetAll: "Erase"
            case .resetNodeDatabase: "Clear"
            case .dfu: "Enter DFU"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .reboot, .otaUpdate: false
            default: true
            }
        }
    }

    var body: some View {
        Form {
            clockSection
            ringtoneSection
            licensedSection
            connectionStatusSection
            restartSection
            resetSection
            backupSection
        }
        .formStyle(.grouped)
        .navigationTitle("Device Tools")
        .formStyle(.grouped)
        .navigationTitle("Device Tools")
        .alert(pendingAction?.title ?? "",
               isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
               presenting: pendingAction) { action in
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) {
                perform(action)
                pendingAction = nil
            }
        } message: { action in
            Text(action.message)
        }
        .sheet(isPresented: $isShowingHamMode) {
            HamModeSheet().frame(width: 460, height: 380)
        }
        .onChange(of: session.ringtone) { _, new in
            if let new { ringtoneText = new }
        }
    }


    private var clockSection: some View {
        Section("Clock") {
            LabeledContent("Radio time") {
                Text(session.myNode?.lastHeard.map(Format.timestamp) ?? "Unknown")
                    .foregroundStyle(.secondary)
            }
            Button("Set Radio Clock to This Mac") {
                Task { await session.setTime() }
            }
            FieldNote("A radio without GPS or network has no idea what time it is until a client tells it.")
        }
    }

    private var ringtoneSection: some View {
        Section("Ringtone") {
            TextField("RTTTL ringtone", text: $ringtoneText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...4)
            HStack {
                Button("Load from Radio") { Task { await session.refreshRingtone() } }
                Button("Save to Radio") { Task { await session.saveRingtone(ringtoneText) } }
                    .disabled(ringtoneText.isEmpty)
            }
            FieldNote("Played by the External Notification module on boards with a buzzer. Uses the RTTTL format, the same as old phone ringtones.")
        }
    }

    private var licensedSection: some View {
        Section("Licensed Operation") {
            Button("Configure Amateur Radio Mode…") { isShowingHamMode = true }
            FieldNote("Sets your call sign, disables encryption, and applies the transmit power and frequency your licence permits. Only for licensed amateur operators.")
        }
    }

    @ViewBuilder
    private var connectionStatusSection: some View {
        Section("Connection Status") {
            if let status = session.connectionStatus {
                if status.hasWifi {
                    let wifi = status.wifi.status
                    DetailRow("WiFi", wifi.isConnected ? "Connected to \(status.wifi.ssid)" : "Not connected")
                    if wifi.isConnected {
                        DetailRow("WiFi Signal", "\(status.wifi.rssi) dBm")
                        DetailRow("MQTT", wifi.isMqttConnected ? "Connected" : "Not connected")
                    }
                }
                if status.hasEthernet {
                    let ethernet = status.ethernet.status
                    DetailRow("Ethernet", ethernet.isConnected ? "Connected" : "Not connected")
                    if ethernet.isConnected {
                        DetailRow("MQTT", ethernet.isMqttConnected ? "Connected" : "Not connected")
                    }
                }
                if status.hasBluetooth {
                    DetailRow("Bluetooth", status.bluetooth.isConnected ? "Connected" : "Not connected")
                }
                if status.hasSerial {
                    DetailRow("Serial", status.serial.isConnected ? "Connected at \(status.serial.baud) baud" : "Not connected")
                }
            } else {
                Text("Not loaded.").foregroundStyle(.secondary)
            }
            Button("Refresh") { Task { await session.refreshConnectionStatus() } }
        }
    }

    private var restartSection: some View {
        Section("Restart") {
            Button("Reboot Radio") { pendingAction = .reboot }
            Button("Shut Down Radio") { pendingAction = .shutdown }
            Button("Restart into Update Mode") { pendingAction = .otaUpdate }
            Button("Enter Firmware Update (DFU) Mode") { pendingAction = .dfu }
        }
    }

    private var resetSection: some View {
        Section("Reset") {
            Button("Clear Node Database", role: .destructive) { pendingAction = .resetNodeDatabase }
            Button("Reset All Settings", role: .destructive) { pendingAction = .factoryResetKeepNodes }
            Button("Full Factory Reset", role: .destructive) { pendingAction = .factoryResetAll }
            FieldNote("Before a factory reset, save a copy of your channel link from the Channels tab. You will need it to rejoin your mesh.",
                      isWarning: true)
        }
    }

    private var backupSection: some View {
        Section("Backups") {
            Button("Back Up Settings to the Device Flash") {
                Task { await session.backupSettings() }
            }
            Button("Restore Settings from the Device Flash") {
                Task { await session.restoreSettings() }
            }
            FieldNote("Stores a copy of the radio's settings on the device itself, which survives a settings reset but not a full erase.")
        }
    }

    private func perform(_ action: DangerousAction) {
        Task {
            switch action {
            case .reboot: await session.reboot()
            case .shutdown: await session.shutdown()
            case .otaUpdate: await session.rebootToOTA()
            case .dfu: await session.enterDFUMode()
            case .resetNodeDatabase: await session.resetNodeDatabase()
            case .factoryResetKeepNodes: await session.factoryReset(keepNodeDatabase: true)
            case .factoryResetAll: await session.factoryReset(keepNodeDatabase: false)
            }
        }
    }
}

private struct HamModeSheet: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var callSign = ""
    @State private var shortName = ""
    @State private var txPower: Int32 = 20
    @State private var frequency: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Amateur Radio Mode").font(.title3.weight(.semibold))
            Text("This disables encryption on all channels and puts your call sign in the clear, as amateur licensing requires. It also lets you set transmit power and frequency beyond the unlicensed limits.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Call sign", text: $callSign)
                    .textCase(.uppercase)
                TextField("Short name", text: $shortName)
                    .onChange(of: shortName) { _, new in
                        if new.count > 4 { shortName = String(new.prefix(4)) }
                    }
                LabeledContent("Transmit power (dBm)") {
                    TextField("", value: $txPower, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                LabeledContent("Frequency (MHz)") {
                    TextField("", value: $frequency, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            .formStyle(.grouped)

            Label("Only enable this if you hold a valid amateur radio licence for the band and power you are entering.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enable") {
                    Task {
                        await session.setHamMode(callSign: callSign.uppercased(), txPower: txPower,
                                                 frequency: frequency, shortName: shortName)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(callSign.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}

