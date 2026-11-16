import SwiftUI
import PhotosUI

// The Settings sub-pages (desktop/src/features/settings/SettingsView.tsx, ActivityPages.tsx, identity/MyIdentity.tsx,
// profile/PersonalProfilePanel.tsx, calls/CallSettings.tsx, calls/CallHistory.tsx).

// MARK: My Profile

struct MyProfilePage: View {
    let onChange: () -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var profile: Profile?
    @State private var identity: StIdentity?
    @State private var editing = false
    @State private var picked: PhotosPickerItem?
    @State private var viewing = false
    @State private var confirmRemove = false
    @State private var note: String?
    @State private var busy = false

    @State private var cropping: PickedImage?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("set.myprofile.title", comment: "")) {
            VStack(spacing: 10) {
                Avatar(token: token, userID: profile?.user_id ?? "", avatarID: (profile?.avatar_id.isEmpty ?? true) ? nil : profile?.avatar_id,
                       title: profile?.display_name.isEmpty == false ? (profile?.display_name ?? "") : (profile?.username ?? "?"), size: 110)
                    .onTapGesture { if !(profile?.avatar_id.isEmpty ?? true) { viewing = true } }
                Text(profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? "")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                Text("@" + (profile?.username ?? "")).font(.system(size: 14)).foregroundStyle(Theme.accent)
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio).font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            HStack(spacing: 10) {
                Button { editing = true } label: {
                    Label("set.edit.profile", systemImage: "pencil").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 42).background(Theme.accent, in: Capsule())
                }
                Menu {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label(LocalizedStringKey((profile?.avatar_id.isEmpty ?? true) ? "set.photo.add" : "set.photo.change"), systemImage: "photo")
                    }
                    if !(profile?.avatar_id.isEmpty ?? true) {
                        Button { viewing = true } label: { Label("set.photo.view", systemImage: "eye") }
                    }
                    Button { copy("@" + (profile?.username ?? ""), "set.copied.username") } label: { Label("set.copy.username", systemImage: "at") }
                    if let pin = identity?.pin { Button { copy(pin, "set.copied.pin") } label: { Label("set.copy.pin", systemImage: "number") } }
                    if !(profile?.avatar_id.isEmpty ?? true) {
                        Button(role: .destructive) { confirmRemove = true } label: { Label("set.photo.remove", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        .frame(width: 42, height: 42).background(Theme.card, in: Circle()).overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                }
            }
            if let pin = identity?.pin {
                TFCard {
                    TFKeyValue(key: "PIN", value: pin, action: NSLocalizedString("set.copy", comment: "")) { copy(pin, "set.copied.pin") }
                }
            }
            if let note { Text(note).font(.system(size: 13)).foregroundStyle(Theme.accent) }
        }
        .overlay { if busy { ProgressView().tint(Theme.accent) } }
        .task { await load() }
        .sheet(isPresented: $editing) {
            if let profile {
                EditProfileSheet(profile: profile) { n, u, b in
                    do {
                        self.profile = try await APIClient.shared.stUpdateProfile(token: token, displayName: n, username: u, bio: b)
                        onChange()
                        return nil
                    } catch APIError.refused(let why) {
                        return why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
                    } catch {
                        return NSLocalizedString("settings.failed", comment: "")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $viewing) {
            AvatarViewer(token: token, userID: profile?.user_id ?? "", avatarID: profile?.avatar_id ?? "")
        }
        .confirmationDialog(Text("set.photo.remove.confirm"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("set.photo.remove", role: .destructive) {
                Task {
                    if let p = try? await APIClient.shared.deleteAvatar(token: token) { profile = p; onChange() }
                }
            }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                cropping = PickedImage(image: img)
            }
        }
        .fullScreenCover(item: $cropping) { p in
            AvatarEditor(image: p.image) { jpeg in
                Task {
                    busy = true
                    if let pr = try? await APIClient.shared.uploadAvatar(token: token, jpeg: jpeg) { profile = pr; onChange() }
                    busy = false
                }
            }
        }
    }

    private func copy(_ s: String, _ key: String) {
        UIPasteboard.general.string = s
        note = NSLocalizedString(key, comment: "")
    }

    private func load() async {
        profile = try? await APIClient.shared.profile(token: token)
        if let d = try? await APIClient.shared.getJSON("identity/me", token: token) {
            identity = try? JSONDecoder().decode(StIdentity.self, from: d)
        }
    }

    /// A centred square, 1024 px at most (the server keeps avatars small).
    static func squareJPEG(_ img: UIImage) -> Data? {
        let side = min(img.size.width, img.size.height)
        let target = CGSize(width: min(1024, side), height: min(1024, side))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scale = target.width / side
        let out = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(x: -(img.size.width - side) / 2 * scale, y: -(img.size.height - side) / 2 * scale,
                                width: img.size.width * scale, height: img.size.height * scale))
        }
        return out.jpegData(compressionQuality: 0.85)
    }
}

struct AvatarViewer: View {
    let token: String
    let userID: String
    let avatarID: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .padding()
        }
        .task {
            if let d = await APIClient.shared.avatar(token: token, userID: userID, avatarID: avatarID) { image = UIImage(data: d) }
        }
    }
}

// MARK: Account

struct AccountPage: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var account: PrivateAccount?
    @State private var editing = false
    @State private var fullName = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var busy = false
    @State private var note: String?
    @State private var problem: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.account", comment: ""), subtitle: NSLocalizedString("settings.account.sub", comment: "")) {
            if let a = account, a.needs_real_name == true || a.needs_email == true {
                VStack(alignment: .leading, spacing: 4) {
                    Label("acct.complete", systemImage: "exclamationmark.circle").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.gold)
                    Text((a.needs_real_name == true ? NSLocalizedString("acct.complete.name", comment: "") + " " : "")
                         + (a.needs_email == true ? NSLocalizedString("acct.complete.email", comment: "") : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold.opacity(0.4), lineWidth: 1))
            }
            TFCard {
                HStack(spacing: 12) {
                    Image(systemName: "person").foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("@" + (store.session?.username ?? "")).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        Text("set.signed.here").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                }
                .padding(14)
            }
            TFCard {
                TFKeyValue(key: NSLocalizedString("signup.username", comment: ""), value: "@" + (store.session?.username ?? ""),
                           action: NSLocalizedString("set.copy", comment: "")) {
                    UIPasteboard.general.string = "@" + (store.session?.username ?? "")
                    note = NSLocalizedString("set.copied.username", comment: "")
                }
                TFDivider()
                TFKeyValue(key: NSLocalizedString("settings.connection", comment: ""),
                           value: NSLocalizedString(live.connected ? "settings.live" : "set.reconnecting", comment: ""))
            }
            TFSectionLabel(text: NSLocalizedString("set.account.info", comment: ""))
            Text("set.account.private").font(.system(size: 12)).foregroundStyle(Theme.faint)
            if let a = account {
                TFCard {
                    TFKeyValue(key: NSLocalizedString("set.realname", comment: ""), value: a.full_name.isEmpty ? "—" : a.full_name,
                               action: NSLocalizedString("set.edit", comment: "")) { startEdit() }
                    TFDivider()
                    TFKeyValue(key: NSLocalizedString("signup.email", comment: ""),
                               value: a.email + " · " + NSLocalizedString(a.email_verified ? "set.verified" : "set.notverified", comment: ""))
                    TFDivider()
                    TFKeyValue(key: NSLocalizedString("set.phone", comment: ""),
                               value: a.phone.isEmpty ? NSLocalizedString("set.phone.none", comment: "") : a.phone,
                               action: NSLocalizedString("set.edit", comment: "")) { startEdit() }
                    TFDivider()
                    TFKeyValue(key: NSLocalizedString("set.country", comment: ""),
                               value: a.country.isEmpty ? NSLocalizedString("set.unknown", comment: "") : CalendarView.flag(a.country) + " " + a.country)
                    TFDivider()
                    TFKeyValue(key: NSLocalizedString("set.joined", comment: ""),
                               value: Date(timeIntervalSince1970: Double(a.created_at)).formatted(date: .numeric, time: .omitted))
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
            if editing {
                TFCard {
                    VStack(spacing: 10) {
                        TextField("set.realname", text: $fullName).textContentType(.name)
                        Divider()
                        TextField("set.phone", text: $phone).keyboardType(.phonePad)
                        Divider()
                        SecureField("set.password.confirm", text: $password).textContentType(.password)
                        HStack {
                            Button("chat.close") { editing = false }.foregroundStyle(Theme.faint)
                            Spacer()
                            Button { Task { await save() } } label: {
                                if busy { ProgressView() } else { Text("settings.save").bold() }
                            }
                            .disabled(password.isEmpty || busy)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                    .foregroundStyle(Theme.text)
                    .padding(14)
                }
            }
            if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
            if let note { Text(note).font(.system(size: 13)).foregroundStyle(Theme.accent) }
        }
        .task { account = try? await APIClient.shared.stPrivateAccount(token: token) }
    }

    private func startEdit() {
        fullName = account?.full_name ?? ""
        phone = account?.phone ?? ""
        password = ""
        problem = nil
        editing = true
    }

    private func save() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await APIClient.shared.stUpdatePrivateAccount(token: token, password: password,
                                                              fullName: fullName != account?.full_name ? fullName : nil,
                                                              phone: phone != account?.phone ? phone : nil)
            account = try? await APIClient.shared.stPrivateAccount(token: token)
            editing = false
            note = NSLocalizedString("set.saved", comment: "")
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

// MARK: My Identity

struct MyIdentityPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var id: StIdentity?
    @State private var showQR = true
    @State private var changing = false
    @State private var newName = ""
    @State private var nameNote: String?
    @State private var nameOK = false
    @State private var busy = false
    @State private var note: String?

    private var token: String { store.session?.token ?? "" }
    @State private var connectCode: String?
    /// The card's QR is the Flash Connect link (an opaque code, never the PIN); the older ?id= link until it is known.
    private var link: String {
        if let c = connectCode, !c.isEmpty { return "https://app.tradeflor.com/?connect=\(c)" }
        return "https://app.tradeflor.com/?id=\(id?.pin ?? "")"
    }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.identity", comment: "")) {
            if let id {
                IdentityShowcase(id: id, link: link, token: token)
                    .padding(.vertical, 8)

                TFCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("set.change.username").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        if let at = id.username_change_available_at, at > Int64(Date().timeIntervalSince1970) {
                            Text(String(format: NSLocalizedString("set.username.wait", comment: ""),
                                        Date(timeIntervalSince1970: Double(at)).formatted(date: .abbreviated, time: .omitted)))
                                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                        } else {
                            Text("set.username.note").font(.system(size: 12)).foregroundStyle(Theme.faint)
                            HStack {
                                Text("@").foregroundStyle(Theme.accent)
                                TextField("signup.username", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .foregroundStyle(Theme.text)
                                    .onChange(of: newName) { v in Task { await check(v) } }
                            }
                            .padding(.horizontal, 12).frame(height: 42).background(Theme.inputGradient, in: Capsule())
                            .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                            if let nameNote { Text(nameNote).font(.system(size: 12)).foregroundStyle(nameOK ? Theme.buy : Theme.danger) }
                            Button { Task { await change() } } label: {
                                HStack { Spacer(); if busy { ProgressView() } else { Text("set.change.username").bold() }; Spacer() }
                                    .foregroundStyle(Theme.onAccent).frame(height: 40).background(Theme.accent.opacity(nameOK ? 1 : 0.4), in: Capsule())
                            }
                            .disabled(!nameOK || busy)
                        }
                    }
                    .padding(14)
                }
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
        .task { connectCode = try? await APIClient.shared.ctMyCode(token: token) }
    }

    private func load() async {
        if let d = try? await APIClient.shared.getJSON("identity/me", token: token) { id = try? JSONDecoder().decode(StIdentity.self, from: d) }
    }

    private func check(_ v: String) async {
        let u = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard u.count >= 3 else { nameNote = nil; nameOK = false; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard u == newName.trimmingCharacters(in: .whitespaces).lowercased() else { return }
        let r = await APIClient.shared.stUsernameAvailable(token: token, u)
        nameOK = r.available
        nameNote = r.available ? NSLocalizedString("set.username.free", comment: "") : (r.reason ?? NSLocalizedString("signup.username.taken", comment: ""))
    }

    private func change() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await APIClient.shared.stChangeUsername(token: token, newName.trimmingCharacters(in: .whitespaces).lowercased())
            newName = ""
            nameNote = nil
            nameOK = false
            await load()
        } catch APIError.refused(let why) {
            nameNote = why
            nameOK = false
        } catch {
            nameNote = NSLocalizedString("settings.failed", comment: "")
            nameOK = false
        }
    }
}

// MARK: Live location

struct LiveLocationPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var mine: [LivePosition] = []
    @State private var names: [String: String] = [:]
    private var token: String { store.session?.token ?? "" }
    private var active: [LivePosition] { mine.filter { $0.stopped != true && Double($0.until) > Date().timeIntervalSince1970 } }

    var body: some View {
        SettingsPage(title: NSLocalizedString("location.live", comment: "")) {
            if active.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "location.slash").font(.system(size: 30)).foregroundStyle(Theme.faint)
                    Text("set.loc.none").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("set.loc.none.sub").font(.system(size: 12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                TFCard {
                    ForEach(Array(active.enumerated()), id: \.element.id) { i, p in
                        HStack {
                            Image(systemName: "location.fill").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(names[p.conversation_id] ?? NSLocalizedString("chats.title", comment: "")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(String(format: NSLocalizedString("location.until", comment: ""),
                                            Date(timeIntervalSince1970: Double(p.until)).formatted(date: .omitted, time: .shortened)))
                                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Button("set.stop") { Task { await stop(p.conversation_id) } }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                        }
                        .padding(14)
                        if i < active.count - 1 { TFDivider() }
                    }
                }
                Button {
                    Task { for p in active { await stop(p.conversation_id) } }
                } label: {
                    Text("set.loc.stopall").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 44).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        mine = await APIClient.shared.stMyLocations(token: token)
        let chats = (try? await APIClient.shared.conversations(token: token)) ?? []
        let groups = (try? await APIClient.shared.groups(token: token)) ?? []
        var n: [String: String] = [:]
        for c in chats { n[c.conversation_id] = c.title }
        for g in groups { n[g.conversation_id] = g.name }
        names = n
    }

    private func stop(_ conv: String) async {
        LocationSharer.shared.stop(conversationID: conv)
        await APIClient.shared.stopLocation(token: token, conversationID: conv)
        await load()
    }
}

// MARK: Linked devices

struct DevicesPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var devices: [LinkedDevice] = []
    @State private var confirm: LinkedDevice?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.devices", comment: ""), subtitle: NSLocalizedString("settings.devices.sub", comment: "")) {
            TFCard {
                ForEach(Array(devices.enumerated()), id: \.element.id) { i, d in
                    HStack(spacing: 12) {
                        Image(systemName: d.device.localizedCaseInsensitiveContains("iphone") ? "iphone"
                              : (d.device.localizedCaseInsensitiveContains("windows") ? "desktopcomputer" : "globe"))
                            .foregroundStyle(Theme.accent).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.device).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            if d.current == true {
                                Text("settings.devices.this").font(.system(size: 12)).foregroundStyle(Theme.accent)
                            } else if let seen = d.last_seen_at.flatMap(serverDate) {
                                if Date().timeIntervalSince(seen) < 300 {
                                    Text("set.active.now").font(.system(size: 12)).foregroundStyle(Theme.online)
                                } else {
                                    Text(seen, style: .relative).font(.system(size: 12)).foregroundStyle(Theme.faint)
                                }
                            }
                        }
                        Spacer()
                        if d.current != true {
                            Button { confirm = d } label: {
                                Text("settings.devices.signout").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.danger)
                                    .padding(.horizontal, 10).frame(height: 28).overlay(Capsule().stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    if i < devices.count - 1 { TFDivider() }
                }
            }
        }
        .task { devices = (try? await APIClient.shared.devices(token: token)) ?? [] }
        .confirmationDialog(Text(String(format: NSLocalizedString("set.device.confirm", comment: ""), confirm?.device ?? "")),
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("settings.devices.signout", role: .destructive) {
                if let d = confirm {
                    Task {
                        if (try? await APIClient.shared.revokeDevice(token: token, id: d.id)) != nil { devices.removeAll { $0.id == d.id } }
                    }
                }
            }
        }
    }
}

// MARK: Events

struct EventsPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var items: [SavedEventFull] = []
    @State private var loading = true
    private var token: String { store.session?.token ?? "" }
    private var now: Int64 { Int64(Date().timeIntervalSince1970) }
    private var upcoming: [SavedEventFull] { items.filter { $0.event_at >= now }.sorted { $0.event_at < $1.event_at } }
    private var past: [SavedEventFull] { items.filter { $0.event_at < now && $0.event_at >= now - 7 * 86400 }.sorted { $0.event_at > $1.event_at } }
    static let reminders = [0, 5, 15, 30, 60]

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.events", comment: ""), subtitle: NSLocalizedString("settings.events.sub", comment: "")) {
            if !loading && items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 30)).foregroundStyle(Theme.faint)
                    Text("set.events.none").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("settings.events.none").font(.system(size: 12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            if !upcoming.isEmpty { section("set.events.upcoming", upcoming) }
            if !past.isEmpty { section("set.events.past", past) }
        }
        .task { await load() }
    }

    private func section(_ key: String, _ list: [SavedEventFull]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TFSectionLabel(text: NSLocalizedString(key, comment: ""))
            TFCard {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(TradeFlorView.impactColor(e.impact ?? "")).frame(width: 3, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(((e.currency ?? "") + " " + e.title).trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(Date(timeIntervalSince1970: Double(e.event_at)).formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                            if e.event_at >= now {
                                Menu {
                                    ForEach(Self.reminders, id: \.self) { m in
                                        Button(Self.label(m)) { Task { try? await APIClient.shared.stResaveEvent(token: token, e, remind: m); await load() } }
                                    }
                                } label: {
                                    Label(Self.label(e.remind_minutes ?? 15), systemImage: "bell").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            Task {
                                if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.event_key)) != nil { items.removeAll { $0.id == e.id } }
                            }
                        } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint).frame(width: 28, height: 28) }
                    }
                    .padding(12)
                    if i < list.count - 1 { TFDivider() }
                }
            }
        }
    }

    static func label(_ m: Int) -> String {
        m == 0 ? NSLocalizedString("set.remind.none", comment: "")
            : (m == 60 ? NSLocalizedString("set.remind.1h", comment: "") : String(format: NSLocalizedString("set.remind.min", comment: ""), m))
    }

    private func load() async {
        items = (try? await APIClient.shared.stSavedEvents(token: token)) ?? items
        loading = false
    }
}

// MARK: Notifications / Privacy (account switches)

/// Loads the account's switches once and saves each change (POST /settings {key: bool}).
@MainActor
final class AccountSwitches: ObservableObject {
    @Published var values: [String: Bool] = [:]
    @Published var problem: String?
    static let defaults: [String: Bool] = [
        "notifications.enabled": true, "notifications.sound": true, "notifications.previews": true, "notifications.when_focused": false,
        "notifications.groups": true, "notifications.mentions": true, "notifications.mentions_in_muted": true,
        "privacy.read_receipts": true, "privacy.calls_enabled": true, "privacy.calls_contacts_only": false, "calls.confirm": false,
    ]

    func load(_ token: String) async {
        let s = (try? await APIClient.shared.stSettings(token: token)) ?? [:]
        values = Self.defaults.merging(s) { _, new in new }
    }

    func binding(_ key: String, token: String) -> Binding<Bool> {
        Binding(get: { self.values[key] ?? Self.defaults[key] ?? false }, set: { v in
            self.values[key] = v
            Task {
                do { try await APIClient.shared.stSetSetting(token: token, key: key, value: v) } catch {
                    self.values[key] = !v
                    self.problem = NSLocalizedString("settings.failed", comment: "")
                }
            }
        })
    }
}

struct NotificationsPage: View {
    @EnvironmentObject private var store: SessionStore
    @StateObject private var sw = AccountSwitches()
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("set.alerts", comment: "")) {
            TFCard {
                TFToggleRow(icon: "bell.badge", title: NSLocalizedString("set.n.enabled", comment: ""), subtitle: NSLocalizedString("set.n.enabled.sub", comment: ""),
                            isOn: sw.binding("notifications.enabled", token: token))
                TFDivider()
                TFToggleRow(icon: "speaker.wave.2", title: NSLocalizedString("set.n.sound", comment: ""), isOn: sw.binding("notifications.sound", token: token))
                TFDivider()
                TFToggleRow(icon: "text.bubble", title: NSLocalizedString("set.n.previews", comment: ""), isOn: sw.binding("notifications.previews", token: token))
                TFDivider()
                TFToggleRow(icon: "app.badge", title: NSLocalizedString("set.n.focused", comment: ""), isOn: sw.binding("notifications.when_focused", token: token))
            }
            TFSectionLabel(text: NSLocalizedString("set.n.groups.sec", comment: ""))
            TFCard {
                TFToggleRow(icon: "person.3", title: NSLocalizedString("set.n.groups", comment: ""), isOn: sw.binding("notifications.groups", token: token))
                TFDivider()
                TFToggleRow(icon: "at", title: NSLocalizedString("set.n.mentions", comment: ""), isOn: sw.binding("notifications.mentions", token: token))
                TFDivider()
                TFToggleRow(icon: "at.badge.plus", title: NSLocalizedString("set.n.mentions.muted", comment: ""), isOn: sw.binding("notifications.mentions_in_muted", token: token))
            }
            Text("settings.notifications.text").font(.system(size: 12)).foregroundStyle(Theme.faint)
            if let p = sw.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await sw.load(token) }
    }
}

struct PrivacyPage: View {
    @EnvironmentObject private var store: SessionStore
    @StateObject private var sw = AccountSwitches()
    @State private var hasPIN = false
    @State private var unlocked = false
    @State private var pinForm = false
    @State private var password = ""
    @State private var pin1 = ""
    @State private var pin2 = ""
    @State private var note: String?
    @State private var problem: String?
    @State private var pinSaved = BiometricPIN.isSaved
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.privacy", comment: "")) {
            TFCard {
                TFToggleRow(icon: "checkmark.message", title: NSLocalizedString("set.p.receipts", comment: ""), subtitle: NSLocalizedString("set.p.receipts.sub", comment: ""),
                            isOn: sw.binding("privacy.read_receipts", token: token))
            }
            TFSectionLabel(text: NSLocalizedString("settings.calls", comment: ""))
            TFCard {
                TFToggleRow(icon: "phone", title: NSLocalizedString("set.p.calls", comment: ""), isOn: sw.binding("privacy.calls_enabled", token: token))
                TFDivider()
                TFToggleRow(icon: "person.crop.circle.badge.checkmark", title: NSLocalizedString("set.p.contactsonly", comment: ""),
                            isOn: sw.binding("privacy.calls_contacts_only", token: token))
            }
            TFSectionLabel(text: NSLocalizedString("set.chatlock", comment: ""))
            TFCard {
                HStack {
                    Image(systemName: "lock").foregroundStyle(Theme.accent).frame(width: 24)
                    Text("lock.pin").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button(LocalizedStringKey(hasPIN ? "set.change" : "set.set")) { pinForm.toggle() }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .padding(14)
                if pinForm {
                    VStack(spacing: 10) {
                        SecureField("set.password.account", text: $password).textContentType(.password)
                        Divider()
                        SecureField("set.pin.new", text: $pin1).keyboardType(.numberPad)
                        Divider()
                        SecureField("set.pin.repeat", text: $pin2).keyboardType(.numberPad)
                        Button { Task { await savePIN() } } label: {
                            Text("settings.save").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 38).background(Theme.accent, in: Capsule())
                        }
                        .disabled(password.isEmpty || pin1.count < 6)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                if BiometricPIN.biometryAvailable && pinSaved {
                    TFDivider()
                    Button {
                        BiometricPIN.delete()
                        pinSaved = false
                    } label: {
                        TFRow(icon: "faceid", title: String(format: NSLocalizedString("settings.lock.forget", comment: ""), BiometricPIN.biometryName),
                              tint: Theme.danger, showChevron: false)
                    }
                }
                if unlocked {
                    TFDivider()
                    HStack {
                        Text("set.lock.open").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("set.lock.now") {
                            Task {
                                await APIClient.shared.relockChats(token: token)
                                unlocked = false
                                note = NSLocalizedString("chat.locked.toast", comment: "")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(14)
                }
            }
            if let p = problem ?? sw.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent) }
        }
        .task {
            await sw.load(token)
            struct Locks: Decodable { let has_pin: Bool?; let unlocked: Bool? }
            if let d = try? await APIClient.shared.getJSON("locks", token: token), let l = try? JSONDecoder().decode(Locks.self, from: d) {
                hasPIN = l.has_pin ?? false
                unlocked = (l.unlocked ?? false) || APIClient.shared.unlockToken != nil
            }
        }
    }

    private func savePIN() async {
        problem = nil
        guard pin1 == pin2 else { problem = NSLocalizedString("set.pin.mismatch", comment: ""); return }
        guard pin1.count >= 6, pin1.count <= 10, pin1.allSatisfy(\.isNumber) else { problem = NSLocalizedString("set.pin.rule", comment: ""); return }
        do {
            try await APIClient.shared.stSetLockPIN(token: token, password: password, pin: pin1)
            BiometricPIN.delete()
            pinSaved = false
            hasPIN = true
            pinForm = false
            password = ""; pin1 = ""; pin2 = ""
            note = NSLocalizedString("set.pin.saved", comment: "")
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

// MARK: Calls

struct CallsPage: View {
    @EnvironmentObject private var store: SessionStore
    @StateObject private var sw = AccountSwitches()
    @AppStorage("tf.calls.ring") private var ring = true
    @State private var history: [CallHistoryItem] = []
    @State private var names: [String: ConversationSummary] = [:]
    @State private var confirmClear = false
    @ObservedObject private var calls = CallManager.shared
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.calls", comment: "")) {
            HStack(spacing: 12) {
                Image(systemName: "phone.fill").font(.system(size: 20)).foregroundStyle(Theme.onAccent)
                    .frame(width: 46, height: 46).background(Theme.sendGradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("set.c.hero").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text("set.c.hero.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
            }
            TFCard {
                TFToggleRow(icon: "questionmark.circle", title: NSLocalizedString("set.c.confirm", comment: ""), isOn: sw.binding("calls.confirm", token: token))
            }
            TFSectionLabel(text: NSLocalizedString("set.c.device", comment: ""))
            TFCard {
                TFToggleRow(icon: "bell.and.waves.left.and.right", title: NSLocalizedString("set.c.ring", comment: ""), isOn: $ring)
                    .onChange(of: ring) { _ in CallManager.shared.applyRingSetting() }
                TFDivider()
                TFKeyValue(key: NSLocalizedString("set.c.mic", comment: ""), value: NSLocalizedString("set.c.bydevice", comment: ""))
                TFDivider()
                TFKeyValue(key: NSLocalizedString("set.c.speaker", comment: ""), value: NSLocalizedString("set.c.bydevice", comment: ""))
            }
            HStack {
                TFSectionLabel(text: NSLocalizedString("set.c.recent", comment: ""))
                if !history.isEmpty {
                    Button("set.c.clear") { confirmClear = true }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.danger)
                }
            }
            if history.isEmpty {
                Text("set.c.none").font(.system(size: 13)).foregroundStyle(Theme.faint)
            } else {
                TFCard {
                    ForEach(Array(history.enumerated()), id: \.element.id) { i, c in
                        let chat = names[c.conversation_id]
                        let missed = c.direction == "incoming" && (c.status == "missed" || c.status == "declined")
                        HStack(spacing: 12) {
                            Image(systemName: c.direction == "incoming" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                .foregroundStyle(missed ? Theme.danger : Theme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat?.title ?? "—").font(.system(size: 15, weight: .semibold)).foregroundStyle(missed ? Theme.danger : Theme.text)
                                Text(Self.line(c)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            if let chat {
                                Button { calls.start(conversationID: chat.conversation_id, peerName: chat.title, peerID: chat.peer_id) } label: {
                                    Image(systemName: "phone").foregroundStyle(Theme.accent).frame(width: 34, height: 34)
                                        .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                                }
                                .disabled(calls.phase != .idle)
                                .accessibilityLabel(Text("call.voice"))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if i < history.count - 1 { TFDivider() }
                    }
                }
            }
        }
        .task { await load() }
        .confirmationDialog(Text("set.c.clear.confirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("set.c.clear", role: .destructive) {
                Task { try? await APIClient.shared.stClearCallHistory(token: token); await load() }
            }
        }
    }

    static func line(_ c: CallHistoryItem) -> String {
        let dir: String
        switch (c.direction, c.status) {
        case ("incoming", "missed"): dir = NSLocalizedString("set.c.missed", comment: "")
        case ("incoming", _): dir = NSLocalizedString("set.c.incoming", comment: "")
        default: dir = NSLocalizedString("set.c.outgoing", comment: "")
        }
        var s = dir + " · " + Date(timeIntervalSince1970: Double(c.created_at > 100_000_000_000 ? c.created_at / 1000 : c.created_at))
            .formatted(date: .abbreviated, time: .shortened)
        if c.duration_ms > 0 { s += " · " + VoiceBubble.length(c.duration_ms) }
        return s
    }

    private func load() async {
        await sw.load(token)
        history = (try? await APIClient.shared.stCallHistory(token: token)) ?? history
        let chats = (try? await APIClient.shared.conversations(token: token)) ?? []
        names = Dictionary(chats.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: Appearance / About

struct AppearancePage: View {
    @AppStorage("tf.night") private var night = true
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.appearance", comment: "")) {
            TFCard {
                TFToggleRow(icon: "moon", title: NSLocalizedString("set.night", comment: ""), subtitle: NSLocalizedString("set.night.sub", comment: ""), isOn: $night)
            }
            Text("set.night.note").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
    }
}

struct AboutPage: View {
    @State private var note: String?
    @ObservedObject private var stats = DeliveryStats.shared
    @State private var mediaLog = MediaLog.read()
    @State private var showLog = false
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.about", comment: "")) {
            VStack(spacing: 10) {
                Image("BrandFlower").resizable().scaledToFit().frame(width: 80, height: 80)
                BrandWordmark(size: 24)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            TFCard {
                TFKeyValue(key: NSLocalizedString("set.version", comment: ""), value: AppConfig.version, action: NSLocalizedString("set.copy", comment: "")) {
                    UIPasteboard.general.string = "Tradeflor iOS \(AppConfig.version)"
                    note = NSLocalizedString("set.copied", comment: "")
                }
                TFDivider()
                TFKeyValue(key: NSLocalizedString("set.server", comment: ""), value: AppConfig.apiBase.host ?? "")
                TFDivider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("about.live").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(stats.summary).font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
                TFDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("about.medialog").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(mediaLog.last.map(MediaLog.diagnose) ?? NSLocalizedString("about.medialog.none", comment: ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    if !mediaLog.isEmpty {
                        if showLog {
                            Text(MediaLog.text(mediaLog)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                        HStack(spacing: 16) {
                            Button(LocalizedStringKey(showLog ? "about.hide" : "about.show")) { showLog.toggle() }
                            Button("set.copy") { UIPasteboard.general.string = MediaLog.text(mediaLog); note = NSLocalizedString("set.copied", comment: "") }
                            Button("about.clear") { MediaLog.clear(); mediaLog = []; showLog = false }
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
            }
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent) }
        }
    }
}
