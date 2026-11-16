import SwiftUI

// Smart Focus for groups (backend/internal/messaging/focus.go, desktop/src/shared/lib/focusMatch.ts): show only the messages
// from important members, admins, mentions of me and replies to me. Saved per user on the server, versioned (409 = rebase).

struct GroupFocus: Codable, Equatable {
    var on = false
    var important: [String] = []
    var use_important = true
    var admins = true
    var mentions = true
    var replies = true

    var hasFilters: Bool { (use_important && !important.isEmpty) || admins || mentions || replies }
    var active: Bool { on && hasFilters }

    func matches(_ m: Message, me: String, roleOf: (String) -> String?) -> Bool {
        if use_important && important.contains(m.sender_id) { return true }
        if admins, let r = roleOf(m.sender_id), r == "owner" || r == "admin" { return true }
        if mentions, Self.mentionsMe(m.mentions, me) { return true }
        if replies && m.reply_sender_id == me && m.sender_id != me { return true }
        return false
    }

    private static func mentionsMe(_ raw: String?, _ me: String) -> Bool {
        guard let raw, let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return list.contains { ($0["user_id"] as? String) == me || ($0["user_id"] as? String) == "all" }
    }

    /// My changes (base -> mine) re-applied over another device's save.
    static func rebase(base: GroupFocus, mine: GroupFocus, theirs: GroupFocus) -> GroupFocus {
        var out = theirs
        if mine.on != base.on { out.on = mine.on }
        if mine.use_important != base.use_important { out.use_important = mine.use_important }
        if mine.admins != base.admins { out.admins = mine.admins }
        if mine.mentions != base.mentions { out.mentions = mine.mentions }
        if mine.replies != base.replies { out.replies = mine.replies }
        let added = mine.important.filter { !base.important.contains($0) }
        let removed = Set(base.important.filter { !mine.important.contains($0) })
        out.important = out.important.filter { !removed.contains($0) }
        for a in added where !out.important.contains(a) { out.important.append(a) }
        return out
    }
}

struct FocusDoc: Codable {
    var version: Int
    var focus: GroupFocus
}

extension APIClient {
    func getFocus(token: String, groupID: String) async throws -> FocusDoc {
        try JSONDecoder().decode(FocusDoc.self, from: try await getJSON("groups/\(groupID)/focus", token: token))
    }

    /// Saves with one automatic rebase when another device saved in between.
    func saveFocus(token: String, groupID: String, base: FocusDoc, focus: GroupFocus) async throws -> FocusDoc {
        func post(_ version: Int, _ f: GroupFocus) async throws -> (Int, Data) {
            let body: [String: Any] = ["base_version": version, "focus": [
                "on": f.on, "important": f.important, "use_important": f.use_important,
                "admins": f.admins, "mentions": f.mentions, "replies": f.replies,
            ]]
            let (data, http) = try await send(request("groups/\(groupID)/focus", method: "POST", token: token, body: body))
            return (http.statusCode, data)
        }
        var (code, data) = try await post(base.version, focus)
        if code == 409, let theirs = try? JSONDecoder().decode(FocusDoc.self, from: data) {
            let merged = GroupFocus.rebase(base: base.focus, mine: focus, theirs: theirs.focus)
            (code, data) = try await post(theirs.version, merged)
        }
        guard (200..<300).contains(code) else {
            throw APIError.refused(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return try JSONDecoder().decode(FocusDoc.self, from: data)
    }

    /// The group's history through my saved focus (oldest first).
    func focusPage(token: String, groupID: String, limit: Int) async -> [Message] {
        guard let data = try? await getJSON("messages?conversation_id=\(groupID)&focus=1&limit=\(limit)", token: token),
              let list = try? JSONDecoder().decode([Message]?.self, from: data) else { return [] }
        return list ?? []
    }
}

struct SmartFocusSheet: View {
    let groupID: String
    let members: [GroupMember]
    let me: String
    let initial: FocusDoc
    var onSaved: (FocusDoc) -> Void

    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var f: GroupFocus
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?

    init(groupID: String, members: [GroupMember], me: String, initial: FocusDoc, onSaved: @escaping (FocusDoc) -> Void) {
        self.groupID = groupID
        self.members = members
        self.me = me
        self.initial = initial
        self.onSaved = onSaved
        _f = State(initialValue: initial.focus)
    }

    private var others: [GroupMember] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return members.filter { $0.user_id != me && (q.isEmpty || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q)) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $f.on) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("focus.on").foregroundStyle(Theme.text)
                            Text("focus.on.note").font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    .tint(Theme.accent)
                }
                .listRowBackground(Theme.card)
                Section {
                    Toggle("focus.admins", isOn: $f.admins).tint(Theme.accent)
                    Toggle("focus.mentions", isOn: $f.mentions).tint(Theme.accent)
                    Toggle("focus.replies", isOn: $f.replies).tint(Theme.accent)
                    Toggle("focus.important", isOn: $f.use_important).tint(Theme.accent)
                } header: { Text("focus.show") } footer: {
                    if f.on && !f.hasFilters { Text("focus.none").foregroundStyle(Theme.danger) }
                }
                .listRowBackground(Theme.card)
                if f.use_important {
                    Section {
                        TextField("focus.search", text: $query).foregroundStyle(Theme.text)
                        ForEach(others) { m in
                            Button {
                                if let i = f.important.firstIndex(of: m.user_id) { f.important.remove(at: i) } else { f.important.append(m.user_id) }
                            } label: {
                                HStack(spacing: 10) {
                                    Avatar(token: store.session?.token ?? "", userID: m.user_id, avatarID: nil, title: m.title, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(m.title).foregroundStyle(Theme.text)
                                        Text("@\(m.username)").font(.caption).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: f.important.contains(m.user_id) ? "star.fill" : "star")
                                        .foregroundStyle(f.important.contains(m.user_id) ? Theme.accent : Theme.muted)
                                }
                            }
                        }
                    } header: { Text(String(format: NSLocalizedString("focus.important.n", comment: ""), f.important.count)) }
                    .listRowBackground(Theme.card)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.panelGradient.ignoresSafeArea())
            .navigationTitle(Text("focus.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("grp.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("grp.save.short").bold() } }
                        .disabled(saving || f == initial.focus)
                }
            }
        }
        .tfColorScheme()
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let doc = try await APIClient.shared.saveFocus(token: store.session?.token ?? "", groupID: groupID, base: initial, focus: f)
            onSaved(doc)
            dismiss()
        } catch {
            self.error = NSLocalizedString("focus.save.failed", comment: "")
        }
    }
}

/// The strip above a focused conversation.
struct FocusBanner: View {
    var showingAll: Bool
    var onToggle: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(Theme.accent)
            Text(LocalizedStringKey(showingAll ? "focus.banner.all" : "focus.banner"))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Button(action: onToggle) {
                Text(LocalizedStringKey(showingAll ? "focus.banner.back" : "focus.banner.showall")).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }.foregroundStyle(Theme.muted)
                .accessibilityLabel(Text("focus.title"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.header)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }
}
