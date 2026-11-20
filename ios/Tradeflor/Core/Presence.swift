import SwiftUI

// Last seen and online, as in WhatsApp (server d4d2e77; website shared/lib/lastSeen.ts, LastSeenPrivacy.tsx):
// online = the app is in front; "last seen today at 4:23 AM" … or nothing when it is hidden or unknown. Never "Offline".

struct PresenceInfo: Decodable {
    let user_id: String?
    let online: Bool?
    let last_seen: Int64?
    let hidden: Bool?
}

struct PresencePrivacy: Codable, Equatable {
    var last_seen: String // everyone | contacts | except | only | nobody
    var online: String    // everyone | same | only
    /// The lists (accepted contacts): hidden from my last seen ("except"), the only ones who see it ("only"), the only
    /// ones who see me online (online "only"). nil on a server from before the lists.
    var last_seen_except: [String]? = nil
    var last_seen_only: [String]? = nil
    var online_only: [String]? = nil
}

extension APIClient {
    /// What I may see of someone: 404 (nil) when nothing is shared with me.
    func presence(token: String, userID: String) async -> PresenceInfo? {
        let id = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let data = try? await getJSON("presence/\(id)", token: token) else { return nil }
        return try? JSONDecoder().decode(PresenceInfo.self, from: data)
    }

    func presencePrivacy(token: String) async throws -> PresencePrivacy {
        let data = try await getJSON("privacy/presence", token: token)
        do { return try JSONDecoder().decode(PresencePrivacy.self, from: data) } catch { throw APIError.decoding }
    }

    func setPresencePrivacy(token: String, _ p: PresencePrivacy) async throws {
        var body: [String: Any] = ["last_seen": p.last_seen, "online": p.online]
        if let l = p.last_seen_except { body["last_seen_except"] = l }
        if let l = p.last_seen_only { body["last_seen_only"] = l }
        if let l = p.online_only { body["online_only"] = l }
        _ = try await postJSON("privacy/presence", token: token, body: body)
    }
}

enum LastSeen {
    // made once: the chat's header line read them on every redraw
    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }
    private static let weekday = template("EEEE")
    private static let monthDay = template("MMMd")
    private static let monthDayYear = template("yMMMd")

    private static func clock(_ d: Date) -> String { clockFormat.string(from: d) }

    /// "last seen today at 4:23 AM", "… yesterday at …", "… Monday at …" (within a week), "… Nov 2 at …" (+ year).
    static func text(_ at: Int64, now: Date = Date()) -> String? {
        guard at > 0 else { return nil }
        let d = Date(timeIntervalSince1970: Double(ChatEdit.secs(at)))
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        let t = clock(d)
        if days <= 0 { return String(format: NSLocalizedString("ls.today", comment: ""), t) }
        if days == 1 { return String(format: NSLocalizedString("ls.yesterday", comment: ""), t) }
        let f = days < 7 ? weekday : (cal.component(.year, from: d) == cal.component(.year, from: now) ? monthDay : monthDayYear)
        return String(format: NSLocalizedString("ls.on", comment: ""), f.string(from: d), t)
    }

    /// What goes under a name: "online", "last seen …", or nil (show nothing).
    static func line(online: Bool, lastSeen: Int64?, hidden: Bool, now: Date = Date()) -> String? {
        if online { return NSLocalizedString("ls.online", comment: "") }
        if hidden { return nil }
        return lastSeen.flatMap { text($0, now: now) }
    }
}

/// Settings > Privacy > Last seen and online (WhatsApp's page, in TRADEFLOR's look, with lists): who sees my last seen
/// (everyone, my contacts, my contacts except…, only these…, nobody) and who sees me online (everyone, same as last seen,
/// only these… — a special list). Saved at once, the old value back on failure. Lists: accepted contacts only
/// (server contract proposed 2026-11-20: last_seen_except / last_seen_only / online_only on privacy/presence).
struct LastSeenPrivacyView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var value: PresencePrivacy?
    @State private var error: String?
    @State private var contacts: [ContactEntry] = []
    @State private var picking: ListKind?

    enum ListKind: String, Identifiable {
        case lastSeenExcept, lastSeenOnly, onlineOnly
        var id: String { rawValue }
    }

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("ls.row", comment: ""), subtitle: NSLocalizedString("ls.page.sub", comment: ""), icon: "eye") {
            if let v = value {
                summaryCard(v)
                section("ls.who.lastseen", icon: "clock") {
                    option("everyone", v.last_seen, "globe", "ls.everyone", "ls.everyone.sub") { set { $0.last_seen = "everyone" } }
                    option("contacts", v.last_seen, "person.2", "ls.contacts", "ls.contacts.sub") { set { $0.last_seen = "contacts" } }
                    option("except", v.last_seen, "person.2.slash", "ls.except", "ls.except.sub") {
                        set { $0.last_seen = "except" }
                        if (value?.last_seen_except ?? []).isEmpty { picking = .lastSeenExcept }
                    }
                    if v.last_seen == "except" { listRow(.lastSeenExcept, v.last_seen_except ?? [], "ls.hidden.from") }
                    option("only", v.last_seen, "person.crop.circle.badge.checkmark", "ls.only", "ls.only.sub") {
                        set { $0.last_seen = "only" }
                        if (value?.last_seen_only ?? []).isEmpty { picking = .lastSeenOnly }
                    }
                    if v.last_seen == "only" { listRow(.lastSeenOnly, v.last_seen_only ?? [], "ls.shared.with") }
                    option("nobody", v.last_seen, "eye.slash", "ls.nobody", "ls.nobody.sub", last: true) { set { $0.last_seen = "nobody" } }
                }
                section("ls.who.online", icon: "circle.fill") {
                    option("everyone", v.online, "globe", "ls.everyone", "ls.online.everyone.sub") { set { $0.online = "everyone" } }
                    option("same", v.online, "equal.circle", "ls.same", "ls.same.sub") { set { $0.online = "same" } }
                    option("only", v.online, "star.circle", "ls.online.only", "ls.online.only.sub", last: v.online != "only") {
                        set { $0.online = "only" }
                        if (value?.online_only ?? []).isEmpty { picking = .onlineOnly }
                    }
                    if v.online == "only" { listRow(.onlineOnly, v.online_only ?? [], "ls.online.with", last: true) }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(SetUI.accent)
                    Text("ls.note").font(.system(size: 12.5)).foregroundStyle(SetUI.sub).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
            } else if let error {
                Text(error).foregroundStyle(Theme.faint)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task {
            do { value = try await APIClient.shared.presencePrivacy(token: token) } catch {
                self.error = NSLocalizedString("ls.failed", comment: "")
            }
            contacts = ((try? await APIClient.shared.ctContacts(token: token)) ?? []).filter { $0.mutual != false }
        }
        .fullScreenCover(item: $picking) { kind in
            ContactListPicker(token: token, title: NSLocalizedString(Self.pickerTitle(kind), comment: ""), contacts: contacts,
                              selected: Set(ids(kind))) { chosen in
                set { p in
                    switch kind {
                    case .lastSeenExcept: p.last_seen_except = chosen
                    case .lastSeenOnly: p.last_seen_only = chosen
                    case .onlineOnly: p.online_only = chosen
                    }
                }
            }
        }
    }

    private static func pickerTitle(_ k: ListKind) -> String {
        switch k {
        case .lastSeenExcept: return "ls.pick.except"
        case .lastSeenOnly: return "ls.pick.only"
        case .onlineOnly: return "ls.pick.online"
        }
    }

    private func ids(_ k: ListKind) -> [String] {
        switch k {
        case .lastSeenExcept: return value?.last_seen_except ?? []
        case .lastSeenOnly: return value?.last_seen_only ?? []
        case .onlineOnly: return value?.online_only ?? []
        }
    }

    // MARK: parts

    /// What others see right now, in one line, with an eye that is open or closed.
    private func summaryCard(_ v: PresencePrivacy) -> some View {
        let hidden = v.last_seen == "nobody" && v.online == "same"
        return HStack(spacing: 14) {
            Image(systemName: hidden ? "eye.slash.fill" : "eye.fill").font(.system(size: 20, weight: .semibold))
                .foregroundStyle(hidden ? SetUI.sub : SetUI.accent)
                .frame(width: 48, height: 48)
                .background(Theme.dyn(0x08D9D9, 0x00A8B5, 0.12, 0.12), in: Circle())
                .overlay(Circle().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.35, 0.4), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("ls.summary.title").font(.system(size: 13, weight: .semibold)).foregroundStyle(SetUI.sub)
                Text(verbatim: Self.summary(v)).font(.system(size: 16, weight: .bold)).foregroundStyle(SetUI.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background { SettingsSweep(peak: 0.28, tail: 0.08, share: 0.55).opacity(0.8) }
        .sCardChrome()
    }

    private func section<C: View>(_ title: String, icon: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .bold)).textCase(.uppercase)
            }
            .foregroundStyle(SetUI.accent).padding(.leading, 6)
            VStack(spacing: 0) { rows() }.sCardChrome()
        }
    }

    private func option(_ key: String, _ current: String, _ icon: String, _ title: String, _ sub: String, last: Bool = false,
                        _ pick: @escaping () -> Void) -> some View {
        let on = key == current
        return VStack(spacing: 0) {
            Button { if !on { pick() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? SetUI.accent : SetUI.sub)
                        .frame(width: 34, height: 34)
                        .background(on ? Theme.dyn(0x08D9D9, 0x00A8B5, 0.14, 0.12) : Color.clear, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(title)).font(.system(size: 16, weight: on ? .semibold : .regular)).foregroundStyle(SetUI.text)
                        Text(LocalizedStringKey(sub)).font(.system(size: 12.5)).foregroundStyle(SetUI.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    ZStack {
                        Circle().stroke(on ? SetUI.accent : Theme.dyn(0x7F98A4, 0x46657A, 0.6, 0.5), lineWidth: 2).frame(width: 22, height: 22)
                        if on { Circle().fill(SetUI.accent).frame(width: 12, height: 12) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(on ? Theme.dyn(0x08D9D9, 0x00A8B5, 0.05, 0.05) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            if !last { Rectangle().fill(SetUI.edge).frame(height: 1).padding(.leading, 60) }
        }
    }

    /// The chosen people of a list: their faces, how many, and "Change".
    private func listRow(_ kind: ListKind, _ ids: [String], _ label: String, last: Bool = false) -> some View {
        let chosen = contacts.filter { ids.contains($0.user_id) }
        return VStack(spacing: 0) {
            Button { picking = kind } label: {
                HStack(spacing: 10) {
                    HStack(spacing: -10) {
                        ForEach(chosen.prefix(4)) { c in
                            Avatar(token: token, userID: c.user_id, avatarID: nil, title: c.title, size: 30)
                                .overlay(Circle().stroke(Theme.dyn(0x03202B, 0xFFFFFF), lineWidth: 2))
                        }
                        if chosen.isEmpty {
                            Image(systemName: "person.badge.plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
                                .frame(width: 30, height: 30).background(Theme.dyn(0x08D9D9, 0x00A8B5, 0.12, 0.12), in: Circle())
                        }
                    }
                    Text(verbatim: String(format: NSLocalizedString(label, comment: ""), ids.count))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.text)
                    Spacer()
                    Text("ls.change").font(.system(size: 13, weight: .bold)).foregroundStyle(SetUI.accent)
                    Image(systemName: "chevron.forward").font(.system(size: 12, weight: .bold)).foregroundStyle(SetUI.accent)
                }
                .padding(.leading, 60).padding(.trailing, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !last { Rectangle().fill(SetUI.edge).frame(height: 1).padding(.leading, 60) }
        }
    }

    // MARK: saving

    private func set(_ change: (inout PresencePrivacy) -> Void) {
        guard var next = value else { return }
        change(&next)
        save(next)
    }

    private func save(_ next: PresencePrivacy) {
        let old = value
        value = next
        error = nil
        Task {
            do { try await APIClient.shared.setPresencePrivacy(token: token, next) } catch {
                value = old
                self.error = NSLocalizedString("ls.save.failed", comment: "")
            }
        }
    }

    static func summary(_ p: PresencePrivacy?) -> String {
        guard let p else { return "" }
        let key: String
        switch p.last_seen {
        case "contacts": key = "ls.contacts"
        case "nobody": key = "ls.nobody"
        case "except": key = "ls.except"
        case "only": key = "ls.only"
        default: key = "ls.everyone"
        }
        let label = NSLocalizedString(key, comment: "")
        if p.online == "only" { return String(format: NSLocalizedString("ls.summary.onlinelist", comment: ""), label, (p.online_only ?? []).count) }
        // "My contacts, online: Everyone" when online is shared more widely than last seen (website summary())
        if p.online == "everyone" && p.last_seen != "everyone" { return String(format: NSLocalizedString("ls.summary.online", comment: ""), label) }
        return label
    }
}

/// Picks people from my accepted contacts (searchable, ticks), for a privacy list.
struct ContactListPicker: View {
    let token: String
    let title: String
    let contacts: [ContactEntry]
    let done: ([String]) -> Void
    @State private var chosen: Set<String>
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(token: String, title: String, contacts: [ContactEntry], selected: Set<String>, done: @escaping ([String]) -> Void) {
        self.token = token
        self.title = title
        self.contacts = contacts
        self.done = done
        _chosen = State(initialValue: selected)
    }

    private var shown: [ContactEntry] {
        let q = ListSearch.needle(query)
        let all = contacts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard !q.isEmpty else { return all }
        return all.filter { ListSearch.needle($0.title).contains(q) || ListSearch.needle($0.username).contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ListSearchField(placeholder: "ls.pick.search", text: $query).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if contacts.isEmpty {
                            Text("ls.pick.empty").font(.system(size: 14)).foregroundStyle(SetUI.sub).padding(.top, 40)
                        }
                        ForEach(shown) { c in
                            let on = chosen.contains(c.user_id)
                            Button {
                                if on { chosen.remove(c.user_id) } else { chosen.insert(c.user_id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(token: token, userID: c.user_id, avatarID: nil, title: c.title, size: 42)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: c.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
                                        Text(verbatim: "@" + c.username).font(.system(size: 13)).foregroundStyle(SetUI.sub)
                                    }
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22)).foregroundStyle(on ? SetUI.accent : SetUI.sub)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .clipped()
            }
            .background(SettingsBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { done(Array(chosen)); dismiss() } label: {
                        Text(verbatim: String(format: NSLocalizedString("ls.pick.done", comment: ""), chosen.count)).fontWeight(.bold)
                    }
                }
            }
        }
        .tfColorScheme()
    }
}
