import SwiftUI

/// The Groups tab: my groups, newest activity first; a group opens in the shared chat screen.
struct GroupsListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var groups: [GroupSummary] = []
    @State private var loading = true
    @State private var path: [GroupSummary] = []

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if loading && groups.isEmpty {
                    ProgressView()
                } else if groups.isEmpty {
                    Text("groups.empty").foregroundStyle(.secondary)
                } else {
                    List(groups) { g in
                        NavigationLink(value: g) { row(g) }
                            .listRowBackground(Theme.ground)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground.ignoresSafeArea())
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .navigationTitle(Text("groups.title"))
            .navigationDestination(for: GroupSummary.self) { g in ChatView(chat: g.asConversation, canSend: g.can_send) }
            .refreshable { await load() }
        }
        .task { await load() }
        .onReceive(live.messages) { m in if m.conversation_id.hasPrefix("grp_") { Task { await load() } } }
    }

    private func row(_ g: GroupSummary) -> some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(g.name).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if let d = g.lastDate {
                        Text(d, style: .date).font(.caption).foregroundStyle(g.unread_count > 0 ? Theme.accent : .secondary)
                    }
                }
                HStack {
                    Text(preview(g)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if g.unread_count > 0 {
                        Text("\(g.unread_count)").font(.caption2.bold()).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func preview(_ g: GroupSummary) -> String {
        if g.last_message.isEmpty { return String(format: NSLocalizedString("groups.members", comment: ""), g.member_count) }
        if let n = g.last_sender_name, !n.isEmpty { return "\(n): \(g.last_message)" }
        return g.last_message
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
