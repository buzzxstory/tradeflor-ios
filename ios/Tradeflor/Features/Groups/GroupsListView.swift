import SwiftUI
import UIKit

/// The Groups screen as on the website (GroupsView.tsx): "Groups" with the new-group button, "Search groups or @link"
/// (which also finds public groups), the folder chips, Archived, and the group rows with their long-press menu.
struct GroupsListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var groups: [GroupSummary] = []
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

    private var token: String { store.session?.token ?? "" }

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
                VStack(spacing: 0) {
                    header
                    SearchPill(placeholder: "groups.search", text: $query).padding(.horizontal, 16)
                    chips.padding(.top, 12).padding(.bottom, 8)
                    content
                    discover
                }
            }
            .refreshable { await load() }
            .background(Theme.panelGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: GroupSummary.self) { g in ChatView(chat: g.asConversation, canSend: g.can_send) }
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

    private var header: some View {
        HStack(spacing: 10) {
            Text("groups.title").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                Button { showCreate = true } label: { Label("grp.new", systemImage: "plus") }
                Button { showJoin = true } label: { Label("group.join", systemImage: "link") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18)).foregroundStyle(Theme.text)
                    .frame(width: 43, height: 43)
                    .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
            }
            .accessibilityLabel(Text("grp.new"))
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                FilterChip(title: NSLocalizedString("folders.all", comment: ""), selected: filter == "all") { filter = "all" }
                FilterChip(title: NSLocalizedString("folders.unread", comment: ""), selected: filter == "unread") { filter = "unread" }
                ForEach(folders) { f in
                    FilterChip(title: f.name, icon: "folder", selected: filter == f.id) { filter = f.id }
                }
                if archivedCount > 0 || showArchived {
                    FilterChip(title: showArchived ? NSLocalizedString("grp.back", comment: "")
                                                   : String(format: NSLocalizedString("grp.archived.n", comment: ""), archivedCount),
                               icon: showArchived ? "chevron.backward" : "archivebox", iconColor: Theme.accent,
                               selected: showArchived) { showArchived.toggle() }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var content: some View {
        if loading && groups.isEmpty {
            ProgressView().tint(Theme.accent).padding(.top, 60)
        } else if shown.isEmpty {
            Text(LocalizedStringKey(showArchived ? "grp.archived.none" : (filter == "unread" ? "grp.unread.none" : "groups.empty")))
                .font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 40)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(shown) { g in
                    NavigationLink(value: g) { row(g) }
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
                        .padding(.horizontal, 15).frame(height: 70)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    private func row(_ g: GroupSummary) -> some View {
        let p = prefs[g.conversation_id]
        let muted = p?.muted ?? false
        let mentions = extras[g.conversation_id]?.unread_mentions ?? 0
        return HStack(spacing: 16) {
            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(g.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if extras[g.conversation_id]?.verified == true {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundStyle(Theme.verified)
                    }
                    Spacer(minLength: 8)
                    if let d = g.lastDate {
                        Text(ChatRow.timeLabel(d)).font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(g.unread_count > 0 ? Theme.accent : Theme.faint)
                    }
                }
                HStack(spacing: 5) {
                    Text(preview(g)).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 6)
                    if muted { Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    if mentions > 0 {
                        Text("@").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.onAccent)
                            .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                            .accessibilityLabel(Text(String(format: NSLocalizedString("grp.mentions.n", comment: ""), mentions)))
                    }
                    if g.unread_count > 0 {
                        Text("\(g.unread_count)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(muted ? AnyShapeStyle(Theme.faint) : AnyShapeStyle(Theme.accent), in: Capsule())
                    } else if p?.marked_unread ?? false {
                        Circle().stroke(Theme.accent, lineWidth: 2).frame(width: 12, height: 12)
                    } else if p?.pinned ?? false {
                        Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Theme.accent).rotationEffect(.degrees(45))
                    }
                }
            }
        }
        .padding(.leading, 15).padding(.trailing, 14)
        .frame(height: 83)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
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

    private func preview(_ g: GroupSummary) -> String {
        if g.last_message.isEmpty { return String(format: NSLocalizedString("groups.members", comment: ""), g.member_count) }
        if let n = g.last_sender_name, !n.isEmpty { return "\(n): \(g.last_message)" }
        return g.last_message
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
        loading = true
        defer { loading = false }
        do {
            groups = try await APIClient.shared.groups(token: token)
            BadgeStore.shared.groups = groups.filter { $0.unread_count > 0 }.count
        } catch APIError.badCredentials {
            store.sessionExpired()
            return
        } catch {}
        if let list = try? await APIClient.shared.prefs(token: token) {
            prefs = Dictionary(list.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        extras = await APIClient.shared.grpListExtras(token: token)
        if folders.isEmpty { folders = (try? await APIClient.shared.folders(token: token)) ?? [] }
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
                } else if p.needs_approval ?? false {
                    Text("grp.approval.note").font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    primary((sent || (p.request_pending ?? false)) ? "grp.request.sent" : "grp.request.join") { Task { await join() } }
                        .disabled(sent || (p.request_pending ?? false))
                } else {
                    primary(busy ? "grp.joining" : "grp.join") { Task { await join() } }.disabled(busy)
                }
                if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                Button("grp.notnow") { dismiss() }.foregroundStyle(Theme.faint).padding(.top, 4)
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
