import SwiftUI

/// Admin Center (desktop/src/features/admin/AdminCenter.tsx): only shown when GET /admin/me returns a role.
/// Overview, Users (search, detail, suspend / restore) and the TRADEFLOR Official statuses (publish, remove, delete).
struct AdminCenterPage: View {
    let role: String
    @EnvironmentObject private var store: SessionStore
    @State private var tab = ""
    @State private var me: AdminMe?
    @State private var meLoaded = false
    @State private var openUser: AdminUser?
    /// Bumped after a change made from a user opened here: the tab on screen reads its figures again.
    @State private var refresh = 0
    /// The Users filter an Overview figure opens (web goUsers).
    @State private var userFilter = "all"

    private var tabs: [(String, String)] {
        guard let me else { return [] }
        var t: [(String, String)] = []
        if me.users == true { t += [("overview", "adm.overview"), ("users", "adm.users")] }
        if me.content == true { t += [("official", "adm.official"), ("library", "adm.library")] }
        if me.users == true { t.append(("reports", "adm.reports")) }
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
                Group {
                    switch tab {
                    case "users": AdminUsersView(me: me, filter: userFilter)
                    case "official": AdminOfficialView(library: false, me: me)
                    case "library": AdminOfficialView(library: true, me: me)
                    case "reports": AdminReportsView()
                    case "audit": AdminAuditView(onOpenUser: open)
                    case "settings": AdminSettingsView(me: me, onOpenUser: open)
                    default: AdminOverviewView(onOpenUser: open) { f in userFilter = f; tab = "users" }
                    }
                }
                .id("\(tab)|\(refresh)")
            } else if meLoaded {
                // the access check did not answer: say so instead of a spinner that never ends
                Text("adm.failed").font(.system(size: 13)).foregroundStyle(Theme.faint)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .refreshable {
            if me == nil { me = await APIClient.shared.stAdminMe(token: store.session?.token ?? "") }
            if tab.isEmpty { tab = tabs.first?.0 ?? "settings" }
            refresh += 1
        }
        .task {
            me = await APIClient.shared.stAdminMe(token: store.session?.token ?? "")
            meLoaded = true
            if tab.isEmpty { tab = tabs.first?.0 ?? "settings" }
        }
        .fullScreenCover(item: $openUser) { u in
            // a suspend / restore / role change made here shows at once in the tab underneath (it was a no-op)
            if let me { AdminUserSheet(user: u, me: me) { refresh += 1 }.tfColorScheme() }
        }
    }

    private func open(_ id: String) {
        Task { openUser = await APIClient.shared.admUser(token: store.session?.token ?? "", id: id) }
    }
}

private struct AdminOverviewView: View {
    var onOpenUser: (String) -> Void
    /// A figure opens Users with its filter (web Overview goUsers).
    var goUsers: (String) -> Void = { _ in }
    @EnvironmentObject private var store: SessionStore
    @State private var o: AdminOverview?
    @State private var failed = false

    var body: some View {
        Group {
            if let o {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    stat("adm.total", o.total, filter: "all")
                    stat("adm.today", o.today, filter: "today")
                    stat("adm.7d", o.last_7_days, filter: "7d")
                    stat("adm.30d", o.last_30_days, filter: "30d")
                    stat("adm.active24", o.active_24h, filter: "active")
                    stat("adm.active7", o.active_7d)
                    stat("adm.online", o.online, filter: "online")
                    stat("adm.verified", o.verified, filter: "verified")
                    stat("adm.unverified", o.unverified, filter: "unverified")
                    stat("adm.suspended", o.suspended, filter: "suspended")
                    stat("adm.official.live", o.official_live)
                    stat("adm.official.views", o.official_views)
                    if let v = o.official_viewers { stat("ux4.adm.official.viewers", v) }
                }
                if let d = o.daily, !d.isEmpty {
                    AdminBars(daily: d, weekly: o.weekly ?? [], monthly: o.monthly ?? [])
                }
                if let r = o.recent {
                    SSection(text: NSLocalizedString("adm.recent", comment: ""))
                    SCard {
                        if r.isEmpty { Text("adm.recent.none").font(.system(size: 12)).foregroundStyle(Theme.faint).padding(12) }
                        ForEach(Array(r.enumerated()), id: \.element.id) { i, u in
                            Button { onOpenUser(u.id) } label: {
                                HStack(spacing: 10) {
                                    Avatar(token: store.session?.token ?? "", userID: u.id, avatarID: u.avatar_id.isEmpty ? nil : u.avatar_id,
                                           title: u.display_name.isEmpty ? (u.username.isEmpty ? "?" : u.username) : u.display_name, size: 34, online: u.online)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(AdminFmt.name(u)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                        Text("\(AdminFmt.handle(u)) · \(AdminFmt.date(u.created_at))").font(.system(size: 11)).foregroundStyle(Theme.faint)
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
            // a quiet refresh every minute while this is open (web); a failed refresh keeps the figures on screen
            while !Task.isCancelled {
                do {
                    o = try await APIClient.shared.stAdminOverview(token: store.session?.token ?? "")
                    failed = false
                } catch {
                    if o == nil { failed = true }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func stat(_ key: String, _ v: Int, filter: String? = nil) -> some View {
        Button { if let filter { goUsers(filter) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(key)).font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text("\(v)").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(filter == nil)
    }
}

private struct AdminUsersView: View {
    let me: AdminMe
    @EnvironmentObject private var store: SessionStore
    @State private var query = ""
    @State private var page = 1
    @State private var data: AdminUsersPage?
    @State private var open: AdminUser?
    @State private var loading = false
    @State private var seq = 0
    @State private var failed = false
    /// web Users filter chips and sort (the server does both; they were fixed to all / newest)
    @State private var filter: String
    @State private var sort = "newest"
    private var token: String { store.session?.token ?? "" }

    init(me: AdminMe, filter: String = "all") {
        self.me = me
        _filter = State(initialValue: filter)
    }

    private static let filters: [(String, String)] = [
        ("all", "adm.state.all"), ("today", "adm.today"), ("7d", "adm.7d"), ("30d", "adm.30d"), ("active", "adm.active24"),
        ("online", "adm.online"), ("verified", "adm.verified"), ("unverified", "adm.unverified"), ("suspended", "adm.suspended"),
    ]
    private static let sorts: [(String, String)] = [
        ("newest", "ux4.adm.sort.newest"), ("oldest", "ux4.adm.sort.oldest"), ("active", "ux4.adm.sort.active"), ("username", "ux4.adm.sort.username"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SearchPill(placeholder: "adm.search", text: $query)
                    .submitLabel(.search)
                    .onSubmit { page = 1; Task { await load() } }
                Menu {
                    Picker("", selection: $sort) {
                        ForEach(Self.sorts, id: \.0) { s in Text(LocalizedStringKey(s.1)).tag(s.0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("ux4.adm.sort"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.filters, id: \.0) { f in
                        FilterChip(title: NSLocalizedString(f.1, comment: ""), selected: filter == f.0) { filter = f.0 }
                    }
                }
            }
            if failed && data == nil {
                VStack(spacing: 8) {
                    Text("adm.failed").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    Button("ux3.cal.retry") { Task { await load() } }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
            } else if let d = data {
                Text(String(format: NSLocalizedString("adm.count", comment: ""), d.total)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                if failed { Text("adm.failed").font(.system(size: 12)).foregroundStyle(Theme.danger) }
                if (d.users ?? []).isEmpty { Text("ux4.adm.nomatch").font(.system(size: 13)).foregroundStyle(Theme.faint) }
                SCard {
                    ForEach(Array((d.users ?? []).enumerated()), id: \.element.id) { i, u in
                        Button { open = u } label: {
                            HStack(spacing: 10) {
                                Avatar(token: token, userID: u.id, avatarID: u.avatar_id.isEmpty ? nil : u.avatar_id,
                                       title: u.display_name.isEmpty ? (u.username.isEmpty ? "?" : u.username) : u.display_name, size: 36, online: u.online)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AdminFmt.name(u)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text(AdminFmt.handle(u) + (u.pin.isEmpty ? "" : " · " + u.pin)).font(.system(size: 11)).foregroundStyle(Theme.faint)
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
                    Button("adm.prev") { page -= 1; Task { await load() } }.disabled(page <= 1 || loading)
                    Spacer()
                    Text("\(page) / \(max(1, Int(ceil(Double(d.total) / Double(max(1, d.limit))))))").foregroundStyle(Theme.faint)
                    Spacer()
                    Button("adm.next") { page += 1; Task { await load() } }.disabled(page * max(1, d.limit) >= d.total || loading)
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        // typing: one search 0.4 s after the last key (each key used to start its own search, and an older, slower answer
        // could replace the newer one)
        .task(id: query) {
            if data != nil {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                page = 1
            }
            await load()
        }
        .onChange(of: filter) { _ in page = 1; Task { await load() } }
        .onChange(of: sort) { _ in page = 1; Task { await load() } }
        .fullScreenCover(item: $open) { u in AdminUserSheet(user: u, me: me) { Task { await load() } }.tfColorScheme() }
    }

    private func load() async {
        seq += 1
        let my = seq
        loading = true
        defer { if my == seq { loading = false } }
        // a failure said nothing (an endless spinner on the first page, a silent no-op on the others)
        do {
            let d = try await APIClient.shared.stAdminUsers(token: token, query: query, page: page, filter: filter, sort: sort)
            guard my == seq else { return }
            data = d
            failed = false
        } catch {
            guard my == seq else { return }
            failed = true
        }
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
    @State private var busy = false
    @State private var confirmSuspend = false
    @State private var fresh: AdminUser?
    @State private var extra: AdminUserExtra?
    private var token: String { store.session?.token ?? "" }
    /// The account as the server has it now (details), the list's row until then.
    private var shown: AdminUser { fresh ?? user }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("signup.username", value: AdminFmt.handle(shown))
                    LabeledContent("PIN", value: shown.pin.isEmpty ? "—" : shown.pin)
                    LabeledContent("signup.email", value: shown.email.isEmpty ? "—" : shown.email)
                    if !shown.email.isEmpty {
                        LabeledContent("adm.verified", value: NSLocalizedString(shown.email_verified ? "ux4.adm.yes" : "ux4.adm.no", comment: ""))
                    }
                    LabeledContent("ux4.adm.lastactive", value: shown.online ? NSLocalizedString("adm.online", comment: "")
                                   : (shown.last_active_at > 0 ? AdminFmt.date(shown.last_active_at) : "—"))
                    if let x = extra {
                        if x.suspended_until ?? 0 > 0 { LabeledContent("ux4.adm.until", value: AdminFmt.date(x.suspended_until ?? 0)) }
                        if let by = x.suspended_by, !by.isEmpty, shown.status == "suspended" { LabeledContent("ux4.adm.by", value: "@" + by) }
                        LabeledContent("ux4.adm.devices", value: "\(x.devices ?? 0)")
                    }
                    if !shown.phone.isEmpty { LabeledContent("set.phone", value: shown.phone) }
                    LabeledContent("set.country", value: shown.country)
                    LabeledContent("set.joined", value: Date(timeIntervalSince1970: Double(shown.created_at)).formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("adm.status", value: NSLocalizedString("adm.status." + shown.status, comment: ""))
                    if let r = shown.suspend_reason, !r.isEmpty { LabeledContent("adm.reason", value: r) }
                }
                .listRowBackground(Theme.surface)
                if shown.status == "suspended" {
                    Section {
                        Button("adm.restore") {
                            guard !busy else { return }
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await APIClient.shared.stAdminRestore(token: token, userID: shown.id); onChange(); dismiss() } catch {
                                    note = NSLocalizedString("settings.failed", comment: "")
                                }
                            }
                        }
                        .disabled(busy)
                        .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.surface)
                } else if shown.id != store.session?.userID && shown.role != "owner"
                            && (shown.type != "administrator" || me.role == "owner") {
                    // never my own account (the web says "You cannot suspend yourself"), never an owner; an owner may suspend
                    // another administrator (server admin.Suspend) — it was hidden for every administrator, owners included
                    Section(header: Text("adm.suspend")) {
                        TextField("adm.reason", text: $reason)
                            .onChange(of: reason) { v in if v.count > 300 { reason = String(v.prefix(300)) } } // web maxLength
                        Picker("adm.duration", selection: $hours) {
                            Text("adm.d.24h").tag(24)
                            Text("adm.d.7d").tag(168)
                            Text("adm.d.30d").tag(720)
                            Text("adm.d.forever").tag(0)
                        }
                        // signs the account out everywhere at once: asked first (it ran on the first tap)
                        Button("adm.suspend", role: .destructive) { confirmSuspend = true }
                            .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                    .listRowBackground(Theme.surface)
                }
                if me.roles == true && shown.status == "active" && shown.id != store.session?.userID {
                    Section(header: Text("adm.role.title")) {
                        Picker("adm.role.title", selection: Binding(get: { shown.role ?? "" }, set: { r in
                            if r == "owner" { confirmOwner = true } else { setRole(r) }
                        })) {
                            Text("adm.role.none").tag("")
                            Text("adm.role.content").tag("content")
                            Text("adm.role.admin").tag("admin")
                            Text("adm.role.owner").tag("owner")
                        }
                    }
                    .disabled(busy)
                    .listRowBackground(Theme.surface)
                }
                if me.audit == true {
                    Section(header: Text("adm.history")) {
                        AdminAuditView(user: shown.id).listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(Color.clear)
                }
                if let note { Section { Text(note).foregroundStyle(Theme.danger) }.listRowBackground(Theme.surface) }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("adm.owner.confirm", comment: ""), shown.username)),
                                isPresented: $confirmOwner, titleVisibility: .visible) {
                Button("adm.role.owner", role: .destructive) { setRole("owner") }
            }
            .confirmationDialog(Text(String(format: NSLocalizedString("adm.suspend.confirm", comment: ""), shown.username)),
                                isPresented: $confirmSuspend, titleVisibility: .visible) {
                Button("adm.suspend", role: .destructive) { suspend() }
            }
            // the list row has no suspension details (reason, …): the account's own record is read
            .task { if let d = await APIClient.shared.admUserDetail(token: token, id: user.id) { fresh = d.0; extra = d.1 } }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(shown.display_name.isEmpty ? shown.username : shown.display_name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { if busy { ProgressView() } }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func suspend() {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !why.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.stAdminSuspend(token: token, userID: shown.id, reason: why, hours: hours)
                onChange()
                dismiss()
            } catch APIError.refused(let why) {
                note = why
            } catch {
                note = NSLocalizedString("settings.failed", comment: "")
            }
        }
    }

    private func setRole(_ r: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await APIClient.shared.admSetRole(token: token, userID: shown.id, role: r)
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
    @State private var acting = false
    @State private var confirmDelete: AdminOfficialPost?
    @State private var confirmRemove: AdminOfficialPost?
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
            SCard {
                ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                    // card row (website OfficialAdmin.tsx): a 9:16 thumbnail, a readable name, two lines of caption, the time
                    // that matters, views and type
                    HStack(alignment: .top, spacing: 12) {
                        OfficialThumb(token: token, post: p)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(OfficialRowText.name(p)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            if let c = OfficialRowText.caption(p) {
                                Text(c).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                            Text(OfficialRowText.when(p)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text("\(NSLocalizedString("adm.state." + (p.state ?? "draft"), comment: "")) · \(p.views) \(NSLocalizedString("adm.views", comment: "")) · \(NSLocalizedString(p.kind == "video" ? "chats.kind.video" : "chats.kind.image", comment: ""))")
                                .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        Menu {
                            // the server publishes drafts only (UPDATE … WHERE state = 'draft'): on a removed or expired
                            // post this answered "not found"
                            if !library && p.state == "draft" {
                                Button("adm.publish") { act(p, "publish") }
                            }
                            if !library && (p.state == "active" || p.state == "scheduled") {
                                // takes it off everyone's screen at once: asked first, as on the website
                                Button("adm.remove", role: .destructive) { confirmRemove = p }
                            }
                            if me.users == true && (p.state == "draft" || p.state == "removed" || p.state == "expired") {
                                Button("adm.delete", role: .destructive) { confirmDelete = p }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .disabled(acting)
                        .accessibilityLabel(Text("chat.more"))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    if i < posts.count - 1 { TFDivider() }
                }
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $composing) { AdminOfficialComposer { Task { await load() } }.environmentObject(store).tfColorScheme() }
        // deleting cannot be undone: it asks first (it ran straight from the menu)
        .confirmationDialog(Text("adm.delete.confirm"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            if let p = confirmDelete { Button("adm.delete", role: .destructive) { act(p, "delete") } }
        }
        .confirmationDialog(Text("adm.remove.confirm"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            if let p = confirmRemove { Button("adm.remove", role: .destructive) { act(p, "remove") } }
        }
    }

    private func act(_ p: AdminOfficialPost, _ action: String) {
        guard !acting else { return }
        acting = true
        note = nil
        Task {
            defer { acting = false }
            do { try await APIClient.shared.stAdminOfficialAction(token: token, id: p.id, action: action) } catch APIError.refused(let why) {
                note = why
            } catch {
                note = NSLocalizedString("settings.failed", comment: "")
            }
            await load()
        }
    }

    private func load() async {
        // a failed first read said "No official posts yet"; now it says it could not load (and keeps any list on screen)
        do {
            all = try await APIClient.shared.stAdminOfficial(token: token)
            if note == NSLocalizedString("adm.failed", comment: "") { note = nil }
        } catch {
            note = NSLocalizedString("adm.failed", comment: "")
        }
        loading = false
    }
}


/// An Official post's thumbnail: the poster of a video (or "Preparing…" until the server has made it), the picture itself.
private struct OfficialThumb: View {
    let token: String
    let post: AdminOfficialPost
    @State private var image: UIImage?

    private var waiting: Bool { post.kind == "video" && post.poster != true }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Theme.hex(0x0A3445), Theme.hex(0x04121D)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 4) {
                    Image("BrandFlower").resizable().scaledToFit().frame(width: 22).opacity(0.7)
                    if waiting { Text("adm.preparing").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.hex(0xC4D5DF)) }
                }
            }
            if post.kind == "video" && image != nil {
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(.black.opacity(0.5), in: Circle())
            }
        }
        .frame(width: 54, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderStrong, lineWidth: 1))
        .task(id: post.id) {
            guard !waiting else { return }
            if let d = await APIClient.shared.statusMedia(token: token, id: "official-" + post.id, poster: post.kind == "video") {
                image = UIImage(data: d)
            }
        }
        .accessibilityHidden(true)
    }
}

enum OfficialRowText {
    /// The caption's first line when the name is only the uploaded file's name.
    static func name(_ p: AdminOfficialPost) -> String {
        let t = (p.title ?? "").trimmingCharacters(in: .whitespaces)
        let looksLikeFile = t.isEmpty || t.range(of: #"\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil
        if looksLikeFile, let first = p.caption?.split(separator: "\n").first, !first.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(first)
        }
        return t.isEmpty ? NSLocalizedString("adm.untitled", comment: "") : t
    }

    /// Two lines of caption, without repeating what the name already shows.
    static func caption(_ p: AdminOfficialPost) -> String? {
        guard var c = p.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        let n = name(p)
        if c.hasPrefix(n) { c = String(c.dropFirst(n.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return c.isEmpty ? nil : c
    }

    /// The time that matters: "23 h left", "starts in 2 d", "ended 5 h ago", or when it was added.
    static func when(_ p: AdminOfficialPost) -> String {
        let now = Date().timeIntervalSince1970
        func span(_ s: Double) -> String {
            let s = max(0, s)
            if s >= 86_400 { return String(format: NSLocalizedString("adm.span.d", comment: ""), Int(s / 86_400)) }
            if s >= 3600 { return String(format: NSLocalizedString("adm.span.h", comment: ""), Int(s / 3600)) }
            return String(format: NSLocalizedString("adm.span.m", comment: ""), max(1, Int(s / 60)))
        }
        switch p.state {
        case "active": if let e = p.expires_at { return String(format: NSLocalizedString("adm.when.left", comment: ""), span(Double(e) - now)) }
        case "scheduled": if let s = p.publish_at { return String(format: NSLocalizedString("adm.when.starts", comment: ""), span(Double(s) - now)) }
        case "expired": if let e = p.expires_at { return String(format: NSLocalizedString("adm.when.ended", comment: ""), span(now - Double(e))) }
        default: break
        }
        return String(format: NSLocalizedString("adm.when.added", comment: ""), AdminFmt.date(p.created_at))
    }
}
