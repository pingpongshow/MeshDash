import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Administering another node over the mesh. The firmware requires that this
/// Mac's radio public key be listed as an admin key on the target, and that the
/// target has issued a session passkey (which reading a setting does).
struct RemoteAdminSheet: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let node: MeshNode

    @State private var hasRequestedSession = false

    private var target: AdminTarget { session.adminTarget(for: node.num) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                Section("Session") {
                    Button("Start Admin Session") {
                        hasRequestedSession = true
                        Task { await session.beginRemoteAdminSession(with: node.num) }
                    }
                    .disabled(!session.isConnected)
                    FieldNote("Reads one setting from \(node.longName), which is what makes it issue the session key that later changes need. Sessions expire after a few minutes of inactivity.")
                    if hasRequestedSession {
                        FieldNote("Watch the notices at the bottom of the window. \"Not authorized\" means this Mac's radio public key is not in that node's admin key list.")
                    }
                }

                Section("Read Settings") {
                    Button("Read All Settings") {
                        Task { await session.refreshAllSettings(for: node.num) }
                    }
                    Button("Read Device Metadata") {
                        Task { await session.refreshDeviceMetadata(target: target) }
                    }
                    Button("Read Canned Messages") {
                        Task { await session.refreshCannedMessages(target: target) }
                    }
                    Button("Read Ringtone") {
                        Task { await session.refreshRingtone(target: target) }
                    }
                    Button("Read Remote Hardware Pins") {
                        Task { await session.refreshRemoteHardwarePins(target: target) }
                    }
                    FieldNote("Settings you read here replace what is shown in the Configuration tab, so you can inspect the remote node with the same forms. Reconnect or reload to get your own radio's settings back.",
                              isWarning: true)
                }

                Section("Actions") {
                    Button("Set Its Clock to This Mac") {
                        Task { await session.setTime(target: target) }
                    }
                    Button("Reboot") {
                        Task { await session.reboot(target: target) }
                    }
                    Button("Shut Down", role: .destructive) {
                        Task { await session.shutdown(target: target) }
                    }
                    FieldNote("A shutdown can only be undone by pressing the button on the device itself.", isWarning: true)
                }

                Section("Your Admin Key") {
                    if let key = session.myNode?.user?.publicKey, !key.isEmpty {
                        Text(key.base64EncodedString())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key.base64EncodedString(), forType: .string)
                        }
                    } else {
                        Text("This radio has no public key yet.").foregroundStyle(.secondary)
                    }
                    FieldNote("Add this key to \(node.longName)'s Security settings — while you still have physical access to it — to allow remote administration.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            NodeAvatar(node: node, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Administration").font(.headline)
                Text("\(node.longName) · \(node.hexID)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}
