import SwiftUI

/// Per-row state from the conversation (the website's message row flags).
struct MessageRowOptions {
    var isGroup = false
    var restricted = false
    var canPin = false
    var pinned = false
    var selecting = false
    var selected = false
    var highlighted = false
    var roleTag: String? = nil
}

/// The extra long-press actions (MessageContextMenu.tsx).
struct MessageRowActions {
    var copyLink: () -> Void = {}
    var select: () -> Void = {}
    var toggleSelect: () -> Void = {}
    var pin: (Bool) -> Void = { _ in }
    var report: () -> Void = {}
    var moreReactions: () -> Void = {}
    var comments: () -> Void = {}
    /// Save As... (photos and videos to Photos, documents to Files / share); nil when the message has no attachment.
    var save: (() -> Void)?
}

/// Wraps any message bubble with what all of them share: sender + role tag (groups), "Forwarded", the quoted
/// message, reactions, views / comments (group posts), selection, and the website's long-press menu:
/// quick reactions, Reply, Copy Text, Copy Message Link, Forward, Pin (group admins), Report, Delete, Select.
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
    var options = MessageRowOptions()
    var actions = MessageRowActions()
    @ViewBuilder let content: () -> Content

    static var quickEmoji: [String] { ["❤️", "🔥", "👏", "👍", "😂", "😮", "😡"] }

    static func expiry(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return String(format: NSLocalizedString("chat.disappears", comment: ""), f.string(from: Date(timeIntervalSince1970: Double(unix))))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if options.selecting {
                Image(systemName: options.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(options.selected ? Theme.accent : Theme.faint)
                    .accessibilityLabel(Text(LocalizedStringKey(options.selected ? "select.deselect" : "select.select")))
            }
            column
        }
        .contentShape(Rectangle())
        .onTapGesture { if options.selecting { actions.toggleSelect() } }
        .background(options.highlighted ? Theme.gold.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var column: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let senderName, !senderName.isEmpty {
                HStack(spacing: 5) {
                    Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    if let r = options.roleTag {
                        Text(LocalizedStringKey("group.role." + r)).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.gold)
                            .padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(Theme.gold.opacity(0.6), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 10)
            }
            if message.forwarded == true && !message.isDeleted {
                Label("chat.forwarded", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.caption2).foregroundStyle(Theme.faint).padding(.horizontal, 8)
            }
            if let snippet = message.reply_snippet, !snippet.isEmpty, !message.isDeleted {
                HStack(spacing: 6) {
                    Capsule().fill(Theme.accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.reply_sender_id == myID ? NSLocalizedString("chat.you", comment: "") : peerName)
                            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(snippet).font(.caption).foregroundStyle(Theme.faint).lineLimit(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 260, alignment: mine ? .trailing : .leading)
            }
            content()
                .contextMenu { if !message.isDeleted && message.kind != "notice" && message.kind != "call" && !options.selecting { menu } }
                .allowsHitTesting(!options.selecting)
            HStack(spacing: 10) {
                if let exp = message.expires_at, exp > 0 {
                    Label(Self.expiry(exp), systemImage: "timer").font(.caption2).foregroundStyle(Theme.faint)
                }
                if options.isGroup, let v = message.views, v > 0 {
                    Label("\(v)", systemImage: "eye").font(.caption2).foregroundStyle(Theme.faint)
                }
                if options.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            if options.isGroup, let c = message.comments {
                Button(action: actions.comments) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text(c.count == 0 ? NSLocalizedString("comments.leave", comment: "") : String(format: NSLocalizedString("comments.n", comment: ""), c.count))
                        Spacer()
                        Image(systemName: "chevron.forward")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).frame(maxWidth: 280, minHeight: 36)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            let reactions = message.reactionList(me: myID)
            if !reactions.isEmpty && message.kind != "poll" {
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
                .offset(y: -4)
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
        Button { actions.moreReactions() } label: { Label("chat.more.reactions", systemImage: "face.smiling") }
        Button { onReply() } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
        if message.kind == "text" && !options.restricted {
            Button { onCopy() } label: { Label("chat.copy.text", systemImage: "doc.on.doc") }
        }
        Button { actions.copyLink() } label: { Label("chat.copy.link", systemImage: "link") }
        if let save = actions.save, !options.restricted, !message.isDeleted {
            Button { save() } label: { Label("chat.save.as", systemImage: "square.and.arrow.down") }
        }
        if !options.restricted {
            Button { onForward() } label: { Label("chat.forward", systemImage: "arrowshape.turn.up.right") }
        }
        if options.canPin {
            Button { actions.pin(!options.pinned) } label: {
                Label(LocalizedStringKey(options.pinned ? "chat.unpin" : "chat.pin"), systemImage: options.pinned ? "pin.slash" : "pin")
            }
        }
        if options.isGroup && !mine {
            Button { actions.report() } label: { Label("chat.report", systemImage: "exclamationmark.bubble") }
        }
        Button { actions.select() } label: { Label("chat.select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { onDelete(false) } label: { Label("chat.delete", systemImage: "trash") }
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
