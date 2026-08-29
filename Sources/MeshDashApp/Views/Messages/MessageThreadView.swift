import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// One conversation: the message list, the composer, and the tapback UI.
struct MessageThreadView: View {
    @Environment(MeshSession.self) private var session
    let conversation: ConversationKey

    @State private var draft = ""
    @State private var replyTarget: MeshMessage?
    @State private var isSending = false
    @State private var isShowingCannedMessages = false

    private var messages: [MeshMessage] { session.thread(for: conversation) }

    private var title: String {
        switch conversation {
        case .channel(let index): session.channelName(index)
        case .direct(let num): session.name(of: num)
        }
    }

    private var subtitle: String {
        switch conversation {
        case .channel(let index):
            let count = messages.count
            return "Channel \(index) · \(count) message\(count == 1 ? "" : "s")"
        case .direct(let num):
            guard let node = session.node(num) else { return "Direct message" }
            var parts = [node.hexID]
            if node.hasPublicKey { parts.append("End-to-end encrypted") }
            if let hops = node.hopsAway { parts.append(hops == 0 ? "Direct radio contact" : "\(hops) hop\(hops == 1 ? "" : "s") away") }
            return parts.joined(separator: " · ")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task(id: conversation) {
            await session.markRead(conversation)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        if shouldShowDateSeparator(message, after: previous) {
                            DateSeparator(date: message.timestamp)
                        }
                        MessageBubble(message: message,
                                      showsSender: showsSender(message, after: previous),
                                      onReply: { replyTarget = message },
                                      onReact: { emoji in
                                          Task { await session.sendReaction(emoji, to: message.id, in: conversation) }
                                      })
                        .id(message.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay {
                if messages.isEmpty {
                    EmptyStateView(title: "No Messages Yet",
                                   message: "Anything you send goes out over the air to everyone who shares this channel.",
                                   symbol: "bubble.left")
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyTarget {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(session.name(of: replyTarget.fromNode))")
                            .font(.caption.weight(.medium))
                        Text(replyTarget.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyTarget = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4))
            }

            HStack(alignment: .bottom, spacing: 8) {
                if let canned = session.cannedMessages, !canned.isEmpty {
                    Menu {
                        ForEach(canned.split(separator: "|").map(String.init), id: \.self) { option in
                            Button(option) { draft = option }
                        }
                    } label: {
                        Image(systemName: "text.bubble")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    .help("Insert a canned message")
                }

                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit(send)

                Text("\(remainingBytes)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(remainingBytes < 30 ? .orange : .secondary)
                    .help("Bytes remaining in this message. Meshtastic packets hold about 200 bytes of text.")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(12)
        }
    }

    private var remainingBytes: Int { session.maximumMessageBytes - draft.utf8.count }
    private var canSend: Bool {
        session.isConnected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remainingBytes >= 0 && !isSending
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let reply = replyTarget?.id
        isSending = true
        draft = ""
        replyTarget = nil
        Task {
            let ok = await session.sendMessage(text, to: conversation, replyTo: reply)
            isSending = false
            if !ok { draft = text }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if case .direct(let num) = conversation {
                if session.supportsTraceroute {
                    Button {
                        Task { await session.traceroute(to: num) }
                    } label: {
                        Label("Trace Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .disabled(!session.isConnected)
                    .help("Find the path packets take to this node")
                }

                if !session.isMeshpointBackend {
                    Button {
                        Task { await session.requestPosition(from: num) }
                    } label: {
                        Label("Request Position", systemImage: "location")
                    }
                    .disabled(!session.isConnected)
                }
            }

            Menu {
                Button("Mark All as Read", systemImage: "envelope.open") {
                    Task { await session.markRead(conversation) }
                }
                Button("Delete Conversation", systemImage: "trash", role: .destructive) {
                    Task { await session.deleteConversation(conversation) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Grouping helpers

    private func shouldShowDateSeparator(_ message: MeshMessage, after previous: MeshMessage?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(message.timestamp, inSameDayAs: previous.timestamp)
    }

    /// Consecutive messages from the same node within a few minutes are grouped.
    private func showsSender(_ message: MeshMessage, after previous: MeshMessage?) -> Bool {
        guard let previous else { return true }
        if previous.fromNode != message.fromNode { return true }
        return message.timestamp.timeIntervalSince(previous.timestamp) > 300
    }
}

private struct DateSeparator: View {
    let date: Date

    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).month().day()))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}
