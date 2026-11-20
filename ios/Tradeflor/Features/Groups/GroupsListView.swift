import SwiftUI
import UIKit

/// The Groups screen as on the website (GroupsView.tsx): "Groups" with the new-group button, "Search groups or @link"
/// (which also finds public groups), the folder chips, Archived, and the group rows with their long-press menu.
struct GroupsListView: View {
    @EnvironmentObject private var store: SessionStore
    /// Used for its events only (nothing it publishes is shown here), so it is not observed: a contact coming online no
    /// longer works this list out again.
    private let live = LiveConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    /// The app really left the front (not just Control Center or a system sheet): only then is the list read again on return.
    @State private var wasBackground = false
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
    @State private var showScan = false
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var query = ""
    @State private var discovered: [GrpDiscover] = []
    /// The search the public groups on screen answer (an answer for older text is never shown for newer text).
    @State private var discoveredFor = ""
    /// A pasted invitation link: Join Group opens with it filled in.
    @State private var joinLink: String?

    /// The public-group search: 2+ characters, without the "@" (web GroupDiscover).
    private var discoverNeedle: String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("@") { q.removeFirst() }
        return q.count >= 2 && pastedInvite == nil ? q : ""
    }

    /// An invitation pasted in the search (https://…/join/<32 hex>, …/g/<handle>, or the bare token): web parseInviteToken.
    private var pastedInvite: String? {
        let t = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6 else { return nil }
        if t.range(of: "/g/[A-Za-z][A-Za-z0-9_]{4,31}/?$", options: .regularExpression) != nil { return t }
        if t.range(of: "(^|/join/)[0-9A-Fa-f]{32}/?$", options: .regularExpression) != nil { return t }
        return nil
    }
    @State private var joining: GrpDiscover?
    @State private var leaving: GroupSummary?
    @State private var problem: String?
    @State private var showFolderEditor = false
    /// each folder's icon and colour, for the chips (website FolderTabs)
    @State private var folderIcons: [String: String] = [:]
    @State private var folderColors: [String: String] = [:]
    /// Lock group / Unlock group from a row's menu (website GroupsView "lock", as Chats' LockChatSheet).
    @State private var lockSheetFor: GroupSummary?

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }

    private func isUnread(_ g: GroupSummary) -> Bool { g.unread_count > 0 || (prefs[g.conversation_id]?.marked_unread ?? false) }
    /// Groups I locked (Chat Lock; GET /groups says so per group): kept out of the list and its circles, under the Locked chip
    /// (website: groups.filter(!locks.has), groupTab "locked").
    /// Kept as state, written with `extras` in load(): as a computed set it was built again for every group asked about
    /// (several times per group on every pass).
    @State private var lockedIDs: Set<String> = []
    private func isLocked(_ g: GroupSummary) -> Bool { lockedIDs.contains(g.conversation_id) }
    private var archivedCount: Int { groups.filter { !isLocked($0) && (prefs[$0.conversation_id]?.archived ?? false) }.count }

    private var shown: [GroupSummary] {
        let locked = lockedIDs
        var g = filter == "locked"
            ? groups.filter { locked.contains($0.conversation_id) }
            : groups.filter { !locked.contains($0.conversation_id) && showArchived == (prefs[$0.conversation_id]?.archived ?? false) }
        switch filter {
        case "all", "locked": break
        case "unread": g = g.filter { isUnread($0) }
        default:
            if let f = folders.first(where: { $0.id == filter }) {
                g = g.filter { f.contains(id: $0.conversation_id, title: $0.name, unread: isUnread($0)) }
            }
        }
        // "Search groups or @link": a leading "@" is part of how a link is typed, not of a name; Arabic / accents / case folded.
        // A pasted invitation link filters nothing (web: inviteToken !== null), its "Join group" row is shown instead.
        let q = ListSearch.needle(query)
        if !q.isEmpty, pastedInvite == nil { g = g.filter { ListSearch.matches(q, $0.name) } }
        g.sort { a, b in
            let pa = prefs[a.conversation_id]?.pinned_at ?? 0, pb = prefs[b.conversation_id]?.pinned_at ?? 0
            if (pa > 0) != (pb > 0) { return pa > 0 }
            if pa > 0 && pa != pb { return pa > pb }
            return a.last_message_at > b.last_message_at
        }
        return g
    }

    /// A burst of group messages is one quiet reload (no spinner, no list redraw per message).
    @State private var pendingReload: Task<Void, Never>?

    @State private var lastReload = Date.distantPast

    /// Back from a chat: the counts are read again at once. The .task that loads the list does not run again when a
    /// pushed chat closes, and the throttle below could skip the refresh, so the badge kept the count of before.
    private func reloadAfterReturn() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // the chat's read mark goes to the server first
            guard !Task.isCancelled else { return }
            pendingReload = nil
            lastReload = Date()
            await load()
        }
    }

    /// At most one reload every 3 s: a busy chat used to reload the list (3-4 requests) for nearly every message.
    private func reloadSoon() {
        guard pendingReload == nil else { return } // one is already on its way and will include this
        let wait = max(0.7, 3 - Date().timeIntervalSince(lastReload))
        pendingReload = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            pendingReload = nil
            lastReload = Date()
            await load()
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // as on the web: the top stays still (brand bar, title and buttons, search, circles, chips) and only the groups
            // scroll; nothing moves by itself, a tap anywhere closes the keyboard and still works
            VStack(spacing: 0) {
                header
                ListSearchField(placeholder: "groups.search", text: $query)
                circles
                chips
                ScrollView {
                    VStack(spacing: 0) {
                        archivedToggle
                        discover
                        content
                            .padding(.bottom, 12)
                    }
                }
                .modifier(DockSpace()) // on the scroll view itself: an inset outside its NavigationStack never reached it
                .modifier(ListNoBounce())
            }
            .simultaneousGesture(TapGesture().onEnded { if TabChrome.shared.keyboard { TabChrome.dismissKeyboard() } })
            .scrollDismissesKeyboard(.immediately)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(ChatsWallpaper())
            .sheet(isPresented: $showFolderEditor) {
                FolderEditorView(token: token, chats: groups.map(\.asConversation)) { Task { await reloadFolders() } }
                    .tfColorScheme()
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
            .sheet(isPresented: $showCreate) { CreateGroupView { id in Task { await open(id) } }.tfColorScheme() }
            .sheet(isPresented: $showJoin) { JoinGroupView { id in Task { await open(id) } }.tfColorScheme() }
            .sheet(item: $joining) { d in
                InviteJoinView(handle: d.handle) { id in Task { await open(id) } }
                    .tfColorScheme()
            }
            .sheet(item: $lockSheetFor) { g in
                LockChatSheet(conversationID: g.conversation_id, name: g.name, locked: isLocked(g), isGroup: true) {
                    Task { await load() }
                }
                .environmentObject(store)
                .tfColorScheme()
            }
            // the owner cannot just leave (server: transfer ownership first, 409): told so, with no Leave button (website
            // GroupsView confirm: myRole !== "owner")
            .confirmationDialog(Text(LocalizedStringKey(leaving?.my_role == "owner" ? "grp.leave.owner" : "grp.leave.confirm")),
                                isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                                titleVisibility: .visible) {
                if leaving?.my_role != "owner" {
                    Button("grp.leave", role: .destructive) {
                        if let g = leaving { Task { await leave(g) } }
                    }
                }
            }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
        }
        .task {
            let k = "groups|" + token
            if FreshGate.isFresh(k) && !groups.isEmpty { return }
            await load()
            FreshGate.mark(k)
        }
        .task(id: discoverNeedle) {
            // web GroupDiscover: 2+ characters, 300 ms after the last key; what was found for older text is not kept on screen
            let q = discoverNeedle
            guard !q.isEmpty else { discovered = []; discoveredFor = ""; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let found = await APIClient.shared.grpDiscover(token: token, query: q)
            if Task.isCancelled || q != discoverNeedle { return } // a newer search is on its way: an older answer never replaces it
            // a group I am already in shows in my own rows; one found only by its @link (its name does not match) stays here,
            // where its sheet offers "Open" (group names are unique on the server)
            let onScreen = Set(shown.map { ChatFolder.fold($0.name) })
            discovered = found.filter { !($0.already_member ?? false) || !onScreen.contains(ChatFolder.fold($0.name)) }
            discoveredFor = q
        }
        .sheet(isPresented: Binding(get: { joinLink != nil }, set: { if !$0 { joinLink = nil } })) {
            JoinGroupView(onJoined: { id in Task { await open(id) } }, initialLink: joinLink ?? "")
                .tfColorScheme()
        }
        .onReceive(live.messages) { m in if m.conversation_id.hasPrefix("grp_") { reloadSoon() } }
        .onReceive(live.groupChanged) { _ in reloadSoon() }
        // after a socket gap or coming back to the app the list is fetched again (it only listened to live events before)
        .onReceive(live.opened) { _ in reloadSoon() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { wasBackground = true }
            else if phase == .active, wasBackground { wasBackground = false; reloadSoon() }
        }
        .onChange(of: path.count) { n in if n == 0 { reloadAfterReturn() } }
    }

    /// Website phone header (GroupsView.tsx .sidebar-head): the big "Groups" and the 43 pt square new-group button
    /// (06-voice.css .sidebar-head-actions .icon-btn); no brand bar on this screen.
    /// Organised as Chats (website 01d0586): the TRADEFLOR bar, the big title with two round buttons -- Scan QR (a
    /// group's or a person's code, the same Scan & Connect as Chats) and New group (also Join with a link).
    private var header: some View {
        VStack(spacing: 0) {
            ListBrandBar()
            HStack(spacing: 12) {
                ListTitle(key: "groups.title")
                Spacer(minLength: 8)
                ListDiscButton(action: { showScan = true }) {
                    ScanGlyph().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 22, height: 22)
                }
                .accessibilityLabel(Text("sc.scan.title"))
                Menu {
                    Button { showCreate = true } label: { Label("grp.new", systemImage: "plus") }
                    Button { showJoin = true } label: { Label("group.join", systemImage: "link") }
                } label: {
                    ListDiscFace { GroupPlusGlyph().frame(width: 24, height: 24) }
                }
                .accessibilityLabel(Text("grp.new"))
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .fullScreenCover(isPresented: $showScan) {
            ScanFlow { c in
                showScan = false
                Task {
                    await load()
                    if let g = groups.first(where: { $0.conversation_id == c.conversation_id }) { path = [g] }
                    else { LocalNotifier.shared.tappedConversation = c.conversation_id } // a person: their chat
                }
            }
            .environmentObject(store)
            .environmentObject(live)
        }
    }

    /// The circles row, as Chats' status row (website 01d0586): New group first, then pinned groups, then those with
    /// unread messages, then the most recent; a lit ring when a group has unread messages; a tap opens it.
    @ViewBuilder private var circles: some View {
        if query.isEmpty {
            let open = groups.filter { !(prefs[$0.conversation_id]?.archived ?? false) && !isLocked($0) }
            let pinned = open.filter { prefs[$0.conversation_id]?.pinned ?? false }
                .sorted { (prefs[$0.conversation_id]?.pinned_at ?? 0) > (prefs[$1.conversation_id]?.pinned_at ?? 0) }
            let rest = open.filter { !(prefs[$0.conversation_id]?.pinned ?? false) }
            let ordered = Array((pinned + rest.filter { isUnread($0) } + rest.filter { !isUnread($0) }).prefix(10))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    // the same size and form as the Chats status row (StatusStrip): a 52 pt ring box, a 43 pt picture, a 2 pt
                    // ring inside it, a 60 pt item, the name 11 pt on a 15 pt line
                    Button { showCreate = true } label: {
                        VStack(spacing: 4) {
                            GroupPlusGlyph().frame(width: 22, height: 22).foregroundStyle(Theme.dyn(0x8FF6F8, 0x0097A5))
                                .frame(width: 43, height: 43)
                                .background(Theme.dyn(0x0A3440, 0xDDF7F8), in: Circle())
                                .frame(width: 52, height: 52)
                                .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4, 3])).foregroundStyle(Theme.dyn(0x288CAF, 0x00A8B5, 0.55, 0.55)))
                            Text("grp.new").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                .lineLimit(1).truncationMode(.tail).frame(height: 15).frame(maxWidth: 60)
                        }
                        .frame(width: 60)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.onAccent)
                                .frame(width: 21, height: 21).background(Theme.accent, in: Circle())
                                .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                                .padding(4.5)
                                .offset(x: -0.5, y: 32.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("grp.new"))
                    ForEach(ordered) { g in
                        let unread = isUnread(g)
                        Button { path = [g] } label: {
                            VStack(spacing: 4) {
                                Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id, size: 43)
                                    .frame(width: 43, height: 43)
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        // the glow only on a lit ring (a clear one was still a shadow to draw)
                                        if unread {
                                            Circle().strokeBorder(lineWidth: 2).foregroundStyle(Theme.accent)
                                                .shadow(color: Theme.hex(0x00D4DF, 0.3), radius: 5)
                                        } else {
                                            Circle().strokeBorder(lineWidth: 2).foregroundStyle(Theme.dyn(0xA9B9C5, 0x5F7686, 0.35, 0.35))
                                        }
                                    }
                                Text(g.name).font(.system(size: 11)).foregroundStyle(Theme.faint)
                                    .lineLimit(1).truncationMode(.tail).frame(height: 15).frame(maxWidth: 60)
                            }
                            .frame(width: 60)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(g.name))
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            }
        }
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
            if !lockedIDs.isEmpty || filter == "locked" {
                ListChip(title: NSLocalizedString("ux1.chips.locked", comment: ""), icon: "lock", count: lockedIDs.count, plainCount: true,
                         selected: filter == "locked") { filter = "locked"; showArchived = false }
            }
        }
    }

    /// "Archived (n)" / "Back to Groups" under the chips (04-app-shell.css .conv-archived-toggle).
    @ViewBuilder private var archivedToggle: some View {
        if archivedCount > 0 || showArchived {
            Button { showArchived.toggle(); if filter == "locked" { filter = "all" } } label: {
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

    /// Locked groups never count (website unreadCount: !locks.has(g.id) && isUnreadGroup(g)).
    private var unreadTotal: Int { groups.filter { isUnread($0) && !isLocked($0) }.count }

    private func unreadIn(_ f: ChatFolder) -> Int {
        groups.filter { isUnread($0) && !isLocked($0) && f.contains(id: $0.conversation_id, title: $0.name, unread: true) }.count
    }

    @ViewBuilder private var content: some View {
        // worked out once per pass (it filters and sorts; it was read twice)
        let rows = shown
        if loading && groups.isEmpty {
            ProgressView().tint(Theme.accent).padding(.top, 60)
        } else if rows.isEmpty {
            if !groups.isEmpty, !ListSearch.needle(query).isEmpty, pastedInvite == nil {
                // searching: "no match", not "you have no groups"
                ListEmptyNote(text: String(format: NSLocalizedString("ux1.chats.nomatch", comment: ""), query.trimmingCharacters(in: .whitespaces)))
            } else if pastedInvite == nil {
                ListEmptyNote(text: NSLocalizedString(filter == "locked" ? "grp.locked.none"
                                                      : (showArchived ? "grp.archived.none" : (filter == "unread" ? "grp.unread.none" : "groups.empty")), comment: ""))
            }
        } else {
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
        if pastedInvite != nil && filter != "locked" {
            // web GroupsView: a pasted invitation link is a "Join group · Use this invite link" row
            Button { joinLink = pastedInvite } label: {
                HStack(spacing: 14) {
                    Image(systemName: "link").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 50, height: 50).background(Theme.avatarGradient, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("group.join").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("grp.search.invite").font(.system(size: 13)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).frame(minHeight: 68)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        // public groups: not in the Locked tab (web), and only for the text on screen now
        if !discoverNeedle.isEmpty && filter != "locked" {
            VStack(alignment: .leading, spacing: 0) {
                TFSectionLabel(text: NSLocalizedString("grp.public", comment: "")).padding(.horizontal, 12)
                if discoveredFor != discoverNeedle {
                    Text("ct.searching").font(.system(size: 13)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                } else if discovered.isEmpty {
                    Text(String(format: NSLocalizedString("grp.public.none", comment: ""), discoverNeedle))
                        .font(.system(size: 13)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                ForEach(discoveredFor == discoverNeedle ? discovered : []) { d in
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
        Button { lockSheetFor = g } label: {
            Label(LocalizedStringKey(isLocked(g) ? "grp.unlock" : "grp.lock"), systemImage: isLocked(g) ? "lock.open" : "lock")
        }
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
            // 409 "transfer ownership before leaving the group" is the server's English: the app's own words instead
            problem = (why.isEmpty || why.contains("transfer ownership")) ? NSLocalizedString("grp.leave.owner", comment: "") : why
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
            // read and decoded off the main thread (a file read and a JSON decode when the tab is first shown)
            let tok = token
            let cached = await Task.detached(priority: .userInitiated) { ListCache.groups(token: tok) }.value
            if groups.isEmpty, !cached.isEmpty { groups = cached }
        }
        // the spinner only shows with no groups on screen; flipping it on every quiet reload redrew the whole list
        if groups.isEmpty { loading = true }
        defer { if loading { loading = false } }
        // everything the list needs is asked at once and put on screen in ONE update (it used to arrive in 4-5 steps:
        // archived and locked groups showed, then vanished; pinned ones moved)
        async let prefsList = try? APIClient.shared.prefs(token: token)
        async let extrasMap = APIClient.shared.grpListExtras(token: token)
        async let statusFeed = try? APIClient.shared.statusFeed(token: token)
        var fresh: [GroupSummary]?
        do {
            fresh = try await APIClient.shared.groups(token: token)
        } catch APIError.badCredentials {
            store.sessionExpired()
            return
        } catch {}
        let list = await prefsList
        let ex = await extrasMap
        let feed = await statusFeed
        // signed out while this load was on its way: nothing of that account is shown or counted any more
        guard !token.isEmpty else { return }
        if let fresh, fresh != groups { groups = fresh }
        if let list {
            let p = Dictionary(list.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
            prefs = p
        }
        extras = ex
        let locked = Set(ex.values.filter { $0.locked == true }.map(\.conversation_id))
        if locked != lockedIDs { lockedIDs = locked }
        if let feed {
            var map: [String: StatusGroup] = [:]
            for s in feed { if let gid = s.group_id, !s.posts.isEmpty { map[gid] = s } }
            if map != groupStatuses { groupStatuses = map }
        }
        // a locked group never shows in the tab's badge either (Chats does the same for locked chats); written once
        // the same rule as the server's icon number (dd979bc): unread, not locked, not archived, not muted
        let nowSec = Int64(Date().timeIntervalSince1970)
        let counted = groups.filter { g in
            let p = prefs[g.conversation_id]
            return g.unread_count > 0 && !locked.contains(g.conversation_id) && !(p?.archived ?? false) && (p?.muted_until ?? 0) <= nowSec
        }
        let badge = counted.count
        let messages = counted.reduce(0) { $0 + $1.unread_count }
        if BadgeStore.shared.groups != badge { BadgeStore.shared.groups = badge }
        if BadgeStore.shared.groupMessages != messages { BadgeStore.shared.groupMessages = messages }
        #if DEBUG
        // CI only: TF_CI_OPEN_GROUP=1 opens the first group once, for a screenshot of a group chat
        if ProcessInfo.processInfo.environment["TF_CI_OPEN_GROUP"] == "1", path.isEmpty, let first = groups.first,
           !UserDefaults.standard.bool(forKey: "tf.ci.groupOpened") {
            UserDefaults.standard.set(true, forKey: "tf.ci.groupOpened")
            path = [first]
        }
        #endif
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
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        // as Avatar: the picture fills the circle, centred; the letter only while there is none
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size)
            } else {
                ZStack {
                    Circle().fill(Theme.avatarGradient)
                    Text(String(title.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Theme.text)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: handle) {
            image = nil
            guard hasAvatar, let d = await APIClient.shared.grpLinkAvatar(token: token, handle: handle) else { return }
            // decoded off the main thread at the size it is drawn
            image = await AvatarImages.decode(d, maxPixels: (size * displayScale).rounded(.up))
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
        guard !busy else { return }
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
