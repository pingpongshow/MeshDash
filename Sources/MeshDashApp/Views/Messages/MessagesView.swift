import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

struct MessagesView: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session

    @State private var isShowingNewDirectMessage = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            ConversationList(isShowingNewDirectMessage: $isShowingNewDirectMessage)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            if let conversation = model.selectedConversation {
                MessageThreadView(conversation: conversation)
                    .id(conversation)
            } else {
                EmptyStateView(title: "No Conversation Selected",
                               message: session.isConnected
                                   ? "Pick a channel or a node to start talking."
                                   : "Connect to a radio to see your channels and messages.",
                               symbol: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $isShowingNewDirectMessage) {
            NewDirectMessageSheet { node in
                model.selectedConversation = .direct(node)
            }
            .frame(minWidth: 420, minHeight: 420)
        }
    }
}

private struct ConversationList: View {
    @Environment(AppModel.self) private var model
    @Environment(MeshSession.self) private var session
    @Binding var isShowingNewDirectMessage: Bool
    @State private var search = ""

    private var conversations: [Conversation] {
        let all = session.conversations
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.lastMessage?.text.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedConversation) {
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation.key) {
                    ConversationRow(conversation: conversation)
                }
                .contextMenu {
                    Button("Mark as Read", systemImage: "envelope.open") {
                        Task { await session.markRead(conversation.key) }
                    }
                    if conversation.lastMessage != nil {
                        Button("Delete Conversation", systemImage: "trash", role: .destructive) {
                            Task { await session.deleteConversation(conversation.key) }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search conversations")
        .navigationTitle("Messages")
        .toolbar {
            Button {
                isShowingNewDirectMessage = true
            } label: {
                Label("New Direct Message", systemImage: "square.and.pencil")
            }
            .disabled(!session.isConnected)
            .help("Start a direct message with a node")
        }
        .overlay {
            if conversations.isEmpty {
                EmptyStateView(title: search.isEmpty ? "No Conversations" : "No Matches",
                               message: search.isEmpty
                                   ? "Channels appear here once the radio sends its configuration."
                                   : "Nothing matches “\(search)”.",
                               symbol: "bubble.left")
            }
        }
    }
}

private struct ConversationRow: View {
    @Environment(MeshSession.self) private var session
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.title).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let time = conversation.lastMessage?.timestamp {
                        Text(Format.relative(time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let last = conversation.lastMessage {
                    let prefix = last.fromNode == session.myNodeNum ? "You: " : ""
                    Text(prefix + last.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(conversation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint, in: Capsule())
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var icon: some View {
        if let node = conversation.node {
            NodeAvatar(node: node, size: 32)
        } else {
            ZStack {
                Circle().fill(.tint.opacity(0.18))
                Image(systemName: "number")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 32, height: 32)
        }
    }
}

/// Picker for starting a direct conversation.
private struct NewDirectMessageSheet: View {
    @Environment(MeshSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let select: (UInt32) -> Void

    private var candidates: [MeshNode] {
        let all = session.messagableNodes
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.longName.localizedCaseInsensitiveContains(search)
                || $0.shortName.localizedCaseInsensitiveContains(search)
                || $0.hexID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Direct Message")
                .font(.headline)
                .padding(.top, 16)
            TextField("Search nodes", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(16)

            List(candidates) { node in
                Button {
                    select(node.num)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        NodeAvatar(node: node, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.longName).lineLimit(1)
                            Text(node.hexID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if node.hasPublicKey {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .help("End-to-end encrypted with this node's public key")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    EmptyStateView(title: "No Nodes",
                                   message: "Nodes appear here once the radio has heard from them.",
                                   symbol: "person.slash")
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }
}
