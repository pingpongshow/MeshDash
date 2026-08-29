import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Common tapbacks, matching what the iOS and Android apps offer.
let quickReactions = ["👍", "👎", "❤️", "😂", "‼️", "❓"]

struct MessageBubble: View {
    @Environment(MeshSession.self) private var session
    let message: MeshMessage
    let showsSender: Bool
    let onReply: () -> Void
    let onReact: (String) -> Void

    @State private var isHovering = false

    private var isOutgoing: Bool { message.fromNode == session.myNodeNum }
    private var sender: MeshNode? { session.node(message.fromNode) }
    private var reactions: [MeshMessage] { session.reactions(for: message.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isOutgoing { Spacer(minLength: 60) }

            if !isOutgoing {
                Group {
                    if showsSender, let sender {
                        NodeAvatar(node: sender, size: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                }
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
                if showsSender, !isOutgoing {
                    Text(session.name(of: message.fromNode))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if let replyTo = message.replyTo, let quoted = session.message(replyTo) {
                    QuotedMessage(message: quoted)
                }

                bubble

                if !reactions.isEmpty { reactionRow }

                metadata
            }

            if !isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.vertical, showsSender ? 5 : 1)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    private var bubble: some View {
        Text(message.text)
            .textSelection(.enabled)
            .font(isEmojiOnly ? .system(size: 40) : .body)
            .padding(.horizontal, isEmojiOnly ? 4 : 11)
            .padding(.vertical, isEmojiOnly ? 2 : 7)
            .background {
                if !isEmojiOnly {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(bubbleColor)
                }
            }
            .foregroundStyle(isOutgoing && !isEmojiOnly ? Color.white : Color.primary)
            .overlay(alignment: isOutgoing ? .topLeading : .topTrailing) {
                if isHovering { hoverActions }
            }
    }

    /// A message that is nothing but emoji renders large and unboxed, the way
    /// the phone apps do it.
    private var isEmojiOnly: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.unicodeScalars.allSatisfy { $0.properties.isEmoji && $0.properties.isEmojiPresentation }
    }

    private var bubbleColor: Color {
        if message.portnum == .alertApp { return .orange.opacity(0.25) }
        if message.portnum == .detectionSensorApp { return .purple.opacity(0.22) }
        return isOutgoing ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(quickReactions, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            } label: {
                Image(systemName: "face.smiling")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)

            Button(action: onReply) {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .offset(x: isOutgoing ? -12 : 12, y: -6)
    }

    private var reactionRow: some View {
        // Collapse identical emoji into one chip with a count.
        let grouped = Dictionary(grouping: reactions, by: \.text)
        return HStack(spacing: 4) {
            ForEach(grouped.keys.sorted(), id: \.self) { emoji in
                let senders = grouped[emoji]?.map { session.name(of: $0.fromNode) } ?? []
                HStack(spacing: 2) {
                    Text(emoji).font(.caption)
                    if senders.count > 1 {
                        Text("\(senders.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: Capsule())
                .help(senders.joined(separator: ", "))
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Text(Format.timestamp(message.timestamp))
            if message.isPKIEncrypted {
                Image(systemName: "lock.fill").help("End-to-end encrypted")
            }
            if message.viaMQTT {
                Image(systemName: "network").help("Arrived over MQTT rather than radio")
            }
            if let hops = message.hopsAway {
                Text(hops == 0 ? "direct" : "\(hops) hop\(hops == 1 ? "" : "s")")
            }
            if let snr = message.snr {
                Text(Format.snr(snr))
            }
            if isOutgoing {
                Image(systemName: message.status.symbolName)
                    .foregroundStyle(message.status == .failed ? .red : .secondary)
                    .help(message.failureReason ?? message.status.label)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
        Menu("React", systemImage: "face.smiling") {
            ForEach(quickReactions, id: \.self) { emoji in
                Button(emoji) { onReact(emoji) }
            }
        }
        Button("Copy Text", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        }
        if message.status == .failed {
            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await session.resend(message) }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task { await session.deleteMessage(message.id) }
        }
    }
}

private struct QuotedMessage: View {
    @Environment(MeshSession.self) private var session
    let message: MeshMessage

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name(of: message.fromNode))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
