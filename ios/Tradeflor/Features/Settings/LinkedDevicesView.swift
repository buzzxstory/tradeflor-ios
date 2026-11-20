import SwiftUI
import Combine

// Settings > Linked Devices V2, as on the website (desktop/src/features/settings/LinkedDevices.tsx and
// styles/76-linked-devices.css, web aa69255). Everything shown comes from the server's own session records
// (GET auth/sessions): this device first, then every other session with its own ⋮ menu (Device details · Rename device ·
// Sign out), and "Sign out of all other devices". The list reloads live when the server says sessions changed.
// No invented models, places or "all secure" claims.

private func ldT(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// The page's own palette (76-linked-devices.css: midnight navy, deep teal cards, soft turquoise accents).
private enum LD {
    static let ink = Theme.dyn(0xEEF8FB, 0x0F2533)
    static let head = Theme.dyn(0xF2FBFF, 0x0F2533)
    static let sub = Theme.dyn(0xA9C0CA, 0x4E6873)
    static let body = Theme.dyn(0xB8CCD5, 0x4E6873)
    static let note = Theme.dyn(0xCFE3EA, 0x3C5668)
    static let empty = Theme.dyn(0x9FB8C4, 0x5F7686)
    static let cyan = Theme.dyn(0x35E6F2, 0x0097A5)
    static let cyanSoft = Theme.dyn(0x7FF3F3, 0x00939F)
    static let green = Theme.dyn(0x22D68A, 0x0FB57F)
    static let greenText = Theme.dyn(0x7FF3C8, 0x0C8564)
    static let red = Theme.dyn(0xFF6B78, 0xD8404A)
    static let line = Theme.dyn(0x51C8DC, 0xA6E3E7, 0.24, 1)
    static let rule = Theme.dyn(0x51C8DC, 0xC4EEF1, 0.14, 1)
    static let cardFill = LinearGradient(colors: [Theme.dyn(0x052C38, 0xFFFFFF, 0.72, 1), Theme.dyn(0x02161F, 0xF6FCFD, 0.86, 1)],
                                         startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
    static let currentFill = LinearGradient(colors: [Theme.dyn(0x063E4A, 0xEFFBFC, 0.78, 1), Theme.dyn(0x021E28, 0xDDF7F8, 0.9, 1)],
                                            startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1))
    static let art = LinearGradient(colors: [Theme.dyn(0x7FF3F3, 0x22CFE0), Theme.dyn(0x22CFE0, 0x0097A5)], startPoint: .leading, endPoint: .trailing)
}

// MARK: what a session is called and how its activity reads (only what the server recorded)

enum LinkedDeviceText {
    private static let os: [String: String] = ["iPhone": "iOS", "iPad": "iPadOS", "Android": "Android", "Mac": "macOS",
                                               "Windows": "Windows", "Linux": "Linux", "Chromebook": "ChromeOS"]
    private static let machine: [String: String] = ["iPhone": "ld.machine.iphone", "iPad": "ld.machine.ipad", "Android": "ld.machine.android",
                                                    "Mac": "ld.machine.mac", "Windows": "ld.machine.windows", "Linux": "ld.machine.linux",
                                                    "Chromebook": "ld.machine.chromebook"]

    static func osName(_ platform: String) -> String { os[platform] ?? platform }

    /// "TRADEFLOR for Windows", "TRADEFLOR for iOS", or the machine ("Windows PC", "iPhone", "Mac"...).
    static func name(_ d: LinkedDevice) -> String {
        if d.app == "desktop" { return ldT("ld.name.desktop") }
        if d.app == "ios" { return ldT("ld.name.ios") }
        guard let p = d.platform, !p.isEmpty else {
            // a server without the V2 fields still names the session ("Chrome on Windows"): that, not "Unknown device"
            let named = d.device.trimmingCharacters(in: .whitespaces)
            return named.isEmpty || named == "Unnamed device" ? ldT("ld.name.unknown") : named
        }
        return machine[p].map(ldT) ?? p
    }

    /// "Chrome · Windows", "Safari · iOS", "Desktop app · Windows", "iPhone app · iOS", "Web browser · macOS".
    static func type(_ d: LinkedDevice) -> String {
        if d.app == "desktop" { return ldT("ld.type.desktop") }
        if d.app == "ios" { return ldT("ld.type.ios") }
        let system = d.platform.map { $0.isEmpty ? "" : osName($0) } ?? ""
        if let b = d.browser, !b.isEmpty { return system.isEmpty ? b : "\(b) · \(system)" }
        return system.isEmpty ? ldT("ld.type.web") : "\(ldT("ld.type.web")) · \(system)"
    }

    static func title(_ d: LinkedDevice) -> String {
        if let l = d.label, !l.isEmpty { return l }
        return name(d)
    }

    static func sub(_ d: LinkedDevice) -> String {
        if let l = d.label, !l.isEmpty { return "\(name(d)) · \(type(d))" }
        return type(d)
    }

    static func icon(_ d: LinkedDevice) -> String {
        if d.app == "desktop" { return "pc" }
        if d.app == "ios" || d.platform == "iPhone" { return "iphone" }
        if d.platform == "Android" { return "candybarphone" }
        if d.browser == "Safari" { return "safari" }
        if d.platform == "iPad" { return "ipad" }
        return "laptopcomputer"
    }

    enum Tone { case live, recent, past }

    /// "Active now" only for a live connection; recent activity in green; older in grey.
    static func activity(_ d: LinkedDevice, now: Date) -> (text: String, tone: Tone) {
        if d.current == true || d.connected == true { return (ldT("ld.act.now"), .live) }
        guard let seen = d.last_seen_at.flatMap(serverDate) else {
            let since = serverDate(d.created_at).map(shortDate) ?? "—"
            return (String(format: ldT("ld.act.signedin"), since), .past)
        }
        let s = max(0, Int(now.timeIntervalSince(seen).rounded()))
        if s < 60 { return (ldT("ld.act.justnow"), .recent) }
        if s < 3600 {
            let m = Int((Double(s) / 60).rounded())
            return (m == 1 ? ldT("ld.act.min.one") : String(format: ldT("ld.act.min.n"), m), .recent)
        }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: seen), to: cal.startOfDay(for: now)).day ?? 0
        if s < 86400 && days == 0 {
            let h = Int((Double(s) / 3600).rounded())
            return (h == 1 ? ldT("ld.act.hour.one") : String(format: ldT("ld.act.hour.n"), h), .past)
        }
        if days <= 1 { return (ldT("ld.act.yesterday"), .past) }
        return (String(format: ldT("ld.act.last.date"), shortDate(seen)), .past)
    }

    /// "Nov 15, 2026" in the reader's locale.
    static func shortDate(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).year()) }

    /// "Nov 15, 2026 at 9:41 PM" in the reader's locale; "—" when unknown.
    static func fullDate(_ v: Int64?) -> String {
        guard let d = v.flatMap(serverDate) else { return "—" }
        return d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}

private enum LDDialog {
    case details(LinkedDevice)
    case rename(LinkedDevice)
    case out(LinkedDevice)
    case all
}

private struct LDToast: Equatable {
    let title: String
    let text: String
}

/// Where each row sits, so its ⋮ menu can open just under it (above everything else on the page).
private struct LDRowAnchor: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: the page

struct LinkedDevicesView: View {
    @EnvironmentObject private var store: SessionStore
    /// Not observed: only "the socket came back" matters here, followed below (`connected`). Observing the whole connection
    /// redrew the page whenever any contact came online.
    private let live = LiveConnection.shared
    @State private var connected = LiveConnection.shared.connected
    @Environment(\.dismiss) private var dismiss

    @State private var list: [LinkedDevice]?
    @State private var problem = ""
    @State private var menu: String?            // the session whose ⋮ menu is open
    @State private var dialog: LDDialog?
    @State private var busy = false
    @State private var toast: LDToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var help = false
    @State private var now = Date()
    @State private var seq = 0
    @State private var renameText = ""
    @State private var renameError = ""
    @FocusState private var renameFocused: Bool

    /// Every minute the "Active N minutes ago" lines move on.
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var token: String { store.session?.token ?? "" }
    private var current: LinkedDevice? { list?.first { $0.current == true } }
    private var others: [LinkedDevice] { list?.filter { $0.current != true } ?? [] }
    private var connectedCount: Int { list?.filter { $0.current == true || $0.connected == true }.count ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if help { helpNote }
                    hero
                    chips
                    if !problem.isEmpty { errorBanner(problem).id("ld.error") }
                    if list == nil && problem.isEmpty {
                        Text("ld.loading").font(.system(size: 14)).foregroundStyle(LD.empty).frame(maxWidth: .infinity)
                    }
                    if let list {
                        summary(count: list.count)
                        if let current {
                            sectionTitle("ld.sec.this")
                            VStack(spacing: 0) { row(current) }
                                // the glow is cast by the card's shape only (not worked out again from the row inside it)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LD.currentFill)
                                    .shadow(color: Theme.dyn(0x35E6F2, 0x0B5E68, 0.12, 0.12), radius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.65, 0.55), lineWidth: 1))
                        }
                        if !others.isEmpty {
                            sectionTitle("ld.sec.others")
                            VStack(spacing: 0) {
                                ForEach(Array(others.enumerated()), id: \.element.id) { i, d in
                                    if i > 0 { Rectangle().fill(LD.rule).frame(height: 1).padding(.leading, 70).padding(.trailing, 14) }
                                    row(d)
                                }
                            }
                            .background(card)
                            signOutAllButton
                        } else {
                            Text("ld.none.others").font(.system(size: 14)).foregroundStyle(LD.empty)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        }
                    }
                    securityCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .modifier(DockSpace()) // on the scroll view itself: an inset outside its NavigationStack never reached it
            .clipped() // the bar and status bar show the page itself: rows stop under them, never a band of another colour
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await load() }
            .onChange(of: problem) { p in
                if !p.isEmpty { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("ld.error", anchor: .center) } }
            }
        }
        .background(background)
        .overlayPreferenceValue(LDRowAnchor.self) { anchors in menuLayer(anchors) }
        .overlay { dialogLayer }
        .overlay(alignment: .bottom) { toastLayer.modifier(DockLift()) } // above the floating dock, never behind it
        .animation(.easeOut(duration: 0.18), value: toast)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        // live: the server says "sessions changed" (a sign-in, a sign-out, a rename on any device), or the socket came back
        .onReceive(live.sessionsChanged) { _ in Task { await load() } }
        .onReceive(live.$connected) { c in if c != connected { connected = c } }
        .onChange(of: connected) { c in if c { Task { await load() } } }
        .onReceive(ticker) { now = $0 }
    }

    // MARK: data

    private func load() async {
        seq += 1
        let my = seq
        do {
            let l = try await APIClient.shared.linkedDevices(token: token)
            guard my == seq else { return }
            list = l.filter { $0.current == true } + l.filter { $0.current != true }
            problem = ""
            now = Date()
            if let m = menu, !l.contains(where: { $0.id == m }) { menu = nil }
        } catch {
            guard my == seq else { return }
            problem = ldT("ld.err.load")
        }
    }

    private func signOut(_ d: LinkedDevice) async {
        busy = true
        do {
            let ended = try await APIClient.shared.signOutDevice(token: token, id: d.id)
            busy = false
            close()
            if ended {
                show(ldT("ld.toast.out.title"), String(format: ldT("ld.toast.out.text"), LinkedDeviceText.title(d)))
            } else {
                // already signed out elsewhere, or expired: the list is simply out of date
                show(ldT("ld.toast.gone.title"), ldT("ld.toast.gone.text"))
            }
            await load()
        } catch {
            busy = false
            close()
            problem = ldT("ld.err.signout")
        }
    }

    private func signOutOthers() async {
        busy = true
        do {
            let n = try await APIClient.shared.signOutOtherDevices(token: token)
            busy = false
            close()
            show(ldT("ld.toast.all.title"), n > 0 ? String(format: ldT("ld.toast.all.text"), n) : ldT("ld.toast.all.none"))
            await load()
        } catch {
            busy = false
            close()
            problem = ldT("ld.err.signout.all")
        }
    }

    /// Return key or Save: one rename at a time (both could start one).
    private func startRename(_ d: LinkedDevice) {
        guard !busy else { return }
        busy = true
        Task { await rename(d) }
    }

    private func rename(_ d: LinkedDevice) async {
        let label = String(renameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        busy = true
        renameError = ""
        do {
            try await APIClient.shared.renameDevice(token: token, id: d.id, label: label)
            busy = false
            close()
            await load()
        } catch APIError.server(status: 400) {
            busy = false
            renameError = ldT("ld.rename.toolong")
        } catch {
            busy = false
            renameError = ldT("ld.rename.err")
        }
    }

    private func show(_ title: String, _ text: String) {
        toastTask?.cancel()
        let t = LDToast(title: title, text: text)
        toast = t
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled && toast == t { toast = nil }
        }
    }

    private func open(_ d: LDDialog) {
        menu = nil
        if case .rename(let x) = d {
            renameText = x.label ?? ""
            renameError = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { renameFocused = true }
        }
        dialog = d
    }

    private func close() {
        renameFocused = false
        dialog = nil
    }

    // MARK: top

    private var background: some View {
        ZStack(alignment: .top) {
            Theme.dyn(0x00131B, 0xF4FAFB)
            RadialGradient(colors: [Theme.dyn(0x128CA0, 0x7FD9E0, 0.22, 0.25), Theme.dyn(0x128CA0, 0x7FD9E0, 0, 0)],
                           center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 250)
                .frame(height: 420)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 8) {
            roundButton("chevron.backward", label: "ld.back") { dismiss() }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image("BrandFlower").resizable().scaledToFit().frame(width: 34, height: 34)
                Text(verbatim: "TRADEFLOR").font(.system(size: 18, weight: .heavy)).tracking(3.2)
                    .foregroundStyle(LD.ink).lineLimit(1).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Tradeflor"))
            Spacer(minLength: 0)
            roundButton("questionmark", label: "ld.help.label", on: help) {
                withAnimation(.easeOut(duration: 0.15)) { help.toggle() }
            }
        }
        .padding(.top, 4)
    }

    private func roundButton(_ icon: String, label: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(LD.ink)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Theme.dyn(0x041019, 0xFFFFFF, 0.7, 1)))
                .overlay(Circle().stroke(on ? Theme.dyn(0x6EE8F4, 0x00A8B5, 0.45, 0.6) : Theme.dyn(0xFFFFFF, 0xA6E3E7, 0.14, 1), lineWidth: 1))
                .contentShape(Circle())
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private var helpNote: some View {
        Text("ld.help")
            .font(.system(size: 14)).lineSpacing(3).foregroundStyle(LD.note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.dyn(0x041E28, 0xFFFFFF, 0.85, 1)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.dyn(0x6EE8F4, 0xA6E3E7, 0.3, 1), lineWidth: 1))
            .transition(.opacity)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.system(size: 64, weight: .regular))
                Image(systemName: "link").font(.system(size: 26, weight: .bold)).rotationEffect(.degrees(-35))
                Image(systemName: "iphone").font(.system(size: 58, weight: .regular))
            }
            .foregroundStyle(LD.art)
            .shadow(color: Theme.dyn(0x28D2E6, 0x0B5E68, 0.35, 0.15), radius: 10)
            .frame(height: 96)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
            Text("ld.title").font(.system(size: 32, weight: .heavy)).tracking(-0.6).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
                .multilineTextAlignment(.center).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            Text("ld.subtitle").font(.system(size: 14.5)).foregroundStyle(LD.body)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip("checkmark.shield", "ld.chip.remote")
            chip("arrow.triangle.2.circlepath", "ld.chip.sync")
            chip("laptopcomputer.and.iphone", "ld.chip.multi")
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func chip(_ icon: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(LD.cyan)
            Text(LocalizedStringKey(key)).font(.system(size: 12)).foregroundStyle(Theme.dyn(0xE6F3F7, 0x264452))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(Capsule().fill(Theme.dyn(0x041821, 0xFFFFFF, 0.7, 1)))
        .overlay(Capsule().stroke(Theme.dyn(0x6EE8F4, 0xA6E3E7, 0.22, 1), lineWidth: 1))
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Theme.dyn(0xFFC9C9, 0xB3333F))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.dyn(0xFF5A5A, 0xFF5A5A, 0.1, 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.dyn(0xFF7878, 0xE0606C, 0.3, 0.4), lineWidth: 1))
            .accessibilityAddTraits(.isStaticText)
    }

    // MARK: cards

    private var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LD.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(LD.line, lineWidth: 1))
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(LocalizedStringKey(key)).font(.system(size: 18, weight: .bold)).foregroundStyle(LD.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, -4)
            .accessibilityAddTraits(.isHeader)
    }

    private func iconCircle(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .regular)).foregroundStyle(LD.cyanSoft)
            .frame(width: size, height: size)
            .background(Circle().fill(RadialGradient(colors: [Theme.dyn(0x28C8DC, 0xC4EEF1, 0.22, 1), Theme.dyn(0x031E28, 0xEFFBFC, 0.9, 1)],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75)))
            .overlay(Circle().stroke(Theme.dyn(0x51C8DC, 0xA6E3E7, 0.3, 1), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func summary(count: Int) -> some View {
        HStack(spacing: 12) {
            iconCircle("laptopcomputer", size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? ldT("ld.summary.one") : String(format: ldT("ld.summary.n"), count))
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
                    .fixedSize(horizontal: false, vertical: true)
                Text("ld.summary.sub").font(.system(size: 13.5)).foregroundStyle(LD.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                Circle().fill(LD.green).frame(width: 9, height: 9).shadow(color: LD.green.opacity(0.6), radius: 4)
                Text(String(format: ldT("ld.connected"), connectedCount))
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(LD.greenText)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 84)
        }
        .padding(.vertical, 13).padding(.horizontal, 14)
        .background(card)
        .accessibilityElement(children: .combine)
    }

    private func row(_ d: LinkedDevice) -> some View {
        let a = LinkedDeviceText.activity(d, now: now)
        let isCurrent = d.current == true
        let title = LinkedDeviceText.title(d)
        return HStack(spacing: 12) {
            iconCircle(LinkedDeviceText.icon(d), size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533)).lineLimit(1)
                Text(LinkedDeviceText.sub(d)).font(.system(size: 13.5)).foregroundStyle(LD.sub).lineLimit(1)
                HStack(spacing: 8) {
                    Circle().fill(a.tone == .past ? Theme.dyn(0x6B8691, 0x9AB0BA) : LD.green).frame(width: 9, height: 9)
                        .shadow(color: a.tone == .past ? .clear : LD.green.opacity(0.55), radius: 3)
                    Text(a.text).font(.system(size: 13.5))
                        .foregroundStyle(a.tone == .past ? Theme.dyn(0xB2C4CC, 0x5F7686) : Theme.dyn(0xDBE9EE, 0x264452)).lineLimit(1)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if isCurrent {
                Text("ld.badge.this").font(.system(size: 12.5, weight: .bold)).foregroundStyle(LD.cyanSoft).lineLimit(1)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(Capsule().fill(Theme.dyn(0x35E6F2, 0x0097A5, 0.1, 0.1)))
                    .overlay(Capsule().stroke(Theme.dyn(0x35E6F2, 0x0097A5, 0.55, 0.45), lineWidth: 1))
                    .fixedSize()
            }
            moreButton(d, title: title, small: isCurrent)
        }
        .padding(12)
        .frame(minHeight: 76)
        .anchorPreference(key: LDRowAnchor.self, value: .bounds) { [d.id: $0] }
    }

    private func moreButton(_ d: LinkedDevice, title: String, small: Bool) -> some View {
        let s: CGFloat = small ? 34 : 40
        let open = menu == d.id
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { menu = open ? nil : d.id }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).rotationEffect(.degrees(90))
                .foregroundStyle(Theme.dyn(0xE6F3F7, 0x264452))
                .frame(width: s, height: s)
                .background(Circle().fill(Theme.dyn(0x03121A, 0xFFFFFF, 0.6, 1)))
                .overlay(Circle().stroke(open ? Theme.dyn(0x6EE8F4, 0x00A8B5, 0.55, 0.6) : Theme.dyn(0xFFFFFF, 0xA6E3E7, 0.16, 1), lineWidth: 1))
                .contentShape(Circle())
        }
        .accessibilityLabel(Text(String(format: ldT("ld.options"), title)))
    }

    private var signOutAllButton: some View {
        Button { open(.all) } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 19, weight: .medium))
                Text("ld.all.button").font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(LD.red)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Theme.dyn(0x3C0A12, 0xFFEEF0, 0.2, 1)))
            .overlay(Capsule().stroke(Theme.dyn(0xFF6B78, 0xD8404A, 0.55, 0.5), lineWidth: 1.5))
            .contentShape(Capsule())
        }
    }

    private var securityCard: some View {
        NavigationLink { PrivacyPage() } label: {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.shield").font(.system(size: 28, weight: .regular)).foregroundStyle(LD.cyan)
                    .shadow(color: Theme.dyn(0x35E6F2, 0x0097A5, 0.45, 0.2), radius: 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ld.security.title").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
                    Text("ld.security.sub").font(.system(size: 13.5)).foregroundStyle(LD.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward").font(.system(size: 16, weight: .semibold)).foregroundStyle(LD.note)
            }
            .padding(16)
            .background(card)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.top, 4)
    }

    // MARK: ⋮ menu

    @ViewBuilder private func menuLayer(_ anchors: [String: Anchor<CGRect>]) -> some View {
        if let id = menu, let anchor = anchors[id], let d = list?.first(where: { $0.id == id }) {
            GeometryReader { g in
                let r = g[anchor]
                let items: CGFloat = d.current == true ? 2 : 3
                let height: CGFloat = 76 + 50 * items
                let below = r.maxY - 6
                let top = below + height > g.size.height - 8 ? max(8, r.minY - height + 6) : below
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { menu = nil } }
                    menuCard(d)
                        .frame(width: min(330, g.size.width - 40))
                        .padding(.top, top)
                        .padding(.trailing, 28)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topTrailing)
            }
            .transition(.opacity)
        }
    }

    private func menuCard(_ d: LinkedDevice) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                iconCircle(LinkedDeviceText.icon(d), size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LinkedDeviceText.title(d)).font(.system(size: 15.5, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533)).lineLimit(1)
                    Text(LinkedDeviceText.type(d)).font(.system(size: 13)).foregroundStyle(LD.sub).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 10)
            Rectangle().fill(Theme.dyn(0x51C8DC, 0xC4EEF1, 0.16, 1)).frame(height: 1)
            menuItem("info.circle", "ld.menu.details") { open(.details(d)) }
            Rectangle().fill(Theme.dyn(0x51C8DC, 0xC4EEF1, 0.1, 1)).frame(height: 1)
            menuItem("pencil", "ld.menu.rename") { open(.rename(d)) }
            if d.current != true {
                Rectangle().fill(Theme.dyn(0x51C8DC, 0xC4EEF1, 0.1, 1)).frame(height: 1)
                menuItem("rectangle.portrait.and.arrow.right", "ld.menu.signout", danger: true) { open(.out(d)) }
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.dyn(0x051E28, 0xFFFFFF, 0.98, 1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.dyn(0x6EE8F4, 0xA6E3E7, 0.3, 1), lineWidth: 1))
        .shadow(color: Theme.dyn(0x000000, 0x0B5E68, 0.55, 0.18), radius: 25, y: 20)
    }

    private func menuItem(_ icon: String, _ key: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(danger ? LD.red : LD.note).frame(width: 24)
                Text(LocalizedStringKey(key)).font(.system(size: 16)).foregroundStyle(danger ? LD.red : LD.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
    }

    // MARK: dialogs (details, rename, sign out, sign out all)

    @ViewBuilder private var dialogLayer: some View {
        if let dlg = dialog {
            ZStack {
                Theme.dyn(0x01080E, 0x0F2533, 0.66, 0.28).ignoresSafeArea()
                    .onTapGesture { if !busy { close() } }
                dialogCard(dlg).padding(20)
            }
            .transition(.opacity)
        }
    }

    private func dialogCard(_ dlg: LDDialog) -> some View {
        VStack(spacing: 12) {
            switch dlg {
            case .details(let d): details(d)
            case .rename(let d): renameForm(d)
            // busy is set before the task starts: a quick second tap sent the same sign-out twice
            case .out(let d): confirm(title: String(format: ldT("ld.out.title"), LinkedDeviceText.title(d)), message: "ld.out.body") {
                guard !busy else { return }
                busy = true
                Task { await signOut(d) }
            }
            case .all: confirm(title: ldT("ld.all.title"), message: "ld.all.body") {
                guard !busy else { return }
                busy = true
                Task { await signOutOthers() }
            }
            }
        }
        .padding(.top, 26).padding(.horizontal, 22).padding(.bottom, 20)
        .frame(maxWidth: 400)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [Theme.dyn(0x0A2C39, 0xFFFFFF), Theme.dyn(0x051A24, 0xF4FBFC)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.dyn(0x6EE8F4, 0xA6E3E7, 0.3, 1), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { if !busy { close() } } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dyn(0xDBE9EE, 0x264452))
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.dyn(0xFFFFFF, 0x0097A5, 0.06, 0.08))).contentShape(Circle())
            }
            .accessibilityLabel(Text("ld.close"))
            .padding(12)
        }
        .shadow(color: Theme.dyn(0x000000, 0x0B5E68, 0.6, 0.18), radius: 40, y: 30)
    }

    private func dialogIcon(_ symbol: String, danger: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 26, weight: .regular)).foregroundStyle(danger ? LD.red : LD.cyanSoft)
            .frame(width: 64, height: 64)
            .background(Circle().fill(danger ? Theme.dyn(0xFF6B78, 0xD8404A, 0.12, 0.1) : Theme.dyn(0x35E6F2, 0x0097A5, 0.1, 0.1)))
            .overlay(Circle().stroke(danger ? Theme.dyn(0xFF6B78, 0xD8404A, 0.35, 0.35) : Theme.dyn(0x35E6F2, 0x0097A5, 0.35, 0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private func dialogTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func dialogBody(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).lineSpacing(3).foregroundStyle(LD.body)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private enum PillStyle { case danger, primary, plain }

    private func pill(_ title: String, _ style: PillStyle, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16.5, weight: .bold))
                .foregroundStyle(style == .danger ? Color.white : style == .primary ? Theme.hex(0x04222C) : LD.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    switch style {
                    case .danger:
                        Capsule().fill(LinearGradient(colors: [Theme.hex(0xFF7A85), Theme.hex(0xE2475A)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.hex(0xE2475A, 0.3), radius: 13, y: 10)
                    case .primary:
                        Capsule().fill(LinearGradient(colors: [Theme.hex(0xA8FBFF), Theme.hex(0x22CFE0)], startPoint: .top, endPoint: .bottom))
                    case .plain:
                        Capsule().stroke(Theme.dyn(0xFFFFFF, 0xA6E3E7, 0.22, 1), lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .disabled(busy)
        .opacity(busy ? 0.55 : 1)
    }

    private func confirm(title: String, message: String, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            dialogIcon("rectangle.portrait.and.arrow.right", danger: true)
            dialogTitle(title)
            dialogBody(ldT(message))
            pill(busy ? ldT("ld.signingout") : ldT("ld.signout"), .danger, action)
            pill(ldT("ld.cancel"), .plain) { close() }
        }
    }

    private func details(_ d: LinkedDevice) -> some View {
        var rows: [(String, String)] = [
            (ldT("ld.d.name"), LinkedDeviceText.title(d)),
            (ldT("ld.d.device"), LinkedDeviceText.name(d)),
            (ldT("ld.d.app"), d.app == "desktop" ? ldT("ld.d.app.desktop") : d.app == "ios" ? ldT("ld.d.app.ios") : ldT("ld.type.web")),
        ]
        if let b = d.browser, !b.isEmpty { rows.append((ldT("ld.d.browser"), b)) }
        if let p = d.platform, !p.isEmpty { rows.append((ldT("ld.d.system"), LinkedDeviceText.osName(p))) }
        let isLive = d.current == true || d.connected == true
        rows.append((ldT("ld.d.signedin"), LinkedDeviceText.fullDate(d.created_at)))
        rows.append((ldT("ld.d.last"), isLive ? ldT("ld.d.now") : LinkedDeviceText.fullDate(d.last_seen_at)))
        rows.append((ldT("ld.d.status"), d.current == true ? ldT("ld.badge.this") : d.connected == true ? ldT("ld.d.st.connected") : ldT("ld.d.st.idle")))
        return VStack(spacing: 12) {
            dialogIcon(LinkedDeviceText.icon(d))
            dialogTitle(LinkedDeviceText.title(d))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(Theme.dyn(0x51C8DC, 0xC4EEF1, 0.12, 1)).frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(r.0).foregroundStyle(LD.empty)
                        Spacer(minLength: 8)
                        Text(r.1).foregroundStyle(LD.ink).multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 14.5))
                    .padding(.vertical, 11).padding(.horizontal, 14)
                    .accessibilityElement(children: .combine)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.dyn(0x51C8DC, 0xA6E3E7, 0.18, 1), lineWidth: 1))
            .padding(.top, 4)
        }
    }

    private func renameForm(_ d: LinkedDevice) -> some View {
        let count = renameText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return VStack(spacing: 12) {
            dialogTitle(ldT("ld.rename.title"))
            dialogBody(String(format: ldT("ld.rename.hint"), LinkedDeviceText.name(d)))
            TextField("", text: $renameText, prompt: Text(LinkedDeviceText.name(d)).foregroundColor(Theme.dyn(0x8FA6B2, 0x7A939E)))
                .font(.system(size: 16))
                .foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
                .tint(LD.cyan)
                .focused($renameFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { startRename(d) }
                .onChange(of: renameText) { v in if v.count > 40 { renameText = String(v.prefix(40)) } }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.dyn(0x021018, 0xF3FBFC, 0.8, 1)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(renameFocused ? Theme.dyn(0x8FF6FB, 0x00A8B5) : Theme.dyn(0x6EE8F4, 0xA6E3E7, 0.4, 1), lineWidth: 1.5))
                .accessibilityLabel(Text("ld.rename.field"))
            Text(verbatim: "\(count)/40").font(.system(size: 12.5)).foregroundStyle(Theme.dyn(0x8FA6B2, 0x7A939E))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, -6)
            if !renameError.isEmpty { errorBanner(renameError) }
            pill(busy ? ldT("ld.saving") : ldT("ld.save"), .primary) { startRename(d) }
            pill(ldT("ld.cancel"), .plain) { close() }
        }
    }

    // MARK: toast (only after the server confirmed)

    @ViewBuilder private var toastLayer: some View {
        if let t = toast {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.white)
                    .frame(width: 36, height: 36).background(Circle().fill(Theme.hex(0x1FBF78)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.dyn(0xFFFFFF, 0x0F2533))
                    Text(t.text).font(.system(size: 13.5)).foregroundStyle(LD.sub).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button { toast = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.dyn(0xDBE9EE, 0x264452))
                        .frame(width: 36, height: 36).background(Circle().fill(Theme.dyn(0xFFFFFF, 0x0097A5, 0.06, 0.08))).contentShape(Circle())
                }
                .accessibilityLabel(Text("ld.dismiss"))
            }
            .padding(.vertical, 12).padding(.leading, 14).padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.dyn(0x052828, 0xEFFBF5, 0.97, 1)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.dyn(0x22D68A, 0x0FB57F, 0.45, 0.5), lineWidth: 1))
            .shadow(color: Theme.dyn(0x000000, 0x0B5E68, 0.45, 0.16), radius: 20, y: 16)
            .frame(maxWidth: 420)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
