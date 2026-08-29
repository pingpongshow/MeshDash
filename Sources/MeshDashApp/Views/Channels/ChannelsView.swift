import AppKit
import CoreImage.CIFilterBuiltins
import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI
import UniformTypeIdentifiers

struct ChannelsView: View {
    @Environment(MeshSession.self) private var session

    @State private var draft: [Channel] = []
    @State private var selection: Int?
    @State private var isShowingShareSheet = false
    @State private var isShowingImportSheet = false
    @State private var isSaving = false

    private var isDirty: Bool { draft != session.channels }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(draft.enumerated()), id: \.offset) { index, channel in
                    NavigationLink(value: index) {
                        ChannelRow(channel: channel, index: index, preset: session.loraConfig.modemPreset)
                    }
                }
            }
            .navigationTitle("Channels")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .toolbar {
                Menu {
                    Button("Share Channels…", systemImage: "qrcode") { isShowingShareSheet = true }
                        .disabled(session.activeChannels.isEmpty)
                    Button("Import from Link…", systemImage: "link") { isShowingImportSheet = true }
                        .disabled(!session.isConnected)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        } detail: {
            if let selection, selection < draft.count {
                ChannelEditor(channel: Binding(
                    get: { draft[selection] },
                    set: { draft[selection] = $0 }
                ), index: selection, isPrimarySlot: selection == 0)
                .id(selection)
            } else {
                EmptyStateView(title: "Channels",
                               message: "A Meshtastic radio carries up to eight channels. The first is the primary channel and defines the mesh you are on; the rest are optional secondary channels.",
                               symbol: "number")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isDirty {
                SaveBar(isDirty: isDirty, isBusy: isSaving) {
                    isSaving = true
                    Task {
                        await session.saveChannels(draft)
                        isSaving = false
                    }
                } revert: {
                    draft = normalized(session.channels)
                }
            }
        }
        .sheet(isPresented: $isShowingShareSheet) { ChannelShareSheet().frame(width: 460, height: 620) }
        .sheet(isPresented: $isShowingImportSheet) { ChannelImportSheet().frame(width: 520, height: 340) }
        .onAppear { draft = normalized(session.channels) }
        .onChange(of: session.channels) { _, new in
            // Adopt the radio's state unless the user has edits in flight.
            if !isDirty || draft.isEmpty { draft = normalized(new) }
        }
    }

    /// A radio always exposes eight slots; pad so every slot is editable.
    private func normalized(_ channels: [Channel]) -> [Channel] {
        var result = channels.sorted { $0.index < $1.index }
        while result.count < 8 {
            var channel = Channel()
            channel.index = Int32(result.count)
            channel.role = result.isEmpty ? .primary : .disabled
            result.append(channel)
        }
        return Array(result.prefix(8))
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let index: Int
    let preset: Config.LoRaConfig.ModemPreset

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(channel.role == .disabled ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.2))
                Text("\(index)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(channel.role == .disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.settings.displayName(preset: preset, isPrimary: channel.role == .primary))
                    .font(.body.weight(.medium))
                    .foregroundStyle(channel.role == .disabled ? .secondary : .primary)
                Text(channel.role == .disabled ? "Disabled" : channel.settings.encryptionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if channel.role == .primary {
                Text("Primary").font(.caption2).foregroundStyle(.tint)
            }
            if channel.settings.hasModuleSettings, channel.settings.moduleSettings.isMuted {
                Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary)
            }
            if channel.settings.uplinkEnabled || channel.settings.downlinkEnabled {
                Image(systemName: "network").font(.caption).foregroundStyle(.secondary)
                    .help("Bridged to MQTT")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ChannelEditor: View {
    @Environment(MeshSession.self) private var session
    @Binding var channel: Channel
    let index: Int
    let isPrimarySlot: Bool

    @State private var keyText = ""
    @State private var keyError: String?

    var body: some View {
        Form {
            Section {
                Picker("Role", selection: roleBinding) {
                    Text("Disabled").tag(Channel.Role.disabled)
                    if isPrimarySlot {
                        Text("Primary").tag(Channel.Role.primary)
                    } else {
                        Text("Secondary").tag(Channel.Role.secondary)
                    }
                }
                .disabled(isPrimarySlot)

                TextField("Name", text: nameBinding, prompt: Text(isPrimarySlot ? session.loraConfig.modemPreset.displayName : "Channel \(index)"))
                    .disabled(channel.role == .disabled)
            } header: {
                Text("Channel \(index)")
            } footer: {
                if isPrimarySlot {
                    Text("The primary channel defines which mesh this radio belongs to. Every node that should hear you needs the same name and key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Encryption") {
                LabeledContent("Key") {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("Base64 key", text: $keyText)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(applyKey)
                            .onChange(of: keyText) { _, _ in applyKey() }
                        if let keyError {
                            Text(keyError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .disabled(channel.role == .disabled)

                HStack {
                    Button("Default Key") { setKey(Data([1])) }
                    Button("Random 128-bit") { setKey(Channel.randomKey(bytes: 16)) }
                    Button("Random 256-bit") { setKey(Channel.randomKey(bytes: 32)) }
                    Button("No Encryption") { setKey(Data()) }
                }
                .controlSize(.small)
                .disabled(channel.role == .disabled)

                Text(encryptionAdvice)
                    .font(.caption)
                    .foregroundStyle(channel.settings.usesDefaultKey ? .orange : .secondary)
            }

            Section("Position Sharing") {
                Picker("Precision", selection: precisionBinding) {
                    Text("Do not share position").tag(UInt32(0))
                    Text("Within about 23 km").tag(UInt32(10))
                    Text("Within about 12 km").tag(UInt32(11))
                    Text("Within about 6 km").tag(UInt32(12))
                    Text("Within about 3 km").tag(UInt32(13))
                    Text("Within about 1.5 km").tag(UInt32(14))
                    Text("Within about 700 m").tag(UInt32(15))
                    Text("Within about 350 m").tag(UInt32(16))
                    Text("Within about 200 m").tag(UInt32(17))
                    Text("Precise location").tag(UInt32(32))
                }
                Text("Lower precision fuzzes your coordinates before they leave the radio, so a public channel does not reveal exactly where you are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(channel.role == .disabled)

            Section("MQTT") {
                Toggle("Send this channel's traffic to MQTT", isOn: uplinkBinding)
                Toggle("Accept traffic from MQTT on this channel", isOn: downlinkBinding)
                Toggle("Mute notifications for this channel", isOn: mutedBinding)
            }
            .disabled(channel.role == .disabled)
        }
        .formStyle(.grouped)
        .navigationTitle(channel.settings.displayName(preset: session.loraConfig.modemPreset,
                                                      isPrimary: channel.role == .primary))
        .onAppear { keyText = channel.settings.psk.base64EncodedString() }
        .onChange(of: index) { _, _ in keyText = channel.settings.psk.base64EncodedString() }
    }

    private var encryptionAdvice: String {
        if channel.settings.psk.isEmpty {
            return "This channel is unencrypted. Anyone in range can read the traffic."
        }
        if channel.settings.usesDefaultKey {
            return "This is the well-known default key. Traffic is obfuscated but not private — anyone running Meshtastic can read it."
        }
        return "Everyone who should hear this channel needs exactly this key. Share it with the QR code rather than typing it out."
    }

    private func setKey(_ data: Data) {
        keyText = data.base64EncodedString()
        applyKey()
    }

    private func applyKey() {
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            channel.settings.psk = Data()
            keyError = nil
            return
        }
        guard let data = Data(base64Encoded: trimmed) else {
            keyError = "That is not valid base64."
            return
        }
        guard [0, 1, 16, 32].contains(data.count) else {
            keyError = "A key must be 1, 16, or 32 bytes. This one is \(data.count)."
            return
        }
        keyError = nil
        channel.settings.psk = data
    }

    // Bindings that keep the nested protobuf writes in one place.
    private var roleBinding: Binding<Channel.Role> {
        Binding { channel.role } set: { channel.role = $0 }
    }
    private var nameBinding: Binding<String> {
        Binding { channel.settings.name } set: { channel.settings.name = $0 }
    }
    private var precisionBinding: Binding<UInt32> {
        Binding { channel.settings.moduleSettings.positionPrecision }
        set: { channel.settings.moduleSettings.positionPrecision = $0 }
    }
    private var uplinkBinding: Binding<Bool> {
        Binding { channel.settings.uplinkEnabled } set: { channel.settings.uplinkEnabled = $0 }
    }
    private var downlinkBinding: Binding<Bool> {
        Binding { channel.settings.downlinkEnabled } set: { channel.settings.downlinkEnabled = $0 }
    }
    private var mutedBinding: Binding<Bool> {
        Binding { channel.settings.moduleSettings.isMuted } set: { channel.settings.moduleSettings.isMuted = $0 }
    }
}

// MARK: - Sharing

private struct ChannelShareSheet: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var includeAll = true
    @State private var url: URL?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Share Channels").font(.title3.weight(.semibold))
            Text("Anyone who scans this code joins the same mesh. It contains your channel keys, so only share it with people you want on your network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Picker("", selection: $includeAll) {
                Text("Primary channel only").tag(false)
                Text("All channels").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 40)

            if let url, let image = QRCode.image(for: url.absoluteString, size: 260) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            if let url {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal)

                HStack {
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Save QR Code…", systemImage: "square.and.arrow.down") { saveImage(url) }
                }
            }

            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .task(id: includeAll) { rebuild() }
    }

    private func rebuild() {
        do {
            url = try session.channelShareURL(includeAllChannels: includeAll)
            errorText = nil
        } catch {
            url = nil
            errorText = error.localizedDescription
        }
    }

    private func saveImage(_ url: URL) {
        guard let image = QRCode.image(for: url.absoluteString, size: 1024) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Meshtastic Channels.png"
        guard panel.runModal() == .OK, let target = panel.url,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: target)
    }
}

private struct ChannelImportSheet: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var applyLoRa = true
    @State private var preview: String?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Channels").font(.title3.weight(.semibold))
            Text("Paste a meshtastic.org/e/# link. This replaces the channels on your radio unless the link says to add.")
                .font(.callout).foregroundStyle(.secondary)

            TextField("https://meshtastic.org/e/#…", text: $link, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .font(.system(.body, design: .monospaced))
                .onChange(of: link) { _, _ in validate() }

            Toggle("Also apply the LoRa settings from the link", isOn: $applyLoRa)

            if let preview {
                Label(preview, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }

            Spacer()
            HStack {
                Button("Paste from Clipboard") {
                    link = NSPasteboard.general.string(forType: .string) ?? ""
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task {
                        await session.importChannels(from: link, applyLoRaConfig: applyLoRa)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil)
            }
        }
        .padding(20)
    }

    private func validate() {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else {
            preview = nil
            errorText = nil
            return
        }
        do {
            let result = try ChannelSharing.parse(link)
            let names = result.channelSet.settings.map { $0.name.isEmpty ? "Primary" : $0.name }
            preview = "\(names.count) channel\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))"
            errorText = nil
        } catch {
            preview = nil
            errorText = error.localizedDescription
        }
    }
}

enum QRCode {
    /// Renders a QR code at a usable pixel size; the generator's native output
    /// is tiny, so scale it up with no interpolation.
    static func image(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
