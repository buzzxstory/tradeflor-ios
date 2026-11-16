import SwiftUI

/// Wraps any message bubble with what all of them share: "Forwarded", the quoted message it replies to, the
/// reactions under it, and the long-press menu (react, reply, copy, forward, delete).
struct MessageRow<Content: View>: View {
    let message: Message
    let mine: Bool
    let myID: String
    let peerName: String
    let senderName: String?
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onCopy: () -> Void
    let onForward: () -> Void
    let onDelete: (_ everyone: Bool) -> Void
    @ViewBuilder let content: () -> Content

    static var quickEmoji: [String] { ["👍", "❤️", "😂", "😮", "😢", "🙏"] }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let senderName, !senderName.isEmpty {
                Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 10)
            }
            if message.forwarded == true && !message.isDeleted {
                Label("chat.forwarded", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if let snippet = message.reply_snippet, !snippet.isEmpty, !message.isDeleted {
                HStack(spacing: 6) {
                    Capsule().fill(Theme.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.reply_sender_id == myID ? NSLocalizedString("chat.you", comment: "") : peerName)
                            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 260, alignment: mine ? .trailing : .leading)
            }
            content()
                .contextMenu { if !message.isDeleted { menu } }
            let reactions = message.reactionList(me: myID)
            if !reactions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(reactions, id: \.emoji) { r in
                        Button { onReact(r.emoji) } label: {
                            Text(r.count > 1 ? "\(r.emoji) \(r.count)" : r.emoji)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(r.mine ? Theme.accent.opacity(0.35) : Theme.surface, in: Capsule())
                                .overlay(Capsule().stroke(Theme.ground, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .offset(y: -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    @ViewBuilder private var menu: some View {
        ControlGroup {
            ForEach(Self.quickEmoji, id: \.self) { e in
                Button(e) { onReact(e) }
            }
        }
        Button { onReply() } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
        if message.kind == "text" {
            Button { onCopy() } label: { Label("chat.copy", systemImage: "doc.on.doc") }
        }
        Button { onForward() } label: { Label("chat.forward", systemImage: "arrowshape.turn.up.right") }
        Divider()
        Button(role: .destructive) { onDelete(false) } label: { Label("chat.delete.me", systemImage: "trash") }
        if mine {
            Button(role: .destructive) { onDelete(true) } label: { Label("chat.delete.everyone", systemImage: "trash.fill") }
        }
    }
}

/// Pick a chat to forward a message to.
struct ForwardSheet: View {
    let token: String
    let message: Message
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [ConversationSummary] = []
    @State private var sending: String?
    @State private var sent: Set<String> = []

    var body: some View {
        NavigationStack {
            List(chats) { c in
                Button {
                    Task { await forward(to: c) }
                } label: {
                    HStack(spacing: 12) {
                        Avatar(token: token, userID: c.peer_id, avatarID: c.peer_avatar_id, title: c.title)
                        Text(c.title).foregroundStyle(.white)
                        Spacer()
                        if sending == c.conversation_id { ProgressView() }
                        if sent.contains(c.conversation_id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .disabled(sending != nil || sent.contains(c.conversation_id))
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("chat.forward"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("chat.done") { dismiss(); onDone() }
                }
            }
        }
        .task { chats = (try? await APIClient.shared.conversations(token: token)) ?? [] }
    }

    private func forward(to c: ConversationSummary) async {
        sending = c.conversation_id
        defer { sending = nil }
        if (try? await APIClient.shared.forward(token: token, messageID: message.id, to: c.conversation_id,
                                                key: UUID().uuidString.lowercased())) != nil {
            sent.insert(c.conversation_id)
        }
    }
}
