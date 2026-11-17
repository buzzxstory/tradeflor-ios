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
    /// The owner speaks as the group (website GroupsView): the group's name with a megaphone mark, no Owner pill.
    var asGroup = false
    /// Group messages from others: the sender's picture beside the first message of a run (blank space for the rest).
    var senderAvatar: AnyView? = nil
    var avatarSlot = false
    /// A member whose name looks like another member's: their real @username beside it.
    var handle: String? = nil
    /// The quoted message's sender as shown (a group member's name), and its photo for the small picture on the right.
    var replySenderName: String? = nil
    var replyPhotoID: String? = nil
    var token = ""
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
    /// Tapping the sender's picture or name opens their profile.
    var openSender: (() -> Void)?
    /// Tapping the quoted message goes to the original.
    var openReply: (() -> Void)?
    /// Edit (my own text message, within 15 minutes); nil when it can't be edited.
    var edit: (() -> Void)?
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
            if options.avatarSlot && !mine {
                Group {
                    if let a = options.senderAvatar {
                        a.onTapGesture { if !options.selecting { actions.openSender?() } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Text(String(format: NSLocalizedString("member.open", comment: ""), senderName ?? "")))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 34, height: 34)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            column
        }
        .contentShape(Rectangle())
        .onTapGesture { if options.selecting { actions.toggleSelect() } }
        .modifier(SwipeToReply(enabled: !options.selecting && !message.isDeleted && message.kind != "notice" && message.kind != "call", onReply: onReply))
        .background(options.highlighted ? Theme.gold.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var column: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if !inside, let line = senderLine { line.padding(.horizontal, 10) }
            if message.forwarded == true && !message.isDeleted {
                Label("chat.forwarded", systemImage: "arrowshape.turn.up.right.fill")
                    .font(.caption2).foregroundStyle(Theme.faint).padding(.horizontal, 8)
            }
            if !inside, let q = quote {
                q.frame(maxWidth: 260, alignment: mine ? .trailing : .leading)
            }
            content()
                .environment(\.tfBubbleHead, inside ? head : nil)
                .environment(\.tfMediaForward, isMedia && !options.restricted && !options.selecting ? onForward : nil)
                .contextMenu { if !message.isDeleted && message.kind != "notice" && message.kind != "call" && !options.selecting { menu } }
                .allowsHitTesting(!options.selecting)
                .padding(.bottom, isMedia && hasReactions ? 12 : 0)
            HStack(spacing: 10) {
                if let exp = message.expires_at, exp > 0 {
                    Image(systemName: "timer").font(.system(size: 9)).foregroundStyle(Theme.faint)
                        .accessibilityLabel(Text(Self.expiry(exp)))
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
                                // on a photo or video: a solid chip ringed in the chat colour, half below the picture (ac48799)
                                .background(isMedia ? Theme.hex(r.mine ? 0x0F3A45 : 0x0D2A35) : (r.mine ? Theme.accent.opacity(0.35) : Theme.surface), in: Capsule())
                                .overlay(Capsule().stroke(isMedia ? Theme.soul : Theme.ground, lineWidth: isMedia ? 2 : 1.5))
                                .shadow(color: .black.opacity(isMedia ? 0.3 : 0), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, isMedia ? 6 : 8)
                .offset(y: isMedia ? -26 : -4)
                .padding(.bottom, isMedia ? -16 : 0)
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private var hasReactions: Bool { !message.reactionList(me: myID).isEmpty && message.kind != "poll" }

    /// A photo or a video on its own (no card): reactions hang over its edge, a forward arrow sits beside it.
    private var isMedia: Bool {
        guard !message.isDeleted, message.file_id != nil else { return false }
        if message.kind == "image" { return true }
        return message.kind == "file" && (message.file_mime ?? "").hasPrefix("video/")
    }

    /// A text message carries the sender line and the quote inside its card (website fda47e1 / 5b6f8e1).
    private var inside: Bool { message.kind == "text" && !message.isDeleted }

    private var senderLine: AnyView? {
        guard let senderName, !senderName.isEmpty else { return nil }
        return AnyView(HStack(spacing: 5) {
            if options.asGroup {
                Image(systemName: "megaphone.fill").font(.system(size: 11)).foregroundStyle(Theme.gold)
                    .accessibilityLabel(Text("group.voice"))
            }
            Text(senderName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .foregroundStyle(options.asGroup ? Theme.gold : NameColour.of(message.sender_id))
                .onTapGesture { if !options.selecting && !options.asGroup { actions.openSender?() } }
            if let h = options.handle { Text("@" + h).font(.caption2).foregroundStyle(Theme.faint) }
            if let r = options.roleTag, !options.asGroup {
                // in the card, as on the web: lowercase, 11 pt, medium, lavender (#c3b2ff)
                Text(NSLocalizedString("group.role." + r, comment: "").lowercased())
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.hex(0xC3B2FF))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Theme.hex(0xC3B2FF, 0.45), lineWidth: 1))
            }
        })
    }

    private var quote: AnyView? {
        guard let snippet = message.reply_snippet, !snippet.isEmpty, !message.isDeleted else { return nil }
        let fromMe = message.reply_sender_id == myID
        let who = fromMe ? NSLocalizedString("chat.you", comment: "") : (options.replySenderName ?? peerName)
        let tint = fromMe ? Theme.accent : (options.isGroup ? NameColour.of(message.reply_sender_id ?? "") : Theme.accent)
        let photo = options.replyPhotoID
        var text = snippet
        for p in ["🖼 ", "📷 ", "🖼", "📷"] where text.hasPrefix(p) { text = String(text.dropFirst(p.count)) }
        return AnyView(HStack(spacing: 6) {
            Capsule().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(who).font(.caption2.weight(.semibold)).foregroundStyle(tint)
                if photo != nil {
                    Label(text.isEmpty ? NSLocalizedString("chats.kind.image", comment: "") : text, systemImage: "camera.fill")
                        .font(.caption).foregroundStyle(Theme.faint).lineLimit(2)
                } else {
                    Text(text).font(.caption).foregroundStyle(Theme.faint).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let photo {
                // a reply to a photo shows the photo, small, on the right (website 1bd3569)
                RemoteImage(token: options.token, fileID: photo).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { if !options.selecting { actions.openReply?() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("chat.reply.goto")))
    }

    /// What goes inside the top of the text bubble.
    private var head: AnyView? {
        let line = senderLine, q = quote
        guard line != nil || q != nil else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            if let line { line }
            if let q { q.frame(minWidth: 140, alignment: .leading) }
        })
    }

    @ViewBuilder private var menu: some View {
        ControlGroup {
            ForEach(Self.quickEmoji, id: \.self) { e in
                Button(e) { onReact(e) }
            }
        }
        .tfReactionRow()
        Button { actions.moreReactions() } label: { Label("chat.more.reactions", systemImage: "face.smiling") }
        Button { onReply() } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
        if message.kind == "text" && !options.restricted {
            Button { onCopy() } label: { Label("chat.copy.text", systemImage: "doc.on.doc") }
        }
        if let edit = actions.edit {
            Button { edit() } label: { Label("chat.edit", systemImage: "pencil") }
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
                        Text(c.title).foregroundStyle(Theme.text)
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
