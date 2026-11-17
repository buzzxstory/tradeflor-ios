import SwiftUI
import PhotosUI
import CoreImage.CIFilterBuiltins

/// Settings home as on the website (45-settings-unified.css): title and subtitle, the profile card with "My Profile",
/// then ACCOUNT (Account, My Identity), ACTIVITY (Live location, Linked devices, Events), PREFERENCES
/// (Notifications, Privacy & Security, Calls, Appearance), APP (About), ADMINISTRATION (admins only) and Sign Out.
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @State private var profile: Profile?
    @State private var identity: StIdentity?
    @State private var adminRole = ""
    @State private var confirmSignOut = false
    @State private var sharingCount = 0
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

                    NavigationLink { MyProfilePage(onChange: { Task { await load() } }) } label: { profileCard }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.account", comment: ""))
                    TFCard {
                        NavigationLink { AccountPage() } label: {
                            TFRow(icon: "person", title: NSLocalizedString("settings.account", comment: ""), subtitle: NSLocalizedString("settings.account.sub", comment: ""))
                        }
                        divider
                        NavigationLink { MyIdentityPage() } label: {
                            TFRow(icon: "qrcode", title: NSLocalizedString("settings.identity", comment: ""), subtitle: NSLocalizedString("settings.identity.sub", comment: ""))
                        }
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.activity", comment: ""))
                    TFCard {
                        NavigationLink { LiveLocationPage() } label: {
                            TFRow(icon: "location", title: NSLocalizedString("location.live", comment: ""),
                                  subtitle: sharingCount == 0 ? NSLocalizedString("settings.none", comment: "")
                                    : String(format: NSLocalizedString("settings.sharing.n", comment: ""), sharingCount))
                        }
                        divider
                        NavigationLink { LinkedDevicesView() } label: {
                            TFRow(icon: "laptopcomputer.and.iphone", title: NSLocalizedString("settings.devices", comment: ""), subtitle: NSLocalizedString("settings.devices.sub", comment: ""))
                        }
                        divider
                        NavigationLink { EventsPage() } label: {
                            TFRow(icon: "calendar.badge.clock", title: NSLocalizedString("settings.events", comment: ""), subtitle: NSLocalizedString("settings.events.sub", comment: ""))
                        }
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.prefs", comment: ""))
                    TFCard {
                        NavigationLink { NotificationsPage() } label: {
                            TFRow(icon: "bell", title: NSLocalizedString("settings.notifications", comment: ""), subtitle: NSLocalizedString("settings.notifications.sub", comment: ""))
                        }
                        divider
                        NavigationLink { PrivacyPage() } label: {
                            TFRow(icon: "checkmark.shield", title: NSLocalizedString("settings.privacy", comment: ""), subtitle: NSLocalizedString("settings.privacy.sub", comment: ""))
                        }
                        if calls.enabled {
                            divider
                            NavigationLink { CallsPage() } label: {
                                TFRow(icon: "phone", title: NSLocalizedString("settings.calls", comment: ""), subtitle: NSLocalizedString("settings.calls.sub", comment: ""))
                            }
                        }
                        divider
                        NavigationLink { AppearancePage() } label: {
                            TFRow(icon: "paintpalette", title: NSLocalizedString("settings.appearance", comment: ""), subtitle: NSLocalizedString("settings.appearance.sub", comment: ""))
                        }
                    }

                    TFSectionLabel(text: NSLocalizedString("settings.sec.app", comment: ""))
                    TFCard {
                        NavigationLink { AboutPage() } label: {
                            TFRow(icon: "info.circle", title: NSLocalizedString("settings.about", comment: ""), subtitle: "Tradeflor \(AppConfig.version)")
                        }
                    }

                    if !adminRole.isEmpty {
                        TFSectionLabel(text: NSLocalizedString("set.sec.admin", comment: ""))
                        TFCard {
                            NavigationLink { AdminCenterPage(role: adminRole) } label: {
                                TFRow(icon: "checkmark.shield.fill", title: NSLocalizedString("adm.title", comment: ""), subtitle: NSLocalizedString("adm.sub", comment: ""))
                            }
                        }
                    }

                    Button { confirmSignOut = true } label: {
                        HStack {
                            Image(systemName: "power")
                            Text("set.signout").bold()
                        }
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.danger.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.top, 20)
                    Text("Tradeflor \(AppConfig.version)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity).padding(.top, 10)
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            .refreshable { await load() }
            .background(Starfield())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .confirmationDialog(Text("settings.signout.confirm"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("set.signout", role: .destructive) { Task { await store.signOut() } }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }

    private var profileCard: some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: profile?.user_id ?? (store.session?.userID ?? ""),
                   avatarID: (profile?.avatar_id.isEmpty ?? true) ? nil : profile?.avatar_id, title: name, size: 50, online: live.connected)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("@" + (profile?.username ?? store.session?.username ?? "")).font(.system(size: 12)).foregroundStyle(Theme.faint)
                HStack(spacing: 4) {
                    Circle().fill(live.connected ? Theme.online : Theme.gold).frame(width: 6, height: 6)
                    Text(LocalizedStringKey(live.connected ? "settings.online" : "set.reconnecting")).font(.system(size: 11.5))
                        .foregroundStyle(live.connected ? Theme.online : Theme.gold)
                }
            }
            Spacer()
            HStack(spacing: 3) {
                Text("settings.myprofile").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).frame(height: 28)
            .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
        }
        .padding(14)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func load() async {
        guard !token.isEmpty else { return }
        do {
            profile = try await APIClient.shared.profile(token: token)
        } catch APIError.badCredentials {
            store.sessionExpired()
            return
        } catch {}
        sharingCount = await APIClient.shared.stMyLocations(token: token).filter { $0.stopped != true }.count
        adminRole = await APIClient.shared.stAdminMe(token: token)?.role ?? ""
    }
}

// MARK: shared page chrome

/// A titled page on the starfield, like the right-hand panels of the website's Settings ("Back to Settings").
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.faint) }
                content()
            }
            .padding(16)
        }
        .background(Starfield())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Theme.header, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// A switch row inside a TFCard (the website's settings switch rows).
struct TFToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.faint) }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct TFDivider: View {
    var body: some View { Rectangle().fill(Theme.rowRule).frame(height: 1).padding(.leading, 50) }
}

/// A key / value line ("Real name   Buzzhub").
struct TFKeyValue: View {
    let key: String
    let value: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 13)).foregroundStyle(Theme.faint).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

enum TFQR {
    static func image(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "Q" // as every QR in the app (BrandedQR); the branded picture itself is BrandedQR.image(text:side:)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct EditProfileSheet: View {
    let profile: Profile
    let onSave: (String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("settings.name")) {
                    TextField("set.name.ph", text: $name).textContentType(.name)
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("signup.username")) {
                    TextField("signup.username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .listRowBackground(Theme.surface)
                Section(header: Text("settings.bio"), footer: Text("\(bio.count)/200")) {
                    TextField("set.bio.ph", text: $bio, axis: .vertical).lineLimit(3...6)
                        .onChange(of: bio) { v in if v.count > 200 { bio = String(v.prefix(200)) } }
                }
                .listRowBackground(Theme.surface)
                if let problem { Section { Text(problem).foregroundStyle(Theme.danger).font(.footnote) }.listRowBackground(Theme.surface) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("set.edit.profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("settings.save") {
                            Task {
                                saving = true
                                problem = await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       username.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       bio.trimmingCharacters(in: .whitespacesAndNewlines))
                                saving = false
                                if problem == nil { dismiss() }
                            }
                        }
                        .bold()
                    }
                }
            }
        }
        .onAppear {
            name = profile.display_name
            username = profile.username
            bio = profile.bio
        }
    }
}
