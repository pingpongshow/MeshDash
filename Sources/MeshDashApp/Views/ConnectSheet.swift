import CoreBluetooth
import MeshtasticCore
import SwiftUI

/// Device picker covering all three transports, with Bluetooth and the local
/// network scanning live and USB serial rescanned on demand.
struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var kind: TransportKind = .bluetooth
    @State private var manualHost = ""
    @State private var manualPort = String(TCPTransport.defaultPort)
    @State private var serialPorts: [DiscoveredDevice] = []
    @State private var knownDevices: [DiscoveredDevice] = []

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Connection", selection: $kind) {
                ForEach(TransportKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    transportSection
                    if !knownDevices.isEmpty { recentSection }
                }
                .padding(20)
            }

            Divider()
            HStack {
                statusText
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .task {
            knownDevices = await session.knownDevices()
            serialPorts = SerialPortScanner.discoveredDevices()
        }
        .onChange(of: kind) { _, newValue in
            if newValue == .serial { serialPorts = SerialPortScanner.discoveredDevices() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("Connect to a Radio").font(.title2.weight(.semibold))
            Text("MeshDash talks to Meshtastic devices over Bluetooth, your local network, or USB.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 22)
        .padding(.horizontal, 30)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var transportSection: some View {
        switch kind {
        case .bluetooth: bluetoothSection
        case .tcp: networkSection
        case .serial: serialSection
        case .meshpoint:
            MeshpointConnectSection(knownDevices: knownDevices) { device in
                Task { await model.connect(to: device) }
                dismiss()
            }
        }
    }

    // MARK: - Bluetooth

    @ViewBuilder
    private var bluetoothSection: some View {
        if let reason = model.bluetoothScanner.unavailableReason {
            EmptyStateView(title: "Bluetooth Unavailable", message: reason, symbol: "wave.3.right.circle")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if model.bluetoothScanner.devices.isEmpty {
            scanningPlaceholder("Looking for radios",
                                "Make sure the radio is powered on and within range. A radio already paired to another app may not advertise.")
        } else {
            deviceList(model.bluetoothScanner.devices)
            Text("The first connection asks the radio for a pairing code shown on its screen. Devices with no screen use the fixed code 123456.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Network

    @ViewBuilder
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.networkScanner.devices.isEmpty {
                scanningPlaceholder("Searching your network",
                                    "Radios with WiFi or Ethernet enabled announce themselves over Bonjour. If yours does not appear, enter its address below.")
            } else {
                deviceList(model.networkScanner.devices)
            }

            GroupBox("Connect by address") {
                HStack {
                    TextField("Hostname or IP", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connectManually)
                    TextField("Port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Button("Connect", action: connectManually)
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(6)
            }

            if let error = model.networkScanner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func connectManually() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let port = UInt16(manualPort) ?? TCPTransport.defaultPort
        let device = model.networkScanner.addManualHost(host, port: port)
        Task { await model.connect(to: device) }
        dismiss()
    }

    // MARK: - Serial

    @ViewBuilder
    private var serialSection: some View {
        if serialPorts.isEmpty {
            VStack(spacing: 12) {
                EmptyStateView(title: "No Serial Devices",
                               message: "Plug the radio in with a data-capable USB cable. Charge-only cables will not work.",
                               symbol: "cable.connector.slash")
                Button("Scan Again") { serialPorts = SerialPortScanner.discoveredDevices() }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            deviceList(serialPorts)
            Button("Scan Again") { serialPorts = SerialPortScanner.discoveredDevices() }
                .controlSize(.small)
        }
    }

    // MARK: - Shared pieces

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently Connected").font(.headline)
            ForEach(knownDevices.filter { $0.address.kind != .meshpoint }) { device in
                DeviceRow(device: device) {
                    Task { await model.connect(to: device) }
                    dismiss()
                } forget: {
                    Task {
                        await session.forgetDevice(device.address)
                        knownDevices = await session.knownDevices()
                    }
                }
            }
        }
    }

    private func deviceList(_ devices: [DiscoveredDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available").font(.headline)
            ForEach(devices) { device in
                DeviceRow(device: device) {
                    Task { await model.connect(to: device) }
                    dismiss()
                }
            }
        }
    }

    private func scanningPlaceholder(_ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    @ViewBuilder
    private var statusText: some View {
        switch session.connectionState {
        case .connecting(let detail):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let connect: () -> Void
    var forget: (() -> Void)?

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 12) {
                Image(systemName: device.address.kind.symbolName)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.medium))
                    Text(device.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let rssi = device.rssi {
                    HStack(spacing: 5) {
                        SignalBars(quality: SignalQuality(snr: 0, rssi: rssi), compact: true)
                        Text("\(rssi)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if let forget {
                Button("Forget This Device", systemImage: "trash", role: .destructive, action: forget)
            }
        }
    }
}
