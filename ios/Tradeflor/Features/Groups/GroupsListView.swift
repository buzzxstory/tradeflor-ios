import SwiftUI
import UIKit

/// The Groups screen as on the website (GroupsView.tsx): "Groups" with the new-group button, "Search groups or @link"
/// (which also finds public groups), the folder chips, Archived, and the group rows with their long-press menu.
struct GroupsListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var groups: [GroupSummary] = []
    @State private var groupStatuses: [String: StatusGroup] = [:]
    @State private var watchGroup: StatusGroup?
    @State private var extras: [String: GrpListExtra] = [:]
    @State private var prefs: [String: ConversationPrefs] = [:]
    @State private var folders: [ChatFolder] = []
    @State private var filter = "all" // all | unread | <folder id>
    @State private var showArchived = false
    @State private var loading = true
    @State private var path: [GroupSummary] = []
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var query = ""
    @State private var discovered: [GrpDiscover] = []
    @State private var joining: GrpDiscover?
    @State private var leaving: GroupSummary?
    @State private var problem: String?
    @State private var showFolderEditor = false
    /// each folder's icon and colour, for the chips (website FolderTabs)
    @State private var folderIcons: [String: String] = [:]
    @State private var folderColors: [String: String] = [:]

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }

    private func isUnread(_ g: GroupSummary) -> Bool { g.unread_count > 0 || (prefs[g.conversation_id]?.marked_unread ?? false) }
    private var archivedCount: Int { groups.filter { prefs[$0.conversation_id]?.archived ?? false }.count }

    private var shown: [GroupSummary] {
        var g = groups.filter { showArchived == (prefs[$0.conversation_id]?.archived ?? false) }
        switch filter {
        case "all": break
        case "unread": g = g.filter { isUnread($0) }
        default:
            if let f = folders.first(where: { $0.id == filter }) {
                g = g.filter { f.contains(id: $0.conversation_id, title: $0.name, unread: isUnread($0)) }
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { g = g.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        g.sort { a, b in
            let pa = prefs[a.conversation_id]?.pinned_at ?? 0, pb = prefs[b.conversation_id]?.pinned_at ?? 0
            if (pa > 0) != (pb > 0) { return pa > 0 }
            if pa > 0 && pa != pb { return pa > pb }
            return a.last_message_at > b.last_message_at
        }
        return g
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // website phone layout (GroupsView.tsx, 27-chats-list.css): big "Groups" + the new-group button, the round
                // search, the folder chips, "Archived (n)", public groups found by the search, then the group rows
                VStack(spacing: 0) {
                    header
                    ListSearchField(placeholder: "groups.search", text: $query)
                    chips
                    archivedToggle
                    discover
                    content
                        .padding(.bottom, 12)
                }
            }
            .refreshable { await load() }
            .background(ListAmbientBackground())
            .sheet(isPresented: $showFolderEditor) {
                FolderEditorView(token: token, chats: groups.map(\.asConversation)) { Task { await reloadFolders() } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: GroupSummary.self) { g in ChatView(chat: g.asConversation, canSend: g.can_send) }
            .fullScreenCover(item: $watchGroup) { st in
                StatusViewerScreen(groups: [st], startGroup: 0, token: token) { Task { await load() } }
            }
            .onReceive(LocalNotifier.shared.$tappedConversation) { id in
                guard let id, id.hasPrefix("grp_") else { return }
                Task {
                    if !groups.contains(where: { $0.conversation_id == id }), let token = store.session?.token {
                        groups = (try? await APIClient.shared.groups(token: token)) ?? groups
                    }
                    if let g = groups.first(where: { $0.conversation_id == id }) { path = [g] }
                    LocalNotifier.shared.tappedConversation = nil
                }
            }
            .sheet(isPresented: $showCreate) { CreateGroupView { id in Task { await open(id) } } }
            .sheet(isPresented: $showJoin) { JoinGroupView { id in Task { await open(id) } } }
            .sheet(item: $joining) { d in
                InviteJoinView(handle: d.handle) { id in Task { await open(id) } }
            }
            .confirmationDialog(Text("grp.leave.confirm"), isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                                titleVisibility: .visible) {
                Button("grp.leave", role: .destructive) {
                    if let g = leaving { Task { await leave(g) } }
                }
            }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
        }
        .task { await load() }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { discovered = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let found = await APIClient.shared.grpDiscover(token: token, query: q)
            discovered = found.filter { !($0.already_member ?? false) }
        }
        .onReceive(live.messages) { m in if m.conversation_id.hasPrefix("grp_") { Task { await load() } } }
    }

    /// Website phone header (GroupsView.tsx .sidebar-head): the big "Groups" and the 43 pt square new-group button
    /// (06-voice.css .sidebar-head-actions .icon-btn); no brand bar on this screen.
    private var header: some View {
        HStack(spacing: 12) {
            ListTitle(key: "groups.title")
            Spacer(minLength: 8)
            Menu {
                Button { showCreate = true } label: { Label("grp.new", systemImage: "plus") }
                Button { showJoin = true } label: { Label("group.join", systemImage: "link") }
            } label: {
                ListSquareFace { GroupPlusGlyph().frame(width: 24, height: 24) }
            }
            .accessibilityLabel(Text("grp.new"))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    /// The same chip row as Chats (website FolderTabs in GroupsView): All chats, Unread, my folders, new folder.
    private var chips: some View {
        ListChipBar(onNewFolder: { showFolderEditor = true }) {
            ListChip(title: NSLocalizedString("folders.all", comment: ""), selected: filter == "all") { filter = "all" }
            ListChip(title: NSLocalizedString("folders.unread", comment: ""), count: unreadTotal, selected: filter == "unread") { filter = "unread" }
            ForEach(folders) { f in
                ListChip(title: f.name, icon: FolderStore.symbol(folderIcons[f.id] ?? "folder"),
                         iconColor: ListLook.folderColor(folderColors[f.id] ?? ""), count: unreadIn(f),
                         selected: filter == f.id) { filter = f.id }
            }
        }
    }

    /// "Archived (n)" / "Back to Groups" under the chips (04-app-shell.css .conv-archived-toggle).
    @ViewBuilder private var archivedToggle: some View {
        if archivedCount > 0 || showArchived {
            Button { showArchived.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "archivebox").font(.system(size: 14))
                    Text(showArchived ? NSLocalizedString("grp.back", comment: "")
                                      : String(format: NSLocalizedString("grp.archived.n", comment: ""), archivedCount))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(ListLook.archivedRule).frame(height: 1) }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var unreadTotal: Int { groups.filter { isUnread($0) }.count }

    private func unreadIn(_ f: ChatFolder) -> Int {
        groups.filter { isUnread($0) && f.contains(id: $0.conversation_id, title: $0.name, unread: true) }.count
    }

    @ViewBuilder private var content: some View {
        if loading && groups.isEmpty {
            ProgressView().tint(Theme.accent).padding(.top, 60)
        } else if shown.isEmpty {
            ListEmptyNote(text: NSLocalizedString(showArchived ? "grp.archived.none" : (filter == "unread" ? "grp.unread.none" : "groups.empty"), comment: ""))
        } else {
            let rows = shown
            LazyVStack(spacing: 0) {
                ForEach(rows) { g in
                    NavigationLink(value: g) { row(g, first: g.conversation_id == rows.first?.conversation_id) }
                        .buttonStyle(.plain)
                        .contextMenu { rowMenu(g) }
                }
            }
        }
    }

    /// Public groups that match the search (GET /discover/groups).
    @ViewBuilder private var discover: some View {
        if !discovered.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                TFSectionLabel(text: NSLocalizedString("grp.public", comment: "")).padding(.horizontal, 12)
                ForEach(discovered) { d in
                    Button { joining = d } label: {
                        HStack(spacing: 14) {
                            LinkAvatar(token: token, handle: d.handle, title: d.name, hasAvatar: d.has_avatar)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(d.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    if d.verified == true { Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Theme.verified) }
                                }
                                Text("@\(d.handle) · " + String(format: NSLocalizedString("groups.members", comment: ""), d.member_count)
                                     + ((d.needs_approval ?? false) ? " · " + NSLocalizedString("grp.request.join.short", comment: "") : ""))
                                    .font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).frame(minHeight: 68)
                        .overlay(alignment: .top) { ListRowRule() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    /// One group row as the website draws it on phones (GroupsView.tsx .conv-row.group-row, 27-chats-list.css): 54 pt
    /// picture (ring when the group has a status), name 16 bold with the blue seal, time 12, preview 14, the hairline above
    /// the text only, and pin / muted / yellow "@" / unread count together on the right.
    private func row(_ g: GroupSummary, first: Bool) -> some View {
        let p = prefs[g.conversation_id]
        let muted = p?.muted ?? false
        let unread = isUnread(g)
        let mentions = unread ? (extras[g.conversation_id]?.unread_mentions ?? 0) : 0
        // teal and bold when there are unread messages, unless muted (website 9ba9f40)
        let hotTime = g.unread_count > 0 && !muted
        return HStack(spacing: 12) {
            Group {
                if let st = groupStatuses[g.conversation_id] {
                    // the group's status: a ring on its picture (accent = new, grey = seen); tap it to watch
                    ListAvatarRing(seen: st.all_seen) {
                        Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
                    }
                    .contentShape(Circle())
                    .highPriorityGesture(TapGesture().onEnded { watchGroup = st })
                    .accessibilityLabel(Text(String(format: NSLocalizedString("gst.watch.named", comment: ""), g.name)))
                } else {
                    Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 5) {
                        Text(g.name).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        if extras[g.conversation_id]?.verified == true { ListVerifiedSeal(size: 15) }
                    }
                    Spacer(minLength: 0)
                    if let d = g.lastDate {
                        Text(ChatRow.timeLabel(d)).font(.system(size: 12, weight: hotTime ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(hotTime ? ListLook.unreadTime : ListLook.rowTime)
                    }
                }
                HStack(spacing: 5) {
                    previewLine(g)
                    Spacer(minLength: 8)
                    ListRowMeta(pinned: p?.pinned ?? false, muted: muted, mentions: mentions,
                                unreadCount: g.unread_count, markedUnread: p?.marked_unread ?? false)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .overlay(alignment: .top) { if !first { ListRowRule() } }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    /// The website's group row menu: Pin, Mute Notifications, Mark as Read/Unread, Archive, Leave Group.
    @ViewBuilder private func rowMenu(_ g: GroupSummary) -> some View {
        let p = prefs[g.conversation_id]
        let id = g.conversation_id
        Button { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, pinned: !(p?.pinned ?? false)) } } label: {
            Label(LocalizedStringKey((p?.pinned ?? false) ? "grp.unpin" : "grp.pin"), systemImage: (p?.pinned ?? false) ? "pin.slash" : "pin")
        }
        if p?.muted ?? false {
            Button { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, unmute: true) } } label: {
                Label("grp.unmute", systemImage: "bell")
            }
        } else {
            Menu {
                Button("grp.mute.8h") { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, muteSeconds: 8 * 3600) } }
                Button("grp.mute.1d") { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, muteSeconds: 86400) } }
                Button("grp.mute.1w") { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, muteSeconds: 7 * 86400) } }
                Button("grp.mute.always") { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, muteForever: true) } }
            } label: { Label("grp.mute", systemImage: "bell.slash") }
        }
        if isUnread(g) {
            Button {
                change {
                    if g.unread_count > 0 { try await APIClient.shared.grpMarkRead(token: token, id: id) }
                    if p?.marked_unread ?? false { try await APIClient.shared.setPrefs(token: token, conversationID: id, markedUnread: false) }
                }
            } label: { Label("grp.markread", systemImage: "envelope.open") }
        } else {
            Button { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, markedUnread: true) } } label: {
                Label("grp.markunread", systemImage: "envelope.badge")
            }
        }
        Button { change { try await APIClient.shared.setPrefs(token: token, conversationID: id, archived: !(p?.archived ?? false)) } } label: {
            Label(LocalizedStringKey((p?.archived ?? false) ? "grp.unarchive" : "grp.archive"), systemImage: "archivebox")
        }
        Button(role: .destructive) { leaving = g } label: { Label("grp.leave", systemImage: "rectangle.portrait.and.arrow.right") }
    }

    /// The second line, as a private chat's (website GroupsView + chatPreview, b6c3ae8 / 63f2616): my own message shows its
    /// ticks, someone else's starts with "Name: "; then the type glyph (photo, video, voice, file, call) and WhatsApp words
    /// ("Voice message (0:10)", "Video", "Audio"), never a bare file name. ChatRow's helpers do the wording.
    @ViewBuilder private func previewLine(_ g: GroupSummary) -> some View {
        if g.last_message.isEmpty && g.last_message_at <= 0 {
            Text(String(format: NSLocalizedString("groups.members", comment: ""), g.member_count))
                .font(.system(size: 14)).foregroundStyle(ListLook.rowPreview).lineLimit(1)
        } else {
            let c = g.previewConversation(me: me)
            let row = ChatRow(chat: c, token: token)
            let status = row.ownStatus
            // my own message: its ticks instead of a name; someone else's: their name first (website: !mine && !p.status)
            let who = !c.last_message_mine && status == nil && !(g.last_sender_name ?? "").isEmpty ? (g.last_sender_name ?? "") + ": " : ""
            if let st = status { ChatRow.ticks(st) }
            if let icon = row.previewIcon {
                // the sender's name comes before the glyph (website .conv-preview-who, then PreviewGlyph)
                if !who.isEmpty { Text(who).font(.system(size: 14)).foregroundStyle(ListLook.rowPreview).lineLimit(1).fixedSize() }
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(row.callMissed ? Theme.danger : Theme.accent)
                Text(row.preview).font(.system(size: 14)).foregroundStyle(row.callMissed ? Theme.danger : ListLook.rowPreview).lineLimit(1)
            } else {
                Text(who + row.preview).font(.system(size: 14)).foregroundStyle(ListLook.rowPreview).lineLimit(1)
            }
        }
    }

    private func change(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch APIError.refused(let why) {
                problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
            } catch {
                problem = NSLocalizedString("chat.action.failed", comment: "")
            }
            await load()
        }
    }

    private func leave(_ g: GroupSummary) async {
        do {
            try await APIClient.shared.grpRemove(token: token, id: g.conversation_id, userID: "")
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("grp.leave.owner", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
        await load()
    }

    private func open(_ id: String) async {
        await load()
        if let g = groups.first(where: { $0.conversation_id == id }) { path = [g] }
    }

    private func load() async {
        if groups.isEmpty {
            let cached = ListCache.groups(token: token)
            if !cached.isEmpty { groups = cached }
        }
        loading = true
        defer { loading = false }
        do {
            groups = try await APIClient.shared.groups(token: token)
            BadgeStore.shared.groups = groups.filter { $0.unread_count > 0 }.count
            #if DEBUG
            // CI only: TF_CI_OPEN_GROUP=1 opens the first group once, for a screenshot of a group chat
            if ProcessInfo.processInfo.environment["TF_CI_OPEN_GROUP"] == "1", path.isEmpty, let first = groups.first,
               !UserDefaults.standard.bool(forKey: "tf.ci.groupOpened") {
                UserDefaults.standard.set(true, forKey: "tf.ci.groupOpened")
                path = [first]
            }
            #endif
            if let feed = try? await APIClient.shared.statusFeed(token: token) {
                var map: [String: StatusGroup] = [:]
                for s in feed { if let gid = s.group_id, !s.posts.isEmpty { map[gid] = s } }
                groupStatuses = map
            }
        } catch APIError.badCredentials {
            store.sessionExpired()
            return
        } catch {}
        if let list = try? await APIClient.shared.prefs(token: token) {
            prefs = Dictionary(list.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        extras = await APIClient.shared.grpListExtras(token: token)
        if folders.isEmpty { await reloadFolders() }
    }

    private func reloadFolders() async {
        folders = (try? await APIClient.shared.folders(token: token)) ?? folders
        if let all = try? await FolderStore.load(token: token) {
            folderIcons = Dictionary(all.1.map { ($0.id, $0.icon) }, uniquingKeysWith: { a, _ in a })
            folderColors = Dictionary(all.1.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        }
    }
}

/// A public group's picture from its permanent link (or its first letter).
struct LinkAvatar: View {
    let token: String
    let handle: String
    let title: String
    let hasAvatar: Bool
    var size: CGFloat = 50
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatarGradient)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String(title.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: handle) {
            guard hasAvatar, let d = await APIClient.shared.grpLinkAvatar(token: token, handle: handle) else { return }
            image = UIImage(data: d)
        }
    }
}

/// "You're invited to join": a public group found by search or link (GET /group-links/{handle}).
struct InviteJoinView: View {
    let handle: String
    let onOpen: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview: GrpInvitePreview?
    @State private var invalid = false
    @State private var busy = false
    @State private var sent = false
    @State private var problem: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Theme.faint.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
            if invalid {
                Spacer()
                Text("grp.invite.invalid").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
            } else if let p = preview {
                Text("grp.invited").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint).padding(.top, 10)
                LinkAvatar(token: token, handle: handle, title: p.name, hasAvatar: p.has_avatar, size: 84)
                Text(p.name).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                Text(String(format: NSLocalizedString("groups.members", comment: ""), p.member_count))
                    .font(.system(size: 14)).foregroundStyle(Theme.faint)
                if p.already_member ?? false {
                    Text("grp.already").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    primary("grp.open") {
                        dismiss()
                        if let id = p.conversation_id { onOpen(id) }
                    }
                } else if sent || (p.request_pending ?? false) {
                    // the request is on its way (website InviteJoin, 596067a): a clear note and one Done button, no dead "Request sent"
                    VStack(spacing: 4) {
                        Text("gp2.inv.sent").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        Text("gp2.inv.sent.note").font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.center)
                    primary("id.done") { dismiss() }
                } else if p.needs_approval ?? false {
                    Text("grp.approval.note").font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    primary(busy ? "grp.joining" : "grp.request.join") { Task { await join() } }.disabled(busy)
                } else {
                    primary(busy ? "grp.joining" : "grp.join") { Task { await join() } }.disabled(busy)
                }
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                // a second button only while there is still a choice: "Close" for a member, "Not now" before joining
                if p.already_member ?? false {
                    Button("chat.close") { dismiss() }.foregroundStyle(Theme.faint).padding(.top, 4)
                } else if !(sent || (p.request_pending ?? false)) {
                    Button("grp.notnow") { dismiss() }.foregroundStyle(Theme.faint).padding(.top, 4).disabled(busy)
                }
                Spacer()
            } else {
                Spacer()
                ProgressView().tint(Theme.accent)
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Theme.panelGradient.ignoresSafeArea())
        .presentationDetents([.medium])
        .task {
            do { preview = try await APIClient.shared.grpLinkPreview(token: token, handle: handle) } catch { invalid = true }
        }
    }

    private func primary(_ key: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 48).background(Theme.accent, in: Capsule())
        }
        .padding(.top, 6)
    }

    private func join() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await APIClient.shared.grpJoinLink(token: token, handle: handle)
            if r.pending ?? false || r.conversation_id.isEmpty {
                sent = true
            } else {
                dismiss()
                onOpen(r.conversation_id)
            }
        } catch APIError.refused(let why) {
            problem = why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }
}
