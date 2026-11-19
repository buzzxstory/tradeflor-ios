import SwiftUI
import UIKit
import ImageIO

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
    @State private var lockedIDs: Set<String> = []
    @State private var blockedIDs: Set<String> = []
    /// Chats deleted from the list on this phone (until a newer message), per account (loaded in load()).
    @State private var hiddenAt: [String: Double] = [:]
    @State private var showFolderEditor = false
    @State private var editingFolder: EditableFolder?
    @State private var showManageFolders = false
    @State private var removingFolder: ChatFolder?
    @State private var lockSheetFor: ConversationSummary?
    /// Block / Delete Chat from a row's menu wait for a confirmation (as Block does inside the chat).
    @State private var confirmBlock: ConversationSummary?
    @State private var confirmDelete: ConversationSummary?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// contacts' statuses, for the ring on their row's picture (website ChatScreen .avatar-status)
    @State private var rowStatuses: [StatusGroup] = []
    @State private var statusOpen: StatusOpen?
    /// each folder's icon and colour (the chips draw them as the website's FolderTabs)
    @State private var folderIcons: [String: String] = [:]
    @State private var folderColors: [String: String] = [:]

    /// Live events refresh the list at once; this slow poll only covers a socket that is down.
    private let refreshEvery: UInt64 = 30
    private var token: String { store.session?.token ?? "" }

    private var shown: [ConversationSummary] {
        let q = ListSearch.needle(query)
        let notHidden = chats.filter { c in
            guard let h = hiddenAt[c.conversation_id] else { return true }
            return Double(c.last_message_at > 100_000_000_000 ? c.last_message_at / 1000 : c.last_message_at) > h
        }
        // a blocked chat is only under the Blocked chip (web visibleConversations: !blockedIds.has(peer) outside that tab)
        let visible = notHidden.filter { showArchived == (prefs[$0.conversation_id]?.archived ?? false) && !lockedIDs.contains($0.conversation_id)
            && !blockedIDs.contains($0.peer_id) }
        var base: [ConversationSummary]
        switch filter {
        case "locked": base = notHidden.filter { lockedIDs.contains($0.conversation_id) }
        case "blocked": base = notHidden.filter { blockedIDs.contains($0.peer_id) }
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
        // the name shown, the @username (a leading "@" typed is ignored), Arabic / accents / case folded
        return base.filter { ListSearch.matches(q, $0.title, $0.peer_username) }
    }

    @State private var pendingReload: Task<Void, Never>?

    @State private var lastReload = Date.distantPast

    /// A text message that arrived live goes onto its row at once: the preview, the time, the unread count, and the row moves
    /// to the top. Other kinds (photos, voice, calls) wait for the reload that follows, which makes their preview.
    private func applyLive(_ m: Message) {
        guard m.kind == "text", !m.isDeleted, !m.isSealed, !lockedIDs.contains(m.conversation_id),
              let i = chats.firstIndex(where: { $0.conversation_id == m.conversation_id }) else { return }
        let c = chats[i]
        let mine = m.sender_id == (store.session?.userID ?? "")
        let ms = chats.contains { $0.last_message_at > 100_000_000_000 } // the list's own unit (seconds or milliseconds)
        let secs = m.created_at > 100_000_000_000 ? m.created_at / 1000 : m.created_at
        let at = ms ? secs * 1000 : secs
        guard at >= c.last_message_at else { return }
        let open = path.last?.conversation_id == c.conversation_id
        let patched = ConversationSummary(
            conversation_id: c.conversation_id, peer_id: c.peer_id, peer_username: c.peer_username,
            peer_display_name: c.peer_display_name, peer_avatar_id: c.peer_avatar_id, last_message: m.body,
            last_message_at: at, last_message_mine: mine, unread_count: (mine || open) ? c.unread_count : c.unread_count + 1,
            last_message_kind: "text", last_file_type: nil, last_duration_ms: nil, last_message_status: nil,
            last_call_state: nil, disappear_secs: c.disappear_secs)
        var next = chats
        next[i] = patched
        next.sort { $0.last_message_at > $1.last_message_at }
        chats = next
    }

    /// At most one reload every 3 s: a busy chat used to reload the list (3-4 requests) for nearly every message.
    private func reloadSoon() {
        guard pendingReload == nil else { return } // one is already on its way and will include this
        let wait = max(0.7, 3 - Date().timeIntervalSince(lastReload))
        pendingReload = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            pendingReload = nil
            lastReload = Date()
            await load(quiet: true)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // as on the web: the top (brand bar, title and buttons, search, status row, chips) stays still and only the
            // conversations scroll; nothing moves up or down by itself, a tap anywhere closes the keyboard and still works
            VStack(spacing: 0) {
                header
                ListSearchField(placeholder: "chats.search", text: $query)
                StatusStrip()
                chipsRow
                ScrollView {
                    list
                        .padding(.bottom, 12)
                }
                .modifier(ListNoBounce())
            }
            .simultaneousGesture(TapGesture().onEnded { if TabChrome.shared.keyboard { TabChrome.dismissKeyboard() } })
            .scrollDismissesKeyboard(.immediately)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(ChatsWallpaper())
            .fullScreenCover(item: $statusOpen) { o in
                // the rings are read again through .tfStatusChanged (posted once the "seen" calls have arrived)
                StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) {}
            }
            .sheet(isPresented: $showFolderEditor) { FolderEditorView(token: token, chats: chats) { Task { await reloadFolders() } } }
            .sheet(item: $editingFolder) { f in FolderEditorView(token: token, chats: chats, editing: f) { Task { await reloadFolders() } } }
            .sheet(isPresented: $showManageFolders) { ManageFoldersView(token: token, chats: chats) { Task { await reloadFolders() } } }
            .sheet(item: $lockSheetFor) { c in
                LockChatSheet(conversationID: c.conversation_id, name: c.title, locked: lockedIDs.contains(c.conversation_id)) {
                    Task { await loadLocks() }
                }
                .environmentObject(store)
            }
            .confirmationDialog(Text("folder.remove.title"), isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }),
                                titleVisibility: .visible) {
                Button("folder.remove", role: .destructive) {
                    if let r = removingFolder {
                        Task {
                            try? await FolderStore.save(token: token) { $0.filter { $0.id != r.id } }
                            if filter == r.id { filter = "all" }
                            await reloadFolders()
                        }
                    }
                }
            } message: { Text("folder.remove.note") }
            .confirmationDialog(Text(String(format: NSLocalizedString("chat.block.confirm", comment: ""), confirmBlock?.title ?? "")),
                                isPresented: Binding(get: { confirmBlock != nil }, set: { if !$0 { confirmBlock = nil } }),
                                titleVisibility: .visible) {
                Button("chats.block", role: .destructive) {
                    if let c = confirmBlock { change(c) { try await APIClient.shared.block(token: token, userID: c.peer_id) } }
                }
            }
            .confirmationDialog(Text("chats.delete.confirm"),
                                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("chats.delete", role: .destructive) {
                    if let c = confirmDelete { hide(c) }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.card, in: Capsule()).padding(.bottom, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ConversationSummary.self) { c in ChatView(chat: c) }
            .onReceive(LocalNotifier.shared.$tappedConversation) { id in
                guard let id, !id.hasPrefix("grp_") else { return }
                Task {
                    if !chats.contains(where: { $0.conversation_id == id }) { await load(quiet: true) }
                    if let c = chats.first(where: { $0.conversation_id == id }) { path = [c] }
                    LocalNotifier.shared.tappedConversation = nil
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
        // a burst of new messages (a busy group) is one reload, not one per message: that redrew the list all the time
        // groups are not in this list: their messages and receipts never reload it
        .onReceive(live.messages) { m in
            if !m.conversation_id.hasPrefix("grp_") {
                applyLive(m) // the row shows it now (no 0.7-3 s wait)
                reloadSoon()
            }
        }
        .onReceive(live.changes) { id in if !id.hasPrefix("grp_") { reloadSoon() } }
        // the socket is back (after a lock, a drop): what arrived meanwhile is read at once, not at the next poll
        .onReceive(live.opened) { _ in reloadSoon() }
        // a status watched (here or in the status row), posted or deleted: the rings on the rows change at once
        .onReceive(NotificationCenter.default.publisher(for: .tfStatusChanged)) { _ in Task { await loadStatuses() } }
        // the last blocked / locked chat left its tab (its chip is gone): back to All, as the web
        .onChange(of: blockedIDs) { b in if filter == "blocked" && b.isEmpty { filter = "all" } }
        .onChange(of: lockedIDs) { l in if filter == "locked" && l.isEmpty { filter = "all" } }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let k = "chats|" + token
            if !(FreshGate.isFresh(k) && !chats.isEmpty) {
                await load()
                await reloadFolders()
                await loadStatuses()
                FreshGate.mark(k)
            }
            var rounds = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshEvery * 1_000_000_000)
                if Task.isCancelled { break }
                if !path.isEmpty { continue } // a chat is open on top: the live events keep the list right
                await load(quiet: true)
                // the status rings on the rows: every two minutes, as the status row (website StatusBar)
                rounds += 1
                if rounds % 4 == 0 { await loadStatuses() }
            }
        }
    }

    /// Website phone header (ChatScreen.tsx .list-brand + .sidebar-head, 27-chats-list.css / 63-chats-polish.css):
    /// the TRADEFLOR brand bar, then the big "Chats" with the two round glass buttons (Scan QR, Contacts).
    private var header: some View {
        VStack(spacing: 0) {
            ListBrandBar()
            HStack(spacing: 12) {
                ListTitle(key: "chats.title")
                Spacer(minLength: 8)
                headerButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var headerButtons: some View {
        // straight to Scan & Connect, as on the web (ChatScreen openFlash({view: "scan"}))
        ListDiscButton(action: { ScanTiming.tapped(); showFlash = true }) {
            ScanGlyph().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 22, height: 22)
        }
            .accessibilityLabel(Text("sc.scan.title"))
            .fullScreenCover(isPresented: $showFlash) {
                ScanFlow { c in
                    showFlash = false
                    Task {
                        await load(quiet: true)
                        path = [c]
                    }
                }
                .environmentObject(store)
                .environmentObject(live)
            }
        ListDiscButton(action: { showContacts = true }) {
            UserPlusGlyph().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(width: 24, height: 24)
        }
            .accessibilityLabel(Text("ct.title"))
            .accessibilityIdentifier("chats.new")
            .sheet(isPresented: $showContacts, onDismiss: { Task { await load(quiet: true) } }) {
                ContactsPanel { c in
                    Task {
                        await load(quiet: true)
                        path = [c]
                    }
                }
            }
    }

    /// All chats / Unread / my Smart Folders (made on the website; the same rules decide what is in them), then Locked,
    /// Archived and Blocked when there are some, and "new folder" (website FolderTabs.tsx, 27-chats-list.css .chat-filter-bar).
    private var chipsRow: some View {
        ListChipBar(onNewFolder: { showFolderEditor = true }) { chipsContent }
    }

    /// One tab at a time, as the website's chatTab: picking any chip leaves Archived.
    private func pick(_ id: String) {
        showArchived = false
        filter = id
    }

    @ViewBuilder private var chipsContent: some View {
        ListChip(title: NSLocalizedString("folders.all", comment: ""), selected: filter == "all" && !showArchived) { pick("all") }
        ListChip(title: NSLocalizedString("folders.unread", comment: ""), count: unreadCount,
                 selected: filter == "unread" && !showArchived) { pick("unread") }
        ForEach(folders) { f in
            ListChip(title: f.name, icon: FolderStore.symbol(folderIcons[f.id] ?? "folder"),
                     iconColor: ListLook.folderColor(folderColors[f.id] ?? ""), count: unreadIn(f),
                     selected: filter == f.id && !showArchived) { pick(f.id) }
                .contextMenu {
                    Button {
                        Task {
                            if let all = try? await FolderStore.load(token: token), let e = all.1.first(where: { $0.id == f.id }) { editingFolder = e }
                        }
                    } label: { Label("folder.edit", systemImage: "pencil") }
                    Button { showManageFolders = true } label: { Label("folder.manage", systemImage: "list.bullet") }
                    Button {
                        Task {
                            for c in chats where f.contains(id: c.conversation_id, title: c.title, unread: isUnread(c)) {
                                await APIClient.shared.markRead(token: token, conversationID: c.conversation_id)
                            }
                            await load(quiet: true)
                        }
                    } label: { Label("chats.markread", systemImage: "envelope.open") }
                    Button(role: .destructive) { removingFolder = f } label: { Label("folder.remove", systemImage: "trash") }
                }
        }
        if !lockedIDs.isEmpty {
            ListChip(title: NSLocalizedString("ux1.chips.locked", comment: ""), icon: "lock", count: lockedIDs.count, plainCount: true,
                     selected: filter == "locked" && !showArchived) { pick("locked") }
        }
        if archivedCount > 0 || showArchived {
            ListChip(title: NSLocalizedString("chats.archived", comment: ""), count: archivedCount, plainCount: true,
                     selected: showArchived) {
                let open = !showArchived
                filter = "all"
                showArchived = open
            }
        }
        if !blockedIDs.isEmpty {
            ListChip(title: NSLocalizedString("ux1.chips.blocked", comment: ""),
                     count: chats.filter { blockedIDs.contains($0.peer_id) }.count, plainCount: true,
                     selected: filter == "blocked" && !showArchived) { pick("blocked") }
        }
    }

    /// Unread chats outside Archived and Locked (the Unread chip's number, website unreadChats).
    private var unreadCount: Int {
        chats.filter { isUnread($0) && !(prefs[$0.conversation_id]?.archived ?? false) && !lockedIDs.contains($0.conversation_id)
            && !blockedIDs.contains($0.peer_id) }.count
    }

    /// How many of a folder's chats are unread (website folderUnread).
    private func unreadIn(_ f: ChatFolder) -> Int {
        chats.filter { c in
            isUnread(c) && !lockedIDs.contains(c.conversation_id) && f.contains(id: c.conversation_id, title: c.title, unread: true)
        }.count
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
        } else if chats.isEmpty {
            // website .conv-empty-action: the note, "Start a chat" (Contacts) and where the groups are
            VStack(spacing: 12) {
                Text("ux1.chats.none").font(.system(size: 13)).foregroundStyle(Theme.faint)
                Button { showContacts = true } label: {
                    Text("ux1.chats.start").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.hex(0x03202A))
                        .padding(.horizontal, 20)
                        .frame(minWidth: 160, minHeight: 44)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Text("ux1.chats.groupsHint").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        } else if shown.isEmpty {
            ListEmptyNote(text: emptyNote)
        } else {
            let rows = shown
            let ringIndex = statusIndexByUser
            LazyVStack(spacing: 0) {
                ForEach(rows) { c in
                    NavigationLink(value: c) {
                        ChatRow(chat: c, token: token, online: live.online.contains(c.peer_id),
                                pinned: prefs[c.conversation_id]?.pinned ?? false, muted: prefs[c.conversation_id]?.muted ?? false,
                                markedUnread: prefs[c.conversation_id]?.marked_unread ?? false,
                                first: c.conversation_id == rows.first?.conversation_id,
                                statusSeen: ringIndex[c.peer_id].map { rowStatuses[$0].all_seen },
                                onStatus: statusAction(c.peer_id, ringIndex))
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
        Button { lockSheetFor = c } label: {
            Label(LocalizedStringKey(lockedIDs.contains(c.conversation_id) ? "chats.unlock" : "chats.lock"), systemImage: "lock")
        }
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
        if blockedIDs.contains(c.peer_id) {
            Button { change(c) { try await APIClient.shared.unblock(token: token, userID: c.peer_id) } } label: { Label("chats.unblock", systemImage: "hand.raised.slash") }
        } else {
            Button(role: .destructive) { confirmBlock = c } label: {
                Label("chats.block", systemImage: "hand.raised")
            }
        }
        Button(role: .destructive) { confirmDelete = c } label: { Label("chats.delete", systemImage: "trash") }
    }

    /// Delete Chat: off this list until a newer message comes (this device only).
    private func hide(_ c: ConversationSummary) {
        hiddenAt[c.conversation_id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(hiddenAt, forKey: BadgeStore.hiddenKey(store.session?.userID ?? ""))
        BadgeStore.shared.chats = badgeNow()
        flash(NSLocalizedString("chats.removed", comment: ""))
    }

    private func flash(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    private func change(_ c: ConversationSummary, _ work: @escaping () async throws -> Void) {
        Task {
            // a choice that did not take says so (it used to fail without a word)
            do { try await work() } catch APIError.refused(let why) {
                flash(why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why)
            } catch {
                flash(NSLocalizedString("chat.action.failed", comment: ""))
            }
            await loadPrefs()
            await loadLocks()
        }
    }

    private func reloadFolders() async {
        folders = (try? await APIClient.shared.folders(token: token)) ?? folders
        if let all = try? await FolderStore.load(token: token) {
            folderIcons = Dictionary(all.1.map { ($0.id, $0.icon) }, uniquingKeysWith: { a, _ in a })
            folderColors = Dictionary(all.1.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Contacts with a status to watch (not mine, not a group's), in the feed's order.
    private func loadStatuses() async {
        guard !token.isEmpty, let feed = try? await APIClient.shared.statusFeed(token: token) else { return }
        let list = feed.filter { !$0.isMine && $0.group_id == nil && !$0.posts.isEmpty }
        if list != rowStatuses { rowStatuses = list }
    }

    private var statusIndexByUser: [String: Int] {
        var map: [String: Int] = [:]
        for (i, g) in rowStatuses.enumerated() where map[g.user_id] == nil { map[g.user_id] = i }
        return map
    }

    /// Tapping the ring opens that contact's status, not the chat (website: stopPropagation on .avatar-status).
    private func statusAction(_ peer: String, _ index: [String: Int]) -> (() -> Void)? {
        guard let i = index[peer] else { return nil }
        let groups = rowStatuses
        return { statusOpen = StatusOpen(groups: groups, index: i) }
    }

    /// The note of an empty tab (website ChatScreen .conv-empty).
    private var emptyNote: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return String(format: NSLocalizedString("ux1.chats.nomatch", comment: ""), q) }
        if filter == "locked" { return NSLocalizedString("ux1.chats.nolocked", comment: "") }
        if filter == "blocked" { return NSLocalizedString("ux1.chats.noblocked", comment: "") }
        if showArchived { return NSLocalizedString("ux1.chats.noarchived", comment: "") }
        if filter == "unread" { return NSLocalizedString("ux1.chats.nounread", comment: "") }
        if folders.contains(where: { $0.id == filter }) { return NSLocalizedString("ux1.chats.nofolder", comment: "") }
        return NSLocalizedString("ux1.chats.allarchived", comment: "")
    }

    /// This account's deleted-from-the-list chats (the single-account list of older versions moves to the account that has it).
    private func loadHidden() {
        guard let uid = store.session?.userID, !uid.isEmpty else { return }
        let d = UserDefaults.standard
        let key = BadgeStore.hiddenKey(uid)
        if let old = d.dictionary(forKey: "tf.hiddenChats") as? [String: Double] {
            var mine = (d.dictionary(forKey: key) as? [String: Double]) ?? [:]
            for (k, v) in old where (mine[k] ?? 0) < v { mine[k] = v }
            d.set(mine, forKey: key)
            d.removeObject(forKey: "tf.hiddenChats")
        }
        let loaded = (d.dictionary(forKey: key) as? [String: Double]) ?? [:]
        if loaded != hiddenAt { hiddenAt = loaded }
    }

    private func loadLocks() async {
        if let st = try? await APIClient.shared.ctLockState(token: token) { lockedIDs = Set((st.locks ?? []).map(\.conversation_id)) }
        blockedIDs = Set((try? await APIClient.shared.blocked(token: token)) ?? [])
        BadgeStore.shared.chats = badgeNow()
    }

    /// The tab badge: unread chats the person can see and has not silenced (BadgeStore.counts, the same rule as the app icon).
    private func badgeNow() -> Int {
        let now = Int64(Date().timeIntervalSince1970)
        return chats.filter { c in
            let p = prefs[c.conversation_id]
            var hidden = false
            if let h = hiddenAt[c.conversation_id] {
                hidden = !(Double(c.last_message_at > 100_000_000_000 ? c.last_message_at / 1000 : c.last_message_at) > h)
            }
            return BadgeStore.counts(unread: isUnread(c), archived: p?.archived ?? false, muted: (p?.muted_until ?? 0) > now,
                                     locked: lockedIDs.contains(c.conversation_id), blocked: blockedIDs.contains(c.peer_id), hidden: hidden)
        }.count
    }

    private func loadPrefs() async {
        if let list = try? await APIClient.shared.prefs(token: token) {
            prefs = Dictionary(list.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func load(quiet: Bool = false) async {
        guard !token.isEmpty else { return }
        loadHidden()
        if chats.isEmpty {
            // the last list this phone saw, at once; the server's answer replaces it a moment later
            let cached = ListCache.conversations(token: token).sorted { $0.last_message_at > $1.last_message_at }
            if !cached.isEmpty { chats = cached }
        }
        if !quiet { loading = true }
        defer { loading = false }
        // prefs, locks and the list asked together (they waited for each other before), the list on screen as soon as it is here
        async let prefsDone: Void = loadPrefs()
        async let locksDone: Void = loadLocks()
        do {
            let out = try await APIClient.shared.conversations(token: token)
            await prefsDone; await locksDone // the locked set is known before the rows are shown (a locked chat never flashes)
            let sorted = out.sorted { $0.last_message_at > $1.last_message_at }
            if sorted != chats { chats = sorted }
            BadgeStore.shared.chats = badgeNow()
            failed = false
            ciOpenFirstChat()
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {
            if !quiet && !Task.isCancelled { failed = true } // leaving the tab cancels the load: not an error
        }
    }
}

extension ChatListView {
    /// CI only (Debug): TF_CI_OPEN_CHAT=1 opens the newest chat once, so the workflow can screenshot the chat screen.
    fileprivate func ciOpenFirstChat() {
        #if DEBUG
        // TF_CI_FLASH=scan|mutual opens Flash Connect on the scanner or My Connect Code
        if !ciOpened, !(ProcessInfo.processInfo.environment["TF_CI_FLASH"] ?? "").isEmpty { ciOpened = true; showFlash = true; return }
        guard !ciOpened, ProcessInfo.processInfo.environment["TF_CI_OPEN_CHAT"] == "1", let first = chats.first else { return }
        ciOpened = true
        path = [first]
        #endif
    }
}

/// One conversation row as the website draws it on phones (27-chats-list.css / 63-chats-polish.css .conv-row): 54 pt
/// picture (with the status ring when the contact has one), 12 pt gap, name 16 bold, time 12, preview 14, the hairline
/// above the text only (none above the first row), and on the right the pin, muted and unread marks together.
struct ChatRow: View {
    let chat: ConversationSummary
    let token: String
    var online = false
    var pinned = false
    var muted = false
    var markedUnread = false
    /// the first row of the list has no hairline above it
    var first = false
    /// the contact's status: nil = none, false = something new, true = all watched
    var statusSeen: Bool? = nil
    /// tapping the ring opens the status instead of the chat
    var onStatus: (() -> Void)? = nil

    private var unread: Bool { chat.unread_count > 0 || markedUnread }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if let d = chat.lastDate {
                        // teal and bold when unread (website 27-chats-list .conv-time.unread)
                        Text(Self.timeLabel(d)).font(.system(size: 12, weight: unread ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(unread ? ListLook.unreadTime : ListLook.rowTime)
                    }
                }
                HStack(spacing: 5) {
                    if let st = ownStatus { Self.ticks(st) }
                    if let icon = previewIcon {
                        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(callMissed ? Theme.danger : Theme.accent)
                    }
                    Text(preview).font(.system(size: 14)).foregroundStyle(callMissed ? Theme.danger : ListLook.rowPreview).lineLimit(1)
                    Spacer(minLength: 8)
                    ListRowMeta(pinned: pinned, muted: muted, unreadCount: chat.unread_count, markedUnread: markedUnread)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .overlay(alignment: .top) { if !first { ListRowRule() } }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        let face = Avatar(token: token, userID: chat.peer_id, avatarID: chat.peer_avatar_id, title: chat.title, online: online)
        if let seen = statusSeen {
            ListAvatarRing(seen: seen) { face }
                .contentShape(Circle())
                .highPriorityGesture(TapGesture().onEnded { onStatus?() })
                .accessibilityLabel(Text(String(format: NSLocalizedString("ux1.status.watch", comment: ""), chat.title)))
                .accessibilityAddTraits(.isButton)
        } else {
            face
        }
    }

    /// My latest message's ticks (sent / delivered / read); shared with the groups list (GroupsListView).
    static func ticks(_ st: String) -> some View {
        Image(systemName: st == "sent" ? "checkmark" : "checkmark.circle")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(st == "read" ? Theme.accent : Theme.faint)
            .overlay(alignment: .leading) {
                if st != "sent" { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(st == "read" ? Theme.accent : Theme.faint).offset(x: -4) }
            }
            .accessibilityLabel(Text(LocalizedStringKey("receipt." + st)))
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

    // The second line of the row, as the website (shared/lib/chatPreview.ts): WhatsApp words, never a bare file name.
    private var kind: String { chat.last_message_kind ?? "text" }

    /// The server's labels start with an emoji ("🖼 Photo", "🎥 Video"); with an icon in front it is dropped.
    private var stripped: String {
        // compared by Unicode scalar: "🖼️" (with its variation selector) is one Character but not equal to "🖼"
        let leads: Set<UInt32> = [0x1F5BC, 0x1F4F7, 0x1F4CE, 0x1F4C4, 0x1F3A5, 0x1F3B5, 0x1F3A4]
        var scalars = Substring(chat.last_message).unicodeScalars[...]
        guard let first = scalars.first, leads.contains(first.value) else { return chat.last_message }
        scalars = scalars.dropFirst()
        if scalars.first?.value == 0xFE0F { scalars = scalars.dropFirst() }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private var fileKind: String {
        let n = stripped.lowercased()
        if chat.last_file_type == "video_note" || n.hasPrefix("videonote_") { return "video_note" }
        if chat.last_file_type == "video" || [".mp4", ".mov", ".webm", ".m4v", ".mkv", ".3gp", ".avi"].contains(where: n.hasSuffix) { return "video" }
        if chat.last_file_type == "audio" || [".mp3", ".m4a", ".ogg", ".wav", ".aac", ".flac", ".opus", ".amr"].contains(where: n.hasSuffix) { return "audio" }
        return "document"
    }

    /// My latest message's delivery state (sent / delivered / read), from the real receipts.
    var ownStatus: String? {
        guard chat.last_message_mine, kind != "call", kind != "locked", let s = chat.last_message_status,
              ["sent", "delivered", "read"].contains(s) else { return nil }
        return s
    }

    var callMissed: Bool {
        kind == "call" && (chat.last_call_state == "missed" || chat.last_call_state == "failed"
            || (chat.last_call_state == nil && (chat.last_message.hasPrefix("Missed") || chat.last_message.hasPrefix("Voice call failed"))))
    }

    var previewIcon: String? {
        switch kind {
        case "call": return callMissed ? "phone.arrow.down.left" : "phone"
        case "voice": return "mic"
        case "image": return "camera"
        case "location": return "location"
        case "locked": return "lock"
        case "signal": return "chart.line.uptrend.xyaxis"
        case "file":
            switch fileKind {
            case "video_note": return "video.circle"
            case "video": return "video"
            case "audio": return "music.note"
            default: return "doc"
            }
        default: return nil
        }
    }

    var preview: String {
        switch kind {
        case "voice":
            if let ms = chat.last_duration_ms, ms > 0 {
                return String(format: NSLocalizedString("chats.kind.voice.len", comment: ""), VoiceBubble.length(ms))
            }
            return NSLocalizedString("chats.kind.voice", comment: "")
        case "image": return stripped.isEmpty ? NSLocalizedString("chats.kind.image", comment: "") : stripped
        case "file":
            let t = stripped
            let looksLikeName = t.isEmpty || t.range(of: #"\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil
            switch fileKind {
            case "video_note": return NSLocalizedString("note.video", comment: "")
            case "video": return looksLikeName ? NSLocalizedString("chats.kind.video", comment: "") : t
            case "audio": return looksLikeName ? NSLocalizedString("chats.kind.audio", comment: "") : t
            default: return t.isEmpty ? NSLocalizedString("chats.kind.file", comment: "") : t
            }
        case "locked": return chat.last_message.isEmpty ? NSLocalizedString("chats.kind.locked", comment: "") : chat.last_message
        case "location": return NSLocalizedString("location.live", comment: "")
        case "signal": return chat.last_message.isEmpty ? NSLocalizedString("notify.signal", comment: "") : chat.last_message
        default: return chat.last_message
        }
    }
}

/// The latest known picture of every person (website profileStore.ts): filled from the server's live "profile" events, my
/// own profile answers, the chat list and the profile pages, so a changed or removed photo shows everywhere at once
/// (the chat rows, My status, Settings, the status row, the call screen) without reloading anything.
@MainActor
final class AvatarBook: ObservableObject {
    static let shared = AvatarBook()
    /// The server's answers: user id -> avatar id ("" = no picture). These win over what a list said earlier.
    @Published private(set) var ids: [String: String] = [:]
    /// What a list said (a contact row, a member list), used only where nothing better is known; never published, so a
    /// screen full of rows does not redraw every picture while they fill it.
    private var filled: [String: String] = [:]

    func note(_ userID: String, _ avatarID: String?) {
        guard !userID.isEmpty else { return }
        let v = avatarID ?? ""
        if ids[userID] != v { ids[userID] = v }
    }

    func note(_ pairs: [String: String]) {
        var next = ids
        for (u, a) in pairs where !u.isEmpty { next[u] = a }
        if next != ids { ids = next }
    }

    func fill(_ userID: String, _ avatarID: String) {
        guard !userID.isEmpty, !avatarID.isEmpty, ids[userID] == nil else { return }
        filled[userID] = avatarID
    }

    func filledID(_ userID: String) -> String? { filled[userID] }

    /// Sign-out: the next account never sees this one's pictures.
    func forget() {
        ids = [:]
        filled = [:]
        AvatarImages.clear()
    }

    /// From a network answer on any thread.
    nonisolated static func noteLater(_ pairs: [String: String]) {
        guard !pairs.isEmpty else { return }
        Task { @MainActor in AvatarBook.shared.note(pairs) }
    }
}

/// Decoded profile pictures, at the size they are drawn (memory only, like the bytes in APIClient.avatarCache).
enum AvatarImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    static func get(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func put(_ image: UIImage, _ key: String) { cache.setObject(image, forKey: key as NSString) }
    static func clear() { cache.removeAllObjects() }

    /// Off the main thread and scaled down to `maxPixels` (a 4000 px photo decoded on the main thread for a 54 pt circle
    /// stalled the list while it scrolled).
    static func decode(_ data: Data, maxPixels: CGFloat) async -> UIImage? {
        let limit = max(32, maxPixels)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

/// Profile picture (website .avatar: radial teal gradient, bold initial), with the online dot when asked.
/// The picture fills the circle, centred (aspect fill, clipped to the circle); the letter shows only while there is no
/// picture. A person's picture follows AvatarBook (a new photo replaces the old one everywhere); each picture is fetched
/// once (shared by every row showing it), decoded off the main thread and kept decoded, so rows scrolling back into view
/// show it at once instead of the letter.
struct Avatar: View {
    let token: String
    let userID: String
    let avatarID: String?
    let title: String
    var groupID: String? = nil
    var size: CGFloat = 54
    var online: Bool? = nil
    @ObservedObject private var book = AvatarBook.shared
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (owner: String, key: String, image: UIImage)?

    init(token: String, userID: String, avatarID: String?, title: String, groupID: String? = nil, size: CGFloat = 54, online: Bool? = nil) {
        self.token = token
        self.userID = userID
        self.avatarID = avatarID
        self.title = title
        self.groupID = groupID
        self.size = size
        self.online = online
    }

    private var owner: String { groupID.map { "g/" + $0 } ?? userID }

    /// The picture to show: the server's latest for this person, else what the caller knows, else what a list said.
    private var shownID: String? {
        if groupID == nil, !userID.isEmpty, let known = book.ids[userID] { return known.isEmpty ? nil : known }
        if let a = avatarID, !a.isEmpty { return a }
        if groupID == nil, !userID.isEmpty, let f = book.filledID(userID) { return f }
        return nil
    }

    private var initial: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "?" : String(t.prefix(1)).uppercased()
    }

    private var pixels: CGFloat { (size * displayScale).rounded(.up) }

    private func picture(for key: String?) -> UIImage? {
        guard let key else { return nil }
        if let hit = AvatarImages.get(key) { return hit }
        if let l = loaded, l.key == key { return l.image }
        // the same person's picture from before a change stays until the new one is ready (no flash of the letter)
        if let l = loaded, l.owner == owner { return l.image }
        return nil
    }

    var body: some View {
        let id = shownID
        let key = id.map { "\(owner)/\($0)@\(Int(pixels))" }
        let image = picture(for: key)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    Circle().fill(Theme.avatarGradient)
                    Text(initial)
                        .font(.system(size: size * 0.4, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if online == true {
                Circle().fill(Theme.online).frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Circle().stroke(Theme.ground, lineWidth: 2))
            }
        }
        .task(id: key ?? "") {
            if groupID == nil, let a = avatarID, !a.isEmpty { book.fill(userID, a) }
            guard let key, let id, !token.isEmpty else { return }
            if let hit = AvatarImages.get(key) {
                loaded = (owner, key, hit)
                return
            }
            // a picture seen before is on disk (its id changes with the picture): shown at once, no download
            let diskKey = "avatar/\(owner)/\(id)"
            if let d = FileDiskCache.load(diskKey), let img = await AvatarImages.decode(d, maxPixels: pixels) {
                AvatarImages.put(img, key)
                if !Task.isCancelled { loaded = (owner, key, img) }
                return
            }
            let data = groupID != nil
                ? await APIClient.shared.groupAvatar(token: token, groupID: groupID ?? "", avatarID: id)
                : await APIClient.shared.avatar(token: token, userID: userID, avatarID: id)
            guard let data, !Task.isCancelled else { return }
            FileDiskCache.save(diskKey, data)
            guard let img = await AvatarImages.decode(data, maxPixels: pixels) else { return }
            AvatarImages.put(img, key)
            if !Task.isCancelled { loaded = (owner, key, img) }
        }
    }
}
