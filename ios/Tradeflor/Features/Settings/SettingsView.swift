import SwiftUI
import PhotosUI
import CoreImage.CIFilterBuiltins

/// Settings as on the website (45-settings-unified.css): title and subtitle, the profile card with "My Profile",
/// then ACCOUNT (Account, My Identity), ACTIVITY (Live location, Linked devices, Events), PREFERENCES
/// (Notifications, Privacy & Security, Calls, Appearance), APP (About) and Sign out.
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var profile: Profile?
    @State private var identity: IdentityCard?
    @State private var devices: [LinkedDevice] = []
    @State private var picked: PhotosPickerItem?
    @State private var busy = false
    @State private var problem: String?
    @State private var editing = false
    @State private var confirmSignOut = false
    @State private var pinSaved = BiometricPIN.isSaved
    @ObservedObject private var location = LocationSharer.shared
    @ObservedObject private var calls = CallManager.shared

    private var token: String { store.session?.token ?? "" }
    private var name: String { profile.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? (store.session?.username ?? "") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("settings.title").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
                            Text("settings.subtitle").font(.system(size: 13)).foregroundStyle(Theme.faint)
                        }
                        Spacer()
                        Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40).background(Theme.card, in: Circle())
                            .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                    }
                    .padding(.bottom, 14)

                    profileCard

                    TFSectionLabel(text: NSLocalizedString("settings.sec.account", comment: ""))
                    TFCard {
                        NavigationLink { AccountPage(profile: profile, identity: identity, onEdit: { editing = true }, picked: $picked,
                                                     onRemovePhoto: { Task { await removePhoto() } }) } label: {
                            TFRow(icon: "person", title: NSLocalizedString("settings.account", comment: ""), subtitle: NSLocalizedString("settings.account.sub", comment: ""))
                        }
                        divider
                        NavigationLink { IdentityPage(identity: identity) } label: {
                            TFRow(icon: "qrcode", title: NSLocalizedString("settings.identity", comment: ""), subtitle: NSLocalizedString("settings.identity.sub", comment: ""))
                        }
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.activity", comment: ""))
                    TFCard {
                        NavigationLink { LiveLocationPage() } label: {
                            TFRow(icon: "location", title: NSLocalizedString("location.live", comment: ""),
                                  subtitle: location.sharing.isEmpty ? NSLocalizedString("settings.none", comment: "")
                                    : String(format: NSLocalizedString("settings.sharing.n", comment: ""), location.sharing.count))
                        }
                        divider
                        NavigationLink { DevicesPage(devices: $devices, onRevoke: { d in Task { await revoke(d) } }) } label: {
                            TFRow(icon: "laptopcomputer.and.iphone", title: NSLocalizedString("settings.devices", comment: ""), subtitle: NSLocalizedString("settings.devices.sub", comment: ""))
                        }
                        divider
                        NavigationLink { SavedEventsPage() } label: {
                            TFRow(icon: "calendar.badge.clock", title: NSLocalizedString("settings.events", comment: ""), subtitle: NSLocalizedString("settings.events.sub", comment: ""))
                        }
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.prefs", comment: ""))
                    TFCard {
                        NavigationLink { InfoPage(title: NSLocalizedString("settings.notifications", comment: ""), icon: "bell",
                                                  text: NSLocalizedString("settings.notifications.text", comment: "")) } label: {
                            TFRow(icon: "bell", title: NSLocalizedString("settings.notifications", comment: ""), subtitle: NSLocalizedString("settings.notifications.sub", comment: ""))
                        }
                        divider
                        NavigationLink { PrivacyPage(pinSaved: $pinSaved) } label: {
                            TFRow(icon: "checkmark.shield", title: NSLocalizedString("settings.privacy", comment: ""), subtitle: NSLocalizedString("settings.privacy.sub", comment: ""))
                        }
                        divider
                        NavigationLink { InfoPage(title: NSLocalizedString("settings.calls", comment: ""), icon: "phone",
                                                  text: NSLocalizedString(calls.enabled ? "settings.calls.on" : "settings.calls.off", comment: "")) } label: {
                            TFRow(icon: "phone", title: NSLocalizedString("settings.calls", comment: ""), subtitle: NSLocalizedString("settings.calls.sub", comment: ""))
                        }
                        divider
                        Button {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        } label: {
                            TFRow(icon: "paintpalette", title: NSLocalizedString("settings.appearance", comment: ""), subtitle: NSLocalizedString("settings.appearance.sub", comment: ""))
                        }
                        .buttonStyle(.plain)
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.app", comment: ""))
                    TFCard {
                        NavigationLink { InfoPage(title: NSLocalizedString("settings.about", comment: ""), icon: "info.circle",
                                                  text: "Tradeflor \(AppConfig.version)\n\(AppConfig.apiBase.host ?? "")") } label: {
                            TFRow(icon: "info.circle", title: NSLocalizedString("settings.about", comment: ""), subtitle: "Tradeflor \(AppConfig.version)")
                        }
                    }

                    Button { confirmSignOut = true } label: {
                        HStack {
                            Image(systemName: "power")
                            Text("chats.signout").bold()
                        }
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.top, 20)
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            .refreshable { await load() }
            .background(Starfield())
            .toolbar(.hidden, for: .navigationBar)
            .overlay { if busy { ProgressView().padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .task { await load() }
        .onAppear { pinSaved = BiometricPIN.isSaved }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await setPhoto(img) }
            }
        }
        .sheet(isPresented: $editing) {
            if let profile {
                EditProfileSheet(profile: profile) { n, b in await save(name: n, bio: b) }
            }
        }
        .confirmationDialog(Text("settings.signout.confirm"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("chats.signout", role: .destructive) { Task { await store.signOut() } }
        }
        .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("chat.close", role: .cancel) {}
        }
    }

    private var divider: some View { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }

    private var profileCard: some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: profile?.user_id ?? (store.session?.userID ?? ""),
                   avatarID: (profile?.avatar_id.isEmpty ?? true) ? nil : profile?.avatar_id, title: name, size: 50, online: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("@" + (profile?.username ?? store.session?.username ?? "")).font(.system(size: 12)).foregroundStyle(Theme.faint)
                HStack(spacing: 4) {
                    Circle().fill(Theme.online).frame(width: 6, height: 6)
                    Text("settings.online").font(.system(size: 11.5)).foregroundStyle(Theme.online)
                }
            }
            Spacer()
            Button { editing = true } label: {
                HStack(spacing: 3) {
                    Text("settings.myprofile").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).frame(height: 28)
                .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
            }
        }
        .padding(14)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func load() async {
        do {
            async let p = APIClient.shared.profile(token: token)
            async let d = APIClient.shared.devices(token: token)
            async let i = APIClient.shared.myIdentity(token: token)
            profile = try await p
            devices = (try? await d) ?? devices
            identity = (try? await i) ?? identity
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {}
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("settings.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("settings.failed", comment: "")
        }
    }

    private func setPhoto(_ img: UIImage) async {
        // a square crop from the centre, 1024 px: the server keeps avatars small
        let side = min(img.size.width, img.size.height)
        let crop = CGRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let target = CGSize(width: min(1024, side), height: min(1024, side))
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            img.draw(in: CGRect(x: -crop.minX * target.width / side, y: -crop.minY * target.height / side,
                                width: img.size.width * target.width / side, height: img.size.height * target.height / side))
        }
        guard let jpeg = square.jpegData(compressionQuality: 0.85) else { return }
        await run { profile = try await APIClient.shared.uploadAvatar(token: token, jpeg: jpeg) }
    }

    private func removePhoto() async {
        await run { profile = try await APIClient.shared.deleteAvatar(token: token) }
    }

    private func save(name: String, bio: String) async -> Bool {
        var ok = false
        await run {
            profile = try await APIClient.shared.updateProfile(token: token, displayName: name, bio: bio)
            ok = true
        }
        return ok
    }

    private func revoke(_ d: LinkedDevice) async {
        await run {
            try await APIClient.shared.revokeDevice(token: token, id: d.id)
            devices.removeAll { $0.id == d.id }
        }
    }
}

// MARK: sub-pages

/// A titled page on the starfield, like the right-hand panels of the website's Settings.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }.padding(16)
        }
        .background(Starfield())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.header, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct AccountPage: View {
    let profile: Profile?
    let identity: IdentityCard?
    let onEdit: () -> Void
    @Binding var picked: PhotosPickerItem?
    let onRemovePhoto: () -> Void

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.account", comment: "")) {
            TFCard {
                TFRow(icon: "at", title: NSLocalizedString("signup.username", comment: ""), trailing: "@" + (profile?.username ?? ""), showChevron: false)
                Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50)
                TFRow(icon: "dot.radiowaves.left.and.right", title: NSLocalizedString("settings.connection", comment: ""),
                      trailing: NSLocalizedString("settings.live", comment: ""), showChevron: false)
            }
            TFCard {
                Button(action: onEdit) { TFRow(icon: "pencil", title: NSLocalizedString("settings.edit", comment: "")) }
                Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50)
                PhotosPicker(selection: $picked, matching: .images) {
                    TFRow(icon: "photo", title: NSLocalizedString("settings.photo.change", comment: ""))
                }
                if let p = profile, !p.avatar_id.isEmpty {
                    Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50)
                    Button(action: onRemovePhoto) {
                        TFRow(icon: "trash", title: NSLocalizedString("settings.photo.remove", comment: ""), tint: Theme.danger, showChevron: false)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct IdentityPage: View {
    let identity: IdentityCard?

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.identity", comment: "")) {
            if let id = identity {
                VStack(spacing: 12) {
                    Text("identity.pin").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                    HStack(spacing: 8) {
                        ForEach(Array(id.pin.enumerated()), id: \.offset) { _, ch in
                            Text(String(ch)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                                .frame(width: 52, height: 62)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderActive, lineWidth: 1.5))
                        }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    Text("@" + id.username).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    if let qr = Self.qr("https://app.tradeflor.com/?id=\(id.pin)") {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 180, height: 180)
                            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    }
                    ShareLink(item: "https://app.tradeflor.com/?id=\(id.pin)") {
                        Label("identity.share", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.onAccent).padding(.horizontal, 20).frame(height: 44)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
    }

    static func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct DevicesPage: View {
    @Binding var devices: [LinkedDevice]
    let onRevoke: (LinkedDevice) -> Void

    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.devices", comment: "")) {
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
                                Text(seen, style: .relative).font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                        }
                        Spacer()
                        if d.current != true {
                            Button { onRevoke(d) } label: {
                                Text("settings.devices.signout").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.danger)
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .overlay(Capsule().stroke(Theme.danger.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    if i < devices.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }
                }
            }
            Text("settings.devices.footer").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
    }
}

struct LiveLocationPage: View {
    @ObservedObject private var location = LocationSharer.shared
    var body: some View {
        SettingsPage(title: NSLocalizedString("location.live", comment: "")) {
            if location.sharing.isEmpty {
                Text("settings.location.none").font(.system(size: 14)).foregroundStyle(Theme.faint)
            } else {
                TFCard {
                    ForEach(Array(location.sharing), id: \.self) { c in
                        HStack {
                            Image(systemName: "location.fill").foregroundStyle(Theme.accent)
                            Text(c.hasPrefix("grp_") ? NSLocalizedString("groups.title", comment: "") : NSLocalizedString("chats.title", comment: ""))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Button("location.stop") { location.stop(conversationID: c) }.foregroundStyle(Theme.danger)
                        }
                        .padding(14)
                    }
                }
            }
        }
    }
}

struct SavedEventsPage: View {
    @EnvironmentObject private var store: SessionStore
    @State private var items: [SavedEvent] = []
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.events", comment: "")) {
            if items.isEmpty {
                Text("settings.events.none").font(.system(size: 14)).foregroundStyle(Theme.faint)
            } else {
                TFCard {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(Date(timeIntervalSince1970: Double(e.event_at)), style: .date).font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Button {
                                Task {
                                    if (try? await APIClient.shared.removeSavedEvent(token: store.session?.token ?? "", key: e.event_key)) != nil {
                                        items.removeAll { $0.id == e.id }
                                    }
                                }
                            } label: { Image(systemName: "bell.slash").foregroundStyle(Theme.faint) }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        if i < items.count - 1 { Rectangle().fill(Theme.rowRule).frame(height: 1) }
                    }
                }
            }
        }
        .task { items = (try? await APIClient.shared.savedEvents(token: store.session?.token ?? "")) ?? [] }
    }
}

struct PrivacyPage: View {
    @Binding var pinSaved: Bool
    var body: some View {
        SettingsPage(title: NSLocalizedString("settings.privacy", comment: "")) {
            TFCard {
                TFRow(icon: "lock", title: NSLocalizedString("settings.lock.info", comment: ""), showChevron: false)
                if pinSaved {
                    Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50)
                    Button {
                        BiometricPIN.delete()
                        pinSaved = false
                    } label: {
                        TFRow(icon: "faceid", title: String(format: NSLocalizedString("settings.lock.forget", comment: ""), BiometricPIN.biometryName),
                              tint: Theme.danger, showChevron: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct InfoPage: View {
    let title: String
    let icon: String
    let text: String
    var body: some View {
        SettingsPage(title: title) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.accent)
                Text(text).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
        }
    }
}

struct EditProfileSheet: View {
    let profile: Profile
    let onSave: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("settings.name")) {
                    TextField("settings.name", text: $name).textContentType(.name)
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("settings.bio")) {
                    TextField("settings.bio", text: $bio, axis: .vertical).lineLimit(3...6)
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("settings.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("settings.save") {
                            Task {
                                saving = true
                                let ok = await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      bio.trimmingCharacters(in: .whitespacesAndNewlines))
                                saving = false
                                if ok { dismiss() }
                            }
                        }
                        .bold()
                    }
                }
            }
        }
        .onAppear {
            name = profile.display_name
            bio = profile.bio
        }
    }
}
