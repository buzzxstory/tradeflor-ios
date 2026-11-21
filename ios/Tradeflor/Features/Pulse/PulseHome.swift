import SwiftUI
import CoreLocation

/// Home | Pulse at the top of the TradeFlor tab (the choice is remembered). Without Pulse on this server: nothing shows.
struct PulseSideSwitch: View {
    @Binding var side: String
    @ObservedObject private var pulse = PulseStore.shared

    var body: some View {
        if pulse.enabled {
            HStack(spacing: 0) {
                button("home", "pulse.side.home")
                button("pulse", "pulse.side.pulse")
            }
            .padding(3)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        }
    }

    private func button(_ v: String, _ key: String) -> some View {
        let on = side == v
        return Button { side = v } label: {
            Text(LocalizedStringKey(key)).font(.system(size: 14, weight: .bold))
                .foregroundStyle(on ? Theme.onAccent : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? Theme.accent : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

struct PulseOpen: Identifiable, Equatable { let id: String }

/// The Pulse home (web PulseHub.tsx, .ph2-*): a hero card with the live count, the title, the line, Create meetup and
/// Instant circle, and a radar; three quick tiles; invitations; live and upcoming meetups; Party mode; trust badges.
struct PulseHomeView: View {
    let token: String
    let me: String
    @ObservedObject private var pulse = PulseStore.shared
    @ObservedObject private var sharer = PulseSharer.shared
    @AppStorage("tf.pulse.party") private var party = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creating = false
    @State private var instant = false
    @State private var open: PulseOpen?
    @State private var capsules = false
    @State private var capture = false
    @State private var sharingFor: PulseCircle?
    @State private var note: String?
    @State private var now = Date()

    private static let violet = Color(red: 0xB4 / 255.0, green: 0x8C / 255.0, blue: 1)
    private static let coral = Color(red: 1, green: 0x7F / 255.0, blue: 0x66 / 255.0)

    private var invitations: [PulseCircleEntry] { pulse.circles.filter { $0.response == "invited" && $0.circle.isOpen } }
    private var meetups: [PulseCircleEntry] {
        pulse.circles.filter { $0.response != "invited" && $0.response != "declined" && $0.circle.isOpen }
    }
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    private var liveCount: Int { meetups.filter { ($0.circle.starts_at ?? 0) <= nowMs }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                HStack(spacing: 10) {
                    quick("location.magnifyingglass", "pulse.card.find", PulseInk.cyan) { findFriend() }
                    quick("hourglass", "pulse.card.capsule", Self.violet) { capsules = true }
                    quick("camera.fill", "pulse.home.capture", PulseInk.amber) { capture = true }
                }
                if let note { Text(verbatim: note).font(.footnote).foregroundStyle(PulseInk.amber) }
                if !invitations.isEmpty {
                    sectionTitle("pulse.home.invitations", invitations.count)
                    ForEach(invitations) { e in invitationCard(e) }
                }
                sectionTitle("pulse.home.live", meetups.count)
                if meetups.isEmpty {
                    VStack(spacing: 6) {
                        PulseIconChip(symbol: "map.fill", color: PulseInk.cyan, size: 52)
                        Text("pulse.home.empty").font(PulseFont.display(17, 800)).foregroundStyle(PulseInk.ink)
                        Text(LocalizedStringKey(pulse.loaded ? "pulse.home.empty.sub" : "pulse.loading")).font(.footnote).foregroundStyle(PulseInk.muted)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                ForEach(meetups) { e in
                    Button { open = PulseOpen(id: e.id) } label: { meetupCard(e) }.buttonStyle(.plain)
                }
                partyCard
                trust
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .clipped()
        .modifier(DockSpace())
        .refreshable { await pulse.reload() }
        .task { await pulse.reload() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(pulse.$openCircle) { id in if let id { open = PulseOpen(id: id); pulse.openCircle = nil } }
        .fullScreenCover(item: $open) { o in PulseMeetupScreen(token: token, me: me, circleID: o.id).tfColorScheme() }
        .sheet(isPresented: $creating) {
            PulseCreateView(token: token, me: me, instant: false) { c in creating = false; open = PulseOpen(id: c.id) }.tfColorScheme()
        }
        .sheet(isPresented: $instant) {
            PulseCreateView(token: token, me: me, instant: true) { c in instant = false; open = PulseOpen(id: c.id) }.tfColorScheme()
        }
        .sheet(isPresented: $capsules) { PulseCapsuleList(token: token, me: me).tfColorScheme() }
        // Capture moment: the status composer; a posted status refreshes the Chats status strip
        .fullScreenCover(isPresented: $capture) {
            StatusCreatorSheet { NotificationCenter.default.post(name: .tfStatusChanged, object: nil) }
        }
        .sheet(item: $sharingFor) { c in
            PulseShareSheet(circle: c, others: max(0, (pulse.circles.first { $0.id == c.id }?.going ?? 1) - 1), token: token, me: me) { _ in
                sharingFor = nil
                open = PulseOpen(id: c.id)
            }
            .presentationDetents([.large])
        }
    }

    // MARK: hero

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            radar.frame(width: 170, height: 170).offset(x: 64, y: -34).opacity(0.35).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 5) {
                        Circle().fill(PulseInk.green).frame(width: 7, height: 7)
                        Text(verbatim: String(format: NSLocalizedString("pulse.home.livenow", comment: ""), liveCount))
                    }
                    .font(.system(size: 11.5, weight: .heavy)).foregroundStyle(PulseInk.green)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(PulseInk.green.opacity(0.14), in: Capsule())
                    Spacer()
                    if sharer.isSharingAnywhere {
                        Button { Task { await sharer.stopAll(); await pulse.reload() } } label: {
                            Label("pulse.stopall", systemImage: "location.slash.fill").font(.system(size: 11.5, weight: .bold))
                                .padding(.horizontal, 10).frame(minHeight: 30)
                                .background(PulseInk.red, in: Capsule()).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // the brand lockup: Trade (white) Flor (the sidebar's turquoise) and the slanted MEETUP badge
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Text(verbatim: "Trade").foregroundStyle(Theme.hex(0xF7FBFD))
                        Text(verbatim: "Flor").foregroundStyle(LinearGradient(colors: [Theme.hex(0x7FF8FF), Theme.hex(0x2AE8F8), Theme.hex(0x14D2F2)],
                                                                         startPoint: .top, endPoint: .bottom))
                    }
                    .font(PulseFont.brand(29))
                    .kerning(-1)
                    MeetupBadge()
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
                // one tagline (web 42d5bedd): "Plan it. Pin it. Meet up live." with the last part in the cyan gradient
                HStack(spacing: 5) {
                    Text("pulse.home.tag1").font(PulseFont.display(18, 700)).foregroundStyle(Theme.hex(0xDFF4F8))
                    Text("pulse.home.tag2").font(PulseFont.display(18, 800))
                        .foregroundStyle(LinearGradient(colors: [Theme.hex(0x7FFAFF), Theme.hex(0x19D9E3), Theme.hex(0x0AA8D8)], startPoint: .leading, endPoint: .trailing))
                }
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityElement(children: .combine)
                HStack(spacing: 10) {
                    Button { creating = true } label: {
                        Label("pulse.home.create", systemImage: "plus").font(PulseFont.display(15, 800)).frame(maxWidth: .infinity, minHeight: 46)
                            .background(PulseInk.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.hex(0x04222C))
                    }
                    .buttonStyle(.plain)
                    Button { instant = true } label: {
                        Label("pulse.home.instant", systemImage: "qrcode").font(PulseFont.display(15, 800)).frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                            .foregroundStyle(PulseInk.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(
            ZStack {
                LinearGradient(colors: [Theme.hex(0x063440), Theme.hex(0x02202A), Theme.hex(0x011820)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [PulseInk.cyan.opacity(0.28), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
                RadialGradient(colors: [PulseInk.amber.opacity(0.16), .clear], center: .bottomLeading, startRadius: 0, endRadius: 200)
                Image("PulseFlower").resizable().scaledToFit().frame(width: 180).opacity(0.12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(PulseInk.cyan.opacity(0.22), lineWidth: 1))
    }

    /// The orb in a glowing circle with three expanding waves and three floating place blips.
    private var radar: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? Double(i) / 3 : ((t / 3) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(PulseInk.cyan.opacity(0.55 * (1 - phase)), lineWidth: 1.5).frame(width: 60 + 110 * phase, height: 60 + 110 * phase)
                }
                Circle().fill(Theme.hex(0x062A34)).frame(width: 62, height: 62)
                    .overlay(Circle().stroke(PulseInk.cyan.opacity(0.6), lineWidth: 2))
                    .shadow(color: PulseInk.cyan.opacity(0.6), radius: 14)
                Image("BrandFlower").resizable().scaledToFit().frame(width: 38, height: 38)
                blip("cup.and.saucer.fill", PulseInk.amber, x: -58, y: -30, t: t, k: 0)
                blip("fork.knife", Self.coral, x: 56, y: 22, t: t, k: 1)
                blip("mappin", PulseInk.cyan, x: -20, y: 58, t: t, k: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func blip(_ e: String, _ c: Color, x: CGFloat, y: CGFloat, t: Double, k: Int) -> some View {
        let bob = reduceMotion ? 0 : CGFloat(sin(t * 1.2 + Double(k) * 2)) * 4
        return Image(systemName: e).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28)
            .background(Theme.hex(0x071A24), in: Circle()).overlay(Circle().stroke(c, lineWidth: 2))
            .shadow(color: c.opacity(0.6), radius: 6)
            .offset(x: x, y: y + bob)
    }

    // MARK: tiles and sections

    private func quick(_ icon: String, _ key: String, _ tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                PulseIconChip(symbol: icon, color: tint)
                Text(LocalizedStringKey(key)).font(PulseFont.display(13.5, 700)).foregroundStyle(PulseInk.ink)
                    .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(12)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(tint.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ key: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(key)).font(PulseFont.display(18, 800)).foregroundStyle(PulseInk.ink)
            Text(verbatim: "\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(PulseInk.muted)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.white.opacity(0.08), in: Capsule())
        }
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func findFriend() {
        if let e = meetups.first(where: { ($0.sharing ?? 0) > 0 }) { open = PulseOpen(id: e.id) } else { note = NSLocalizedString("pulse.find.none", comment: "") }
    }

    private static let whenFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private func invitationCard(_ e: PulseCircleEntry) -> some View {
        let c = e.circle
        let when = Self.whenFormat.string(from: Date(timeIntervalSince1970: Double(max(c.starts_at ?? 0, 0) == 0 ? nowMs : c.starts_at!) / 1000))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                activityBadge(c, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: NSLocalizedString("pulse.home.invited", comment: ""), pulse.name(e.invited_by ?? "")))
                        .font(.caption.weight(.semibold)).foregroundStyle(PulseInk.amber)
                    Text(verbatim: c.title ?? "").font(PulseFont.display(16.5, 800)).foregroundStyle(PulseInk.ink).lineLimit(1)
                    Label(((c.dest_name ?? "").isEmpty ? "—" : c.dest_name!) + " · " + when, systemImage: "mappin").font(PulseFont.text(12.5)).foregroundStyle(PulseInk.muted).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Button { Task { await respond(e, "going"); sharingFor = c } } label: {
                    Text("pulse.home.joinshare").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity, minHeight: 42)
                        .background(PulseInk.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(Theme.hex(0x04222C))
                }
                Button { Task { await respond(e, "going") } } label: {
                    Text("pulse.home.joinonly").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous)).foregroundStyle(PulseInk.ink)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 18) {
                Button("pulse.maybe") { Task { await respond(e, "maybe") } }
                Button("pulse.decline") { Task { await respond(e, "declined") } }
            }
            .font(.footnote.weight(.semibold)).foregroundStyle(PulseInk.muted).buttonStyle(.plain)
        }
        .padding(14)
        .background(LinearGradient(colors: [PulseInk.amber.opacity(0.14), Color.white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseInk.amber.opacity(0.3), lineWidth: 1))
    }

    /// Answering never shares a location: "Join & share location" answers going, then opens the share step.
    private func respond(_ e: PulseCircleEntry, _ r: String) async {
        _ = try? await APIClient.shared.pulsePost(token: token, circle: e.id, "respond", body: ["response": r])
        await pulse.reload()
    }

    private func activityBadge(_ c: PulseCircle, size: CGFloat) -> some View {
        Image(systemName: c.symbol).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size - 6, height: size - 6)
            .background(Theme.hex(0x071A24), in: Circle())
            .padding(3)
            .overlay(Circle().stroke(AngularGradient(colors: [PulseInk.cyan, Color(red: 0.6, green: 0.97, blue: 1), PulseInk.amber, Self.coral, PulseInk.cyan],
                                                     center: .center), lineWidth: 3))
    }

    private func meetupCard(_ e: PulseCircleEntry) -> some View {
        let c = e.circle
        let started = (c.starts_at ?? 0) <= nowMs
        let sharing = e.sharing ?? 0
        return HStack(spacing: 12) {
            activityBadge(c, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: c.title ?? "").font(PulseFont.display(16.5, 800)).foregroundStyle(PulseInk.ink).lineLimit(1)
                if let d = c.dest_name, !d.isEmpty { Label(d, systemImage: "mappin").font(PulseFont.text(12.5)).foregroundStyle(PulseInk.muted).lineLimit(1) }
                HStack(spacing: 6) {
                    chip("person.2.fill", String(format: NSLocalizedString("pulse.home.joined", comment: ""), e.going ?? 0), PulseInk.muted)
                    chip("dot.radiowaves.left.and.right", String(format: NSLocalizedString("pulse.home.sharing", comment: ""), sharing), sharing > 0 ? PulseInk.cyan : PulseInk.muted)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                if started {
                    HStack(spacing: 4) {
                        Circle().fill(PulseInk.green).frame(width: 6, height: 6)
                        Text("pulse.hdr.live").textCase(.uppercase)
                    }
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(PulseInk.green)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(PulseInk.green.opacity(0.14), in: Capsule())
                    Text(verbatim: String(format: NSLocalizedString("pulse.home.left", comment: ""), PulseRules.shortLeft((c.expires_at ?? 0) - nowMs)))
                        .font(.caption2).foregroundStyle(PulseInk.muted)
                } else {
                    Text("pulse.home.upcoming").font(.system(size: 10, weight: .heavy)).foregroundStyle(PulseInk.amber)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(PulseInk.amber.opacity(0.14), in: Capsule())
                    Text(verbatim: String(format: NSLocalizedString("pulse.home.in", comment: ""), PulseRules.shortLeft((c.starts_at ?? 0) - nowMs)))
                        .font(.caption2).foregroundStyle(PulseInk.muted)
                }
                if sharer.isSharing(e.id) { Image(systemName: "location.fill").font(.caption).foregroundStyle(PulseInk.cyan) }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func chip(_ icon: String, _ text: String, _ c: Color) -> some View {
        Label(text, systemImage: icon).font(PulseFont.text(11.5, 600)).foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 3).background(c.opacity(0.12), in: Capsule())
    }

    private var partyCard: some View {
        Toggle(isOn: $party) {
            HStack(spacing: 10) {
                PulseIconChip(symbol: "sparkles", color: Self.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("pulse.party").font(PulseFont.display(15.5, 800)).foregroundStyle(PulseInk.ink)
                    Text("pulse.party.sub").font(PulseFont.text(12.5)).foregroundStyle(PulseInk.muted)
                }
            }
        }
        .tint(Self.violet)
        .padding(14)
        .background(Self.violet.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Self.violet.opacity(0.22), lineWidth: 1))
    }

    /// Safe by design: four cards, each a colour chip, a title and one line.
    private var trust: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("pulse.safe.title").font(PulseFont.display(18, 800)).foregroundStyle(PulseInk.ink).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                safe("lock.fill", PulseInk.cyan, "pulse.trust.private", "pulse.trust.private.sub")
                safe("timer", Self.violet, "pulse.trust.ends", "pulse.trust.ends.sub")
                safe("bell.fill", PulseInk.amber, "pulse.trust.arrival", "pulse.trust.arrival.sub")
                safe("shield.fill", Color(red: 1, green: 0x6B / 255.0, blue: 0x79 / 255.0), "pulse.trust.safety", "pulse.trust.safety.sub")
            }
        }
    }

    private func safe(_ icon: String, _ color: Color, _ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PulseIconChip(symbol: icon, color: color, size: 34)
            Text(LocalizedStringKey(title)).font(PulseFont.display(14, 800)).foregroundStyle(PulseInk.ink)
            Text(LocalizedStringKey(line)).font(PulseFont.text(12)).foregroundStyle(PulseInk.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(12)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(color.opacity(0.2), lineWidth: 1))
    }
}

/// "Share your live location": a radar with my face and the friends who will see me, three duration tiles (1 hour by default),
/// one Start sharing button and three promises. Nothing is shared before Start sharing; the order (permission, first fix,
/// consent, positions) is the sharer's.
struct PulseShareSheet: View {
    let circle: PulseCircle
    let others: Int
    var faces: [String] = []
    var people: [String: PulsePerson] = [:]
    var token = ""
    var me = ""
    let onDone: (Bool) -> Void
    @State private var minutes = 60
    @State private var busy = false
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var seeLine: String {
        if faces.count == 1, let n = people[faces[0]]?.name, !n.isEmpty {
            return String(format: NSLocalizedString("pulse.share.radar.one", comment: ""), n)
        }
        return String(format: NSLocalizedString("pulse.share.radar.n", comment: ""), max(others, faces.count))
    }

    private var endTime: String {
        guard let e = circle.expires_at, e > 0 else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(e) / 1000))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                radar.frame(height: 170)
                Text(verbatim: seeLine).font(.headline).foregroundStyle(PulseInk.ink).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    tile(15, "15", "pulse.share.t15b", NSLocalizedString("pulse.share.t15c", comment: ""))
                    tile(60, "1", "pulse.share.t60b", NSLocalizedString("pulse.share.t60c", comment: ""))
                    tile(0, NSLocalizedString("pulse.share.tenda", comment: ""), "pulse.share.tendb",
                         endTime.isEmpty ? "" : String(format: NSLocalizedString("pulse.share.tendc", comment: ""), endTime))
                }
                Button { Task { await share() } } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Theme.hex(0x04222C)) } else { Image(systemName: "dot.radiowaves.left.and.right") }
                        Text("pulse.share.start")
                    }
                    .font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 52)
                    .background(PulseInk.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(Theme.hex(0x04222C))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                if let error { Text(verbatim: error).font(.footnote).foregroundStyle(PulseInk.red).multilineTextAlignment(.center) }
                VStack(spacing: 8) {
                    promise("person.2.fill", "pulse.share.p1")
                    promise("timer", "pulse.share.p2")
                    promise("sparkles", "pulse.share.p3")
                }
                Button("notes.cancel") { onDone(false) }.foregroundStyle(PulseInk.muted).frame(minHeight: 44)
            }
            .padding(20)
        }
        .modifier(PulseSheetLook())
    }

    private var radar: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = reduceMotion ? Double(i) / 3 : ((t / 2.4) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(PulseInk.cyan.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                        .frame(width: 66 + 120 * phase, height: 66 + 120 * phase)
                }
                Ellipse().stroke(PulseInk.amber.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(width: 224, height: 92)
                ForEach(Array(faces.prefix(6).enumerated()), id: \.offset) { i, id in
                    let a = 2 * Double.pi * Double(i) / Double(max(1, min(6, faces.count))) - Double.pi / 2
                    Avatar(token: token, userID: id, avatarID: people[id]?.avatar_id, title: people[id]?.name ?? "", size: 30)
                        .overlay(Circle().stroke(PulseInk.amber, lineWidth: 2))
                        .offset(x: 112 * cos(a), y: 46 * sin(a))
                }
                Avatar(token: token, userID: me, avatarID: nil, title: "", size: 66)
                    .overlay(Circle().stroke(PulseInk.cyan, lineWidth: 3))
                    .shadow(color: PulseInk.cyan.opacity(0.5), radius: 12)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func tile(_ m: Int, _ big: String, _ unit: String, _ sub: String) -> some View {
        let on = minutes == m
        return Button { minutes = m } label: {
            VStack(spacing: 2) {
                Text(verbatim: big).font(.system(size: big.count > 3 ? 17 : 24, weight: .heavy)).foregroundStyle(PulseInk.ink)
                Text(LocalizedStringKey(unit)).font(.caption.weight(.semibold)).foregroundStyle(PulseInk.ink.opacity(0.85))
                Text(verbatim: sub).font(.caption2).foregroundStyle(PulseInk.muted).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(on ? PulseInk.cyan.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? PulseInk.cyan : Color.white.opacity(0.08), lineWidth: on ? 2 : 1))
            .shadow(color: on ? PulseInk.cyan.opacity(0.45) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func promise(_ icon: String, _ key: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(PulseInk.cyan)
                .frame(width: 30, height: 30).background(PulseInk.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(LocalizedStringKey(key)).font(.footnote).foregroundStyle(PulseInk.ink.opacity(0.85))
            Spacer()
        }
    }

    private func share() async {
        busy = true
        defer { busy = false }
        do {
            try await PulseSharer.shared.start(circle: circle.id, minutes: minutes, dest: circle.dest)
            onDone(true)
        } catch PulseSharer.ShareError.denied {
            error = NSLocalizedString("pulse.share.denied", comment: "")
        } catch PulseSharer.ShareError.noFix {
            error = NSLocalizedString("pulse.share.nofix", comment: "")
        } catch {
            self.error = NSLocalizedString("pulse.share.failed", comment: "")
        }
    }
}

/// Create Meetup (or an Instant Circle): activity, name, place pin on a small map, when, how long, who, majority policy.
struct PulseCreateView: View {
    let token: String
    let me: String
    let instant: Bool
    let onCreated: (PulseCircle) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pulse = PulseStore.shared
    @State private var activity = "coffee"
    @State private var title = ""
    @State private var place = ""
    @State private var pin: CLLocationCoordinate2D?
    @State private var when = 0 // minutes from now; -1 = chosen time
    @State private var at = Date().addingTimeInterval(3600)
    @State private var hours: Double = 3
    @State private var friends: [ConversationSummary] = []
    @State private var chosen = Set<String>()
    @State private var majority = false
    @State private var busy = false
    @State private var error: String?
    @State private var camera = PulseCamera(mode: .place)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(PulseRules.activities, id: \.self) { a in
                                Button { activity = a; if title.isEmpty || title.hasPrefix(suggestedPrefix) { title = suggested(a) } } label: {
                                    Text(verbatim: (PulseRules.activityIcon[a] ?? "") + " " + NSLocalizedString("pulse.act." + a, comment: ""))
                                        .font(.footnote.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                                        .background(activity == a ? Theme.accent : Theme.card, in: Capsule())
                                        .foregroundStyle(activity == a ? Theme.onAccent : Theme.text)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    TextField(NSLocalizedString("pulse.create.name", comment: ""), text: $title)
                }
                Section {
                    TextField(NSLocalizedString("pulse.create.place", comment: ""), text: $place)
                        .onChange(of: place) { _ in if title.isEmpty || title.hasPrefix(suggestedPrefix) { title = suggested(activity) } }
                    ZStack(alignment: .topTrailing) {
                        PulseMapView(token: token, styleURL: pulse.config.style_url, people: [],
                                     dest: pin.map { PulseMapDest(coordinate: $0, name: place, icon: PulseRules.activityIcon[activity] ?? "📍") },
                                     camera: camera, selected: nil, compact: true, onTapMap: { c in pin = c },
                                     onTapPlace: { name, c, _ in pin = c; place = name })
                            .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 12))
                        Button {
                            Task {
                                // "Near me": this device's position once, for this screen only (never shared)
                                if let l = await PulseSharer.shared.readOnce() { pin = l.coordinate; camera = PulseCamera(mode: .place, nonce: camera.nonce + 1) }
                            }
                        } label: {
                            Label("pulse.create.nearme", systemImage: "location").font(.caption.weight(.bold)).padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(8)
                    }
                    .listRowInsets(EdgeInsets())
                    Text("pulse.create.pinhint").font(.caption).foregroundStyle(Theme.faint)
                }
                Section {
                    Picker("pulse.create.when", selection: $when) {
                        Text("pulse.when.now").tag(0)
                        Text("pulse.when.30").tag(30)
                        Text("pulse.when.60").tag(60)
                        Text("pulse.when.pick").tag(-1)
                    }
                    if when == -1 { DatePicker("pulse.when.at", selection: $at, in: Date()...) }
                    VStack(alignment: .leading) {
                        Text(verbatim: String(format: NSLocalizedString("pulse.create.ends", comment: ""), Int(hours)))
                        Slider(value: $hours, in: 1...24, step: 1)
                    }
                }
                Section {
                    ForEach(friends) { f in
                        let on = chosen.contains(f.peer_id)
                        Button { if on { chosen.remove(f.peer_id) } else { chosen.insert(f.peer_id) } } label: {
                            HStack {
                                Avatar(token: token, userID: f.peer_id, avatarID: f.peer_avatar_id, title: f.peer_display_name ?? f.peer_username, size: 34)
                                Text(verbatim: f.peer_display_name ?? f.peer_username).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Theme.accent : Theme.faint)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("pulse.create.invite") }
                Section {
                    Toggle("pulse.create.majority", isOn: $majority)
                }
                if let error { Text(verbatim: error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle(Text(LocalizedStringKey(instant ? "pulse.card.instant" : "pulse.card.create")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("notes.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(instant ? "pulse.create.instant.go" : "pulse.create.go")) { Task { await create() } }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || (!instant && chosen.isEmpty))
                }
            }
        }
        .task {
            if title.isEmpty { title = suggested(activity) }
            friends = ((try? await APIClient.shared.conversations(token: token)) ?? []).filter { !$0.peer_id.isEmpty && !$0.conversation_id.hasPrefix("grp_") }
        }
    }

    private var suggestedPrefix: String { NSLocalizedString("pulse.act." + activity, comment: "") }

    private func suggested(_ a: String) -> String {
        let act = NSLocalizedString("pulse.act." + a, comment: "")
        let p = place.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? act : String(format: NSLocalizedString("pulse.create.suggest", comment: ""), act, p)
    }

    private func create() async {
        busy = true
        defer { busy = false }
        let starts: Int64 = when == 0 ? 0 : (when > 0 ? PulseRules.nowMs() + Int64(when) * 60_000 : Int64(at.timeIntervalSince1970 * 1000))
        var body: [String: Any] = ["title": String(title.prefix(80)), "activity": activity, "dest_name": String(place.prefix(80)),
                                   "starts_at": starts, "duration_min": Int(hours) * 60, "invite": Array(chosen),
                                   "policy": majority ? "majority" : "organizer", "party": UserDefaults.standard.bool(forKey: "tf.pulse.party"),
                                   "instant": instant]
        if let pin { body["dest_lat"] = pin.latitude; body["dest_lon"] = pin.longitude }
        do {
            let c = try await APIClient.shared.pulseCreate(token: token, body: body)
            await pulse.reload()
            onCreated(c)
        } catch let e as PulseHTTPError {
            error = e.status == 403 ? NSLocalizedString("pulse.err.blocked", comment: "")
                : e.status == 409 ? NSLocalizedString("pulse.err.limit", comment: "") : NSLocalizedString("pulse.err.other", comment: "")
        } catch {
            self.error = NSLocalizedString("pulse.err.other", comment: "")
        }
    }
}

/// The MEETUP pill next to the wordmark (web 36558896): fully rounded, filled with the cyan gradient, an inner top highlight,
/// a soft glow and a thin light ring; a pin and "MEETUP" in Montserrat 800, dark; a white shine every 5.5 s.
struct MeetupBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.5)
            let sweep = min(1, t / 0.9)
            HStack(spacing: 5) {
                Image(systemName: "mappin").font(.system(size: 15, weight: .bold))
                Text(verbatim: "MEETUP").font(PulseFont.brand(12.5)).tracking(3)
            }
            .foregroundStyle(Theme.hex(0x00242B))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(LinearGradient(colors: [Theme.hex(0x8FFBFF), Theme.hex(0x2EE6F0), Theme.hex(0x0FB8D6), Theme.hex(0x0A9FE0)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay(Capsule().stroke(LinearGradient(colors: [Color.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center), lineWidth: 1).padding(1))
            .overlay {
                if !reduceMotion && sweep < 1 {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 36)
                            .offset(x: -36 + (g.size.width + 36) * sweep)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .overlay(Capsule().stroke(Color(red: 127 / 255, green: 250 / 255, blue: 1, opacity: 0.35), lineWidth: 1))
            .shadow(color: Theme.hex(0x2EE6F0, 0.5), radius: 10)
        }
        .fixedSize()
        .accessibilityLabel(Text(verbatim: "Meetup"))
    }
}

/// A drawn icon, white, in a gradient chip (its colour -> 55 % over #03202a) with an inner top highlight and a coloured glow
/// (web PulseIcons.tsx). Emoji stay only on the map markers.
struct PulseIconChip: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        return Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ZStack {
                Theme.hex(0x03202A)
                LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }, in: shape)
            .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: color.opacity(0.5), radius: 8)
            .accessibilityHidden(true)
    }
}

/// The Meetup home's type: Montserrat 800 for the wordmark, Red Hat Display (700-800) for headings, Red Hat Text (500) for
/// text. The fonts are latin only: Arabic falls back to the system font by itself.
enum PulseFont {
    static func brand(_ size: CGFloat) -> Font {
        UIFont(name: "MontserratThin-ExtraBold", size: size) != nil ? .custom("MontserratThin-ExtraBold", size: size) : .system(size: size, weight: .heavy)
    }
    static func display(_ size: CGFloat, _ weight: CGFloat = 800) -> Font { variable("RedHatDisplay-Regular", size, weight, .heavy) }
    static func text(_ size: CGFloat, _ weight: CGFloat = 500) -> Font { variable("RedHatText-Regular", size, weight, .medium) }

    private static func variable(_ name: String, _ size: CGFloat, _ wght: CGFloat, _ fallback: Font.Weight) -> Font {
        guard UIFont(name: name, size: size) != nil else { return .system(size: size, weight: fallback) }
        let wghtTag = 0x7767_6874 // 'wght'
        let d = UIFontDescriptor(fontAttributes: [.name: name, UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtTag: wght]])
        return Font(UIFont(descriptor: d, size: size) as CTFont)
    }
}
