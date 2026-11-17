import SwiftUI
import PhotosUI
import CoreImage.CIFilterBuiltins

/// Settings home as on the website (SettingsView.tsx, 45-settings-unified.css): "Settings" (30, bold) and its line with the
/// gear mark on the right, the profile card (62 pt face with its presence dot, name 19, @handle, Online, "My Profile"),
/// then ACCOUNT (Account, My Identity), ACTIVITY (Live location, Linked devices, Events), PREFERENCES
/// (Notifications, Privacy & Security, Calls, Appearance), APP (About), ADMINISTRATION (admins only), the Sign Out card
/// and "Tradeflor · Version".
struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    /// The last profile answer, kept across a rebuilt tab: the card never starts on the bare username and a letter.
    private static var lastProfile: Profile?
    @State private var profile: Profile? = SettingsView.lastProfile
    @State private var identity: StIdentity?
    /// The last role answer for this account, kept on the device and shown at once (the server still checks every admin
    /// request): Admin Center no longer vanishes on a fast refresh or a refused check (web 5106e98).
    @State private var adminRole = UserDefaults.standard.string(forKey: "tf.admin.role") ?? ""
    @State private var confirmSignOut = false
    @State private var sharingCount = 0
    @AppStorage("tf.night") private var night = true
    @ObservedObject private var calls = CallManager.shared

    private var token: String { store.session?.token ?? "" }
    private var username: String { profile?.username ?? store.session?.username ?? "" }
    private var name: String {
        if let p = profile { return p.display_name.isEmpty ? p.username : p.display_name }
        return store.session?.username ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    NavigationLink { MyProfilePage(onChange: { Task { await load() } }) } label: { profileCard }
                        .padding(.top, 4)

                    group("settings.sec.account") {
                        NavigationLink { AccountPage() } label: {
                            SMenuRow(icon: "person", title: NSLocalizedString("settings.account", comment: ""), subtitle: NSLocalizedString("settings.account.sub", comment: ""))
                        }
                        SDivider()
                        NavigationLink { MyIdentityPage() } label: {
                            SMenuRow(icon: "qrcode", title: NSLocalizedString("settings.identity", comment: ""), subtitle: NSLocalizedString("settings.identity.sub", comment: ""))
                        }
                    }

                    group("settings.sec.activity") {
                        NavigationLink { LiveLocationPage() } label: {
                            SMenuRow(icon: "location", title: NSLocalizedString("location.live", comment: ""),
                                     subtitle: sharingCount == 0 ? NSLocalizedString("settings.none", comment: "")
                                        : String(format: NSLocalizedString("settings.sharing.n", comment: ""), sharingCount))
                        }
                        SDivider()
                        NavigationLink { LinkedDevicesView() } label: {
                            SMenuRow(icon: "laptopcomputer.and.iphone", title: NSLocalizedString("settings.devices", comment: ""), subtitle: NSLocalizedString("settings.devices.sub", comment: ""))
                        }
                        SDivider()
                        NavigationLink { EventsPage() } label: {
                            SMenuRow(icon: "calendar.badge.clock", title: NSLocalizedString("settings.events", comment: ""), subtitle: NSLocalizedString("settings.events.sub", comment: ""))
                        }
                    }

                    group("settings.sec.prefs") {
                        NavigationLink { NotificationsPage() } label: {
                            SMenuRow(icon: "bell", title: NSLocalizedString("settings.notifications", comment: ""), subtitle: NSLocalizedString("settings.notifications.sub", comment: ""))
                        }
                        SDivider()
                        NavigationLink { PrivacyPage() } label: {
                            SMenuRow(icon: "checkmark.shield", title: NSLocalizedString("settings.privacy", comment: ""), subtitle: NSLocalizedString("settings.privacy.sub", comment: ""))
                        }
                        if calls.enabled {
                            SDivider()
                            NavigationLink { CallsPage() } label: {
                                SMenuRow(icon: "phone", title: NSLocalizedString("settings.calls", comment: ""), subtitle: NSLocalizedString("settings.calls.sub", comment: ""))
                            }
                        }
                        SDivider()
                        NavigationLink { AppearancePage() } label: {
                            // web: the line under Appearance says the look now, "Night" or "Day"
                            SMenuRow(icon: "paintpalette", title: NSLocalizedString("settings.appearance", comment: ""),
                                     subtitle: NSLocalizedString(night ? "ux3.set.night" : "ux3.set.day", comment: ""))
                        }
                    }

                    group("settings.sec.app") {
                        NavigationLink { AboutPage() } label: {
                            SMenuRow(icon: "info.circle", title: NSLocalizedString("settings.about", comment: ""),
                                     subtitle: String(format: NSLocalizedString("ux3.set.version.n", comment: ""), AppConfig.version))
                        }
                    }

                    if !adminRole.isEmpty {
                        group("set.sec.admin") {
                            NavigationLink { AdminCenterPage(role: adminRole) } label: {
                                SMenuRow(icon: "checkmark.shield", title: NSLocalizedString("adm.title", comment: ""), subtitle: NSLocalizedString("adm.sub", comment: ""))
                            }
                        }
                    }

                    // Sign Out: its own card, red only here, behind a confirmation
                    SCard(border: SetUI.dangerEdge) {
                        Button { confirmSignOut = true } label: {
                            SMenuRow(icon: "power", title: NSLocalizedString("set.signout", comment: ""),
                                     subtitle: String(format: NSLocalizedString("ux3.set.signout.sub", comment: ""), "@" + username),
                                     danger: true, chevron: false)
                        }
                    }
                    .padding(.top, 10)

                    Text(String(format: NSLocalizedString("ux3.set.foot", comment: ""), AppConfig.version))
                        .font(.system(size: 12.5)).foregroundStyle(SetUI.foot)
                        .frame(maxWidth: .infinity).padding(.top, 2).padding(.bottom, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .buttonStyle(.plain)
            .refreshable { await load() }
            .background(SettingsBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await load() }
        .confirmationDialog(Text("settings.signout.confirm"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("set.signout", role: .destructive) { Task { await store.signOut() } }
        }
    }

    /// .s-head: "Settings" 30/36 bold, the line 14 #9fb4bf, a 46 pt gear mark (radial turquoise, thin edge).
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.title").font(.system(size: 30, weight: .bold)).kerning(-0.3).foregroundStyle(SetUI.text)
                Text("settings.subtitle").font(.system(size: 14)).foregroundStyle(SetUI.sub)
            }
            Spacer(minLength: 8)
            Image(systemName: "gearshape").font(.system(size: 21, weight: .regular)).foregroundStyle(SetUI.accent)
                .frame(width: 46, height: 46)
                .background(RadialGradient(colors: [Theme.hex(0x08D9D9, 0.14), Theme.hex(0x08D9D9, 0.03)], center: .center, startRadius: 0, endRadius: 23),
                            in: Circle())
                .overlay(Circle().stroke(Theme.hex(0x08D9D9, 0.25), lineWidth: 1))
                .accessibilityHidden(true)
        }
        .padding(.top, 2)
    }

    private func group<Content: View>(_ key: String, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SSection(text: NSLocalizedString(key, comment: ""))
            SCard { rows() }
        }
    }

    /// .s-profile: avatar 62 with a turquoise edge and the green presence dot, name 19, @handle 14, "● Online" 13;
    /// "My Profile ›" pill (36 high); the quiet turquoise sweep on the right.
    private var profileCard: some View {
        let on = live.steadyConnected
        return HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(token: token, userID: profile?.user_id ?? (store.session?.userID ?? ""),
                       avatarID: (profile?.avatar_id.isEmpty ?? true) ? nil : profile?.avatar_id, title: name, size: 62)
                    .overlay(Circle().strokeBorder(Theme.hex(0x08D9D9, 0.45), lineWidth: 2))
                if on {
                    Circle().fill(Theme.hex(0x14D99A)).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Theme.dyn(0x03202B, 0xEAF3F7), lineWidth: 3))
                        .offset(x: -1, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 19, weight: .bold)).foregroundStyle(SetUI.text).lineLimit(1)
                Text("@" + username).font(.system(size: 14)).foregroundStyle(Theme.dyn(0xB9CAD3, 0x46657A)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().frame(width: 7, height: 7)
                    Text(LocalizedStringKey(on ? "settings.online" : "set.reconnecting")).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(on ? Theme.dyn(0x14D99A, 0x0C8564) : Theme.hex(0xF0B46A))
                .padding(.top, 3)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                Text("settings.myprofile").font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(SetUI.accent)
            .padding(.leading, 12).padding(.trailing, 8).frame(height: 36)
            .background(Theme.dyn(0x031E28, 0x0A8FA0, 0.7, 0.08), in: Capsule())
            .overlay(Capsule().stroke(Theme.dyn(0x08D9D9, 0x0A8FA0, 0.3, 0.25), lineWidth: 1))
        }
        .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 14)
        .frame(minHeight: 92)
        .background { SettingsSweep(peak: 0.28, tail: 0.08, share: 0.55).opacity(0.8) }
        .sCardChrome()
        .contentShape(Rectangle())
    }

    private func load() async {
        guard !token.isEmpty else { return }
        do {
            let p = try await APIClient.shared.profile(token: token)
            profile = p
            Self.lastProfile = p
        } catch APIError.badCredentials {
            store.sessionExpired()
            return
        } catch {}
        sharingCount = await APIClient.shared.stMyLocations(token: token).filter { $0.stopped != true }.count
        for n in 0..<6 {
            switch await APIClient.shared.stAdminCheck(token: token) {
            case .role(let r):
                adminRole = r
                UserDefaults.standard.set(r, forKey: "tf.admin.role")
                return
            case .none:
                adminRole = ""
                UserDefaults.standard.removeObject(forKey: "tf.admin.role")
                return
            case .unknown:
                // refused for now (429 after many refreshes, network): keep it and ask again in 2 … 30 s
                try? await Task.sleep(nanoseconds: UInt64(min(30, 2 << n)) * 1_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }
}

// MARK: shared page chrome (45-settings-unified.css)

/// The Settings palette: deep navy cards with thin turquoise-tinted edges, one turquoise accent, #9fb4bf notes.
enum SetUI {
    static let text = Theme.dyn(0xF0F6F9, 0x0E2A3A)
    static let sub = Theme.dyn(0x9FB4BF, 0x46657A)
    static let dim = Theme.dyn(0x7F98A4, 0x46657A)
    static let foot = Theme.dyn(0x6F8A96, 0x46657A)
    static let accent = Theme.dyn(0x14D8EA, 0x0A8FA0)
    static let danger = Theme.dyn(0xFF7B88, 0xC43848)
    static let edge = Theme.dyn(0x288CAA, 0x0A8FA0, 0.34, 0.3)
    static let dangerEdge = Theme.dyn(0xFF5E6E, 0xDC3C4B, 0.3, 0.3)
    static let rule = Theme.dyn(0x286E91, 0x286E91, 0.35, 0.22)
    static let fill = LinearGradient(colors: [Theme.dyn(0x042A38, 0xEAF3F7, 0.95, 1), Theme.dyn(0x021C26, 0xE4EFF4, 0.95, 1)],
                                     startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
    static let tileFill = Theme.dyn(0x08D9D9, 0x0A8FA0, 0.08, 0.08)
    static let tileEdge = Theme.dyn(0x08D9D9, 0x0A8FA0, 0.2, 0.25)
}

/// .settings-view background: a soft radial glow over #011e29 → #011922 (day: the app's light ground).
struct SettingsBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.dyn(0x011E29, 0xEEF3F7), Theme.dyn(0x011A24, 0xEEF3F7), Theme.dyn(0x011922, 0xEEF3F7)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.dyn(0x012E40, 0xEEF3F7, 0.55, 0), .clear], center: UnitPoint(x: 0.6, y: 0.1), startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The card look: radius 18, the navy gradient, a thin turquoise-tinted edge, a soft drop shadow.
    func sCardChrome(border: Color = SetUI.edge) -> some View {
        self
            .background(SetUI.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
    }
}

/// A Settings card group (.s-rows / .s-menu).
struct SCard<Content: View>: View {
    var border: Color = SetUI.edge
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sCardChrome(border: border)
    }
}

/// .s-section: 13 bold, wide tracking, uppercase, #9fb4bf.
struct SSection: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .bold))
            .kerning(1.3)
            .foregroundStyle(SetUI.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }
}

/// .s-menu-row: a 38 pt icon tile (radius 12), the title 16 and its 13 line, the chevron; 62 high.
struct SMenuRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var danger = false
    var chevron = true
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .regular)).foregroundStyle(danger ? SetUI.danger : SetUI.accent)
                .frame(width: 38, height: 38)
                .background(danger ? Theme.dyn(0xFF5E6E, 0xDC3C4B, 0.08, 0.06) : SetUI.tileFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(danger ? Theme.dyn(0xFF5E6E, 0xDC3C4B, 0.28, 0.3) : SetUI.tileEdge, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(danger ? SetUI.danger : SetUI.text).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(SetUI.sub).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if chevron {
                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.dim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
    }
}

/// .s-row with a chevron (a row that opens a page inside a Settings card): 24 pt icon, 16 title, 13 note.
struct SRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = SetUI.accent
    var trailing: String? = nil
    var showChevron = true
    var body: some View {
        HStack(spacing: 14) {
            if !icon.isEmpty {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(tint).frame(width: 24).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint == SetUI.accent ? SetUI.text : tint)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundStyle(SetUI.sub) }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(size: 14.5, weight: .medium)).foregroundStyle(SetUI.sub).lineLimit(1) }
            if showChevron { Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.dim) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

/// .s-card-head: the page banner: a 54 pt icon in a soft square (radius 16), the title 19 bold and one 13.5 line, and the
/// quiet turquoise sweep on the right.
struct SBanner: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var image: String? = nil
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let image { Image(image).resizable().scaledToFit().frame(width: 32, height: 32) }
                else { Image(systemName: icon).font(.system(size: 24, weight: .regular)).foregroundStyle(SetUI.accent) }
            }
            .frame(width: 54, height: 54)
            .background(LinearGradient(colors: [Theme.hex(0x08D9D9, 0.16), Theme.hex(0x08D9D9, 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hex(0x08D9D9, 0.28), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(SetUI.text).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13.5)).foregroundStyle(SetUI.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 84)
        .background { SettingsSweep(peak: 0.32, tail: 0.1, share: 0.62) }
        .sCardChrome()
    }
}

/// The banner sweep (the web's inline SVG: M40 100C90 70 120 22 200 8V0C110 14 80 62 22 100Z in a 200 × 100 box),
/// fading in from the left; mirrored for right-to-left.
struct SettingsSweep: View {
    var peak: Double = 0.32
    var tail: Double = 0.1
    /// the part of the card's width it covers, on the trailing side
    var share: CGFloat = 0.62
    var body: some View {
        GeometryReader { g in
            sweep.frame(width: g.size.width * share, height: g.size.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sweep: some View {
        SweepShape()
            .fill(LinearGradient(stops: [.init(color: Theme.hex(0x08D9D9, 0), location: 0),
                                         .init(color: Theme.hex(0x08D9D9, peak), location: 0.55),
                                         .init(color: Theme.hex(0x08D9D9, tail), location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .flipsForRightToLeftLayoutDirection(true)
    }

    private struct SweepShape: Shape {
        func path(in r: CGRect) -> Path {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 200 * r.width, y: r.minY + y / 100 * r.height) }
            var path = Path()
            path.move(to: p(40, 100))
            path.addCurve(to: p(200, 8), control1: p(90, 70), control2: p(120, 22))
            path.addLine(to: p(200, 0))
            path.addCurve(to: p(22, 100), control1: p(110, 14), control2: p(80, 62))
            path.closeSubpath()
            return path
        }
    }
}

/// The Settings switch (51 × 28): #163d4c off, the turquoise gradient on with a soft glow; the thumb #cfdbe2 / white.
struct TFSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.dyn(0x00C9D6, 0x00B9C7), Theme.dyn(0x00E3F0, 0x00CDD9)], startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Theme.dyn(0x163D4C, 0xC7D6E0)))
                    .shadow(color: configuration.isOn ? Theme.hex(0x00DCEB, 0.3) : .clear, radius: 5)
                Circle().fill(configuration.isOn ? Color.white : Theme.hex(0xCFDBE2))
                    .frame(width: 22, height: 22)
                    .padding(3)
            }
            .frame(width: 51, height: 28)
            .environment(\.layoutDirection, .leftToRight)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A titled page (the website's .s-page on a phone): the system Back stays (and its swipe), the head is the web's —
/// the title 26 bold, its line 14, the page's mark in a 46 pt circle on the right — then the page body, 12 apart.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        if icon == nil { classic } else { web }
    }

    /// The earlier look (Contact Info, Flash Connect, My Profile and other pages that reuse this chrome): the title in the bar.
    private var classic: some View {
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

    private var web: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(SetUI.text).lineLimit(2)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 14)).foregroundStyle(SetUI.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let icon {
                        Image(systemName: icon).font(.system(size: 21)).foregroundStyle(SetUI.accent)
                            .frame(width: 46, height: 46)
                            .background(RadialGradient(colors: [Theme.hex(0x08D9D9, 0.14), Theme.hex(0x08D9D9, 0.03)], center: .center, startRadius: 0, endRadius: 23),
                                        in: Circle())
                            .overlay(Circle().stroke(Theme.hex(0x08D9D9, 0.25), lineWidth: 1))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, 2).padding(.bottom, 2)
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(SettingsBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// A switch row (.s-row): optional 24 pt icon, the label 16 semibold and its 13 note, the Settings switch.
struct SToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 14) {
            if !icon.isEmpty {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(SetUI.accent).frame(width: 24).padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(SetUI.text).fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(SetUI.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(TFSwitchStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
    }
}

/// The rule between rows: full width, rgba(40,110,145,.35).
struct SDivider: View {
    var body: some View { Rectangle().fill(SetUI.rule).frame(height: 1) }
}

/// A key / value line (.id-priv-row: the label 13.5 in a 96 pt column, the value 15 semibold, a turquoise action).
struct SKeyValue: View {
    let key: String
    let value: String
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 13.5)).foregroundStyle(SetUI.sub).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(SetUI.text).lineLimit(2)
            Spacer(minLength: 6)
            if let action, let onAction {
                Button(action, action: onAction).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetUI.accent).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
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
