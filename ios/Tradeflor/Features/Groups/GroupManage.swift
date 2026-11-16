import SwiftUI

/// New group: name, description, public/private, and members picked from my chats.
struct CreateGroupView: View {
    let onCreated: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var isPublic = false
    @State private var people: [ConversationSummary] = []
    @State private var picked: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("group.name", text: $name)
                    TextField("group.about", text: $about, axis: .vertical).lineLimit(2...4)
                    Toggle("group.public", isOn: $isPublic).tint(Theme.accent)
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("group.members.pick")) {
                    ForEach(people) { c in
                        Button {
                            if picked.contains(c.peer_id) { picked.remove(c.peer_id) } else { picked.insert(c.peer_id) }
                        } label: {
                            HStack {
                                Avatar(token: token, userID: c.peer_id, avatarID: c.peer_avatar_id, title: c.title)
                                Text(c.title).foregroundStyle(.white)
                                Spacer()
                                Image(systemName: picked.contains(c.peer_id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("group.create"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("group.create.go") { Task { await create() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .task {
            people = ((try? await APIClient.shared.conversations(token: token)) ?? []).filter { $0.conversation_id.hasPrefix("dm_") }
        }
    }

    private func create() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let id = try await APIClient.shared.createGroup(token: token, name: name.trimmingCharacters(in: .whitespaces),
                                                            description: about, isPublic: isPublic, memberIDs: Array(picked))
            dismiss()
            onCreated(id)
        } catch APIError.refused(let why) {
            error = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            self.error = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// Join a group from an invite link or a public group link.
struct JoinGroupView: View {
    let onJoined: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var busy = false
    @State private var info: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("group.join.hint")) {
                    TextField("group.join.link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                .listRowBackground(Theme.surface)
                if let info { Section { Text(info).foregroundStyle(Theme.accent) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("group.join"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("group.join.go") { Task { await join() } }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func join() async {
        guard let token = store.session?.token else { return }
        busy = true
        defer { busy = false }
        do {
            let id = try await APIClient.shared.joinGroup(token: token, link: link)
            if id.isEmpty {
                info = NSLocalizedString("group.join.pending", comment: "")
            } else {
                dismiss()
                onJoined(id)
            }
        } catch APIError.refused(let why) {
            info = why.isEmpty ? NSLocalizedString("group.join.bad", comment: "") : why
        } catch {
            info = NSLocalizedString("login.error.network", comment: "")
        }
    }
}

/// Group info: name and description (editable by admins), members with roles, add / remove / make admin,
/// an invite link to share, and leave.
struct GroupInfoView: View {
    let groupID: String
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var group: GroupDetail?
    @State private var members: [GroupMemberFull] = []
    @State private var name = ""
    @State private var about = ""
    @State private var addName = ""
    @State private var invite: String?
    @State private var problem: String?
    @State private var confirmLeave = false

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }
    private var admin: Bool { group?.isAdmin ?? false }

    var body: some View {
        NavigationStack {
            List {
                if let g = group {
                    Section {
                        HStack(spacing: 14) {
                            Avatar(token: token, userID: "", avatarID: g.avatar_id, title: g.name, groupID: g.conversation_id)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(g.name).font(.headline).foregroundStyle(.white)
                                Text(String(format: NSLocalizedString("groups.members", comment: ""), g.member_count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if admin {
                            TextField("group.name", text: $name)
                            TextField("group.about", text: $about, axis: .vertical).lineLimit(2...5)
                            Button("settings.save") { Task { await save() } }
                                .disabled(name == g.name && about == g.description)
                        } else if !g.description.isEmpty {
                            Text(g.description).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Theme.surface)

                    if admin || g.can_invite == true {
                        Section(header: Text("group.invite")) {
                            HStack {
                                TextField("group.add.username", text: $addName)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                Button("group.add") { Task { await add() } }.disabled(addName.count < 3)
                            }
                            if let invite {
                                ShareLink(item: invite) { Label(invite, systemImage: "square.and.arrow.up").lineLimit(1) }
                            } else {
                                Button { Task { await makeInvite() } } label: { Label("group.invite.link", systemImage: "link") }
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }

                Section(header: Text("group.members")) {
                    ForEach(members) { m in
                        HStack {
                            Avatar(token: token, userID: m.user_id, avatarID: m.avatar_id, title: m.title)
                            VStack(alignment: .leading) {
                                Text(m.user_id == me ? NSLocalizedString("chat.you", comment: "") : m.title).foregroundStyle(.white)
                                Text("@" + m.username).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.role != "member" {
                                Text(LocalizedStringKey("group.role." + m.role)).font(.caption).foregroundStyle(Theme.accent)
                            }
                        }
                        .swipeActions {
                            if admin && m.user_id != me && m.role != "owner" {
                                Button(role: .destructive) { Task { await remove(m) } } label: { Label("group.remove", systemImage: "person.fill.xmark") }
                                Button { Task { await toggleAdmin(m) } } label: {
                                    Label(LocalizedStringKey(m.role == "admin" ? "group.admin.off" : "group.admin.on"), systemImage: "star")
                                }
                                .tint(Theme.accent)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("group.leave", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("group.info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .confirmationDialog(Text("group.leave.confirm"), isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("group.leave", role: .destructive) { Task { await leave() } }
            }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let g = try? await APIClient.shared.groupInfo(token: token, id: groupID) {
            group = g
            name = g.name
            about = g.description
        }
        members = (try? await APIClient.shared.list(GroupMemberFull.self, "groups/\(groupID)/members", token: token)) ?? members
    }

    private func run(_ work: () async throws -> Void) async {
        do { try await work(); await load() } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }

    private func save() async { await run { try await APIClient.shared.updateGroup(token: token, id: groupID, name: name, description: about) } }
    private func add() async {
        await run { try await APIClient.shared.addGroupMember(token: token, id: groupID, username: addName) }
        addName = ""
    }
    private func remove(_ m: GroupMemberFull) async { await run { try await APIClient.shared.removeGroupMember(token: token, id: groupID, userID: m.user_id) } }
    private func toggleAdmin(_ m: GroupMemberFull) async {
        await run { try await APIClient.shared.setGroupRole(token: token, id: groupID, userID: m.user_id, admin: m.role != "admin") }
    }
    private func makeInvite() async {
        do { invite = try await APIClient.shared.createInvite(token: token, id: groupID) } catch APIError.refused(let why) {
            problem = why
        } catch { problem = NSLocalizedString("chat.action.failed", comment: "") }
    }
    private func leave() async {
        do {
            try await APIClient.shared.removeGroupMember(token: token, id: groupID, userID: "")
            dismiss()
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("chat.action.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("chat.action.failed", comment: "")
        }
    }
}
