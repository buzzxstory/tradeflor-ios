import SwiftUI

/// Admin Center (desktop/src/features/admin/AdminCenter.tsx): only shown when GET /admin/me returns a role.
/// Overview, Users (search, detail, suspend / restore) and the TRADEFLOR Official statuses (publish, remove, delete).
struct AdminCenterPage: View {
    let role: String
    @EnvironmentObject private var store: SessionStore
    @State private var tab = ""
    @State private var me: AdminMe?
    @State private var openUser: AdminUser?

    private var tabs: [(String, String)] {
        guard let me else { return [] }
        var t: [(String, String)] = []
        if me.users == true { t += [("overview", "adm.overview"), ("users", "adm.users")] }
        if me.content == true { t += [("official", "adm.official"), ("library", "adm.library")] }
        if me.audit == true { t.append(("audit", "adm.audit")) }
        t.append(("settings", "adm.settings"))
        return t
    }

    var body: some View {
        SettingsPage(title: NSLocalizedString("adm.title", comment: ""), subtitle: NSLocalizedString("adm.sub", comment: "")) {
            if let me {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(tabs, id: \.0) { t in
                            FilterChip(title: NSLocalizedString(t.1, comment: ""), selected: tab == t.0) { tab = t.0 }
                        }
                    }
                }
                switch tab {
                case "users": AdminUsersView(me: me)
                case "official": AdminOfficialView(library: false, me: me)
                case "library": AdminOfficialView(library: true, me: me)
                case "audit": AdminAuditView(onOpenUser: open)
                case "settings": AdminSettingsView(me: me, onOpenUser: open)
                default: AdminOverviewView(onOpenUser: open)
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task {
            me = await APIClient.shared.stAdminMe(token: store.session?.token ?? "")
            if tab.isEmpty { tab = tabs.first?.0 ?? "settings" }
        }
        .sheet(item: $openUser) { u in
            if let me { AdminUserSheet(user: u, me: me) {} }
        }
    }

    private func open(_ id: String) {
        Task { openUser = await APIClient.shared.admUser(token: store.session?.token ?? "", id: id) }
    }
}

private struct AdminOverviewView: View {
    var onOpenUser: (String) -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var o: AdminOverview?
    @State private var failed = false

    var body: some View {
        Group {
            if let o {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    stat("adm.total", o.total)
                    stat("adm.today", o.today)
                    stat("adm.7d", o.last_7_days)
                    stat("adm.30d", o.last_30_days)
                    stat("adm.active24", o.active_24h)
                    stat("adm.active7", o.active_7d)
                    stat("adm.online", o.online)
                    stat("adm.verified", o.verified)
                    stat("adm.unverified", o.unverified)
                    stat("adm.suspended", o.suspended)
                    stat("adm.official.live", o.official_live)
                    stat("adm.official.views", o.official_views)
                }
                if let d = o.daily, !d.isEmpty {
                    AdminBars(daily: d, weekly: o.weekly ?? [], monthly: o.monthly ?? [])
                }
                if let r = o.recent {
                    TFSectionLabel(text: NSLocalizedString("adm.recent", comment: ""))
                    TFCard {
                        if r.isEmpty { Text("adm.recent.none").font(.system(size: 12)).foregroundStyle(Theme.faint).padding(12) }
                        ForEach(Array(r.enumerated()), id: \.element.id) { i, u in
                            Button { onOpenUser(u.id) } label: {
                                HStack(spacing: 10) {
                                    Avatar(token: store.session?.token ?? "", userID: u.id, avatarID: u.avatar_id.isEmpty ? nil : u.avatar_id,
                                           title: u.display_name.isEmpty ? u.username : u.display_name, size: 34, online: u.online)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(u.display_name.isEmpty ? u.username : u.display_name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                        Text("@\(u.username) · \(AdminFmt.date(u.created_at))").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                    }
                                    Spacer()
                                    if !u.country.isEmpty { Text(IdentityCardFace.flag(u.country)) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            if i < r.count - 1 { TFDivider() }
                        }
                    }
                }
            } else if failed {
                Text("adm.failed").font(.system(size: 13)).foregroundStyle(Theme.faint)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task {
            do { o = try await APIClient.shared.stAdminOverview(token: store.session?.token ?? "") } catch { failed = true }
        }
    }

    private func stat(_ key: String, _ v: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(key)).font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("\(v)").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
    }
}

private struct AdminUsersView: View {
    let me: AdminMe
    @EnvironmentObject private var store: SessionStore
    @State private var query = ""
    @State private var page = 1
    @State private var data: AdminUsersPage?
    @State private var open: AdminUser?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchPill(placeholder: "adm.search", text: $query)
                .onSubmit { page = 1; Task { await load() } }
                .onChange(of: query) { _ in page = 1; Task { try? await Task.sleep(nanoseconds: 400_000_000); await load() } }
            if let d = data {
                Text(String(format: NSLocalizedString("adm.count", comment: ""), d.total)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                TFCard {
                    ForEach(Array((d.users ?? []).enumerated()), id: \.element.id) { i, u in
                        Button { open = u } label: {
                            HStack(spacing: 10) {
                                Avatar(token: token, userID: u.id, avatarID: u.avatar_id.isEmpty ? nil : u.avatar_id,
                                       title: u.display_name.isEmpty ? u.username : u.display_name, size: 36, online: u.online)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(u.display_name.isEmpty ? u.username : u.display_name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text("@\(u.username) · \(u.pin)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                Text(LocalizedStringKey("adm.status." + u.status)).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(u.status == "suspended" ? Theme.danger : (u.status == "pending" ? Theme.gold : Theme.buy))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        if i < (d.users ?? []).count - 1 { TFDivider() }
                    }
                }
                HStack {
                    Button("adm.prev") { page -= 1; Task { await load() } }.disabled(page <= 1)
                    Spacer()
                    Text("\(page)").foregroundStyle(Theme.faint)
                    Spacer()
                    Button("adm.next") { page += 1; Task { await load() } }.disabled(page * d.limit >= d.total)
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
        .sheet(item: $open) { u in AdminUserSheet(user: u, me: me) { Task { await load() } } }
    }

    private func load() async {
        data = try? await APIClient.shared.stAdminUsers(token: token, query: query, page: page)
    }
}

private struct AdminUserSheet: View {
    let user: AdminUser
    let me: AdminMe
    let onChange: () -> Void
    @State private var confirmOwner = false
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var hours = 0
    @State private var note: String?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("signup.username", value: "@" + user.username)
                    LabeledContent("PIN", value: user.pin)
                    LabeledContent("signup.email", value: user.email)
                    if !user.phone.isEmpty { LabeledContent("set.phone", value: user.phone) }
                    LabeledContent("set.country", value: user.country)
                    LabeledContent("set.joined", value: Date(timeIntervalSince1970: Double(user.created_at)).formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("adm.status", value: NSLocalizedString("adm.status." + user.status, comment: ""))
                    if let r = user.suspend_reason, !r.isEmpty { LabeledContent("adm.reason", value: r) }
                }
                .listRowBackground(Theme.surface)
                if user.status == "suspended" {
                    Section {
                        Button("adm.restore") {
                            Task {
                                do { try await APIClient.shared.stAdminRestore(token: token, userID: user.id); onChange(); dismiss() } catch {
                                    note = NSLocalizedString("settings.failed", comment: "")
                                }
                            }
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.surface)
                } else if user.type != "administrator" {
                    Section(header: Text("adm.suspend")) {
                        TextField("adm.reason", text: $reason)
                        Picker("adm.duration", selection: $hours) {
                            Text("adm.d.24h").tag(24)
                            Text("adm.d.7d").tag(168)
                            Text("adm.d.30d").tag(720)
                            Text("adm.d.forever").tag(0)
                        }
                        Button("adm.suspend", role: .destructive) {
                            Task {
                                do {
                                    try await APIClient.shared.stAdminSuspend(token: token, userID: user.id, reason: reason, hours: hours)
                                    onChange()
                                    dismiss()
                                } catch APIError.refused(let why) {
                                    note = why
                                } catch {
                                    note = NSLocalizedString("settings.failed", comment: "")
                                }
                            }
                        }
                        .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .listRowBackground(Theme.surface)
                }
                if me.roles == true && user.status == "active" && user.id != store.session?.userID {
                    Section(header: Text("adm.role.title")) {
                        Picker("adm.role.title", selection: Binding(get: { user.role ?? "" }, set: { r in
                            if r == "owner" { confirmOwner = true } else { setRole(r) }
                        })) {
                            Text("adm.role.none").tag("")
                            Text("adm.role.content").tag("content")
                            Text("adm.role.admin").tag("admin")
                            Text("adm.role.owner").tag("owner")
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
                if me.audit == true {
                    Section(header: Text("adm.history")) {
                        AdminAuditView(user: user.id).listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(Color.clear)
                }
                if let note { Section { Text(note).foregroundStyle(Theme.danger) }.listRowBackground(Theme.surface) }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("adm.owner.confirm", comment: ""), user.username)),
                                isPresented: $confirmOwner, titleVisibility: .visible) {
                Button("adm.role.owner", role: .destructive) { setRole("owner") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(user.display_name.isEmpty ? user.username : user.display_name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
    }

    private func setRole(_ r: String) {
        Task {
            do {
                try await APIClient.shared.admSetRole(token: token, userID: user.id, role: r)
                note = nil
                onChange()
                dismiss()
            } catch APIError.refused(let why) {
                note = why
            } catch {
                note = NSLocalizedString("settings.failed", comment: "")
            }
        }
    }
}


private struct AdminOfficialView: View {
    let library: Bool
    let me: AdminMe
    @EnvironmentObject private var store: SessionStore
    @State private var show = "all"
    @State private var composing = false
    @State private var all: [AdminOfficialPost] = []
    private var posts: [AdminOfficialPost] { all.filter { show == "all" || ($0.state ?? "draft") == show } }
    @State private var loading = true
    @State private var note: String?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(library ? "adm.library.note" : "adm.official.note")).font(.system(size: 12)).foregroundStyle(Theme.faint)
            if !library {
                Button { composing = true } label: {
                    Label("adm.off.new", systemImage: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 16).frame(height: 40).background(Theme.accent, in: Capsule())
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["all", "active", "scheduled", "draft", "expired", "removed"], id: \.self) { s in
                            FilterChip(title: NSLocalizedString(s == "all" ? "adm.state.all" : "adm.state." + s, comment: ""), selected: show == s) { show = s }
                        }
                    }
                }
            }
            if loading { ProgressView().tint(Theme.accent).frame(maxWidth: .infinity) }
            else if posts.isEmpty { Text("adm.official.none").font(.system(size: 13)).foregroundStyle(Theme.faint) }
            TFCard {
                ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 10) {
                        Image(systemName: p.kind == "video" ? "video" : "photo").foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title?.isEmpty == false ? (p.title ?? "") : (p.caption ?? p.id)).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(NSLocalizedString("adm.state." + (p.state ?? "draft"), comment: "")) · \(p.views) \(NSLocalizedString("adm.views", comment: ""))")
                                .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        Menu {
                            if !library && (p.state == "draft" || p.state == "removed" || p.state == "expired") {
                                Button("adm.publish") { act(p, "publish") }
                            }
                            if !library && (p.state == "active" || p.state == "scheduled") {
                                Button("adm.remove") { act(p, "remove") }
                            }
                            if me.users == true && (p.state == "draft" || p.state == "removed" || p.state == "expired") {
                                Button("adm.delete", role: .destructive) { act(p, "delete") }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 32, height: 32)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    if i < posts.count - 1 { TFDivider() }
                }
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await load() }
        .sheet(isPresented: $composing) { AdminOfficialComposer { Task { await load() } }.environmentObject(store) }
    }

    private func act(_ p: AdminOfficialPost, _ action: String) {
        Task {
            do { try await APIClient.shared.stAdminOfficialAction(token: token, id: p.id, action: action) } catch APIError.refused(let why) {
                note = why
            } catch {
                note = NSLocalizedString("settings.failed", comment: "")
            }
            await load()
        }
    }

    private func load() async {
        all = (try? await APIClient.shared.stAdminOfficial(token: token)) ?? all
        loading = false
    }
}
