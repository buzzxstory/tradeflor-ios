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
    @ObservedObject private var sos = SOSCenter.shared

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
    @State private var sosCountdown = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }

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
            PulseInk.ground.ignoresSafeArea() // the app's teal-black (the sidebar's), never pure black
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
        // a frame for this meetup (an alert carries its meetup inside it)
        .onReceive(pulse.frames.filter { [circleID] d in
            (d["circle_id"] as? String) == circleID || ((d["alert"] as? [String: Any])?["circle_id"] as? String) == circleID
        }) { d in handle(d) }
        .fullScreenCover(isPresented: $sosCountdown) {
            PulseSOSCountdown(others: members.filter { $0.user_id != me }.count) { reason, key, attach in
                sosCountdown = false
                Task { await sendSOS(reason, key: key, attach: attach) }
            } onCancel: { sosCountdown = false }
        }
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
                             onTilesFailed: { tilesFailed = $0 },
                             beacons: sosBeacons)
                    .ignoresSafeArea(edges: .horizontal)
                VStack(spacing: 8) {
                    if tilesFailed { banner("pulse.tiles.failed", Theme.gold) }
                    if proposing { banner("pulse.propose.tap", Theme.accent) }
                    if ended { banner("pulse.ended.banner", Theme.faint) }
                    if sharer.stopPending.contains(circleID) { banner("pulse.stop.pending", Theme.gold).accessibilityAddTraits(.updatesFrequently) }
                    ForEach(activeSOS) { s in sosBanner(s) }
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

    /// The header: a round back button, the activity in a 46 pt badge with a story-style ring (cyan → light cyan → amber →
    /// coral, slowly turning; amber while inviting, grey when ended) and a live dot, the title, "Live · N people", the time
    /// pill with its ring (what is left of the meetup) and the round glass shield.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.system(size: 16, weight: .bold)).frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel(Text("chat.close"))
            activityBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: circle?.title ?? "").font(.system(size: 17.5, weight: .heavy)).foregroundStyle(PulseInk.ink).lineLimit(1)
                HStack(spacing: 5) {
                    if wide {
                        HStack(spacing: -6) {
                            ForEach(members.prefix(3)) { m in
                                Avatar(token: token, userID: m.user_id, avatarID: people[m.user_id]?.avatar_id, title: name(m.user_id), size: 20)
                                    .overlay(Circle().stroke(Theme.hex(0x00161F), lineWidth: 1.5))
                            }
                        }
                    }
                    Text(LocalizedStringKey(stateKey)).foregroundStyle(stateColor).fontWeight(.bold)
                    Text(verbatim: "·").foregroundStyle(PulseInk.muted)
                    Text(verbatim: String(format: NSLocalizedString("pulse.hdr.people", comment: ""), going.count)).foregroundStyle(PulseInk.muted)
                    if wide { Text(verbatim: "· " + NSLocalizedString("pulse.hdr.private", comment: "")).foregroundStyle(PulseInk.muted) }
                }
                .font(.caption).lineLimit(1)
            }
            Spacer(minLength: 4)
            timePill
            Button { sheet = .safety } label: {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18, weight: .semibold)).foregroundStyle(PulseInk.ink)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(LinearGradient(colors: [PulseInk.cyan, PulseInk.cyan.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                    .environment(\.colorScheme, .dark)
            }
            .accessibilityLabel(Text("pulse.safety"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            ZStack {
                LinearGradient(colors: [Theme.hex(0x03212C), Theme.hex(0x00161F)], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [PulseInk.cyan.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 200)
            }
            .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(PulseInk.cyan.opacity(0.55)).frame(height: 1).shadow(color: PulseInk.cyan.opacity(0.8), radius: 4)
        }
    }

    private var stateKey: String { ended ? "pulse.hdr.ended" : (startsLater || circle?.state == "inviting") ? "pulse.hdr.inviting" : "pulse.hdr.live" }
    private var stateColor: Color { ended ? PulseInk.muted : (startsLater || circle?.state == "inviting") ? PulseInk.amber : PulseInk.green }

    private var activityBadge: some View {
        let colors: [Color] = ended ? [Color.gray, Color.gray.opacity(0.5), Color.gray]
            : (startsLater || circle?.state == "inviting") ? [PulseInk.amber, PulseInk.amber.opacity(0.5), PulseInk.amber]
            : [PulseInk.cyan, Color(red: 0.6, green: 0.97, blue: 1), PulseInk.amber, Color(red: 1, green: 0.5, blue: 0.4), PulseInk.cyan]
        let turn = reduceMotion || ended ? 0 : (now.timeIntervalSince1970 * 24).truncatingRemainder(dividingBy: 360)
        return ZStack(alignment: .bottomTrailing) {
            Image(systemName: circle?.symbol ?? "mappin").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Theme.hex(0x071A24), in: Circle())
                .padding(3)
                .overlay(Circle().stroke(AngularGradient(colors: colors, center: .center), lineWidth: 3).rotationEffect(.degrees(turn))
                    .animation(.linear(duration: 1), value: turn))
                .frame(width: 46, height: 46)
            if stateKey == "pulse.hdr.live" {
                Circle().fill(PulseInk.green).frame(width: 10, height: 10).overlay(Circle().stroke(Theme.hex(0x00161F), lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }

    /// What is left: a 34 pt ring that empties over the meetup (amber in the last 15 minutes) and "2h 46m left".
    private var timePill: some View {
        let c = circle
        let left = startsLater ? (c?.starts_at ?? 0) - nowMs : (c?.expires_at ?? 0) - nowMs
        let frac = PulseRules.leftFraction(now: nowMs, starts: c?.starts_at, expires: c?.expires_at)
        let tint = !startsLater && left < 15 * 60_000 ? PulseInk.amber : PulseInk.cyan
        return HStack(spacing: 7) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: ended ? 0 : frac).stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: ended ? "0m" : PulseRules.shortLeft(left)).font(.system(size: 14.5, weight: .heavy).monospacedDigit()).foregroundStyle(PulseInk.ink)
                Text(LocalizedStringKey(startsLater ? "pulse.untilstart" : "pulse.left")).font(.system(size: 10, weight: .semibold)).foregroundStyle(PulseInk.muted)
            }
        }
        .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 4)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
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
            // SOS lives in this right-hand column (web 6eee89d5): it never covers the place cards at the bottom of the map;
            // there while the meetup is live, not while my own SOS is on
            if !ended && mySOS == nil {
                PulseSOSButton(disc: 52) { sosCountdown = true }.padding(.top, 2)
            }
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
                             : String(format: NSLocalizedString("pulse.summary.n", comment: ""), sharingCount, members.count))
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
                .background(alignment: .bottom) {
                    Image("PulseFlower").resizable().scaledToFit().frame(width: 140).opacity(0.5).allowsHitTesting(false)
                }
            }
        }
        .background(PulseInk.ground)
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

    private enum RowState { case on, here, approx, stale, off }

    /// What is true now for this person (web PersonRow): arrived, location off, an old position, a position too rough for
    /// a distance, or live.
    private func rowState(_ m: PulseMember, _ loc: PulseLocation?) -> RowState {
        if m.arrived { return .here }
        guard m.sharing == true else { return .off }
        guard let loc else { return .on }
        if PulseRules.freshness(loc.measured_at, now: nowMs) == .stale { return .stale }
        let known = PulseRules.distanceKnown(loc.distance_m, accuracy: loc.accuracy ?? 0)
        // without a place there is no distance to judge: only a rough position itself is "approximate"
        if loc.approximate || (loc.distance_m != nil && !known) { return .approx }
        return .on
    }

    private func rowColor(_ st: RowState) -> Color {
        switch st {
        case .on: return Theme.hex(0x7FF0B5)
        case .here: return Theme.hex(0x59F0A0)
        case .approx: return Theme.hex(0xFFD39A)
        case .stale: return Theme.hex(0xFFB08A)
        case .off: return Theme.hex(0x8FA9B1)
        }
    }

    private func rowLine(_ m: PulseMember, _ loc: PulseLocation?, _ st: RowState) -> String {
        switch st {
        case .here: return NSLocalizedString(m.arrived_kind == "manual" ? "pulse.row.said" : "pulse.arrived", comment: "")
        case .off: return NSLocalizedString(m.response == "maybe" ? "pulse.row.maybeoff" : "pulse.row.off", comment: "")
        case .stale: return String(format: NSLocalizedString("pulse.row.lastseen", comment: ""), PulseRules.agoText(loc?.measured_at ?? nowMs, now: nowMs))
        case .approx: return NSLocalizedString("pulse.row.approx", comment: "")
        case .on:
            guard let loc else { return NSLocalizedString("pulse.row.sharing", comment: "") }
            let fresh = nowMs - loc.measured_at < 10_000
            return String(format: NSLocalizedString("pulse.row.live", comment: ""),
                          fresh ? NSLocalizedString("pulse.row.justnow", comment: "") : PulseRules.agoText(loc.measured_at, now: nowMs))
        }
    }

    /// The one figure on the right and what it means; a straight-line time over 3 h says nothing, so the distance instead.
    private func rowMetric(_ loc: PulseLocation?, _ st: RowState) -> (value: String, label: String)? {
        switch st {
        case .here: return (NSLocalizedString("pulse.m.here", comment: ""), NSLocalizedString("pulse.m.atplace", comment: ""))
        case .approx: return ("±" + PulseRules.accuracyText(loc?.accuracy ?? 0), NSLocalizedString("pulse.m.accuracy", comment: ""))
        case .stale: return (PulseRules.ageShort(loc?.measured_at ?? nowMs, now: nowMs), NSLocalizedString("pulse.m.ago", comment: ""))
        case .off: return nil
        case .on:
            guard let loc, let d = loc.distance_m, PulseRules.distanceKnown(d, accuracy: loc.accuracy ?? 0) else { return nil }
            if let mins = PulseRules.etaMinutes(distance: d, speed: loc.speed), mins <= 180,
               let e = PulseRules.eta(distance: d, speed: loc.speed, arrived: false) {
                return (e, String(format: NSLocalizedString("pulse.m.est", comment: ""), PulseRules.distanceText(d)))
            }
            return (PulseRules.distanceText(d), NSLocalizedString("pulse.m.toplace", comment: ""))
        }
    }

    /// The person's own status as a quote ("“Parking now”"), nil without one.
    private func statusQuote(_ m: PulseMember) -> String? {
        guard let t = m.status?.text, !t.isEmpty else { return nil }
        let emoji = m.status?.emoji.map { $0 + " " } ?? ""
        return "“" + emoji + t + "”"
    }

    private func metricView(_ value: String, _ label: String, _ st: RowState) -> some View {
        let style: AnyShapeStyle = st == .on
            ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x7FF6FF), Theme.hex(0x00D4DF)], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(rowColor(st))
        return VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: value).font(PulseFont.display(17, 800)).monospacedDigit().lineLimit(1).foregroundStyle(style)
            Text(verbatim: label).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.hex(0x7FB5C2)).lineLimit(1)
        }
        .frame(minWidth: 64, maxWidth: 120, alignment: .trailing)
    }

    /// A person as a card (web 2e26b511): the face with a ring by state (turquoise live, green arrived, grey off) and a
    /// green live dot; the name with YOU / HOST; one coloured state line; their own status as a quote; a thin bar only when
    /// live with a known distance; one figure with its meaning on the right.
    private func participantRow(_ m: PulseMember) -> some View {
        let p = people[m.user_id]
        let loc = locations[m.user_id]
        let st = rowState(m, loc)
        let color = rowColor(st)
        let ring: Color = st == .here ? PulseInk.green : (st == .off ? Color.white.opacity(0.22) : PulseInk.cyan)
        let known = loc.map { PulseRules.distanceKnown($0.distance_m, accuracy: $0.accuracy ?? 0) } ?? false
        let pct = PulseRules.progress(first: firstDistance[m.user_id], now: loc?.distance_m, arrived: m.arrived)
        let blink = Int(now.timeIntervalSince1970) % 2 == 0
        let status = statusQuote(m)
        return Button { if loc != nil { selected = m.user_id; camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1) } } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Avatar(token: token, userID: m.user_id, avatarID: p?.avatar_id, title: p?.name ?? "", size: 48)
                        .saturation(st == .off ? 0 : 1)
                        .overlay(Circle().stroke(ring, lineWidth: 2.5))
                    if m.sharing == true && st != .off {
                        Circle().fill(PulseInk.green).frame(width: 11, height: 11).opacity(blink ? 1 : 0.35)
                            .overlay(Circle().stroke(Theme.hex(0x061A24), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(verbatim: p?.name ?? name(m.user_id)).font(PulseFont.display(15.5, 800)).foregroundStyle(PulseInk.ink).lineLimit(1)
                        if m.user_id == me {
                            Text("pulse.you").font(.system(size: 9.5, weight: .black)).tracking(0.7).foregroundStyle(Theme.hex(0x04222C))
                                .padding(.horizontal, 7).padding(.vertical, 2).background(PulseInk.cyan, in: Capsule())
                        }
                        if m.role == "organizer" {
                            Text("pulse.host").font(.system(size: 9.5, weight: .black)).tracking(0.7).foregroundStyle(Theme.hex(0x3A2A00))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(LinearGradient(colors: [Theme.hex(0xFFE08A), Theme.hex(0xF2B155)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(verbatim: rowLine(m, loc, st)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(color).lineLimit(1)
                    }
                    if let status {
                        Text(verbatim: status).font(.system(size: 12.5).italic()).foregroundStyle(Theme.hex(0xCFE7EE)).lineLimit(1)
                    }
                    if st == .on && known {
                        ProgressView(value: Double(max(pct, 4)), total: 100).tint(PulseInk.cyan).padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                if let metric = rowMetric(loc, st) { metricView(metric.value, metric.label, st) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .opacity(st == .off ? 0.85 : 1)
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
            // one dock row: My Status, Find Friend, the walkie-talkie, More, and Share / Stop sharing (always visible)
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
            .padding(.top, 8) // about 22-24 pt between the message box and the round button
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(
            ZStack {
                PulseInk.ground
                HStack {
                    Image("PulseWave").resizable().scaledToFit().frame(width: 150).opacity(0.5)
                    Spacer()
                    Image("PulseWave").resizable().scaledToFit().frame(width: 150).opacity(0.5).scaleEffect(x: -1)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(PulseInk.cyan.opacity(0.45)).frame(height: 1).shadow(color: PulseInk.cyan.opacity(0.7), radius: 4)
        }
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
                                      glide: PulseRules.glideMs(prev: previous[id], next: loc, reduceMotion: reduceMotion) / 1000,
                                      sos: activeSOS.contains { $0.user_id == id }))
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

    // MARK: SOS

    private var activeSOS: [PulseSOS] { view?.sos ?? [] }
    private var mySOS: PulseSOS? { activeSOS.first { $0.user_id == me } }

    /// SOS senders whose live position is not here but whose SOS has one: a red beacon.
    private var sosBeacons: [PulseSOSBeacon] {
        activeSOS.compactMap { s in
            guard s.user_id != me, locations[s.user_id] == nil, let lat = s.lat, let lon = s.lon else { return nil }
            return PulseSOSBeacon(id: s.id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), name: name(s.user_id))
        }
    }

    /// Sends the SOS to the meetup: one key per confirmation (its retries reuse it), at most one position snapshot (only when
    /// "Attach my current location" stayed on), and never starts live sharing because of it.
    private func sendSOS(_ reason: String, key: String, attach: Bool) async {
        var position: [String: Any]?
        if attach {
            var fix = sharer.lastFix
            if fix.map({ -$0.timestamp.timeIntervalSinceNow > 60 }) ?? true { fix = await sharer.readOnce() ?? fix }
            if let l = fix { position = SOSCenter.snapshot(l) }
        }
        guard let id = await SOSCenter.shared.send(circle: circleID, reason: reason, key: key, position: position) else {
            flash = NSLocalizedString("pulse.sos.failed", comment: "")
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        SOSCenter.shared.toast = NSLocalizedString("sos.toast.created", comment: "")
        if !id.isEmpty { SOSCenter.shared.open(id) }
        await load()
    }

    /// A red banner per active SOS: mine with the delivery line and "I'm safe..." (asked first, on the emergency screen);
    /// others with "Show" and "Help".
    private func sosBanner(_ s: PulseSOS) -> some View {
        let mine = s.user_id == me
        let mins = max(0, Int((nowMs - (s.created_at ?? nowMs)) / 60_000))
        let glow = 0.35 + 0.25 * (0.5 + 0.5 * sin(now.timeIntervalSince1970 * 2 * .pi / 2.4))
        let em = sos.emergency(s.id)
        let responders = (em?.rows ?? []).filter { $0.responding_at != nil }.map { name($0.user_id) }
        let ago = mins < 1 ? NSLocalizedString("pulse.ago.now", comment: "") : String(format: NSLocalizedString("pulse.sos.ago", comment: ""), mins)
        let resp = responders.isEmpty ? "" : String(format: NSLocalizedString("sos.banner.responding", comment: ""), responders.joined(separator: ", "))
        let otherLine = [s.text ?? "SOS", ago, resp].filter { !$0.isEmpty }.joined(separator: " · ")
        let mineLine = PulseSOSRules.deliveryText(em, responding: responders).line
        return HStack(spacing: 10) {
            Text(verbatim: "SOS").font(.system(size: 11, weight: .black)).foregroundStyle(Theme.hex(0xB8102A))
                .frame(width: 36, height: 36).background(.white, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                if mine {
                    Text("pulse.sos.mine").font(.subheadline.weight(.heavy))
                    Text(verbatim: mineLine).font(.caption).opacity(0.9).lineLimit(2)
                } else {
                    Text(verbatim: String(format: NSLocalizedString("pulse.sos.other", comment: ""), name(s.user_id))).font(.subheadline.weight(.heavy))
                    Text(verbatim: otherLine).font(.caption).opacity(0.9).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 4)
            if mine {
                Button { sos.open(s.id) } label: {
                    Text("sos.safe").font(.footnote.weight(.heavy)).padding(.horizontal, 12).frame(minHeight: 36)
                        .background(PulseInk.green, in: Capsule()).foregroundStyle(Theme.hex(0x04222C))
                }
                .buttonStyle(.plain)
            } else {
                Button { showSOSFriend(s) } label: {
                    Text("pulse.sos.show").font(.footnote.weight(.heavy)).padding(.horizontal, 12).frame(minHeight: 36)
                        .background(.white, in: Capsule()).foregroundStyle(Theme.hex(0xB8102A))
                }
                .buttonStyle(.plain)
                Button { sos.open(s.id) } label: {
                    Text("sos.help").font(.footnote.weight(.heavy)).padding(.horizontal, 12).frame(minHeight: 36)
                        .background(PulseInk.green, in: Capsule()).foregroundStyle(Theme.hex(0x04222C))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(LinearGradient(colors: [Theme.hex(0xFF4A5C), Theme.hex(0xB8102A)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.hex(0xFF3B4E).opacity(glow), radius: 14)
        .accessibilityElement(children: .contain)
    }

    private func showSOSFriend(_ s: PulseSOS) {
        selected = s.user_id
        if locations[s.user_id] != nil {
            camera = PulseCamera(mode: .follow(s.user_id), nonce: camera.nonce + 1)
        } else if s.lat != nil {
            camera = PulseCamera(mode: .everyone, nonce: camera.nonce + 1)
        }
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
                // a compact centred pill (web 6eee89d5), not a full-width bar
                Text(LocalizedStringKey(decides ? "pulse.pick.make" : "pulse.pick.suggest")).font(.subheadline.weight(.bold))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 40)
                    .background(PulseInk.gradient, in: Capsule())
                    .foregroundStyle(Theme.hex(0x04222C))
                    .opacity(empty ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .frame(maxWidth: .infinity)
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
        case .status: statusSheet.presentationDetents([.medium, .large])
        case .find: findSheet.presentationDetents([.medium, .large])
        case .more: moreSheet.presentationDetents([.medium, .large])
        case .safety:
            PulseSafetyCenter(token: token, me: me, circleID: circleID, members: members.filter { $0.user_id != me }, people: people,
                              sharingHere: sharingHere, onLeave: { sheet = nil; confirmLeave = true })
        case .code: PulseInstantCodeSheet(token: token, circleID: circleID, people: people)
        case .invite: PulseInviteMore(token: token, circleID: circleID, already: Set(members.map(\.user_id)))
        case .capsule: PulseCapsuleView(token: token, me: me, circleID: circleID, title: circle?.title ?? "")
        }
    }

    /// The menus' look for each quick status (web 872dfbee): a drawn icon in a coloured chip instead of the emoji. The emoji
    /// is still sent: it floats over the avatar on every app's map.
    private static let statusLook: [String: (icon: String, tone: Tone)] = [
        "On my way!": ("car.fill", .cyan), "Stuck in traffic": ("car.2.fill", .amber), "5 min away": ("timer", .violet),
        "I'm here!": ("mappin.and.ellipse", .green), "Running late": ("hourglass", .rose), "Order for me": ("cup.and.saucer.fill", .blue),
    ]

    /// The sheets' chip colours (web .t-*): a light and a deep stop.
    enum Tone {
        case cyan, amber, violet, green, rose, blue, red, slate
        var stops: (Color, Color) {
            switch self {
            case .cyan: return (Theme.hex(0x00D4DF), Theme.hex(0x0A7F8A))
            case .amber: return (Theme.hex(0xF2B155), Theme.hex(0xB86A12))
            case .violet: return (Theme.hex(0xB48CFF), Theme.hex(0x6A3FD1))
            case .green: return (Theme.hex(0x4FE39A), Theme.hex(0x138A52))
            case .rose: return (Theme.hex(0xFF7A9A), Theme.hex(0xC0305A))
            case .blue: return (Theme.hex(0x6CB4FF), Theme.hex(0x2563C9))
            case .red: return (Theme.hex(0xFF5A6E), Theme.hex(0xB8102A))
            case .slate: return (Theme.hex(0x8FB0BB), Theme.hex(0x3F5B66))
            }
        }
    }

    /// A drawn icon in a gradient chip (40 pt, radius 13, white icon).
    private func toneChip(_ icon: String, _ tone: Tone, size: CGFloat = 40) -> some View {
        let (a, b) = tone.stops
        let shape = RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
        return Image(systemName: icon).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: a.opacity(0.35), radius: 8, y: 4)
            .accessibilityHidden(true)
    }

    /// The sheet's title and a round close button.
    private func sheetHeader(_ key: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key)).font(PulseFont.display(19, 800)).foregroundStyle(PulseInk.ink)
            Spacer()
            Button { sheet = nil } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(PulseInk.ink)
                    .frame(width: 36, height: 36).background(Color.white.opacity(0.08), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.close"))
        }
    }

    /// My status (web 872dfbee): what is shown now with Clear; six tiles; my own text with Set inside the field; I'm here.
    private var statusSheet: some View {
        let current = view?.me?.status?.text ?? ""
        let arrived = view?.me?.arrived == true
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sheetHeader("pulse.mystatus")
                if !current.isEmpty {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("pulse.status.now").font(.system(size: 10.5, weight: .heavy)).tracking(0.8).textCase(.uppercase)
                                .foregroundStyle(Theme.hex(0x7FB5C2))
                            Text(verbatim: "“" + current + "”").font(.system(size: 14.5).italic()).foregroundStyle(.white).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Button { Task { await setStatus("", nil) } } label: {
                            Text("pulse.status.clear2").font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.hex(0xFFD7DC))
                                .padding(.horizontal, 14).frame(minHeight: 32)
                                .background(Theme.hex(0xFF5A6E, 0.14), in: Capsule())
                                .overlay(Capsule().stroke(Theme.hex(0xFF5A6E, 0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(PulseInk.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseInk.cyan.opacity(0.25), lineWidth: 1))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(PulseRules.quickStatuses, id: \.text) { q in statusTile(q.text, q.emoji, current: current) }
                }
                HStack(spacing: 8) {
                    Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.hex(0x7FB5C2))
                    TextField(NSLocalizedString("pulse.status.own2", comment: ""), text: $bubbleText)
                        .font(.system(size: 14.5)).foregroundStyle(.white).submitLabel(.done)
                        .onSubmit { sendOwnStatus() }
                    let empty = bubbleText.trimmingCharacters(in: .whitespaces).isEmpty
                    Button { sendOwnStatus() } label: {
                        Text("pulse.status.set").font(.system(size: 14, weight: .heavy)).padding(.horizontal, 18).frame(minHeight: 40)
                            .foregroundStyle(empty ? Color.white.opacity(0.45) : Theme.hex(0x00242B))
                            .background(empty ? AnyShapeStyle(Color.white.opacity(0.07))
                                        : AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x6FF8FC), Theme.hex(0x00BCC6)], startPoint: .topLeading, endPoint: .bottomTrailing)),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseInk.cyan.opacity(0.22), lineWidth: 1))
                // "I'm here" works without location (said, not measured)
                menuRow("mappin.and.ellipse", .green, arrived ? "pulse.imhere.undo" : "pulse.imhere2", arrived ? "pulse.imhere.undo.sub" : "pulse.imhere.sub") {
                    Task { _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "here", body: ["here": !arrived]); sheet = nil; await load() }
                }
            }
            .padding(20)
        }
    }

    private func sendOwnStatus() {
        let t = bubbleText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        Task { await setStatus(String(t.prefix(40)), nil); bubbleText = "" }
    }

    private func statusTile(_ text: String, _ emoji: String, current: String) -> some View {
        let look = Self.statusLook[text] ?? ("bubble.left.fill", .cyan)
        let label = NSLocalizedString("pulse.qs." + text, comment: "")
        let on = current == label || current == text
        let tc = look.tone.stops.0
        return Button { Task { await setStatus(label, emoji) } } label: {
            HStack(spacing: 10) {
                toneChip(look.icon, look.tone, size: 36)
                Text(verbatim: label).font(PulseFont.display(14, 800)).foregroundStyle(Theme.hex(0xF2FBFD)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 9).padding(.trailing, 12).frame(minHeight: 58)
            .background(LinearGradient(colors: [tc.opacity(0.14), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(LinearGradient(colors: [Theme.hex(0x0B2F3B), Theme.hex(0x061C25)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tc.opacity(on ? 1 : 0.3), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One menu row (web MenuRow): a coloured icon chip, a title and one line of help, a chevron; red-tinted when it is the
    /// leave / end row.
    private func menuRow(_ icon: String, _ tone: Tone, _ title: String, _ sub: String?, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        let tc = tone.stops.0
        let bg: [Color] = danger ? [Theme.hex(0xB8102A, 0.22), Theme.hex(0x12060A)] : [Theme.hex(0x0B2F3B), Theme.hex(0x061C25)]
        return Button(action: action) {
            HStack(spacing: 12) {
                toneChip(icon, tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(PulseFont.display(15, 800)).foregroundStyle(danger ? Theme.hex(0xFFB3BD) : Theme.hex(0xF2FBFD))
                    if let sub { Text(LocalizedStringKey(sub)).font(.system(size: 12.5)).foregroundStyle(Theme.hex(0x8FB6C0)).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward").font(.system(size: 14, weight: .bold)).foregroundStyle(tc.opacity(0.9))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 10)
            .background(LinearGradient(colors: bg, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(danger ? Theme.hex(0xFF5A6E, 0.3) : PulseInk.cyan.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func setStatus(_ text: String, _ emoji: String?) async {
        var body: [String: Any] = ["text": text]
        if let emoji { body["emoji"] = emoji }
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "status", body: body)
        sheet = nil
        await load()
    }

    /// Find My Friend (web 208efd39): per friend, the face, the name and one coloured state line; Updated / Accuracy /
    /// Distance as three labelled values; one plain sentence only when needed; Directions and Meet halfway.
    private var findSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sheetHeader("pulse.findfriend")
                let sharing = members.filter { $0.user_id != me && locations[$0.user_id] != nil }
                let others = members.filter { $0.user_id != me && ($0.response == "going" || $0.response == "maybe" || $0.role == "organizer") }
                ForEach(sharing) { m in friendCard(m, locations[m.user_id]!) }
                // nobody shares: the first friend is shown, with what to expect and a way to reach them
                if sharing.isEmpty {
                    if let first = others.first { notSharingCard(first) } else {
                        Text("pulse.find.nobody").font(PulseFont.text(14)).foregroundStyle(PulseInk.muted)
                    }
                }
            }
            .padding(20)
        }
    }

    private func friendCard(_ m: PulseMember, _ loc: PulseLocation) -> some View {
        let stale = PulseRules.freshness(loc.measured_at, now: nowMs) == .stale
        let mine = sharingHere ? sharer.lastFix : nil
        let away = mine.map { PulseRules.distanceM($0.coordinate.latitude, $0.coordinate.longitude, loc.lat, loc.lon) }
        let acc = loc.accuracy ?? 0
        let known = away.map { PulseRules.distanceKnown($0, accuracy: max(acc, mine?.horizontalAccuracy ?? 0)) } ?? false
        let state: (key: String, color: Color) = stale ? ("pulse.find.state.stale", Theme.hex(0xFFB08A))
            : loc.approximate ? ("pulse.find.state.approx", Theme.hex(0xFFD39A)) : ("pulse.find.state.live", Theme.hex(0x7FF0B5))
        let distance = known ? away.map(PulseRules.distanceText) ?? "—" : "—"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Avatar(token: token, userID: m.user_id, avatarID: people[m.user_id]?.avatar_id, title: name(m.user_id), size: 46)
                    .overlay(Circle().stroke(PulseInk.cyan, lineWidth: 2.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name(m.user_id)).font(PulseFont.display(17, 800)).foregroundStyle(PulseInk.ink).lineLimit(1)
                    Text(LocalizedStringKey(state.key)).font(.system(size: 12.5, weight: .bold)).foregroundStyle(state.color)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                findStat("clock", "pulse.find.updated", PulseRules.agoText(loc.measured_at, now: nowMs), warn: stale)
                Rectangle().fill(PulseInk.cyan.opacity(0.18)).frame(width: 1)
                findStat("scope", "pulse.find.accuracy", "±" + PulseRules.accuracyText(acc), warn: loc.approximate)
                Rectangle().fill(PulseInk.cyan.opacity(0.18)).frame(width: 1)
                findStat("mappin", "pulse.find.distance", distance, warn: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(PulseInk.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(PulseInk.cyan.opacity(0.2), lineWidth: 1))
            if away == nil {
                Text("pulse.find.hint.share").font(.system(size: 12.5)).foregroundStyle(Theme.hex(0xA9CDD6))
            } else if !known {
                Text("pulse.find.hint.hidden").font(.system(size: 12.5)).foregroundStyle(Theme.hex(0xA9CDD6))
            }
            HStack(spacing: 10) {
                Button {
                    if let u = URL(string: "http://maps.apple.com/?daddr=\(loc.lat),\(loc.lon)") { UIApplication.shared.open(u) }
                } label: {
                    Label("pulse.find.directions2", systemImage: "map").font(PulseFont.display(14, 800)).frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(Capsule().stroke(PulseInk.cyan.opacity(0.6), lineWidth: 1.2)).foregroundStyle(PulseInk.ink)
                }
                Button {
                    selected = m.user_id
                    camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1)
                    Task {
                        var fix = sharer.lastFix
                        if fix == nil { fix = await sharer.readOnce() }
                        guard let mine = fix else { flash = NSLocalizedString("pulse.find.needyou", comment: ""); return }
                        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "proposals",
                                                                 body: ["name": NSLocalizedString("pulse.halfway", comment: ""),
                                                                        "lat": (mine.coordinate.latitude + loc.lat) / 2, "lon": (mine.coordinate.longitude + loc.lon) / 2])
                        sheet = nil
                        await load()
                    }
                } label: {
                    Label("pulse.find.halfway2", systemImage: "person.2.fill").font(PulseFont.display(14, 800)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(PulseInk.gradient, in: Capsule()).foregroundStyle(Theme.hex(0x04222C))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = m.user_id
            camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1)
            sheet = nil
        }
    }

    /// Find My Friend when the friend is not sharing (web 872dfbee): grey chip, what is true, and a Message pill.
    private func notSharingCard(_ m: PulseMember) -> some View {
        HStack(alignment: .top, spacing: 12) {
            toneChip("eye.slash", .slate)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: String(format: NSLocalizedString("pulse.find.notsharing", comment: ""), name(m.user_id)))
                        .font(PulseFont.display(15, 800)).foregroundStyle(Theme.hex(0xF2FBFD))
                    Text("pulse.find.notsharing.sub").font(.system(size: 12.5)).foregroundStyle(Theme.hex(0x8FB6C0))
                }
                Button { Task { await messageFriend(m.user_id) } } label: {
                    Label("sos.message", systemImage: "bubble.left.fill").font(.system(size: 13.5, weight: .heavy))
                        .padding(.horizontal, 14).frame(minHeight: 38)
                        .foregroundStyle(Theme.hex(0x00242B))
                        .background(LinearGradient(colors: [Theme.hex(0x6FF8FC), Theme.hex(0x00BCC6)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(LinearGradient(colors: [Theme.hex(0x0B2F3B), Theme.hex(0x061C25)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hex(0x8FB0BB, 0.22), lineWidth: 1))
    }

    /// The private chat with this person (fails visibly when they are not a contact).
    private func messageFriend(_ id: String) async {
        do {
            let conv = try await APIClient.shared.directConversation(token: token, with: id)
            sheet = nil
            LocalNotifier.shared.tappedConversation = conv
        } catch {
            flash = NSLocalizedString("sos.notcontact", comment: "")
        }
    }

    /// One of the three labelled values: a tiny uppercase label with its icon, the value under it.
    private func findStat(_ icon: String, _ label: String, _ value: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(LocalizedStringKey(label)).textCase(.uppercase)
            }
            .font(.system(size: 10.5, weight: .heavy)).tracking(0.7).foregroundStyle(Theme.hex(0x7FB5C2)).lineLimit(1)
            Text(verbatim: value).font(PulseFont.display(15, 800)).foregroundStyle(warn ? Theme.hex(0xFFD39A) : .white)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// More (web 872dfbee): each row an icon chip, a title and one help line.
    private var moreSheet: some View {
        ScrollView {
            VStack(spacing: 8) {
                sheetHeader("pulse.more")
                menuRow("mappin.and.ellipse", .cyan, "pulse.more.propose", "pulse.more.propose.sub") { sheet = nil; proposing = true }
                if isOrganizer && !ended {
                    menuRow("qrcode", .violet, "pulse.more.code", "pulse.more.code.sub") { sheet = .code }
                    menuRow("person.badge.plus", .blue, "pulse.more.invite2", "pulse.more.invite.sub") { sheet = .invite }
                }
                menuRow("photo.on.rectangle", .amber, "pulse.card.capsule", "pulse.more.capsule.sub") { sheet = .capsule }
                menuRow("shield.lefthalf.filled", .green, "pulse.safety", "pulse.more.safety.sub") { sheet = .safety }
                if isOrganizer {
                    if !ended {
                        menuRow("power", .red, "pulse.more.end", "pulse.more.end.sub", danger: true) { sheet = nil; confirmLeave = true }
                    }
                } else {
                    menuRow("rectangle.portrait.and.arrow.right", .red, "pulse.more.leave", "pulse.more.leave.sub", danger: true) { sheet = nil; confirmLeave = true }
                }
            }
            .padding(20)
        }
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
        case "alert", "sos-resolved":
            if e == "alert", ((d["alert"] as? [String: Any])?["kind"] as? String) == "sos" { UINotificationFeedbackGenerator().notificationOccurred(.error) }
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wide: Bool { sizeClass == .regular }
    let token: String
    let circleID: String
    let onNote: (String) -> Void
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: walkie.recording ? "waveform" : "mic.fill").font(.system(size: 24, weight: .bold))
                .foregroundStyle(walkie.recording ? .white : Theme.onAccent)
                // never above its row (it covered the message box): 56 pt on phones, 60 pt on wide screens
                .frame(width: wide ? 60 : 56, height: wide ? 60 : 56)
                .background(walkie.recording ? Theme.danger : Theme.accent, in: Circle())
                .shadow(color: Theme.hex(0x3CF0EE, 0.45), radius: 10, y: 2)
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
    /// The app's teal-black (the sidebar's): #00161f -> #00141c -> #001018.
    static let ground = LinearGradient(colors: [Color(red: 0, green: 0x16 / 255.0, blue: 0x1F / 255.0), Color(red: 0, green: 0x14 / 255.0, blue: 0x1C / 255.0),
                                                Color(red: 0, green: 0x10 / 255.0, blue: 0x18 / 255.0)], startPoint: .top, endPoint: .bottom)
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

/// The SOS button on the map: a 58 pt red disc with a siren, a white ring, a pulsing red ring, and the "SOS" pill.
struct PulseSOSButton: View {
    var disc: CGFloat = 58
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.7 : 1)
                    let phase = (t / 1.6).truncatingRemainder(dividingBy: 1)
                    ZStack {
                        Circle().stroke(Theme.hex(0xFF3B4E).opacity(0.7 * (1 - phase)), lineWidth: 3)
                            .frame(width: disc + disc * 0.5 * phase, height: disc + disc * 0.5 * phase)
                        Circle().fill(RadialGradient(colors: [Theme.hex(0xFF8A95), Theme.hex(0xFF3B4E), Theme.hex(0xB8102A)], center: .init(x: 0.4, y: 0.35),
                                                     startRadius: 2, endRadius: disc * 0.6))
                            .frame(width: disc, height: disc)
                            .overlay(Circle().stroke(.white, lineWidth: disc < 56 ? 2.5 : 3))
                            .shadow(color: Theme.hex(0xFF3B4E).opacity(0.6), radius: 10)
                        Image(systemName: "light.beacon.max.fill").font(.system(size: disc * 0.42, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: disc * 1.5, height: disc * 1.5)
                }
                .frame(width: disc + 8, height: disc + 4) // the wave may spread past the column; it is never clipped
                Text(verbatim: "SOS").font(PulseFont.brand(disc < 56 ? 11 : 12)).tracking(disc < 56 ? 2 : 3).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Theme.hex(0xB8102A), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("pulse.sos.button"))
    }
}

/// The full-screen SOS countdown (PULSE_SAFETY_RESPONSE_SPEC.md section 1): 5 seconds, the reason, "Attach my current
/// location" (one snapshot), Send now / Cancel. It sends by itself at 0, but never after the app left the foreground: then it
/// pauses ("Nothing was sent") and only Send now or Restart continues. One idempotency key per confirmation.
struct PulseSOSCountdown: View {
    let others: Int
    let onSend: (_ reason: String, _ key: String, _ attach: Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.scenePhase) private var phase
    @State private var left = 5
    @State private var reason = 0
    @State private var attach = true
    @State private var paused = false
    @State private var sent = false
    @State private var key = PulseSOSRules.newKey()

    private static let reasons = ["pulse.sos.r.help", "pulse.sos.r.accident", "pulse.sos.r.danger", "pulse.sos.r.medical"]
    /// web d68efdfc: lifebuoy, car, warning triangle, square with a plus
    private static let reasonIcons = ["lifepreserver", "car.fill", "exclamationmark.triangle.fill", "cross.case.fill"]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                dial
                Text(LocalizedStringKey(paused ? "sos.paused" : "pulse.sos.sending")).font(PulseFont.display(26, 900))
                    .accessibilityAddTraits(.isHeader)
                if paused {
                    Text(verbatim: lead)
                        .font(PulseFont.text(15)).multilineTextAlignment(.center).opacity(0.9).padding(.horizontal, 24)
                } else {
                    // who is alerted, as a pill
                    Label { Text(verbatim: lead) } icon: { Image(systemName: "person.2.fill").font(.system(size: 13, weight: .semibold)) }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.hex(0xFFE3E6))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                Text("sos.what").font(.system(size: 11.5, weight: .heavy)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(Theme.hex(0xFFC2CA))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                reasonGrid
                attachRow
                Button { send() } label: {
                    Text("pulse.sos.now").font(.headline.weight(.heavy)).frame(maxWidth: .infinity, minHeight: 54)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).foregroundStyle(Theme.hex(0xB8102A))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                if paused {
                    Button { restart() } label: {
                        Text("sos.restart").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }
                Button { sent = true; onCancel() } label: {
                    Text("notes.cancel").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .semibold)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("sos.footer.1")
                        Text("sos.footer.2")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5)).opacity(0.85).padding(.horizontal, 24)
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 30)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadialGradient(colors: [Theme.hex(0xD0182F), Theme.hex(0x7A0716), Theme.hex(0x3A020A)], center: .center, startRadius: 20, endRadius: 520).ignoresSafeArea())
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in tick() }
        .onChange(of: phase) { p in if p != .active { pause() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in pause() }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            announce(String(format: NSLocalizedString("sos.ax.start", comment: ""), 5))
        }
    }

    private var lead: String {
        if paused { return NSLocalizedString("sos.paused.sub", comment: "") }
        return String(format: NSLocalizedString(others == 1 ? "sos.alerting.one" : "sos.alerting.n", comment: ""), others)
    }

    private var dial: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 8)
            Circle().trim(from: 0, to: CGFloat(left) / 5).stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: left)
            Text(verbatim: paused ? "II" : "\(left)").font(.system(size: 64, weight: .black).monospacedDigit())
        }
        .frame(width: 150, height: 150)
        .opacity(paused ? 0.7 : 1)
        .accessibilityHidden(true)
    }

    private var reasonGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Self.reasons.indices, id: \.self) { i in
                Button { reason = i } label: {
                    HStack(spacing: 9) {
                        Image(systemName: Self.reasonIcons[i]).font(.system(size: 17, weight: .semibold)).frame(width: 22)
                        Text(LocalizedStringKey(Self.reasons[i])).font(.system(size: 14, weight: .bold)).multilineTextAlignment(.leading)
                            .lineLimit(2).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(reason == i ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(reason == i ? Theme.hex(0xB8102A) : .white)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(reason == i ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
    }

    /// The location as a switch row: a white chip with a pin, the title and its note, a switch (green when on).
    private var attachRow: some View {
        Toggle(isOn: $attach) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(attach ? Theme.hex(0xB8102A) : .white)
                    .frame(width: 36, height: 36)
                    .background(attach ? Color.white : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("sos.attach2").font(.system(size: 14.5, weight: .heavy))
                    Text("sos.attach.sub").font(.system(size: 12)).foregroundStyle(Theme.hex(0xFFCFD5))
                }
            }
        }
        .tint(Theme.hex(0x59F0A0))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 24)
    }

    private func tick() {
        guard !sent, !paused else { return }
        // never from the background: a countdown nobody watched does not send
        guard phase == .active, UIApplication.shared.applicationState == .active else { pause(); return }
        if left > 1 {
            left -= 1
            if left <= 2 { announce("\(left)") }
        } else {
            left = 0
            send()
        }
    }

    private func restart() {
        left = 5
        paused = false
        announce(String(format: NSLocalizedString("sos.ax.start", comment: ""), 5))
    }

    private func pause() {
        guard !sent, !paused else { return }
        paused = true
        announce(NSLocalizedString("sos.ax.paused", comment: ""))
    }

    private func announce(_ t: String) { UIAccessibility.post(notification: .announcement, argument: t) }

    private func send() {
        guard !sent else { return }
        sent = true
        onSend(NSLocalizedString(Self.reasons[reason], comment: ""), key, attach)
    }
}
