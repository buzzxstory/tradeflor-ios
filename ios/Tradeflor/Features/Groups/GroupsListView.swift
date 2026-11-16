import SwiftUI

/// The Groups screen as on the website: "Groups" with the new-group button, "Search groups or @link", the chips and
/// the group rows; a group opens in the shared chat screen.
struct GroupsListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var groups: [GroupSummary] = []
    @State private var loading = true
    @State private var path: [GroupSummary] = []
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var query = ""
    @State private var unreadOnly = false

    private var token: String { store.session?.token ?? "" }
    private var shown: [GroupSummary] {
        var g = unreadOnly ? groups.filter { $0.unread_count > 0 } : groups
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { g = g.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return g
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("groups.title").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
                        Spacer()
                        Menu {
                            Button { showCreate = true } label: { Label("group.create", systemImage: "plus") }
                            Button { showJoin = true } label: { Label("group.join", systemImage: "link") }
                        } label: {
                            Image(systemName: "person.2.badge.plus")
                                .font(.system(size: 17)).foregroundStyle(Theme.text)
                                .frame(width: 43, height: 43)
                                .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
                        }
                        .accessibilityLabel(Text("group.create"))
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                    SearchPill(placeholder: "groups.search", text: $query).padding(.horizontal, 16)
                    HStack(spacing: 7) {
                        FilterChip(title: NSLocalizedString("folders.all", comment: ""), selected: !unreadOnly) { unreadOnly = false }
                        FilterChip(title: NSLocalizedString("folders.unread", comment: ""), selected: unreadOnly) { unreadOnly = true }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    if loading && groups.isEmpty {
                        ProgressView().tint(Theme.accent).padding(.top, 60)
                    } else if shown.isEmpty {
                        Text("groups.empty").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 40)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { g in
                                NavigationLink(value: g) { row(g) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
            .background(Theme.panelGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: GroupSummary.self) { g in ChatView(chat: g.asConversation, canSend: g.can_send) }
            .sheet(isPresented: $showCreate) { CreateGroupView { id in Task { await open(id) } } }
            .sheet(isPresented: $showJoin) { JoinGroupView { id in Task { await open(id) } } }
        }
        .task { await load() }
        .onReceive(live.messages) { m in if m.conversation_id.hasPrefix("grp_") { Task { await load() } } }
    }

    private func row(_ g: GroupSummary) -> some View {
        HStack(spacing: 16) {
            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(g.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    if let d = g.lastDate {
                        Text(ChatRow.timeLabel(d)).font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(g.unread_count > 0 ? Theme.accent : Theme.faint)
                    }
                }
                HStack {
                    Text(preview(g)).font(.system(size: 15)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 6)
                    if g.unread_count > 0 {
                        Text("\(g.unread_count)").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22).background(Theme.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.leading, 15).padding(.trailing, 14)
        .frame(height: 83)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rowRule).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func preview(_ g: GroupSummary) -> String {
        if g.last_message.isEmpty { return String(format: NSLocalizedString("groups.members", comment: ""), g.member_count) }
        if let n = g.last_sender_name, !n.isEmpty { return "\(n): \(g.last_message)" }
        return g.last_message
    }

    private func open(_ id: String) async {
        await load()
        if let g = groups.first(where: { $0.conversation_id == id }) { path = [g] }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            groups = try await APIClient.shared.groups(token: token).sorted { $0.last_message_at > $1.last_message_at }
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {}
    }
}
