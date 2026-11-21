import SwiftUI
import CoreLocation
import AVFoundation

/// The meetup screen (PULSE_PRODUCT_SPEC.md "The meetup screen"): a top bar with the countdown and the Safety center, the map,
/// a one-line panel (Participants / Activity), the bubble field, My Status / Walkie-Talkie / Find Friend / More, and Stop
/// Sharing always visible while sharing.
struct PulseMeetupScreen: View {
    let token: String
    let me: String
    let circleID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var pulse = PulseStore.shared
    @ObservedObject private var sharer = PulseSharer.shared

    @State private var view: PulseView?
    @State private var invitation: PulseInvitation?
    @State private var people: [String: PulsePerson] = [:]
    @State private var locations: [String: PulseLocation] = [:]
    @State private var previous: [String: PulseLocation] = [:]
    @State private var firstDistance: [String: Double] = [:]
    @State private var flashBubble: [String: (text: String, until: Date)] = [:]
    @State private var gone: String?
    @State private var loadFailed = false
    @State private var now = Date()
    @State private var serverSkew: Int64 = 0
    @State private var camera = PulseCamera(mode: .everyone)
    @State private var selected: String?
    @State private var panelOpen = false
    @State private var panelTab = 0
    @State private var bubbleText = ""
    @State private var sheet: Sheet?
    @State private var proposing = false
    @State private var proposalAt: CLLocationCoordinate2D?
    @State private var proposalName = ""
    /// the tapped place's badge group (cafe, food, fast, bar, sweet), nil for a spot picked on the map
    @State private var pickGroup: String?
    @State private var tilesFailed = false
    @State private var confirmLeave = false
    @State private var flash: String?
    @StateObject private var walkie = PulseWalkie()

    enum Sheet: String, Identifiable {
        case share, status, find, more, safety, code, invite, capsule
        var id: String { rawValue }
    }

    private var circle: PulseCircle? { view?.circle ?? invitation?.circle }
    private var members: [PulseMember] {
        (view?.members ?? []).filter { !["left", "removed", "declined"].contains($0.response ?? "") }
    }
    private var going: [PulseMember] { members.filter { $0.response == "going" || $0.role == "organizer" } }
    private var isOrganizer: Bool { view?.me?.role == "organizer" }
    private var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) + serverSkew }
    private var sharingHere: Bool { sharer.isSharing(circleID) }
    private var ended: Bool { circle.map { !$0.isOpen } ?? false }

    var body: some View {
        ZStack {
            Theme.hex(0x020C14).ignoresSafeArea()
            if let gone {
                VStack(spacing: 14) {
                    Image(systemName: "mappin.slash").font(.largeTitle).foregroundStyle(Theme.faint)
                    Text(verbatim: gone).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    Button("chat.close") { dismiss() }
                }
                .padding(30)
            } else if let invitation, view == nil {
                invitationCard(invitation)
            } else if view != nil {
                meetup
            } else if loadFailed {
                VStack(spacing: 12) {
                    Text("pulse.err.load").foregroundStyle(Theme.muted)
                    Button("stk.retry") { Task { await load() } }
                    Button("chat.close") { dismiss() }
                }
            } else {
                ProgressView()
            }
        }
        .foregroundStyle(.white)
        .task { await load() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { d in
            now = d
            flashBubble = flashBubble.filter { $0.value.until > d }
        }
        .onReceive(pulse.frames.filter { [circleID] d in (d["circle_id"] as? String) == circleID }) { d in handle(d) }
        .onReceive(LiveConnection.shared.opened.receive(on: RunLoop.main)) { Task { await load() } } // missed frames: reload, never replay
        .sheet(item: $sheet) { s in sheetView(s).tfColorScheme().modifier(PulseSheetLook()) }
        .confirmationDialog(Text(LocalizedStringKey(isOrganizer ? "pulse.end.q" : "pulse.leave.q")), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(LocalizedStringKey(isOrganizer ? "pulse.end" : "pulse.leave"), role: .destructive) { Task { await leaveOrEnd() } }
        }
    }

    // MARK: layout

    private var meetup: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .top) {
                PulseMapView(token: token, styleURL: pulse.config.style_url, people: mapPeople, dest: mapDest, camera: camera, selected: selected,
                             onTapMap: proposing ? { c in proposing = false; proposalName = ""; pickGroup = nil; proposalAt = c } : nil,
                             // a café or restaurant tapped: the place card (nothing is sent until its button)
                             onTapPlace: ended ? nil : { name, c, cls in proposing = false; proposalName = name; pickGroup = PulseMapView.poiGroupKey(cls); proposalAt = c },
                             onSelect: { id in selected = id; panelOpen = true; panelTab = 0 },
                             onUserMoved: { if case .follow = camera.mode { camera.mode = .none } },
                             onTilesFailed: { tilesFailed = $0 })
                    .ignoresSafeArea(edges: .horizontal)
                VStack(spacing: 8) {
                    if tilesFailed { banner("pulse.tiles.failed", Theme.gold) }
                    if proposing { banner("pulse.propose.tap", Theme.accent) }
                    if ended { banner("pulse.ended.banner", Theme.faint) }
                    ForEach(openProposals) { p in proposalCard(p) }
                    if let flash { banner(flash, Theme.accent).onTapGesture { self.flash = nil } }
                }
                .padding(10)
                cameraButtons.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(12)
                if let at = proposalAt {
                    pickCard(at).frame(maxHeight: .infinity, alignment: .bottom).padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            panel
            if !ended { bottomBar }
        }
    }

    private func banner(_ key: String, _ tint: Color) -> some View {
        Text(LocalizedStringKey(key)).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.hex(0x04111E, 0.9), in: Capsule()).overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
    }

    /// A round back button, the title with "🔒 Private · N people" and a LIVE / INVITING / ENDED pill, the timer pill and
    /// a round shield.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.system(size: 16, weight: .bold)).frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel(Text("chat.close"))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: (circle?.icon ?? "📍") + " " + (circle?.title ?? "")).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: String(format: NSLocalizedString("pulse.private.people", comment: ""), going.count))
                        .font(.caption).foregroundStyle(PulseInk.muted)
                    livePill
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 0) {
                Text(LocalizedStringKey(startsLater ? "pulse.timer.starts" : "pulse.timer.ends")).font(.system(size: 8.5, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(PulseInk.muted)
                Text(verbatim: countdownText).font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(PulseInk.ink)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(PulseInk.cyan.opacity(0.25), lineWidth: 1))
            .accessibilityElement(children: .combine)
            Button { sheet = .safety } label: {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel(Text("pulse.safety"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.hex(0x04111E))
    }

    private var livePill: some View {
        let state: (String, Color) = ended ? ("pulse.pill.ended", PulseInk.muted)
            : (startsLater || circle?.state == "inviting") ? ("pulse.pill.inviting", PulseInk.amber) : ("pulse.pill.live", PulseInk.green)
        let blink = Int(now.timeIntervalSince1970) % 2 == 0
        return HStack(spacing: 4) {
            if state.0 == "pulse.pill.live" { Circle().fill(PulseInk.green).frame(width: 6, height: 6).opacity(blink ? 1 : 0.3) }
            Text(LocalizedStringKey(state.0)).font(.system(size: 9.5, weight: .heavy)).tracking(0.6)
        }
        .foregroundStyle(state.1)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(state.1.opacity(0.14), in: Capsule())
    }

    private var startsLater: Bool { (circle?.starts_at ?? 0) > nowMs }
    private var countdownText: String {
        guard let c = circle else { return "" }
        if startsLater { return PulseRules.countdown((c.starts_at ?? 0) - nowMs) }
        return PulseRules.countdown((c.expires_at ?? 0) - nowMs)
    }

    private var cameraButtons: some View {
        VStack(spacing: 8) {
            camButton("person.3", "pulse.cam.everyone") { camera = PulseCamera(mode: .everyone, nonce: camera.nonce + 1) }
            if mapDest != nil { camButton("mappin.and.ellipse", "pulse.cam.place") { camera = PulseCamera(mode: .place, nonce: camera.nonce + 1) } }
            if mapPeople.contains(where: \.isMe) { camButton("location.fill", "pulse.cam.me") { camera = PulseCamera(mode: .me, nonce: camera.nonce + 1) } }
        }
    }

    private func camButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                .background(Theme.hex(0x04111E, 0.85), in: Circle()).overlay(Circle().stroke(Theme.hex(0x2FE6E6, 0.3), lineWidth: 1))
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    // MARK: the summary strip (opens the people and activity panel)

    private var panel: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { panelOpen.toggle() } } label: {
                HStack(spacing: 10) {
                    HStack(spacing: -10) {
                        ForEach(members.prefix(5)) { m in
                            Avatar(token: token, userID: m.user_id, avatarID: people[m.user_id]?.avatar_id, title: name(m.user_id), size: 32)
                                .overlay(Circle().stroke(m.sharing == true ? PulseInk.cyan : Theme.hex(0x061A24), lineWidth: 2))
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: sharingCount == 0 ? NSLocalizedString("pulse.summary.nobody", comment: "")
                             : String(format: NSLocalizedString("pulse.summary.n", comment: ""), sharingCount, going.count))
                            .font(.footnote.weight(.bold)).foregroundStyle(PulseInk.ink)
                        Text(verbatim: String(format: NSLocalizedString("pulse.summary.sub", comment: ""), members.count))
                            .font(.caption2).foregroundStyle(PulseInk.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(panelOpen ? 180 : 0))
                        .frame(width: 30, height: 30).background(Color.white.opacity(0.08), in: Circle())
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if panelOpen {
                HStack(spacing: 4) {
                    tabPill(0, String(format: NSLocalizedString("pulse.tab.people", comment: ""), members.count))
                    tabPill(1, NSLocalizedString("pulse.activity", comment: ""))
                }
                .padding(3).background(Color.white.opacity(0.06), in: Capsule())
                .padding(.horizontal, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if panelTab == 0 { ForEach(members) { m in participantRow(m) } } else { activityList }
                        Text(verbatim: String(format: NSLocalizedString("pulse.private.footer", comment: ""), countdownText))
                            .font(.caption2).foregroundStyle(PulseInk.muted)
                    }
                    .padding(14)
                }
                .frame(maxHeight: 260)
            }
        }
        .background(Theme.hex(0x061A24))
    }

    private func tabPill(_ tab: Int, _ title: String) -> some View {
        let on = panelTab == tab
        return Button { panelTab = tab } label: {
            Text(verbatim: title).font(.system(size: 12.5, weight: .bold)).frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(on ? Theme.hex(0x04222C) : PulseInk.muted)
                .background(on ? AnyShapeStyle(PulseInk.cyan) : AnyShapeStyle(Color.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var sharingCount: Int { members.filter { $0.sharing == true }.count }

    /// A person as a card: the face (cyan + a blinking green dot while sharing, green when arrived, grey when off), 👑 for
    /// the organizer, YOU for me, the line, a progress bar when the distance means something, and a pill on the right.
    private func participantRow(_ m: PulseMember) -> some View {
        let p = people[m.user_id]
        let loc = locations[m.user_id]
        let stale = loc.map { PulseRules.freshness($0.measured_at, now: nowMs) == .stale } ?? false
        let sharing = m.sharing == true && loc != nil
        let ring: Color = m.arrived ? PulseInk.green : (sharing ? PulseInk.cyan : Color.white.opacity(0.2))
        let pct = PulseRules.progress(first: firstDistance[m.user_id], now: loc?.distance_m, arrived: m.arrived)
        let showBar = sharing && !stale && !m.arrived && (firstDistance[m.user_id] ?? 0) >= 150
        let blink = Int(now.timeIntervalSince1970) % 2 == 0
        return Button { if loc != nil { selected = m.user_id; camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1) } } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Avatar(token: token, userID: m.user_id, avatarID: p?.avatar_id, title: p?.name ?? "", size: 40)
                        .saturation(sharing || m.arrived ? 1 : 0)
                        .overlay(Circle().stroke(ring, lineWidth: 2.5))
                    if sharing && !m.arrived {
                        Circle().fill(PulseInk.green).frame(width: 9, height: 9).opacity(blink ? 1 : 0.35)
                            .overlay(Circle().stroke(Theme.hex(0x061A24), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(verbatim: p?.name ?? name(m.user_id)).font(.subheadline.weight(.semibold)).foregroundStyle(PulseInk.ink).lineLimit(1)
                        if m.role == "organizer" { Text(verbatim: "👑").font(.caption) }
                        if m.user_id == me {
                            Text("pulse.you").font(.system(size: 9, weight: .heavy)).foregroundStyle(PulseInk.cyan)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(PulseInk.cyan.opacity(0.16), in: Capsule())
                        }
                    }
                    Text(verbatim: m.status?.text.map { (m.status?.emoji.map { $0 + " " } ?? "") + $0 } ?? personLine(m, loc))
                        .font(.caption).foregroundStyle(PulseInk.muted).lineLimit(1)
                    if showBar { ProgressView(value: Double(pct), total: 100).tint(PulseInk.cyan) }
                }
                Spacer(minLength: 4)
                personPill(m, loc, stale: stale)
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isOrganizer && m.user_id != me {
                Button(role: .destructive) { Task { _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "remove", body: ["user_id": m.user_id]); await load() } } label: {
                    Label("pulse.remove", systemImage: "person.badge.minus")
                }
            }
        }
    }

    private func personPill(_ m: PulseMember, _ loc: PulseLocation?, stale: Bool) -> some View {
        let (text, color): (String, Color) = {
            if m.arrived { return (NSLocalizedString("pulse.pill.here", comment: ""), PulseInk.green) }
            guard let loc else { return (NSLocalizedString("pulse.pill.off", comment: ""), PulseInk.muted) }
            if stale { return (PulseRules.agoText(loc.measured_at, now: nowMs), PulseInk.muted) }
            if loc.approximate { return (String(format: NSLocalizedString("pulse.pill.approx", comment: ""), PulseRules.distanceText(loc.accuracy ?? 0)), PulseInk.amber) }
            if let e = PulseRules.eta(distance: loc.distance_m, speed: loc.speed, arrived: false) { return (e, PulseInk.cyan) }
            return (loc.distance_m.map(PulseRules.distanceText) ?? NSLocalizedString("pulse.pill.live", comment: ""), PulseInk.cyan)
        }()
        return Text(verbatim: text).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var activityList: some View {
        let bubbles = (view?.bubbles ?? []).sorted { ($0.created_at ?? 0) > ($1.created_at ?? 0) }
        ForEach(view?.voice ?? []) { v in
            HStack {
                Text(verbatim: "🎙️ " + pulse.name(v.user_id ?? "")).font(.caption.weight(.semibold))
                Spacer()
                Button { walkie.play(token: token, id: v.id) } label: {
                    Image(systemName: walkie.playing == v.id ? "stop.fill" : "play.fill").frame(width: 44, height: 36)
                }
                .accessibilityLabel(Text("pulse.voice.play"))
            }
        }
        ForEach(bubbles) { b in
            HStack(alignment: .top) {
                Text(verbatim: name(b.user_id ?? "") + ":").font(.caption.weight(.bold))
                Text(verbatim: b.text ?? "").font(.caption)
            }
        }
        ForEach(Array((view?.activity ?? []).enumerated()), id: \.offset) { _, a in
            Text(verbatim: activityLine(a)).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func activityLine(_ a: PulseActivityItem) -> String {
        let who = name(a.user_id ?? "")
        let key = "pulse.act.log." + (a.kind ?? "")
        let t = NSLocalizedString(key, comment: "")
        return t == key ? who + " · " + (a.text ?? a.kind ?? "") : String(format: t, who)
    }

    // MARK: the bottom

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField(NSLocalizedString(selected.map { _ in "pulse.bubble.reply" } ?? "pulse.bubble", comment: ""), text: $bubbleText)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendBubble() } }
                    .padding(.leading, 14)
                let empty = bubbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { Task { await sendBubble() } } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(empty ? PulseInk.muted : Theme.hex(0x04222C))
                        .frame(width: 36, height: 36)
                        .background(empty ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(PulseInk.gradient), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .accessibilityLabel(Text("pulse.bubble.send"))
            }
            .padding(3)
            .background(Theme.hex(0x0B2833), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            // one dock row: My Status, Find Friend, the raised walkie-talkie, More, and Share / Stop sharing (always visible)
            HStack(alignment: .bottom, spacing: 0) {
                tool("face.smiling", "pulse.mystatus") { sheet = .status }
                tool("location.viewfinder", "pulse.findfriend") { sheet = .find }
                PulseWalkieButton(walkie: walkie, token: token, circleID: circleID) { flash = $0 }
                    .frame(maxWidth: .infinity)
                tool("ellipsis", "pulse.more") { sheet = .more }
                PulseShareTile(sharing: sharingHere) {
                    if sharingHere { Task { await sharer.stop(circleID); await load() } } else { sheet = .share }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(Theme.hex(0x04111E))
    }

    /// A dock tile: a 47 pt rounded square (radius 16) with a line icon, its name under it.
    private func tool(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                    .frame(width: 47, height: 47)
                    .background(Theme.hex(0x0B2833), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hex(0x2FE6E6, 0.18), lineWidth: 1))
                Text(LocalizedStringKey(label)).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: the map's people

    private var mapDest: PulseMapDest? {
        guard let c = circle, let d = c.dest else { return nil }
        return PulseMapDest(coordinate: d, name: c.dest_name ?? "", icon: c.icon)
    }

    private var mapPeople: [PulseMapPerson] {
        var out: [PulseMapPerson] = []
        for (id, loc) in locations {
            guard let m = members.first(where: { $0.user_id == id }) else { continue }
            let p = people[id]
            let fresh = PulseRules.freshness(loc.measured_at, now: nowMs)
            let ring: PulseMapPerson.Ring = m.arrived ? .arrived : (fresh == .live ? .live : fresh == .lagging ? .lagging : .stale)
            var status = m.status?.text.map { (m.status?.emoji.map { $0 + " " } ?? "") + $0 }
            if let b = flashBubble[id] { status = "💬 " + b.text }
            out.append(PulseMapPerson(id: id, name: p?.name ?? "", avatarID: p?.avatar_id, coordinate: loc.coordinate,
                                      accuracy: loc.accuracy ?? 0, approximate: loc.approximate, ring: ring, line: personLine(m, loc),
                                      status: status, statusAt: flashBubble[id] != nil ? nowMs : m.status?.at, isMe: id == me,
                                      moving: (loc.speed ?? 0) > 0.6 || (loc.distance_m ?? 0) > 150, measuredAt: loc.measured_at,
                                      glide: PulseRules.glideMs(prev: previous[id], next: loc, reduceMotion: reduceMotion) / 1000))
        }
        return out
    }

    private func personLine(_ m: PulseMember, _ loc: PulseLocation?) -> String {
        if m.arrived { return NSLocalizedString(m.arrived_kind == "manual" ? "pulse.imhere.said" : "pulse.arrived", comment: "") }
        guard let loc else { return NSLocalizedString("pulse.notsharing", comment: "") }
        if PulseRules.freshness(loc.measured_at, now: nowMs) == .stale {
            return String(format: NSLocalizedString("pulse.lastupdated", comment: ""), PulseRules.agoText(loc.measured_at, now: nowMs))
        }
        var parts: [String] = []
        if let e = PulseRules.eta(distance: loc.distance_m, speed: loc.speed, arrived: false) { parts.append(e) }
        if let d = loc.distance_m { parts.append(PulseRules.distanceText(d)) }
        var s = parts.joined(separator: " · ")
        if loc.approximate { s += " " + NSLocalizedString("pulse.approx", comment: "") }
        return s
    }

    private func name(_ id: String) -> String {
        if id == me { return NSLocalizedString("chat.you", comment: "") }
        return people[id]?.name ?? pulse.name(id)
    }

    // MARK: proposals

    private var openProposals: [PulseProposal] { (view?.proposals ?? []).filter { ($0.state ?? "open") == "open" } }

    private func proposalCard(_ p: PulseProposal) -> some View {
        let km = (circle?.dest).flatMap { d in p.lat.flatMap { lat in p.lon.map { PulseRules.distanceM(d.latitude, d.longitude, lat, $0) } } }
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "📍 " + String(format: NSLocalizedString("pulse.proposal.line", comment: ""), p.name ?? "", name(p.user_id ?? "")))
                .font(.footnote.weight(.semibold))
            if let km { Text(verbatim: String(format: NSLocalizedString("pulse.proposal.from", comment: ""), PulseRules.distanceText(km))).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
            HStack {
                if p.user_id == me {
                    Button("pulse.proposal.withdraw") { Task { try? await APIClient.shared.pulseDelete(token: token, path: "pulse/circles/\(APIClient.pSeg(circleID))/proposals/\(APIClient.pSeg(p.id))"); await load() } }
                } else {
                    Button("pulse.proposal.accept") { Task { await vote(p, true) } }
                    Button("pulse.proposal.another") { proposing = true }
                    Button("pulse.proposal.reject") { Task { await vote(p, false) } }
                }
            }
            .font(.footnote.weight(.bold)).buttonStyle(.borderless)
        }
        .padding(12).background(Theme.hex(0x04111E, 0.92), in: RoundedRectangle(cornerRadius: 12))
    }

    private func vote(_ p: PulseProposal, _ accept: Bool) async {
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "proposals/\(APIClient.pSeg(p.id))/vote", body: ["accept": accept])
        await load()
    }

    private func propose() async {
        guard let at = proposalAt else { return }
        let n = proposalName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        proposalAt = nil
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "proposals", body: ["name": String(n.prefix(80)), "lat": at.latitude, "lon": at.longitude])
        await load()
    }

    /// The place card: the badge in its colour, the type, the editable name, the distance from the current place, and one
    /// button: "Make this the meeting place" for the organizer under the organizer policy (applied at once), otherwise
    /// "Suggest this place". Nothing is sent before the button.
    private func pickCard(_ at: CLLocationCoordinate2D) -> some View {
        let g = PulseMapView.poiGroups.first { $0.key == pickGroup }
        let tint = g.map { PulseMapView.color($0.ring) } ?? PulseInk.cyan
        let km = (circle?.dest).map { PulseRules.distanceM($0.latitude, $0.longitude, at.latitude, at.longitude) }
        let decides = isOrganizer && circle?.policy != "majority"
        let empty = proposalName.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: g?.emoji ?? "📍").font(.system(size: 24)).frame(width: 52, height: 52)
                    .background(Theme.hex(0x071A24), in: Circle())
                    .overlay(Circle().stroke(tint, lineWidth: 3))
                    .shadow(color: tint.opacity(0.6), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("pulse.poi." + (g?.key ?? "pin"))).font(.system(size: 11, weight: .heavy)).tracking(0.9).foregroundStyle(tint)
                    TextField(NSLocalizedString("pulse.create.place", comment: ""), text: $proposalName)
                        .font(.system(size: 19, weight: .bold)).foregroundStyle(PulseInk.ink)
                    if let km, circle?.hasDest == true {
                        Text(verbatim: String(format: NSLocalizedString("pulse.proposal.from", comment: ""), PulseRules.distanceText(km)))
                            .font(.caption).foregroundStyle(PulseInk.muted)
                    }
                }
                Spacer(minLength: 0)
                Button { withAnimation { proposalAt = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("chat.close"))
            }
            Button { Task { await propose() } } label: {
                Text(LocalizedStringKey(decides ? "pulse.pick.make" : "pulse.pick.suggest")).font(.body.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(PulseInk.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(Theme.hex(0x04222C))
                    .opacity(empty ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(empty)
            Text(LocalizedStringKey(decides ? "pulse.pick.note.org" : "pulse.pick.note")).font(.caption2).foregroundStyle(PulseInk.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [tint.opacity(0.22), Theme.hex(0x061A24, 0.97)], startPoint: .topLeading, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
    }

    // MARK: sheets

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .share:
            if let c = circle {
                PulseShareSheet(circle: c, others: max(0, going.count - 1), faces: going.map(\.user_id).filter { $0 != me }, people: people,
                                token: token, me: me) { ok in sheet = nil; if ok { Task { await load() } } }
                    .presentationDetents([.large])
            }
        case .status: statusSheet.presentationDetents([.medium])
        case .find: findSheet.presentationDetents([.medium, .large])
        case .more: moreSheet.presentationDetents([.medium])
        case .safety:
            PulseSafetyCenter(token: token, me: me, circleID: circleID, members: members.filter { $0.user_id != me }, people: people,
                              sharingHere: sharingHere, onLeave: { sheet = nil; confirmLeave = true })
        case .code: PulseInstantCodeSheet(token: token, circleID: circleID, people: people)
        case .invite: PulseInviteMore(token: token, circleID: circleID, already: Set(members.map(\.user_id)))
        case .capsule: PulseCapsuleView(token: token, me: me, circleID: circleID, title: circle?.title ?? "")
        }
    }

    private var statusSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("pulse.mystatus").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(PulseRules.quickStatuses, id: \.text) { q in
                    Button { Task { await setStatus(NSLocalizedString("pulse.qs." + q.text, comment: ""), q.emoji) } } label: {
                        Text(verbatim: q.emoji + " " + NSLocalizedString("pulse.qs." + q.text, comment: "")).font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(NSLocalizedString("pulse.status.own", comment: ""), text: $bubbleText).textFieldStyle(.roundedBorder)
                Button("pulse.status.set") { Task { await setStatus(String(bubbleText.prefix(40)), nil); bubbleText = "" } }
            }
            HStack {
                // "I'm here" works without location (said, not measured)
                Button { Task { _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "here", body: ["here": !(view?.me?.arrived ?? false)]); sheet = nil; await load() } } label: {
                    Label(LocalizedStringKey(view?.me?.arrived == true ? "pulse.imhere.undo" : "pulse.imhere"), systemImage: "cup.and.saucer.fill")
                }
                Spacer()
                Button("pulse.status.clear") { Task { await setStatus("", nil) } }
            }
            .font(.callout.weight(.semibold))
        }
        .padding(20)
    }

    private func setStatus(_ text: String, _ emoji: String?) async {
        var body: [String: Any] = ["text": text]
        if let emoji { body["emoji"] = emoji }
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "status", body: body)
        sheet = nil
        await load()
    }

    private var findSheet: some View {
        NavigationStack {
            List {
                let sharing = members.filter { $0.user_id != me && locations[$0.user_id] != nil }
                if sharing.isEmpty { Text("pulse.find.nobody").foregroundStyle(Theme.muted) }
                ForEach(sharing) { m in
                    let loc = locations[m.user_id]!
                    let stale = PulseRules.freshness(loc.measured_at, now: nowMs) == .stale
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            selected = m.user_id
                            camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1)
                            sheet = nil
                        } label: {
                            HStack {
                                Avatar(token: token, userID: m.user_id, avatarID: people[m.user_id]?.avatar_id, title: name(m.user_id), size: 36)
                                Text(verbatim: name(m.user_id)).font(.headline)
                            }
                        }
                        Text(verbatim: String(format: NSLocalizedString("pulse.find.age", comment: ""), PulseRules.agoText(loc.measured_at, now: nowMs), Int(loc.accuracy ?? 0)))
                            .font(.caption).foregroundStyle(Theme.muted)
                        if stale { Text("pulse.find.stale").font(.caption).foregroundStyle(Theme.gold) }
                        if let mine = sharer.lastFix, sharingHere {
                            Text(verbatim: String(format: NSLocalizedString("pulse.find.fromyou", comment: ""),
                                                  PulseRules.distanceText(PulseRules.distanceM(mine.coordinate.latitude, mine.coordinate.longitude, loc.lat, loc.lon))))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Text("pulse.find.indoors").font(.caption2).foregroundStyle(Theme.faint)
                        HStack {
                            Button("pulse.find.directions") {
                                if let u = URL(string: "http://maps.apple.com/?daddr=\(loc.lat),\(loc.lon)") { UIApplication.shared.open(u) }
                            }
                            Spacer()
                            if let mine = sharer.lastFix, sharingHere {
                                Button("pulse.find.halfway") {
                                    Task {
                                        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "proposals",
                                                                                 body: ["name": NSLocalizedString("pulse.halfway", comment: ""),
                                                                                        "lat": (mine.coordinate.latitude + loc.lat) / 2, "lon": (mine.coordinate.longitude + loc.lon) / 2])
                                        sheet = nil
                                        await load()
                                    }
                                }
                            }
                        }
                        .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(Text("pulse.findfriend"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var moreSheet: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("pulse.more").font(.headline).foregroundStyle(PulseInk.ink).frame(maxWidth: .infinity, alignment: .leading)
                choice("mappin.and.ellipse", "pulse.more.propose") { sheet = nil; proposing = true }
                if isOrganizer {
                    choice("qrcode", "pulse.more.code") { sheet = .code }
                    choice("person.badge.plus", "pulse.more.invite") { sheet = .invite }
                }
                choice("photo.stack", "pulse.card.capsule") { sheet = .capsule }
                choice("shield.lefthalf.filled", "pulse.safety") { sheet = .safety }
                choice(isOrganizer ? "stop.circle" : "rectangle.portrait.and.arrow.right", isOrganizer ? "pulse.end" : "pulse.leave", danger: true) {
                    sheet = nil
                    confirmLeave = true
                }
            }
            .padding(20)
        }
    }

    /// A choice row: a card with its icon chip and a › chevron.
    private func choice(_ icon: String, _ key: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36)
                    .background((danger ? PulseInk.red : PulseInk.cyan).opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(danger ? PulseInk.red : PulseInk.cyan)
                Text(LocalizedStringKey(key)).font(.callout.weight(.semibold)).foregroundStyle(danger ? PulseInk.red : PulseInk.ink)
                Spacer()
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .bold)).foregroundStyle(PulseInk.muted)
            }
            .padding(12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: the invitation (opened before answering)

    private func invitationCard(_ inv: PulseInvitation) -> some View {
        VStack(spacing: 16) {
            Text(verbatim: inv.circle.icon).font(.system(size: 54))
            Text(verbatim: inv.circle.title ?? "").font(.title2.weight(.bold))
            Text(verbatim: String(format: NSLocalizedString("pulse.invited.by", comment: ""), name(inv.invited_by ?? ""))).foregroundStyle(.white.opacity(0.7))
            if let d = inv.circle.dest_name, !d.isEmpty { Label(d, systemImage: "mappin") }
            Button { Task { await respond("going"); sheet = .share } } label: { wide("pulse.join.share", primary: true) }
            Button { Task { await respond("going") } } label: { wide("pulse.join.noshare") }
            HStack {
                Button { Task { await respond("maybe") } } label: { wide("pulse.maybe") }
                Button { Task { await respond("declined"); dismiss() } } label: { wide("pulse.decline") }
            }
            Button("chat.close") { dismiss() }
        }
        .buttonStyle(.plain)
        .padding(24)
    }

    private func wide(_ key: String, primary: Bool = false) -> some View {
        Text(LocalizedStringKey(key)).font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 48)
            .background(primary ? Theme.accent : Theme.hex(0x0B2833), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(primary ? Theme.onAccent : .white)
    }

    /// Answering never shares a location.
    private func respond(_ r: String) async {
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "respond", body: ["response": r])
        await load()
        await pulse.reload()
    }

    // MARK: data

    private func load() async {
        do {
            let d = try await APIClient.shared.pulseCircle(token: token, id: circleID)
            people.merge(d.people ?? [:]) { _, n in n }
            pulse.noteName(d.people ?? [:])
            invitation = d.invitation
            if let v = d.view {
                if let n = v.now { serverSkew = n - PulseRules.nowMs() }
                view = v
                var fresh: [String: PulseLocation] = [:]
                for l in v.locations ?? [] { fresh[l.user_id] = l }
                for (id, l) in fresh {
                    if let old = locations[id], old.measured_at > l.measured_at { fresh[id] = old }
                    if firstDistance[id] == nil, let dd = l.distance_m { firstDistance[id] = dd }
                }
                previous = locations
                locations = fresh
                PulseSharer.shared.setDestination(circleID, v.circle.dest)
                if !v.circle.isOpen { PulseSharer.shared.stopLocally(circleID) }
            }
            loadFailed = false
        } catch let e as PulseHTTPError where e.status == 404 {
            PulseSharer.shared.stopLocally(circleID)
            gone = NSLocalizedString("pulse.gone", comment: "")
        } catch {
            if view == nil { loadFailed = true }
        }
    }

    private func handle(_ d: [String: Any]) {
        guard let e = d["e"] as? String else { return }
        switch e {
        case "location":
            guard let raw = d["loc"], let data = try? JSONSerialization.data(withJSONObject: raw),
                  let loc = try? JSONDecoder().decode(PulseLocation.self, from: data) else { return }
            if let old = locations[loc.user_id], old.measured_at >= loc.measured_at { return } // never older than what is shown
            previous[loc.user_id] = locations[loc.user_id]
            locations[loc.user_id] = loc
            if firstDistance[loc.user_id] == nil, let dd = loc.distance_m { firstDistance[loc.user_id] = dd }
            if let i = view?.members?.firstIndex(where: { $0.user_id == loc.user_id }) { view?.members?[i].sharing = true }
        case "sharing":
            if let u = d["user_id"] as? String, (d["sharing"] as? Bool) == false {
                locations[u] = nil
                if let i = view?.members?.firstIndex(where: { $0.user_id == u }) { view?.members?[i].sharing = false }
            } else {
                Task { await load() }
            }
        case "bubble":
            if let b = d["bubble"] as? [String: Any], let u = b["user_id"] as? String, let t = b["text"] as? String {
                flashBubble[u] = (t, Date().addingTimeInterval(6))
            }
            Task { await load() }
        case "arrived":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if (d["all"] as? Bool) == true { flash = NSLocalizedString("pulse.all.here", comment: "") }
            Task { await load() }
        case "removed":
            PulseSharer.shared.stopLocally(circleID)
            gone = NSLocalizedString("pulse.removed", comment: "")
        case "ended":
            PulseSharer.shared.stopLocally(circleID)
            Task { await load() }
        case "voice", "status", "circle", "alert-seen":
            Task { await load() }
        default: break
        }
    }

    private func sendBubble() async {
        let t = bubbleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        bubbleText = ""
        var body: [String: Any] = ["text": String(t.prefix(80))]
        if let s = selected, s != me { body["reply_to"] = s }
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "bubble", body: body)
        flashBubble[me] = (t, Date().addingTimeInterval(6))
    }

    private func leaveOrEnd() async {
        PulseSharer.shared.stopLocally(circleID)
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, isOrganizer ? "end" : "leave")
        await pulse.reload()
        dismiss()
    }
}

// MARK: walkie-talkie

/// Hold to talk (AAC in an .m4a, at most 30 s); the microphone is asked for on the first press only and never left on.
/// Clips play on tap, never by themselves.
@MainActor
final class PulseWalkie: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published var recording = false
    @Published var playing: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var started = Date()
    private var limit: Task<Void, Never>?
    private var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tf-pulse-walkie.m4a") }

    func begin() async -> Bool {
        guard !CallManager.shared.lineInUse else { return false } // never during a call
        let ok: Bool = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        guard ok else { return false }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1,
                                       AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder = r
        r.record(forDuration: 30)
        started = Date()
        recording = true
        return true
    }

    /// The clip, or nil when it was too short.
    func end() -> (Data, Int)? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let ms = min(30_000, Int(Date().timeIntervalSince(started) * 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        guard ms >= 500, let d = try? Data(contentsOf: url) else { return nil }
        return (d, ms)
    }

    func play(token: String, id: String) {
        if playing == id { player?.stop(); playing = nil; return }
        Task {
            guard let d = try? await APIClient.shared.pulseCall("pulse/voice/\(APIClient.pSeg(id))", token: token) else { return }
            guard !CallManager.shared.lineInUse else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(data: d)
            player?.delegate = self
            player?.play()
            playing = id
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

/// Share (a filled turquoise tile) or Stop sharing (a red tile with a pulsing ring).
struct PulseShareTile: View {
    let sharing: Bool
    let action: () -> Void
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: sharing ? "location.slash.fill" : "location.fill").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(sharing ? .white : Theme.onAccent)
                    .frame(width: 47, height: 47)
                    .background(sharing ? Theme.danger : Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        if sharing {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.danger.opacity(pulse ? 0 : 0.7), lineWidth: 3)
                                .padding(-4).scaleEffect(pulse ? 1.18 : 1)
                        }
                    }
                Text(LocalizedStringKey(sharing ? "pulse.stopsharing" : "pulse.share.short")).font(.system(size: 10, weight: .bold)).lineLimit(1)
                    .minimumScaleFactor(0.7).foregroundStyle(sharing ? Theme.danger : Theme.hex(0x3CF0EE))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(sharing ? "pulse.stopsharing" : "pulse.sharemine")))
        .onAppear { startPulse() }
        .onChange(of: sharing) { _ in startPulse() }
    }

    private func startPulse() {
        pulse = false
        guard sharing, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
    }
}

struct PulseWalkieButton: View {
    @ObservedObject var walkie: PulseWalkie
    let token: String
    let circleID: String
    let onNote: (String) -> Void
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: walkie.recording ? "waveform" : "mic.fill").font(.system(size: 24, weight: .bold))
                .foregroundStyle(walkie.recording ? .white : Theme.onAccent)
                .frame(width: 62, height: 62)
                .background(walkie.recording ? Theme.danger : Theme.accent, in: Circle())
                .overlay(Circle().stroke(Theme.hex(0x04111E), lineWidth: 4))
                .shadow(color: Theme.hex(0x3CF0EE, 0.45), radius: 12, y: 2)
                .offset(y: -10)
                .padding(.bottom, -10)
            Text(LocalizedStringKey(walkie.recording ? "pulse.walkie.release" : "pulse.walkie.hold")).font(.system(size: 10, weight: .bold)).lineLimit(1)
                .minimumScaleFactor(0.7).foregroundStyle(Theme.hex(0x3CF0EE))
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressing else { return }
                pressing = true
                Task { if !(await walkie.begin()) { onNote(NSLocalizedString("pulse.walkie.nomic", comment: "")) } }
            }
            .onEnded { _ in
                pressing = false
                guard let clip = walkie.end() else { return }
                let data = clip.0, ms = clip.1
                Task {
                    do {
                        _ = try await APIClient.shared.pulseUpload(token: token, path: "pulse/circles/\(APIClient.pSeg(circleID))/voice",
                                                                   fields: ["duration_ms": String(ms)], fileField: "audio", fileName: "walkie.m4a",
                                                                   mime: "audio/mp4", data: data)
                    } catch {
                        onNote(NSLocalizedString("pulse.walkie.failed", comment: ""))
                    }
                }
            })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("pulse.walkie"))
        .accessibilityHint(Text("pulse.walkie.hint"))
    }
}

/// The Pulse Night palette (web 100-pulse.css).
enum PulseInk {
    static let cyan = Color(red: 0, green: 0xD4 / 255.0, blue: 0xDF / 255.0)
    static let ink = Color(red: 0xE8 / 255.0, green: 0xF7 / 255.0, blue: 0xFB / 255.0)
    static let muted = Color(red: 0x8F / 255.0, green: 0xB3 / 255.0, blue: 0xBF / 255.0)
    static let green = Color(red: 0x59 / 255.0, green: 0xF0 / 255.0, blue: 0xA0 / 255.0)
    static let amber = Color(red: 0xF2 / 255.0, green: 0xB1 / 255.0, blue: 0x55 / 255.0)
    static let red = Color(red: 1, green: 0x5A / 255.0, blue: 0x6A / 255.0)
    static let gradient = LinearGradient(colors: [Color(red: 0.24, green: 0.94, blue: 0.93), cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Pulse sheets on phones: from the bottom, 26 pt top corners, a grab handle, a warmer gradient.
struct PulseSheetLook: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
                .presentationBackground(LinearGradient(colors: [Theme.hex(0x0B2A35), Theme.hex(0x061722)], startPoint: .top, endPoint: .bottom))
        } else {
            content.presentationDragIndicator(.visible)
        }
    }
}
