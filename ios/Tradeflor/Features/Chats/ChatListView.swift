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
    @State private var folders: [ChatFolder] = []
    @State private var filter = "all" // all | unread | <folder id>

    /// Live events refresh the list at once; this slow poll only covers a socket that is down.
    private let refreshEvery: UInt64 = 30
    private var token: String { store.session?.token ?? "" }

    private var shown: [ConversationSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base: [ConversationSummary]
        switch filter {
        case "all": base = chats
        case "unread": base = chats.filter { $0.unread_count > 0 }
        default:
            if let f = folders.first(where: { $0.id == filter }) {
                base = chats.filter { f.contains(id: $0.conversation_id, title: $0.title, unread: $0.unread_count > 0) }
            } else { base = chats }
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
            SquareIconButton(systemName: "qrcode.viewfinder") { showNew = true }
                .accessibilityLabel(Text("new.title"))
            SquareIconButton(systemName: "person.badge.plus") { showNew = true }
                .accessibilityLabel(Text("new.title"))
                .accessibilityIdentifier("chats.new")
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
                ForEach(shown) { c in
                    NavigationLink(value: c) {
                        ChatRow(chat: c, token: token, online: live.online.contains(c.peer_id))
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityIdentifier("chats.list")
        }
    }

    private func load(quiet: Bool = false) async {
        guard !token.isEmpty else { return }
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
                    if chat.unread_count > 0 {
                        Text("\(chat.unread_count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 22)
                            .background(Theme.accent, in: Capsule())
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
