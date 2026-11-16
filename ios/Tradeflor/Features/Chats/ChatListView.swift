import SwiftUI
import UIKit

/// The Chats screen, laid out like the website's phone view: "Chats" with the scan / add-contact buttons, the search
/// pill, the status row (My status, TRADEFLOR Official, contacts), the filter chips and the conversation rows.
struct ChatListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var chats: [ConversationSummary] = []
    @State private var loading = true
    @State private var failed = false
    @State private var query = ""
    @State private var path: [ConversationSummary] = []
    @State private var ciOpened = false
    @State private var showNew = false
    @State private var showFlash = false
    @State private var showContacts = false
    @State private var folders: [ChatFolder] = []
    @State private var filter = "all" // all | unread | <folder id>
    @State private var prefs: [String: ConversationPrefs] = [:]
    @State private var showArchived = false

    /// Live events refresh the list at once; this slow poll only covers a socket that is down.
    private let refreshEvery: UInt64 = 30
    private var token: String { store.session?.token ?? "" }

    private var shown: [ConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let visible = chats.filter { showArchived == (prefs[$0.conversation_id]?.archived ?? false) }
        var base: [ConversationSummary]
        switch filter {
        case "all": base = visible
        case "unread": base = visible.filter { isUnread($0) }
        default:
            if let f = folders.first(where: { $0.id == filter }) {
                base = visible.filter { f.contains(id: $0.conversation_id, title: $0.title, unread: isUnread($0)) }
            } else { base = visible }
        }
        // pinned first (newest pin on top), then by the last message
        base.sort { a, b in
            let pa = prefs[a.conversation_id]?.pinned_at ?? 0, pb = prefs[b.conversation_id]?.pinned_at ?? 0
            if (pa > 0) != (pb > 0) { return pa > 0 }
            if pa > 0 && pa != pb { return pa > pb }
            return a.last_message_at > b.last_message_at
        }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.peer_username.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    SearchPill(placeholder: "chats.search", text: $query)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    StatusStrip()
                        .padding(.top, 12)
                    chipsRow
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    list
                }
            }
            .refreshable { await load() }
            .background(Theme.panelGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ConversationSummary.self) { c in ChatView(chat: c) }
            .sheet(isPresented: $showNew) {
                NewChatView { c in
                    Task {
                        await load(quiet: true)
                        path = [c]
                    }
                }
            }
        }
        .onReceive(live.messages) { _ in Task { await load(quiet: true) } }
        .onReceive(live.changes) { _ in Task { await load(quiet: true) } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await load()
            folders = (try? await APIClient.shared.folders(token: token)) ?? folders
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshEvery * 1_000_000_000)
                if Task.isCancelled { break }
                await load(quiet: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("chats.title").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            SquareIconButton(systemName: "qrcode.viewfinder") { showFlash = true }
                .accessibilityLabel(Text("fc.title"))
                .sheet(isPresented: $showFlash) {
                    FlashConnectView { c in
                        Task {
                            await load(quiet: true)
                            path = [c]
                        }
                    }
                }
            SquareIconButton(systemName: "person.badge.plus") { showContacts = true }
                .accessibilityLabel(Text("ct.title"))
                .accessibilityIdentifier("chats.new")
                .sheet(isPresented: $showContacts) {
                    ContactsPanel { c in
                        Task {
                            await load(quiet: true)
                            path = [c]
                        }
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// All chats / Unread / my Smart Folders (made on the website; the same rules decide what is in them).
    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                FilterChip(title: NSLocalizedString("folders.all", comment: ""), selected: filter == "all") { filter = "all" }
                FilterChip(title: NSLocalizedString("folders.unread", comment: ""), selected: filter == "unread") { filter = "unread" }
                ForEach(folders) { f in
                    FilterChip(title: f.name, icon: "folder", selected: filter == f.id) { filter = f.id }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var list: some View {
        if loading && chats.isEmpty {
            ProgressView().tint(Theme.accent).padding(.top, 60)
        } else if failed && chats.isEmpty {
            VStack(spacing: 12) {
                Text("chats.error").foregroundStyle(Theme.faint)
                Button("chats.retry") { Task { await load() } }.foregroundStyle(Theme.accent)
            }
            .padding(.top, 60)
        } else if shown.isEmpty {
            Text("chats.empty").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                if !showArchived && archivedCount > 0 {
                    Button { showArchived = true } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "archivebox").font(.system(size: 20)).foregroundStyle(Theme.accent)
                                .frame(width: 54, height: 40)
                            Text("chats.archived").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(archivedCount)").font(.system(size: 13)).foregroundStyle(Theme.faint)
                        }
                        .padding(.leading, 15).padding(.trailing, 14).frame(height: 56)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
                if showArchived {
                    Button { showArchived = false } label: {
                        HStack {
                            Image(systemName: "chevron.backward")
                            Text("chats.archived").font(.system(size: 16, weight: .bold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 16).frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(shown) { c in
                    NavigationLink(value: c) {
                        ChatRow(chat: c, token: token, online: live.online.contains(c.peer_id),
                                pinned: prefs[c.conversation_id]?.pinned ?? false, muted: prefs[c.conversation_id]?.muted ?? false,
                                markedUnread: prefs[c.conversation_id]?.marked_unread ?? false)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(c) }
                }
            }
            .accessibilityIdentifier("chats.list")
        }
    }

    private var archivedCount: Int { chats.filter { prefs[$0.conversation_id]?.archived ?? false }.count }

    private func isUnread(_ c: ConversationSummary) -> Bool { c.unread_count > 0 || (prefs[c.conversation_id]?.marked_unread ?? false) }

    /// Long-press on a chat (the website's row menu): pin, mute, mark as unread, archive.
    @ViewBuilder private func rowMenu(_ c: ConversationSummary) -> some View {
        let p = prefs[c.conversation_id]
        Button { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, pinned: !(p?.pinned ?? false)) } } label: {
            Label(LocalizedStringKey((p?.pinned ?? false) ? "chats.unpin" : "chats.pin"), systemImage: (p?.pinned ?? false) ? "pin.slash" : "pin")
        }
        if p?.muted ?? false {
            Button { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, unmute: true) } } label: {
                Label("chats.unmute", systemImage: "bell")
            }
        } else {
            Menu {
                Button("mute.8h") { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, muteSeconds: 8 * 3600) } }
                Button("mute.1w") { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, muteSeconds: 7 * 86400) } }
                Button("mute.always") { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, muteForever: true) } }
            } label: { Label("chats.mute", systemImage: "bell.slash") }
        }
        Button { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, markedUnread: !isUnread(c)) } } label: {
            Label(LocalizedStringKey(isUnread(c) ? "chats.markread" : "chats.markunread"), systemImage: isUnread(c) ? "envelope.open" : "envelope.badge")
        }
        Button { change(c) { try await APIClient.shared.setPrefs(token: token, conversationID: c.conversation_id, archived: !(p?.archived ?? false)) } } label: {
            Label(LocalizedStringKey((p?.archived ?? false) ? "chats.unarchive" : "chats.archive"), systemImage: "archivebox")
        }
    }

    private func change(_ c: ConversationSummary, _ work: @escaping () async throws -> Void) {
        Task {
            try? await work()
            await loadPrefs()
        }
    }

    private func loadPrefs() async {
        if let list = try? await APIClient.shared.prefs(token: token) {
            prefs = Dictionary(list.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func load(quiet: Bool = false) async {
        guard !token.isEmpty else { return }
        await loadPrefs()
        if !quiet { loading = true }
        defer { loading = false }
        do {
            let out = try await APIClient.shared.conversations(token: token)
            let sorted = out.sorted { $0.last_message_at > $1.last_message_at }
            if sorted != chats { chats = sorted }
            failed = false
            ciOpenFirstChat()
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {
            if !quiet { failed = true }
        }
    }
}

extension ChatListView {
    /// CI only (Debug): TF_CI_OPEN_CHAT=1 opens the newest chat once, so the workflow can screenshot the chat screen.
    fileprivate func ciOpenFirstChat() {
        #if DEBUG
        guard !ciOpened, ProcessInfo.processInfo.environment["TF_CI_OPEN_CHAT"] == "1", let first = chats.first else { return }
        ciOpened = true
        path = [first]
        #endif
    }
}

/// One conversation row (website .conv-row): 54 pt avatar, name 17 semibold, time on the right, a preview line with
/// the same small icons (call, video, file, ticks) and the unread count.
struct ChatRow: View {
    let chat: ConversationSummary
    let token: String
    var online = false
    var pinned = false
    var muted = false
    var markedUnread = false

    var body: some View {
        HStack(spacing: 16) {
            Avatar(token: token, userID: chat.peer_id, avatarID: chat.peer_avatar_id, title: chat.title, online: online)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if let d = chat.lastDate {
                        Text(Self.timeLabel(d)).font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(chat.unread_count > 0 ? Theme.accent : Theme.faint)
                    }
                }
                HStack(spacing: 5) {
                    if chat.last_message_mine && chat.last_message_kind != "call" {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                    }
                    if let icon = previewIcon {
                        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    Text(preview).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 6)
                    if muted { Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    if chat.unread_count > 0 {
                        Text("\(chat.unread_count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(muted ? AnyShapeStyle(Theme.faint) : AnyShapeStyle(Theme.accent), in: Capsule())
                    } else if markedUnread {
                        Circle().fill(Theme.accent).frame(width: 12, height: 12)
                    } else if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).rotationEffect(.degrees(45))
                    }
                }
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 14)
        .frame(height: 83)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
        .contentShape(Rectangle())
    }

    /// "now", "12 min", "4 h", "Yesterday", "16 Nov" -- the website's relative times.
    static func timeLabel(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return NSLocalizedString("time.now", comment: "") }
        if s < 3600 { return String(format: NSLocalizedString("time.min", comment: ""), Int(s / 60)) }
        if Calendar.current.isDateInToday(d) { return String(format: NSLocalizedString("time.h", comment: ""), Int(s / 3600)) }
        if Calendar.current.isDateInYesterday(d) { return NSLocalizedString("time.yesterday", comment: "") }
        return dayFormatter.string(from: d)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private var previewIcon: String? {
        switch chat.last_message_kind {
        case "call": return "phone"
        case "voice": return "mic"
        case "image": return "photo"
        case "location": return "location"
        case "file":
            switch chat.last_file_type {
            case "video_note", "video": return "video"
            default: return "doc"
            }
        default: return nil
        }
    }

    private var preview: String {
        switch chat.last_message_kind {
        case "voice": return NSLocalizedString("chats.kind.voice", comment: "")
        case "image": return chat.last_message.isEmpty ? NSLocalizedString("chats.kind.image", comment: "") : chat.last_message
        case "file":
            if chat.last_file_type == "video_note" { return NSLocalizedString("note.video", comment: "") }
            return chat.last_message.isEmpty ? NSLocalizedString("chats.kind.file", comment: "") : chat.last_message
        case "locked": return NSLocalizedString("chats.kind.locked", comment: "")
        case "location": return NSLocalizedString("location.live", comment: "")
        default: return chat.last_message
        }
    }
}

/// Profile picture (website .avatar: radial teal gradient, bold initial), with the online dot when asked.
struct Avatar: View {
    let token: String
    let userID: String
    let avatarID: String?
    let title: String
    var groupID: String? = nil
    var size: CGFloat = 54
    var online: Bool? = nil
    @State private var image: UIImage?

    init(token: String, userID: String, avatarID: String?, title: String, groupID: String? = nil, size: CGFloat = 54, online: Bool? = nil) {
        self.token = token
        self.userID = userID
        self.avatarID = avatarID
        self.title = title
        self.groupID = groupID
        self.size = size
        self.online = online
    }

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatarGradient)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if online == true {
                Circle().fill(Theme.online).frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Circle().stroke(Theme.ground, lineWidth: 2))
            }
        }
        .task(id: avatarID) {
            guard let avatarID, !avatarID.isEmpty, !token.isEmpty else { image = nil; return }
            let data = groupID != nil
                ? await APIClient.shared.groupAvatar(token: token, groupID: groupID ?? "", avatarID: avatarID)
                : await APIClient.shared.avatar(token: token, userID: userID, avatarID: avatarID)
            if let data { image = UIImage(data: data) }
        }
    }
}
