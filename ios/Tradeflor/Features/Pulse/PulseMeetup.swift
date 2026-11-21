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
        .sheet(item: $sheet) { s in sheetView(s).tfColorScheme() }
        .alert(Text("pulse.propose.name"), isPresented: Binding(get: { proposalAt != nil }, set: { if !$0 { proposalAt = nil } })) {
            TextField(NSLocalizedString("pulse.create.place", comment: ""), text: $proposalName)
            Button("pulse.propose.send") { Task { await propose() } }
            Button("notes.cancel", role: .cancel) { proposalAt = nil }
        }
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
                             onTapMap: proposing ? { c in proposing = false; proposalName = ""; proposalAt = c } : nil,
                             // a café or restaurant tapped: offered as the meeting place (nothing is sent until Propose)
                             onTapPlace: ended ? nil : { name, c in proposing = false; proposalName = name; proposalAt = c },
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
            }
            panel
            if !ended { bottomBar }
        }
    }

    private func banner(_ key: String, _ tint: Color) -> some View {
        Text(LocalizedStringKey(key)).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.hex(0x04111E, 0.9), in: Capsule()).overlay(Capsule().stroke(tint.opacity(0.6), lineWidth: 1))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel(Text("chat.close"))
            Text(verbatim: circle?.icon ?? "📍").font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("pulse.meetup").font(.caption2.weight(.bold)).foregroundStyle(Theme.hex(0x3CF0EE))
                Text(verbatim: circle?.title ?? "").font(.headline).lineLimit(1)
                Text(verbatim: String(format: NSLocalizedString("pulse.private.line", comment: ""), going.count)).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(LocalizedStringKey(startsLater ? "pulse.starts" : "pulse.ends")).font(.caption2).foregroundStyle(.white.opacity(0.7))
                Text(verbatim: countdownText).font(.system(.subheadline, design: .monospaced).weight(.bold))
            }
            .accessibilityElement(children: .combine)
            Button { sheet = .safety } label: {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("pulse.safety"))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.hex(0x04111E))
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

    // MARK: the panel (one line, opens on tap)

    private var panel: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { panelOpen.toggle() } } label: {
                HStack {
                    Circle().fill(Theme.hex(0x14C27A)).frame(width: 8, height: 8)
                    Text(verbatim: String(format: NSLocalizedString("pulse.panel.line", comment: ""), sharingCount, going.count))
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: panelOpen ? "chevron.down" : "chevron.up").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 14).frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            if panelOpen {
                Picker("", selection: $panelTab) {
                    Text("pulse.participants").tag(0)
                    Text("pulse.activity").tag(1)
                }
                .pickerStyle(.segmented).padding(.horizontal, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if panelTab == 0 { ForEach(members) { m in participantRow(m) } } else { activityList }
                        Text(verbatim: String(format: NSLocalizedString("pulse.private.footer", comment: ""), countdownText))
                            .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(14)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(Theme.hex(0x061A24))
    }

    private var sharingCount: Int { members.filter { $0.sharing == true }.count }

    private func participantRow(_ m: PulseMember) -> some View {
        let p = people[m.user_id]
        let loc = locations[m.user_id]
        let line = personLine(m, loc)
        let pct = PulseRules.progress(first: firstDistance[m.user_id], now: loc?.distance_m, arrived: m.arrived)
        return Button { if loc != nil { selected = m.user_id; camera = PulseCamera(mode: .follow(m.user_id), nonce: camera.nonce + 1) } } label: {
            HStack(spacing: 10) {
                Avatar(token: token, userID: m.user_id, avatarID: p?.avatar_id, title: p?.name ?? "", size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: m.user_id == me ? NSLocalizedString("chat.you", comment: "") : (p?.name ?? "")).font(.subheadline.weight(.semibold))
                    Text(verbatim: m.status?.text.map { (m.status?.emoji.map { $0 + " " } ?? "") + $0 } ?? line).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if m.sharing == true || m.arrived {
                        ProgressView(value: Double(pct), total: 100).tint(m.arrived ? Theme.hex(0x14C27A) : Theme.hex(0x3CF0EE))
                    }
                }
                Spacer()
                if m.sharing == true || m.arrived { Text(verbatim: "\(pct)%").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6)) }
            }
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
            HStack(spacing: 8) {
                TextField(NSLocalizedString(selected.map { _ in "pulse.bubble.reply" } ?? "pulse.bubble", comment: ""), text: $bubbleText)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendBubble() } }
                    .padding(.horizontal, 12).frame(minHeight: 40)
                    .background(Theme.hex(0x0B2833), in: Capsule())
            }
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
        proposalAt = nil
        guard !n.isEmpty else { return }
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "proposals", body: ["name": String(n.prefix(80)), "lat": at.latitude, "lon": at.longitude])
        await load()
    }

    // MARK: sheets

    @ViewBuilder private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .share:
            if let c = circle {
                PulseShareSheet(circle: c, others: max(0, going.count - 1)) { ok in sheet = nil; if ok { Task { await load() } } }
                    .presentationDetents([.medium])
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
        NavigationStack {
            List {
                Button { sheet = nil; proposing = true } label: { Label("pulse.more.propose", systemImage: "mappin.and.ellipse") }
                if isOrganizer {
                    Button { sheet = .code } label: { Label("pulse.more.code", systemImage: "qrcode") }
                    Button { sheet = .invite } label: { Label("pulse.more.invite", systemImage: "person.badge.plus") }
                }
                Button { sheet = .capsule } label: { Label("pulse.card.capsule", systemImage: "photo.stack") }
                Button { sheet = .safety } label: { Label("pulse.safety", systemImage: "shield.lefthalf.filled") }
                Button(role: .destructive) { sheet = nil; confirmLeave = true } label: {
                    Label(LocalizedStringKey(isOrganizer ? "pulse.end" : "pulse.leave"), systemImage: isOrganizer ? "stop.circle" : "rectangle.portrait.and.arrow.right")
                }
            }
            .navigationTitle(Text("pulse.more"))
            .navigationBarTitleDisplayMode(.inline)
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
