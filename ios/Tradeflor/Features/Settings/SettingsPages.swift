import SwiftUI
import PhotosUI
import UserNotifications

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
    @State private var groupsCount: Int?
    @State private var chatsCount: Int?
    @EnvironmentObject private var live: LiveConnection

    @State private var cropping: PickedImage?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                actionRow
                statRow
                if let pin = identity?.pin, !pin.isEmpty { pinRow(pin) }
                linksCard
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Starfield())
        .navigationTitle(Text("set.myprofile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Theme.header, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .disabled(profile == nil) // the sheet needs the profile: before it arrived the sheet opened empty
                    .accessibilityLabel(Text("set.edit.profile"))
                moreMenu
            }
        }
        .overlay { if busy { ProgressView().tint(Theme.accent) } }
        .task { await load() }
        .sheet(isPresented: $editing) {
            if let profile {
                EditProfileSheet(profile: profile) { n, u, b in
                    do {
                        // the @username goes to the server only when it was changed (the server applies its rename rules to it)
                        let clean = u.trimmingCharacters(in: CharacterSet(charactersIn: "@＠ ")).lowercased()
                        let changed = clean != profile.username.lowercased() && !clean.isEmpty
                        let p = try await APIClient.shared.stUpdateProfile(token: token, displayName: n, username: changed ? clean : nil, bio: b)
                        self.profile = p
                        store.renamed(p.username) // a new @username shows everywhere the session's name is used
                        onChange()
                        return nil
                    } catch APIError.refused(let why) {
                        // the name and bio may already be saved even when the rename was refused: show what the server has
                        Task { await load() }
                        // 409: the username is someone else's (the server's line is English)
                        if why.localizedCaseInsensitiveContains("taken") { return NSLocalizedString("signup.username.taken", comment: "") }
                        return why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
                    } catch APIError.rateLimited {
                        return NSLocalizedString("login.error.rate", comment: "")
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
                guard !busy else { return }
                busy = true // set at once: a second tap before the task started removed it twice
                note = nil
                Task {
                    // the answer goes to AvatarBook too (APIClient.known): the letter shows everywhere at once
                    if let p = try? await APIClient.shared.deleteAvatar(token: token) { profile = p; onChange() }
                    else { note = NSLocalizedString("settings.failed", comment: "") }
                    busy = false
                }
            }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            note = nil
            Task {
                // a photo that cannot be read (iCloud offline, an unknown format) is said instead of nothing happening
                guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else {
                    note = NSLocalizedString("stx.pick.failed", comment: "")
                    return
                }
                cropping = PickedImage(image: img)
            }
        }
        .fullScreenCover(item: $cropping) { p in
            AvatarEditor(image: p.image) { jpeg in
                guard !busy else { return }
                busy = true
                note = nil
                Task {
                    // the new photo shows here, on the Settings card, in My status and everywhere else at once (AvatarBook);
                    // the server's reason (too large, not a picture) is shown when it refuses
                    do {
                        profile = try await APIClient.shared.uploadAvatar(token: token, jpeg: jpeg)
                        onChange()
                    } catch APIError.refused(let why) {
                        note = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
                    } catch {
                        note = NSLocalizedString("settings.failed", comment: "")
                    }
                    busy = false
                }
            }
        }
    }

    // MARK: look (the web's My Profile: desktop/src/features/profile/PersonalProfilePanel.tsx, 85-profile-v2.css)

    private static let azure = Theme.hex(0x5AA8FF)
    private var displayName: String {
        guard let p = profile else { return "" }
        return p.display_name.isEmpty ? p.username : p.display_name
    }
    private var hasPhoto: Bool { !(profile?.avatar_id.isEmpty ?? true) }
    private var edge: Color { Theme.accent.opacity(0.28) }

    /// The picture with its turquoise ring and camera badge, the name, the @handle, "Online" and the bio, on soft curved light lines.
    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                ProfileHeroLines().frame(height: 220)
                ZStack(alignment: .bottomTrailing) {
                    Avatar(token: token, userID: profile?.user_id ?? "", avatarID: hasPhoto ? profile?.avatar_id : nil,
                           title: displayName.isEmpty ? "?" : displayName, size: 124)
                        .padding(5)
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [Theme.accent, Self.azure], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 16)
                        .onTapGesture { if hasPhoto { viewing = true } }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.onAccent)
                            .frame(width: 38, height: 38)
                            .background(LinearGradient(colors: [Theme.accent, Theme.hex(0x0AAAB4)], startPoint: .top, endPoint: .bottom), in: Circle())
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 3))
                    }
                    .disabled(busy)
                    .accessibilityLabel(Text(LocalizedStringKey(hasPhoto ? "set.photo.change" : "set.photo.add")))
                    .offset(x: 2, y: 2)
                }
            }
            Text(displayName).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
                .lineLimit(2).multilineTextAlignment(.center)
            if let u = profile?.username, !u.isEmpty {
                Text("＠" + u).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            if live.steadyConnected && profile != nil {
                HStack(spacing: 6) {
                    Circle().fill(Theme.hex(0x14D99A)).frame(width: 8, height: 8)
                    Text("pv2.online").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            // the bio as it was written (its own line breaks, Arabic and English per line, emoji); a tap edits it
            Button { if profile != nil { editing = true } } label: {
                let bio = profile?.bio ?? ""
                Text(bio.isEmpty ? NSLocalizedString("pv2.bio.empty", comment: "") : bio)
                    .font(.system(size: 15)).lineSpacing(3)
                    .foregroundStyle(bio.isEmpty ? Theme.faint : Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8).padding(.top, 6)
            }
            .buttonStyle(.plain)
            .disabled(profile == nil)
        }
        .padding(.top, -6)
    }

    /// Edit Profile (the wide turquoise-to-azure pill), Share and My Identity's QR (square glass buttons).
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button { editing = true } label: {
                Label("set.edit.profile", systemImage: "pencil").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 54)
                    .background(LinearGradient(colors: [Theme.hex(0x12D6D8), Theme.hex(0x0AAAB4), Theme.hex(0x0B86C4)],
                                               startPoint: .leading, endPoint: .trailing), in: Capsule())
            }
            .disabled(profile == nil)
            ShareLink(item: "＠" + (profile?.username ?? "") + " · TRADEFLOR") {
                squareButton("square.and.arrow.up")
            }
            .disabled((profile?.username ?? "").isEmpty)
            .accessibilityLabel(Text("pv2.share"))
            NavigationLink { MyIdentityPage() } label: { squareButton("qrcode") }
                .accessibilityLabel(Text("settings.identity"))
        }
    }

    private func squareButton(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Theme.accent)
            .frame(width: 54, height: 54)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(edge, lineWidth: 1))
    }

    /// Groups, Chats and Member since (a year): turquoise, azure and gold.
    private var statRow: some View {
        HStack(spacing: 10) {
            stat("person.2", groupsCount.map(String.init) ?? "—", "pv2.groups", Theme.accent)
            stat("bubble.left.and.bubble.right", chatsCount.map(String.init) ?? "—", "pv2.chats", Self.azure)
            stat("calendar", memberYear ?? "—", "pv2.since", Theme.gold)
        }
    }

    private var memberYear: String? {
        guard let t = identity?.member_since, t > 0, let d = serverDate(t) else { return nil }
        return String(Calendar.current.component(.year, from: d))
    }

    private func stat(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint)
            Text(value).font(.system(size: 30, weight: .heavy)).monospacedDigit().foregroundStyle(Theme.text)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(LocalizedStringKey(label)).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private func pinRow(_ pin: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 19)).foregroundStyle(Theme.accent)
                .frame(width: 50, height: 50)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(edge, lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text("PIN").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                Text(pin).font(.system(size: 32, weight: .heavy)).monospacedDigit().tracking(2).foregroundStyle(Theme.text)
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { copy(pin, "set.copied.pin") } label: {
                Label("set.copy", systemImage: "doc.on.doc").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16).frame(height: 46)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(edge, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(edge, lineWidth: 1))
    }

    /// Account & Security, Privacy, Notifications and App Settings: icon tile, title, one line, chevron.
    private var linksCard: some View {
        VStack(spacing: 0) {
            linkRow("checkmark.shield", Theme.accent, "pv2.account", "settings.account.sub") { AccountPage() }
            linkDivider
            linkRow("lock", Self.azure, "pv2.privacy", "settings.privacy.sub") { PrivacyPage() }
            linkDivider
            linkRow("bell", Theme.gold, "settings.notifications", "settings.notifications.sub") { NotificationsPage() }
            linkDivider
            linkRow("slider.horizontal.3", Theme.accent, "pv2.app", "pv2.app.sub") { AppearancePage() }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(edge, lineWidth: 1))
    }

    private var linkDivider: some View { Rectangle().fill(edge.opacity(0.5)).frame(height: 1).padding(.leading, 78) }

    private func linkRow<D: View>(_ icon: String, _ tint: Color, _ title: String, _ sub: String,
                                  @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint)
                    .frame(width: 50, height: 50)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text(LocalizedStringKey(sub)).font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The photo actions, copy, and remove (the web's "more" menu).
    private var moreMenu: some View {
        Menu {
            PhotosPicker(selection: $picked, matching: .images) {
                Label(LocalizedStringKey(hasPhoto ? "set.photo.change" : "set.photo.add"), systemImage: "photo")
            }
            if hasPhoto {
                Button { viewing = true } label: { Label("set.photo.view", systemImage: "eye") }
            }
            Button { copy("＠" + (profile?.username ?? ""), "set.copied.username") } label: { Label("set.copy.username", systemImage: "at") }
            if let pin = identity?.pin, !pin.isEmpty { Button { copy(pin, "set.copied.pin") } label: { Label("set.copy.pin", systemImage: "number") } }
            if hasPhoto {
                Button(role: .destructive) { confirmRemove = true } label: { Label("set.photo.remove", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .disabled(busy)
        .accessibilityLabel(Text("chat.more"))
    }

    private func copy(_ s: String, _ key: String) {
        UIPasteboard.general.string = s
        note = NSLocalizedString(key, comment: "")
    }

    private func load() async {
        // a failed read keeps what is on screen (it used to blank the page)
        async let g = try? APIClient.shared.groups(token: token)
        async let c = try? APIClient.shared.conversations(token: token)
        if let p = try? await APIClient.shared.profile(token: token) { profile = p }
        if let g = await g { groupsCount = g.count }
        if let c = await c { chatsCount = c.count }
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

/// The soft curved turquoise / azure light lines behind the picture (the web's profile hero).
struct ProfileHeroLines: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<4 {
                let k = CGFloat(i)
                var p = Path()
                let y0 = size.height * (0.28 + 0.13 * k)
                p.move(to: CGPoint(x: 0, y: y0))
                p.addCurve(to: CGPoint(x: size.width, y: y0 - 34 + k * 12),
                           control1: CGPoint(x: size.width * 0.28, y: y0 - 80),
                           control2: CGPoint(x: size.width * 0.66, y: y0 + 70))
                ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.0), Theme.accent.opacity(0.45),
                                                                      Theme.hex(0x5AA8FF, 0.32), Theme.accent.opacity(0.0)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                           lineWidth: 1.3)
            }
        }
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AvatarViewer: View {
    let token: String
    let userID: String
    let avatarID: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if failed {
                // it could not be read: a way to try again instead of a spinner that never ends
                Button { failed = false; Task { await load() } } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.title3)
                        Text("photo.retry").font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 160, height: 120)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("chat.close"))
            .padding()
        }
        .gesture(DragGesture().onEnded { v in
            if v.translation.height > 120 || v.predictedEndTranslation.height > 320 { dismiss() } // swipe down closes
        })
        .task { await load() }
    }

    private func load() async {
        guard !avatarID.isEmpty, let d = await APIClient.shared.avatar(token: token, userID: userID, avatarID: avatarID),
              let img = UIImage(data: d) else {
            failed = true
            return
        }
        image = img
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
    @State private var loadFailed = false

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.account", comment: ""), subtitle: NSLocalizedString("settings.account.sub", comment: ""), icon: "person") {
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
            // .s-card-head: "@username", "Signed in on this device"; then Username (copy) and Connection (the green Live pill)
            SBanner(icon: "person", title: "@" + (store.session?.username ?? ""), subtitle: NSLocalizedString("set.signed.here", comment: ""))
            SCard {
                HStack(spacing: 14) {
                    Image(systemName: "person").font(.system(size: 19)).foregroundStyle(SetUI.accent).frame(width: 24).padding(.horizontal, 4)
                    Text("signup.username").font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
                    Spacer(minLength: 6)
                    Text("@" + (store.session?.username ?? "")).font(.system(size: 14.5, weight: .medium)).foregroundStyle(SetUI.sub).lineLimit(1)
                    Button {
                        UIPasteboard.general.string = "@" + (store.session?.username ?? "")
                        note = NSLocalizedString("set.copied.username", comment: "")
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 17)).foregroundStyle(SetUI.sub)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("set.copy.username"))
                }
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 64)
                SDivider()
                connectionRow
            }
            VStack(alignment: .leading, spacing: 3) {
                SSection(text: NSLocalizedString("set.account.info", comment: ""))
                Text("set.account.private").font(.system(size: 13)).foregroundStyle(SetUI.dim).padding(.horizontal, 4)
            }
            if let a = account {
                SCard {
                    SKeyValue(key: NSLocalizedString("set.realname", comment: ""), value: a.full_name.isEmpty ? "—" : a.full_name,
                               action: NSLocalizedString("set.edit", comment: "")) { startEdit() }
                    SDivider()
                    // no email yet (needs_email): a dash, not " · Not verified" on its own
                    SKeyValue(key: NSLocalizedString("signup.email", comment: ""),
                               value: a.email.isEmpty ? "—"
                                : a.email + " · " + NSLocalizedString(a.email_verified ? "set.verified" : "set.notverified", comment: ""))
                    SDivider()
                    SKeyValue(key: NSLocalizedString("set.phone", comment: ""),
                               value: a.phone.isEmpty ? NSLocalizedString("set.phone.none", comment: "") : a.phone,
                               action: NSLocalizedString("set.edit", comment: "")) { startEdit() }
                    SDivider()
                    SKeyValue(key: NSLocalizedString("set.country", comment: ""),
                               value: a.country.isEmpty ? NSLocalizedString("set.unknown", comment: "") : CalendarView.flag(a.country) + " " + a.country)
                    SDivider()
                    SKeyValue(key: NSLocalizedString("set.joined", comment: ""),
                               value: Date(timeIntervalSince1970: Double(a.created_at)).formatted(date: .numeric, time: .omitted))
                }
            } else if loadFailed {
                // not read (offline, server busy): said, with a way to try again, instead of a skeleton that never ends
                VStack(spacing: 8) {
                    Text("adm.failed").font(.system(size: 13)).foregroundStyle(SetUI.sub)
                    Button("chats.retry") { Task { await loadAccount() } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                // the private details on their way: the rows' shape, quietly (no spinner)
                SCard {
                    ForEach(0..<5, id: \.self) { i in
                        if i > 0 { SDivider() }
                        HStack(spacing: 10) {
                            QuietSkeleton(width: 70, height: 11, radius: 4).frame(width: 96, alignment: .leading)
                            QuietSkeleton(width: 130, height: 13, radius: 4)
                            Spacer()
                        }
                        .padding(.horizontal, 14).frame(minHeight: 56)
                    }
                }
            }
            if editing {
                SCard {
                    VStack(spacing: 10) {
                        TextField("set.realname", text: $fullName).textContentType(.name)
                        Divider()
                        TextField("set.phone", text: $phone).keyboardType(.phonePad)
                        Divider()
                        SecureField("set.password.confirm", text: $password).textContentType(.password)
                        HStack {
                            Button("chat.close") { editing = false; password = ""; problem = nil }.foregroundStyle(Theme.faint)
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
        .modifier(KeyboardDoneBar())
        .task { await loadAccount() }
        .refreshable { await loadAccount() }
    }

    private func loadAccount() async {
        loadFailed = false
        do { account = try await APIClient.shared.stPrivateAccount(token: token) } catch {
            if account == nil { loadFailed = true }
        }
    }

    /// Connection: the green "● Live" pill (13-settings.css .s-live), amber while reconnecting.
    private var connectionRow: some View {
        let on = live.steadyConnected
        return HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 18)).foregroundStyle(SetUI.accent).frame(width: 24).padding(.horizontal, 4)
            Text("settings.connection").font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Circle().frame(width: 9, height: 9).shadow(color: on ? Theme.hex(0x14D99A, 0.6) : .clear, radius: 4)
                Text(LocalizedStringKey(on ? "settings.live" : "set.reconnecting")).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(on ? Theme.hex(0x14D99A) : Theme.hex(0xF0B46A))
            .padding(.horizontal, 12).frame(height: 30)
            .background(on ? Theme.dyn(0x012F36, 0xE3F7EE) : Theme.hex(0xF0B46A, 0.1), in: Capsule())
            .overlay(Capsule().stroke(on ? Theme.hex(0x00CC83, 0.25) : Theme.hex(0xF0B46A, 0.3), lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 64)
    }

    private func startEdit() {
        fullName = account?.full_name ?? ""
        phone = account?.phone ?? ""
        password = ""
        problem = nil
        editing = true
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await APIClient.shared.stUpdatePrivateAccount(token: token, password: password,
                                                              fullName: fullName != account?.full_name ? fullName : nil,
                                                              phone: phone != account?.phone ? phone : nil)
            account = (try? await APIClient.shared.stPrivateAccount(token: token)) ?? account
            editing = false
            password = "" // the account password does not stay in memory once used
            note = NSLocalizedString("set.saved", comment: "")
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch APIError.rateLimited {
            // 10 changes per 10 minutes (account-private)
            problem = NSLocalizedString("login.error.rate", comment: "")
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
    @State private var loadFailed = false

    private var token: String { store.session?.token ?? "" }
    @State private var connectCode: String?
    /// The card's QR is the Flash Connect link (an opaque code, never the PIN); the older ?id= link until it is known.
    private var link: String {
        if let c = connectCode, !c.isEmpty { return "https://app.tradeflor.com/?connect=\(c)" }
        return "https://app.tradeflor.com/?id=\(id?.pin ?? "")"
    }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.identity", comment: ""), subtitle: NSLocalizedString("settings.identity.sub", comment: ""), icon: "qrcode") {
            if let id {
                IdentityShowcase(id: id, link: link, token: token)
                    .padding(.vertical, 8)

                SCard {
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
                                    .submitLabel(.done)
                                    .onChange(of: newName) { v in
                                        // the server's names are 3 to 24 characters
                                        if v.count > 24 { newName = String(v.prefix(24)); return }
                                        note = nil
                                        Task { await check(v) }
                                    }
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
                if let note { Text(note).font(.system(size: 13)).foregroundStyle(Theme.accent) }
            } else if loadFailed {
                VStack(spacing: 8) {
                    Text("adm.failed").font(.system(size: 13)).foregroundStyle(SetUI.sub)
                    Button("chats.retry") { Task { await load() } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                QuietSkeleton(height: 250, radius: 18)
                QuietSkeleton(height: 150, radius: 18)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .task { connectCode = try? await APIClient.shared.ctMyCode(token: token) }
    }

    private func load() async {
        loadFailed = false
        if let d = try? await APIClient.shared.getJSON("identity/me", token: token),
           let card = try? JSONDecoder().decode(StIdentity.self, from: d) {
            id = card
            store.renamed(card.username)
        } else if id == nil {
            loadFailed = true // said, with Try again, instead of the card's skeleton for ever
        }
    }

    private func check(_ v: String) async {
        let u = v.trimmingCharacters(in: .whitespaces).lowercased()
        // the name changed: the earlier "available" no longer holds until this one is checked (Change could send an
        // unchecked name in that window)
        nameOK = false
        guard u.count >= 3 else { nameNote = nil; return }
        // my own name is "free" for me on the server: offering Change for it only spent the once-in-a-while change
        if u == id?.username.lowercased() { nameNote = nil; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard u == newName.trimmingCharacters(in: .whitespaces).lowercased() else { return }
        let answer = await APIClient.shared.stUsernameAvailable(token: token, u)
        guard u == newName.trimmingCharacters(in: .whitespaces).lowercased() else { return } // typed on meanwhile
        guard let r = answer else {
            // no answer (offline, too many checks): not "available"
            nameNote = NSLocalizedString("adm.failed", comment: "")
            return
        }
        nameOK = r.available
        nameNote = r.available ? NSLocalizedString("set.username.free", comment: "") : (r.reason ?? NSLocalizedString("signup.username.taken", comment: ""))
    }

    private func change() async {
        guard !busy, nameOK else { return }
        busy = true
        defer { busy = false }
        do {
            let card = try await APIClient.shared.stChangeUsername(token: token, newName.trimmingCharacters(in: .whitespaces).lowercased())
            newName = ""
            nameOK = false
            store.renamed(card.username) // "@name" on Settings, Account, Flash Connect… follow at once
            await load()
            nameNote = nil
            note = NSLocalizedString("set.saved", comment: "")
        } catch APIError.refused(let why) {
            nameNote = why
            nameOK = false
        } catch APIError.rateLimited {
            // changed recently (the server's cooldown, 429) or too many tries: the card says until when once read again
            nameOK = false
            await load()
            nameNote = NSLocalizedString("login.error.rate", comment: "")
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
    @State private var stopping = false
    @State private var loaded = false
    private var token: String { store.session?.token ?? "" }
    private var active: [LivePosition] { mine.filter { $0.stopped != true && Double($0.until) > Date().timeIntervalSince1970 } }

    var body: some View {
        SettingsPage(title: NSLocalizedString("location.live", comment: ""), icon: "location") {
            if !loaded {
                // reading: "You're not sharing your location" flashed before the list of shares arrived
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if active.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "location.slash").font(.system(size: 30)).foregroundStyle(Theme.faint)
                    Text("set.loc.none").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("set.loc.none.sub").font(.system(size: 12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                SCard {
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
                            Button("set.stop") { Task { await stopAll([p.conversation_id]) } }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.danger)
                                .disabled(stopping)
                        }
                        .padding(14)
                        if i < active.count - 1 { SDivider() }
                    }
                }
                // "Stop sharing everywhere" only when there is more than one (web), the one row's Stop does the rest
                if active.count > 1 {
                    Button {
                        Task { await stopAll(active.map(\.conversation_id)) }
                    } label: {
                        Text("set.loc.stopall").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, minHeight: 44).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                    }
                    .disabled(stopping)
                    .opacity(stopping ? 0.5 : 1)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        mine = await APIClient.shared.stMyLocations(token: token)
        loaded = true
        let chats = (try? await APIClient.shared.conversations(token: token)) ?? []
        let groups = (try? await APIClient.shared.groups(token: token)) ?? []
        var n: [String: String] = [:]
        for c in chats { n[c.conversation_id] = c.title }
        for g in groups { n[g.conversation_id] = g.name }
        names = n
    }

    /// Stops sharing in these chats, then reads the list once (it was read again after each one, and a second tap
    /// started the same stops twice).
    private func stopAll(_ convs: [String]) async {
        guard !stopping, !convs.isEmpty else { return }
        stopping = true
        defer { stopping = false }
        for conv in convs {
            LocationSharer.shared.stop(conversationID: conv)
            await APIClient.shared.stopLocation(token: token, conversationID: conv)
        }
        await load()
    }
}

// MARK: Events

struct EventsPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var items: [SavedEventFull] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var working: Set<String> = []
    @State private var problem: String?
    private var token: String { store.session?.token ?? "" }
    private var now: Int64 { Int64(Date().timeIntervalSince1970) }
    private var upcoming: [SavedEventFull] { items.filter { $0.event_at >= now }.sorted { $0.event_at < $1.event_at } }
    private var past: [SavedEventFull] { items.filter { $0.event_at < now && $0.event_at >= now - 7 * 86400 }.sorted { $0.event_at > $1.event_at } }
    static let reminders = [0, 5, 15, 30, 60]

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.events", comment: ""), subtitle: NSLocalizedString("settings.events.sub", comment: ""), icon: "calendar.badge.clock") {
            if loading && items.isEmpty {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if loadFailed {
                VStack(spacing: 8) {
                    Text("adm.failed").font(.system(size: 13)).foregroundStyle(SetUI.sub)
                    Button("chats.retry") { Task { loading = true; await load() } }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if !loading && upcoming.isEmpty && past.isEmpty {
                // also when every saved event is older than a week (the page was blank then)
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 30)).foregroundStyle(Theme.faint)
                    Text("set.events.none").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("settings.events.none").font(.system(size: 12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            if !upcoming.isEmpty { section("set.events.upcoming", upcoming) }
            if !past.isEmpty { section("set.events.past", past) }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func section(_ key: String, _ list: [SavedEventFull]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SSection(text: NSLocalizedString(key, comment: ""))
            SCard {
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
                                    // the chosen one is ticked; choosing it again sends nothing
                                    ForEach(Self.reminders, id: \.self) { m in
                                        Button {
                                            if m != (e.remind_minutes ?? 15) { Task { await remind(e, m) } }
                                        } label: {
                                            if m == (e.remind_minutes ?? 15) { Label(Self.label(m), systemImage: "checkmark") } else { Text(Self.label(m)) }
                                        }
                                    }
                                } label: {
                                    Label(Self.label(e.remind_minutes ?? 15), systemImage: "bell").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                                .disabled(working.contains(e.event_key))
                            }
                        }
                        Spacer()
                        Button { Task { await remove(e) } } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.faint)
                                .frame(width: 40, height: 40).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(working.contains(e.event_key))
                        .accessibilityLabel(Text("set.events.remove"))
                    }
                    .padding(12)
                    if i < list.count - 1 { SDivider() }
                }
            }
        }
    }

    static func label(_ m: Int) -> String {
        m == 0 ? NSLocalizedString("set.remind.none", comment: "")
            : (m == 60 ? NSLocalizedString("set.remind.1h", comment: "") : String(format: NSLocalizedString("set.remind.min", comment: ""), m))
    }

    private func load() async {
        do {
            items = try await APIClient.shared.stSavedEvents(token: token)
            loadFailed = false
        } catch {
            // not read: said (it showed "No saved events yet" as if the list were empty)
            loadFailed = items.isEmpty
        }
        loading = false
    }

    private func remind(_ e: SavedEventFull, _ minutes: Int) async {
        guard !working.contains(e.event_key) else { return }
        working.insert(e.event_key)
        defer { working.remove(e.event_key) }
        problem = nil
        do { try await APIClient.shared.stResaveEvent(token: token, e, remind: minutes) } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
        await load()
    }

    private func remove(_ e: SavedEventFull) async {
        guard !working.contains(e.event_key) else { return }
        working.insert(e.event_key)
        defer { working.remove(e.event_key) }
        problem = nil
        if (try? await APIClient.shared.removeSavedEvent(token: token, key: e.event_key)) != nil {
            items.removeAll { $0.id == e.id }
        } else {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }
}

// MARK: Notifications / Privacy (account switches)

/// Loads the account's switches once and saves each change (POST /settings {key: bool}).
@MainActor
final class AccountSwitches: ObservableObject {
    @Published var values: [String: Bool] = [:]
    @Published var problem: String?
    /// The server's own defaults (messaging/prefs.go settingDefaults): "when_focused" and "calls.confirm" is off there since 2026-11-18 (the owner asked: a call starts at once),
    /// and a page that could not read the account showed them off.
    static let defaults: [String: Bool] = [
        "notifications.enabled": true, "notifications.sound": true, "notifications.previews": true, "notifications.when_focused": true,
        "notifications.groups": true, "notifications.mentions": true, "notifications.mentions_in_muted": true,
        "privacy.read_receipts": true, "privacy.calls_enabled": true, "privacy.calls_contacts_only": false, "calls.confirm": false,
    ]

    func load(_ token: String) async {
        do {
            let s = try await APIClient.shared.stSettings(token: token)
            values = Self.defaults.merging(s) { _, new in new }
            problem = nil
        } catch {
            // not read: the switches show the defaults, and the page says so (they used to pass for the account's own)
            if values.isEmpty { values = Self.defaults }
            problem = NSLocalizedString("ls.failed", comment: "")
        }
    }

    func binding(_ key: String, token: String) -> Binding<Bool> {
        Binding(get: { self.values[key] ?? Self.defaults[key] ?? false }, set: { v in
            self.values[key] = v
            self.problem = nil
            Task {
                do {
                    try await APIClient.shared.stSetSetting(token: token, key: key, value: v)
                    // this phone's own notifications follow at once (they read the switches at most every 2 minutes)
                    LocalNotifier.shared.settingChanged(key, v)
                } catch {
                    // back to what the server has, unless the switch was flipped again meanwhile
                    if self.values[key] == v { self.values[key] = !v }
                    self.problem = NSLocalizedString("settings.failed", comment: "")
                }
            }
        })
    }
}

struct NotificationsPage: View {
    @EnvironmentObject private var store: SessionStore
    @StateObject private var sw = AccountSwitches()
    @State private var system: UNAuthorizationStatus?
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.notifications", comment: ""), subtitle: NSLocalizedString("settings.notifications.sub", comment: ""), icon: "bell") {
            // .s-card-head "Alerts & Sounds", then ALERTS and GROUPS & MENTIONS: label + switch rows, no icons (as the web)
            SBanner(icon: "bell", title: NSLocalizedString("set.alerts", comment: ""), subtitle: NSLocalizedString("ux3.set.n.banner", comment: ""))
            systemNote
            SSection(text: NSLocalizedString("ux3.set.alerts.sec", comment: ""))
            SCard {
                SToggleRow(icon: "", title: NSLocalizedString("set.n.enabled", comment: ""), subtitle: NSLocalizedString("set.n.enabled.sub", comment: ""),
                            isOn: sw.binding("notifications.enabled", token: token))
                SDivider()
                SToggleRow(icon: "", title: NSLocalizedString("set.n.sound", comment: ""), isOn: sw.binding("notifications.sound", token: token))
                SDivider()
                SToggleRow(icon: "", title: NSLocalizedString("set.n.previews", comment: ""), isOn: sw.binding("notifications.previews", token: token))
                SDivider()
                SToggleRow(icon: "", title: NSLocalizedString("set.n.focused", comment: ""), isOn: sw.binding("notifications.when_focused", token: token))
            }
            SSection(text: NSLocalizedString("set.n.groups.sec", comment: ""))
            SCard {
                SToggleRow(icon: "", title: NSLocalizedString("set.n.groups", comment: ""), isOn: sw.binding("notifications.groups", token: token))
                SDivider()
                SToggleRow(icon: "", title: NSLocalizedString("set.n.mentions", comment: ""), isOn: sw.binding("notifications.mentions", token: token))
                SDivider()
                SToggleRow(icon: "", title: NSLocalizedString("set.n.mentions.muted", comment: ""), isOn: sw.binding("notifications.mentions_in_muted", token: token))
            }
            Text("settings.notifications.text").font(.system(size: 13)).foregroundStyle(SetUI.dim).padding(.horizontal, 4)
            if let p = sw.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await sw.load(token) }
        .task { await readSystem() }
        // back from iOS Settings: the note goes once notifications are allowed there
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await readSystem() }
        }
    }

    /// The web's "Notifications are blocked for this site" note: the account's switches do nothing while iOS itself does
    /// not let Tradeflor notify.
    @ViewBuilder private var systemNote: some View {
        if sw.values["notifications.enabled"] ?? true, let s = system, s == .denied || s == .notDetermined {
            HStack(spacing: 12) {
                Image(systemName: "bell.slash").font(.system(size: 18)).foregroundStyle(Theme.gold).accessibilityHidden(true)
                Text(LocalizedStringKey(s == .denied ? "set.n.os.denied" : "set.n.os.notyet"))
                    .font(.system(size: 13)).foregroundStyle(SetUI.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    if s == .denied {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    } else {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                            await readSystem()
                        }
                    }
                } label: {
                    Text(LocalizedStringKey(s == .denied ? "cam.settings" : "folder.allow")).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SetUI.accent).padding(.horizontal, 12).frame(minHeight: 36)
                        .overlay(Capsule().stroke(SetUI.tileEdge, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
        }
    }

    private func readSystem() async {
        system = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
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
    @State private var savingPIN = false
    @State private var presence: PresencePrivacy?
    @ObservedObject private var calls = CallManager.shared
    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.privacy", comment: ""), subtitle: NSLocalizedString("settings.privacy.sub", comment: ""), icon: "checkmark.shield") {
            SBanner(icon: "checkmark.shield", title: NSLocalizedString("ux3.set.p.title", comment: ""), subtitle: NSLocalizedString("ux3.set.p.banner", comment: ""))
            // Who can see my personal info: Last seen and online (website LastSeenPrivacy.tsx, server d4d2e77)
            SSection(text: NSLocalizedString("ls.section", comment: ""))
            SCard {
                NavigationLink { LastSeenPrivacyView() } label: {
                    SRow(icon: "eye", title: NSLocalizedString("ls.row", comment: ""), subtitle: LastSeenPrivacyView.summary(presence))
                }
                .buttonStyle(.plain)
            }
            // read on every appearance: back from "Last seen & online" the line shows the choice just made (a .task ran
            // once, and the old choice stayed)
            .onAppear { Task { if let p = try? await APIClient.shared.presencePrivacy(token: token) { presence = p } } }
            SSection(text: NSLocalizedString("ux3.set.p.messages", comment: ""))
            SCard {
                SToggleRow(icon: "", title: NSLocalizedString("set.p.receipts", comment: ""), subtitle: NSLocalizedString("set.p.receipts.sub", comment: ""),
                            isOn: sw.binding("privacy.read_receipts", token: token))
            }
            // Calls: only while calls are on for the account; "Only my contacts" only while audio calls are allowed (web)
            if calls.enabled {
                SSection(text: NSLocalizedString("settings.calls", comment: ""))
                SCard {
                    SToggleRow(icon: "", title: NSLocalizedString("set.p.calls", comment: ""), isOn: sw.binding("privacy.calls_enabled", token: token))
                    if sw.values["privacy.calls_enabled"] ?? true {
                        SDivider()
                        SToggleRow(icon: "", title: NSLocalizedString("set.p.contactsonly", comment: ""),
                                    isOn: sw.binding("privacy.calls_contacts_only", token: token))
                    }
                }
            }
            SSection(text: NSLocalizedString("set.chatlock", comment: ""))
            SCard {
                HStack(spacing: 14) {
                    Image(systemName: "lock").font(.system(size: 19)).foregroundStyle(SetUI.accent).frame(width: 24).padding(.horizontal, 4)
                    Text("lock.pin").font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
                    Spacer()
                    // .chip-btn: the Calls pill button
                    Button {
                        pinForm.toggle()
                        // closed: nothing typed (the account password above all) stays behind
                        if !pinForm { password = ""; pin1 = ""; pin2 = ""; problem = nil }
                    } label: {
                        Text(LocalizedStringKey(hasPIN ? "set.change" : "set.set")).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.dyn(0xE6F2F5, 0x0E2A3A))
                            .padding(.horizontal, 16).frame(minHeight: 40)
                            .background(Theme.dyn(0x08D9D9, 0xF2F8FA, 0.06, 1), in: Capsule())
                            .overlay(Capsule().stroke(Theme.dyn(0x288CAA, 0x0A8FA0, 0.45, 0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 64)
                if pinForm {
                    VStack(spacing: 10) {
                        SecureField("set.password.account", text: $password).textContentType(.password)
                        Divider()
                        SecureField("set.pin.new", text: $pin1).keyboardType(.numberPad)
                        Divider()
                        SecureField("set.pin.repeat", text: $pin2).keyboardType(.numberPad)
                        Button { Task { await savePIN() } } label: {
                            Group { if savingPIN { ProgressView().tint(Theme.onAccent) } else { Text("settings.save").bold() } }
                                .foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 38).background(Theme.accent, in: Capsule())
                        }
                        .disabled(password.isEmpty || pin1.count < 6 || savingPIN)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                if BiometricPIN.biometryAvailable && pinSaved {
                    SDivider()
                    Button {
                        BiometricPIN.delete()
                        pinSaved = false
                    } label: {
                        SRow(icon: "faceid", title: String(format: NSLocalizedString("settings.lock.forget", comment: ""), BiometricPIN.biometryName),
                              tint: Theme.danger, showChevron: false)
                    }
                }
                if unlocked {
                    SDivider()
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
        .modifier(KeyboardDoneBar())
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
        guard !savingPIN else { return }
        savingPIN = true
        defer { savingPIN = false }
        problem = nil
        // the server takes 0-9 only: digits typed on an Arabic keypad (٠١٢…) are the same digits, sent as 0-9
        let a = Self.asciiDigits(pin1), b = Self.asciiDigits(pin2)
        guard a == b else { problem = NSLocalizedString("set.pin.mismatch", comment: ""); return }
        guard let pin = a, pin.count >= 6, pin.count <= 10 else { problem = NSLocalizedString("set.pin.rule", comment: ""); return }
        do {
            try await APIClient.shared.stSetLockPIN(token: token, password: password, pin: pin)
            BiometricPIN.delete()
            pinSaved = false
            hasPIN = true
            pinForm = false
            password = ""; pin1 = ""; pin2 = ""
            // a new PIN starts locked on the server (locks.Relock): the open grant this phone held no longer works
            await APIClient.shared.relockChats(token: token)
            unlocked = false
            note = NSLocalizedString("set.pin.saved", comment: "")
        } catch APIError.refused(let why) {
            // the server's lines are English: the wrong password (403) and the PIN rule (400) are said in the app's words
            if why.localizedCaseInsensitiveContains("password") { problem = NSLocalizedString("lockc.badpassword", comment: "") }
            else if why.localizedCaseInsensitiveContains("PIN") { problem = NSLocalizedString("set.pin.rule", comment: "") }
            else { problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why }
        } catch APIError.rateLimited {
            problem = NSLocalizedString("lock.slow", comment: "")
        } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }

    /// "123456" for any decimal digits (Western or Arabic-Indic); nil when something else was typed.
    static func asciiDigits(_ s: String) -> String? {
        var out = ""
        for ch in s {
            guard let v = ch.wholeNumberValue, (0...9).contains(v), ch.isNumber else { return nil }
            out += String(v)
        }
        return out
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
    @State private var clearing = false
    @State private var loaded = false
    @ObservedObject private var calls = CallManager.shared
    private var token: String { store.session?.token ?? "" }

    /// .cs-row: a 40 pt icon tile (radius 12; bare in the "This Device" list), the label 16 and its 13 note, the control.
    private func csRow<Control: View>(icon: String, title: String, note: String? = nil, plain: Bool = false,
                                      @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(SetUI.accent)
                .frame(width: plain ? 32 : 40, height: 40)
                .background(plain ? Color.clear : SetUI.tileFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(plain ? Color.clear : SetUI.tileEdge, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text)
                if let note { Text(LocalizedStringKey(note)).font(.system(size: 13)).foregroundStyle(SetUI.sub).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 64)
    }

    /// .cs-call: face 46, name 16, the direction arrow (green answered, red missed) with "Outgoing · 4:47", the time, a 44 pt
    /// call-back circle.
    private func callRow(_ c: CallHistoryItem) -> some View {
        let chat = names[c.conversation_id]
        let ok = c.status == "completed" || c.duration_ms > 0
        let bad = !ok && (c.status == "missed" || c.status == "declined" || c.status == "failed")
        let name = chat?.title ?? "—"
        let when = Date(timeIntervalSince1970: Double(c.created_at > 100_000_000_000 ? c.created_at / 1000 : c.created_at))
        return HStack(spacing: 12) {
            Avatar(token: token, userID: c.peer_id, avatarID: nil, title: name, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: c.direction == "outgoing" ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ok ? Theme.hex(0x14D99A) : (bad ? Theme.hex(0xFF5E6E) : Theme.hex(0x8FA8B3)))
                    Text(Self.label(c)).font(.system(size: 13.5))
                        .foregroundStyle(bad ? Theme.dyn(0xC9A0A6, 0xA4505C) : Theme.dyn(0xA9BCC6, 0x46657A)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(ChatRow.timeLabel(when)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.dyn(0xA9BCC6, 0x46657A))
            Button { if let chat { calls.start(conversationID: chat.conversation_id, peerName: chat.title, peerID: chat.peer_id) } } label: {
                Image(systemName: "phone").font(.system(size: 17)).foregroundStyle(Theme.dyn(0xE6F2F5, 0x0E2A3A))
                    .frame(width: 44, height: 44)
                    .background(Theme.dyn(0x031E28, 0xF2F8FA, 0.7, 1), in: Circle())
                    .overlay(Circle().stroke(Theme.dyn(0x288CAA, 0x0A8FA0, 0.45, 0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(chat == nil || calls.lineInUse)
            .opacity(chat == nil || calls.lineInUse ? 0.45 : 1)
            .accessibilityLabel(Text("call.voice"))
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 8)
        .frame(minHeight: 68)
    }

    /// "Outgoing", "Incoming" or "Missed", with the length when there was one.
    static func label(_ c: CallHistoryItem) -> String {
        let dir: String
        switch (c.direction, c.status) {
        case ("incoming", "missed"): dir = NSLocalizedString("set.c.missed", comment: "")
        case ("incoming", _): dir = NSLocalizedString("set.c.incoming", comment: "")
        default: dir = NSLocalizedString("set.c.outgoing", comment: "")
        }
        return c.duration_ms > 0 ? dir + " · " + VoiceBubble.length(c.duration_ms) : dir
    }

    var body: some View {
        // 43-calls-settings.css: the "Voice Calls" banner, the confirmation row, THIS DEVICE (ring, microphone, speaker),
        // RECENT CALLS with Clear All, each call with the face, name, direction and length, time, and a call-back button
        SettingsPage(title: NSLocalizedString("settings.calls", comment: ""), subtitle: NSLocalizedString("settings.calls.sub", comment: ""), icon: "phone") {
            SBanner(icon: "phone", title: NSLocalizedString("set.c.hero", comment: ""), subtitle: NSLocalizedString("set.c.hero.sub", comment: ""))
            SCard {
                csRow(icon: "questionmark.circle", title: "set.c.confirm", note: "ux3.set.c.confirm.sub") {
                    Toggle(NSLocalizedString("set.c.confirm", comment: ""), isOn: sw.binding("calls.confirm", token: token))
                        .labelsHidden().toggleStyle(TFSwitchStyle())
                }
            }
            SSection(text: NSLocalizedString("set.c.device", comment: ""))
            SCard {
                csRow(icon: "bell.and.waves.left.and.right", title: "set.c.ring", plain: true) {
                    Toggle(NSLocalizedString("set.c.ring", comment: ""), isOn: $ring).labelsHidden().toggleStyle(TFSwitchStyle())
                }
                .onChange(of: ring) { _ in CallManager.shared.applyRingSetting() }
                SDivider()
                csRow(icon: "mic", title: "set.c.mic", plain: true) {
                    Text("set.c.bydevice").font(.system(size: 14)).foregroundStyle(SetUI.sub)
                }
                SDivider()
                csRow(icon: "speaker.wave.2", title: "set.c.speaker", plain: true) {
                    Text("set.c.bydevice").font(.system(size: 14)).foregroundStyle(SetUI.sub)
                }
            }
            HStack {
                SSection(text: NSLocalizedString("set.c.recent", comment: ""))
                Spacer()
                if !history.isEmpty {
                    Button { confirmClear = true } label: {
                        Label("set.c.clear", systemImage: "trash").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent)
                            .padding(.horizontal, 10).frame(minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(calls.phase != .idle || clearing)
                    .opacity(calls.phase != .idle ? 0.45 : 1)
                    .padding(.top, 8)
                }
            }
            if !loaded {
                SCard {
                    ForEach(0..<3, id: \.self) { i in
                        if i > 0 { SDivider() }
                        HStack(spacing: 12) {
                            QuietSkeleton(width: 46, height: 46, radius: 23)
                            VStack(alignment: .leading, spacing: 6) {
                                QuietSkeleton(width: 110, height: 13, radius: 4)
                                QuietSkeleton(width: 150, height: 10, radius: 4)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).frame(minHeight: 68)
                    }
                }
            } else if history.isEmpty {
                Text("set.c.none").font(.system(size: 14)).foregroundStyle(Theme.dyn(0xA9BCC6, 0x46657A))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .sCardChrome()
            } else {
                SCard {
                    ForEach(Array(history.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { SDivider() }
                        callRow(c)
                    }
                }
            }
            // a switch that did not save (it flips back) and a failed Clear All say so here
            if let p = sw.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .task { await load() }
        // a call placed from this list (call back) is in it once it ended: the page stays open under the call screen
        .onChange(of: calls.phase) { p in if p == .idle && loaded { Task { await load() } } }
        .confirmationDialog(Text("set.c.clear.confirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("set.c.clear", role: .destructive) {
                guard !clearing else { return }
                clearing = true
                Task {
                    defer { clearing = false }
                    sw.problem = nil
                    do {
                        try await APIClient.shared.stClearCallHistory(token: token)
                        history = [] // gone at once, not only after the list is read again
                    } catch {
                        sw.problem = NSLocalizedString("settings.failed", comment: "")
                    }
                    await load()
                }
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
        loaded = true
        let chats = (try? await APIClient.shared.conversations(token: token)) ?? []
        names = Dictionary(chats.map { ($0.conversation_id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: Appearance / About

struct AppearancePage: View {
    @AppStorage("tf.night") private var night = true
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.appearance", comment: ""),
                     subtitle: NSLocalizedString(night ? "ux3.set.night" : "ux3.set.day", comment: ""), icon: "paintpalette") {
            SBanner(icon: "moon", title: NSLocalizedString("ux3.set.theme", comment: ""), subtitle: NSLocalizedString("ux3.set.theme.sub", comment: ""))
            SCard {
                SToggleRow(icon: "", title: NSLocalizedString("set.night", comment: ""),
                            subtitle: NSLocalizedString(night ? "ux3.set.night.on" : "ux3.set.night.off", comment: ""), isOn: $night)
            }
            Text("set.night.note").font(.system(size: 13)).foregroundStyle(SetUI.dim).padding(.horizontal, 4)
        }
    }
}

struct AboutPage: View {
    static var versionBuild: String {
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        return build.isEmpty || build == AppConfig.version ? AppConfig.version : "\(AppConfig.version) (\(build))"
    }
    @State private var note: String?
    @ObservedObject private var stats = DeliveryStats.shared
    @State private var mediaLog = MediaLog.read()
    @State private var showLog = false
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.about", comment: ""),
                     subtitle: String(format: NSLocalizedString("ux3.set.version.n", comment: ""), AppConfig.version), icon: "info.circle") {
            SBanner(icon: "info.circle", title: "Tradeflor", subtitle: NSLocalizedString("ux3.set.about.sub", comment: ""), image: "BrandFlower")
            SCard {
                // the version and its build ("1.4 (212)"): two TestFlight builds of one version were told apart nowhere
                SKeyValue(key: NSLocalizedString("set.version", comment: ""), value: Self.versionBuild, action: NSLocalizedString("set.copy", comment: "")) {
                    UIPasteboard.general.string = "Tradeflor iOS \(Self.versionBuild)"
                    note = NSLocalizedString("set.copied", comment: "")
                }
                SDivider()
                SKeyValue(key: NSLocalizedString("set.server", comment: ""), value: AppConfig.apiBase.host ?? "")
                SDivider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("about.live").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(stats.summary).font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
                SDivider()
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
