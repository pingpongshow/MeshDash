import MeshtasticCore
import SwiftUI

/// Meshpoint tab of the connect sheet: address entry, remembered gateways, and
/// the sign-in step the dashboard API requires.
struct MeshpointConnectSection: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    let knownDevices: [DiscoveredDevice]
    let connect: (DiscoveredDevice) -> Void

    @State private var host = ""
    @State private var port = String(MeshpointClient.defaultPort)
    @State private var status: Status = .idle
    @State private var pendingLogin: DiscoveredDevice?

    private enum Status: Equatable {
        case idle
        case checking
        case failed(String)
    }

    private var meshpoints: [DiscoveredDevice] {
        knownDevices.filter { $0.address.kind == .meshpoint }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A Meshpoint gateway runs its own dashboard rather than the Meshtastic network API, so MeshDash signs in to it and reads the mesh through that.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Gateway address") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Hostname or IP", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(check)
                        TextField("Port", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Button("Connect", action: check)
                            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || status == .checking)
                    }
                    switch status {
                    case .checking:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").font(.caption).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    case .idle:
                        Text("The dashboard's default port is 8080.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }

            if !meshpoints.isEmpty {
                Text("Known Gateways").font(.headline)
                ForEach(meshpoints) { device in
                    Button {
                        beginConnect(to: device)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.title3).frame(width: 26).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.body.weight(.medium))
                                Text(device.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .contextMenu {
                        Button("Sign Out and Forget", systemImage: "trash", role: .destructive) {
                            Task {
                                if case .meshpoint(let host, let port) = device.address {
                                    await MeshpointClient(host: host, port: port).signOut()
                                }
                                await session.forgetDevice(device.address)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $pendingLogin) { device in
            MeshpointLoginSheet(device: device) { connect(device) }
                .frame(width: 420, height: 360)
        }
    }

    private func check() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let portValue = UInt16(port) ?? MeshpointClient.defaultPort
        let device = DiscoveredDevice(address: .meshpoint(host: trimmed, port: portValue),
                                      name: trimmed,
                                      detail: "Meshpoint dashboard · \(trimmed):\(portValue)")
        beginConnect(to: device)
    }

    /// Confirms the address really is a Meshpoint, then either connects with the
    /// stored session or asks the user to sign in.
    private func beginConnect(to device: DiscoveredDevice) {
        guard case .meshpoint(let host, let port) = device.address else { return }
        status = .checking
        Task {
            let client = MeshpointClient(host: host, port: port)
            do {
                try await client.probe()
            } catch {
                status = .failed(error.localizedDescription)
                return
            }
            if await client.hasStoredToken {
                // A stored token may have expired; find out before connecting.
                do {
                    _ = try await client.deviceStatus()
                    status = .idle
                    connect(device)
                    return
                } catch MeshpointError.authenticationRequired {
                    // Fall through to the sign-in sheet.
                } catch {
                    status = .failed(error.localizedDescription)
                    return
                }
            }
            status = .idle
            pendingLogin = device
        }
    }
}

/// Sign-in for a Meshpoint. The password goes straight to the gateway and is
/// never stored; only the session token it returns is kept, in the keychain.
struct MeshpointLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let device: DiscoveredDevice
    let onSuccess: () -> Void

    @State private var username = "admin"
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign In to Meshpoint").font(.title3.weight(.semibold))
                Text(device.detail).font(.caption).foregroundStyle(.secondary)
            }

            Text("Use the same credentials as the Meshpoint web dashboard. MeshDash keeps only the session token it returns, in your login keychain — never the password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                    .focused($passwordFocused)
                    .onSubmit(submit)
            }
            .formStyle(.grouped)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || username.isEmpty || isWorking)
            }
        }
        .padding(20)
        .onAppear { passwordFocused = true }
    }

    private func submit() {
        guard case .meshpoint(let host, let port) = device.address else { return }
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        errorText = nil
        Task {
            let client = MeshpointClient(host: host, port: port)
            do {
                _ = try await client.logIn(username: username, password: password)
                password = ""
                isWorking = false
                dismiss()
                onSuccess()
            } catch {
                isWorking = false
                errorText = error.localizedDescription
            }
        }
    }
}
