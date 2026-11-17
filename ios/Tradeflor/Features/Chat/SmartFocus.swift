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
    @FocusState private var searching: Bool

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
        // the website's Important members dialog in the platform colours (styles/38-smart-focus.css .fx-members)
        VStack(spacing: 0) {
            head
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card {
                        Toggle(isOn: $f.on) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("focus.on").font(.system(size: 15, weight: .semibold)).foregroundStyle(SFLook.text)
                                Text("focus.on.note").font(.system(size: 12.5)).foregroundStyle(SFLook.muted)
                            }
                        }
                        .tint(SFLook.cyan)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                    }
                    sectionLabel(Text("focus.show"))
                    card {
                        toggleRow("focus.admins", $f.admins)
                        hairline
                        toggleRow("focus.mentions", $f.mentions)
                        hairline
                        toggleRow("focus.replies", $f.replies)
                        hairline
                        toggleRow("focus.important", $f.use_important)
                    }
                    if f.on && !f.hasFilters {
                        Text("focus.none").font(.system(size: 12.5)).foregroundStyle(Theme.hex(0xFF8A8A))
                    }
                    if f.use_important { importantMembers }
                    if let error {
                        Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.hex(0xFF8A8A))
                    }
                }
                .padding(16)
            }
            footer
        }
        .background(SFLook.dialog.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .tfColorScheme()
    }

    // MARK: - look (38-smart-focus.css)

    private var head: some View {
        HStack {
            Text("focus.title").font(.system(size: 18, weight: .bold)).tracking(0.18).foregroundStyle(SFLook.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.hex(0xEEF4F7))
                    .frame(width: 34, height: 34)
                    .background(Theme.hex(0x01141B, 0.7), in: Circle())
                    .overlay(Circle().stroke(Theme.hex(0x50AAC8, 0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("grp.cancel"))
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hex(0x288CAA, 0.22)).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Text("grp.cancel").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.hex(0xEEF5F8))
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.hex(0x021A23), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hex(0x3C96B4, 0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            Button { Task { await save() } } label: {
                Group {
                    if saving { ProgressView().tint(Theme.hex(0x052332)) } else { Text("grp.save.short").font(.system(size: 15, weight: .bold)) }
                }
                .foregroundStyle(Theme.hex(0x052332))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(LinearGradient(stops: [.init(color: Theme.hex(0x5AF6FC), location: 0), .init(color: Theme.hex(0x20E4EE), location: 0.45),
                                                   .init(color: Theme.hex(0x03D2DC), location: 1)], startPoint: .top, endPoint: .bottom), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hex(0x78FAFF, 0.7), lineWidth: 1.5))
                .shadow(color: Theme.hex(0x12E0F0, 0.4), radius: 9)
            }
            .buttonStyle(.plain)
            .disabled(saving || f == initial.focus)
            .opacity(saving || f == initial.focus ? 0.55 : 1)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hex(0x288CAA, 0.22)).frame(height: 1) }
    }

    @ViewBuilder private var importantMembers: some View {
        // search
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(SFLook.label)
            TextField("", text: $query, prompt: Text("focus.search").foregroundColor(SFLook.label))
                .font(.system(size: 15)).foregroundStyle(SFLook.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($searching)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.hex(0x01141B, 0.6), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(searching ? Theme.hex(0x12E0F0, 0.8) : Theme.hex(0x287896, 0.55), lineWidth: 1.5))
        .shadow(color: searching ? Theme.hex(0x12E0F0, 0.14) : .clear, radius: 3)
        // chosen
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(Text(String(format: NSLocalizedString("focus.important.n", comment: ""), f.important.count)))
            if !f.important.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(f.important, id: \.self) { uid in chip(uid) }
                    }
                }
            }
        }
        // members
        LazyVStack(spacing: 0) {
            ForEach(Array(others.enumerated()), id: \.element.id) { i, m in
                if i > 0 { hairline }
                memberRow(m)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.hex(0x041D26), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hex(0x78BED2, 0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func memberRow(_ m: GroupMember) -> some View {
        let on = f.important.contains(m.user_id)
        return Button { toggle(m.user_id) } label: {
            HStack(spacing: 10) {
                Avatar(token: store.session?.token ?? "", userID: m.user_id, avatarID: nil, title: m.title, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SFLook.text).lineLimit(1)
                    Text("@\(m.username)").font(.system(size: 12)).foregroundStyle(SFLook.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                tick(on)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(LinearGradient(stops: [.init(color: Theme.hex(0x2FF0F3, 0.12), location: 0), .init(color: Theme.hex(0x2FF0F3, 0.02), location: 0.7)],
                                                          startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The round-cornered tick: empty soul square, or the cyan gradient with a dark check and a glow.
    private func tick(_ on: Bool) -> some View {
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: 7).fill(SFLook.cyanGradient)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.hex(0x032229))
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Theme.hex(0x01141B, 0.7))
                RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hex(0x50AAC8, 0.55), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .shadow(color: on ? Theme.hex(0x2FF0F3, 0.4) : .clear, radius: 5)
    }

    private func chip(_ uid: String) -> some View {
        let name = members.first(where: { $0.user_id == uid })?.title ?? NSLocalizedString("qx.focus.former", comment: "")
        return HStack(spacing: 5) {
            Text(name).font(.system(size: 13, weight: .bold)).lineLimit(1)
            Button { toggle(uid) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("grp.cancel") + Text(" " + name))
        }
        .foregroundStyle(Theme.hex(0x032229))
        .padding(.leading, 11).padding(.trailing, 9).frame(height: 28)
        .background(SFLook.cyanGradient, in: Capsule())
    }

    private func toggleRow(_ key: LocalizedStringKey, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) { Text(key).font(.system(size: 15)).foregroundStyle(SFLook.text) }
            .tint(SFLook.cyan)
            .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 4)
            .background(Theme.hex(0x041D26), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hex(0x78BED2, 0.12), lineWidth: 1))
    }

    private func sectionLabel(_ t: Text) -> some View {
        t.font(.system(size: 11, weight: .bold)).tracking(0.88).textCase(.uppercase).foregroundStyle(SFLook.label)
    }

    private var hairline: some View { Rectangle().fill(Theme.hex(0x78BED2, 0.06)).frame(height: 1) }

    private func toggle(_ uid: String) {
        if let i = f.important.firstIndex(of: uid) { f.important.remove(at: i) } else { f.important.append(uid) }
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

/// Smart Focus colours (styles/38-smart-focus.css, .fx-members): the one colour soul, cyan ticks and chips.
private enum SFLook {
    static let text = Theme.hex(0xF4F8FB)
    static let muted = Theme.hex(0x7F9AA7)
    static let label = Theme.hex(0x6F93A3)
    static let cyan = Theme.hex(0x2FF0F3)
    static let cyanGradient = LinearGradient(colors: [Theme.hex(0x2FF0F3), Theme.hex(0x08A8B8)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// radial rgba(6,70,90,.35) at the top-left over #03202b -> #021821 (55%) -> #01141B
    static var dialog: some View {
        ZStack {
            LinearGradient(stops: [.init(color: Theme.hex(0x03202B), location: 0), .init(color: Theme.hex(0x021821), location: 0.55),
                                   .init(color: Theme.hex(0x01141B), location: 1)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.hex(0x06465A, 0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 340)
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
        .background(Theme.soul)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderStrong).frame(height: 1) }
    }
}
