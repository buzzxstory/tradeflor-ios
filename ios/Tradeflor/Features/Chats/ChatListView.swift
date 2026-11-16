import SwiftUI
import UIKit

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
            VStack(spacing: 0) {
                folderBar
                content
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground.ignoresSafeArea())
                .toolbarBackground(Theme.ground, for: .navigationBar)
                .navigationTitle(Text("chats.title"))
                .searchable(text: $query, prompt: Text("chats.search"))
                .refreshable { await load() }
                .navigationDestination(for: ConversationSummary.self) { c in ChatView(chat: c) }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel(Text("new.title"))
                            .accessibilityIdentifier("chats.new")
                    }
                }
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
            if let t = store.session?.token { folders = (try? await APIClient.shared.folders(token: t)) ?? folders }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshEvery * 1_000_000_000)
                if Task.isCancelled { break }
                await load(quiet: true)
            }
        }
    }

    /// All / Unread / my Smart Folders (made on the website; the same rules decide what is in them).
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("all", NSLocalizedString("folders.all", comment: ""))
                chip("unread", NSLocalizedString("folders.unread", comment: ""))
                ForEach(folders) { f in chip(f.id, f.name) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ id: String, _ title: String) -> some View {
        Button { filter = id } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .foregroundStyle(filter == id ? Theme.onAccent : .white)
                .background(filter == id ? Theme.accent : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if loading && chats.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if failed && chats.isEmpty {
            VStack(spacing: 12) {
                Text("chats.error").foregroundStyle(.secondary)
                Button("chats.retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if chats.isEmpty {
            Text("chats.empty")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(shown) { c in
                NavigationLink(value: c) {
                    ChatRow(chat: c, token: store.session?.token ?? "")
                }
                .listRowBackground(Theme.ground)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowBackground(Theme.ground)
            .accessibilityIdentifier("chats.list")
        }
    }

    private func load(quiet: Bool = false) async {
        guard let token = store.session?.token else { return }
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

private struct ChatRow: View {
    let chat: ConversationSummary
    let token: String

    var body: some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: chat.peer_id, avatarID: chat.peer_avatar_id, title: chat.title)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chat.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let d = chat.lastDate {
                        Text(Self.timeLabel(d))
                            .font(.caption)
                            .foregroundStyle(chat.unread_count > 0 ? Theme.accent : .secondary)
                    }
                }
                HStack {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if chat.unread_count > 0 {
                        Text("\(chat.unread_count)")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    static func timeLabel(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? todayFormatter.string(from: d) : dayFormatter.string(from: d)
    }

    private var preview: String {
        let body: String
        switch chat.last_message_kind {
        case "voice": body = NSLocalizedString("chats.kind.voice", comment: "")
        case "image": body = NSLocalizedString("chats.kind.image", comment: "")
        case "file": body = chat.last_file_type == "video_note" ? "🎥 " + NSLocalizedString("note.video", comment: "")
            : NSLocalizedString("chats.kind.file", comment: "")
        case "locked": body = NSLocalizedString("chats.kind.locked", comment: "")
        case "location": body = "📍 " + NSLocalizedString("location.live", comment: "")
        default: body = chat.last_message
        }
        if chat.last_message_mine && chat.last_message_kind != "call" {
            return NSLocalizedString("chats.you", comment: "") + body
        }
        return body
    }
}

/// Profile picture with the first letter as a placeholder until (or unless) it loads.
struct Avatar: View {
    let token: String
    let userID: String
    let avatarID: String?
    let title: String
    var groupID: String? = nil
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .task(id: avatarID) {
            guard let avatarID, !avatarID.isEmpty, !token.isEmpty else { image = nil; return }
            let data = groupID != nil
                ? await APIClient.shared.groupAvatar(token: token, groupID: groupID ?? "", avatarID: avatarID)
                : await APIClient.shared.avatar(token: token, userID: userID, avatarID: avatarID)
            if let data {
                image = UIImage(data: data)
            }
        }
    }
}
