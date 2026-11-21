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

/// Pulse home: Create Meetup, Instant Circle, Find My Friend, Time Capsule; invitations with four answers; Recent & Active
/// with LIVE; Party Mode; Stop all sharing whenever this device shares anywhere.
struct PulseHomeView: View {
    let token: String
    let me: String
    @Binding var side: String
    @ObservedObject private var pulse = PulseStore.shared
    @ObservedObject private var sharer = PulseSharer.shared
    @AppStorage("tf.pulse.party") private var party = false
    @State private var creating = false
    @State private var instant = false
    @State private var open: PulseOpen?
    @State private var capsules = false
    @State private var sharingFor: PulseCircle?
    @State private var note: String?

    private var invitations: [PulseCircleEntry] { pulse.circles.filter { $0.response == "invited" && $0.circle.isOpen } }
    private var active: [PulseCircleEntry] { pulse.circles.filter { $0.response != "invited" && $0.response != "declined" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PulseSideSwitch(side: $side)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("pulse.title").font(.title2.weight(.heavy)).foregroundStyle(Theme.text)
                        Text("pulse.tagline").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if sharer.isSharingAnywhere {
                        Button { Task { await sharer.stopAll(); await pulse.reload() } } label: {
                            Label("pulse.stopall", systemImage: "location.slash.fill").font(.footnote.weight(.bold))
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(Theme.danger, in: Capsule()).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    card("person.3.fill", "pulse.card.create", "pulse.card.create.sub") { creating = true }
                    card("qrcode", "pulse.card.instant", "pulse.card.instant.sub") { instant = true }
                    card("location.viewfinder", "pulse.card.find", "pulse.card.find.sub") { findFriend() }
                    card("photo.stack", "pulse.card.capsule", "pulse.card.capsule.sub") { capsules = true }
                }
                if let note { Text(verbatim: note).font(.footnote).foregroundStyle(Theme.gold) }
                if !invitations.isEmpty {
                    section("pulse.invitations")
                    ForEach(invitations) { e in invitationRow(e) }
                }
                section("pulse.recent")
                if active.isEmpty {
                    Text(LocalizedStringKey(pulse.loaded ? "pulse.recent.none" : "pulse.loading")).font(.callout).foregroundStyle(Theme.muted)
                        .padding(.vertical, 8)
                }
                ForEach(active) { e in
                    Button { open = PulseOpen(id: e.id) } label: { activeRow(e) }.buttonStyle(.plain)
                }
                Toggle(isOn: $party) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("pulse.party").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("pulse.party.sub").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .padding(14).background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14))
                Text("pulse.footer").font(.caption).foregroundStyle(Theme.faint).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 28)
        }
        .clipped()
        .modifier(DockSpace())
        .refreshable { await pulse.reload() }
        .task { await pulse.reload() }
        .onReceive(pulse.$openCircle) { id in if let id { open = PulseOpen(id: id); pulse.openCircle = nil } }
        .fullScreenCover(item: $open) { o in PulseMeetupScreen(token: token, me: me, circleID: o.id).tfColorScheme() }
        .sheet(isPresented: $creating) {
            PulseCreateView(token: token, me: me, instant: false) { c in creating = false; open = PulseOpen(id: c.id) }.tfColorScheme()
        }
        .sheet(isPresented: $instant) {
            PulseCreateView(token: token, me: me, instant: true) { c in instant = false; open = PulseOpen(id: c.id) }.tfColorScheme()
        }
        .sheet(isPresented: $capsules) { PulseCapsuleList(token: token, me: me).tfColorScheme() }
        .sheet(item: $sharingFor) { c in
            PulseShareSheet(circle: c, others: max(0, (pulse.circles.first { $0.id == c.id }?.going ?? 1) - 1)) { _ in
                sharingFor = nil
                open = PulseOpen(id: c.id)
            }
            .presentationDetents([.medium])
        }
    }

    private func findFriend() {
        if let e = active.first(where: { ($0.sharing ?? 0) > 0 && $0.circle.isOpen }) { open = PulseOpen(id: e.id) } else { note = NSLocalizedString("pulse.find.none", comment: "") }
    }

    private func section(_ key: String) -> some View {
        Text(LocalizedStringKey(key)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).padding(.top, 6).accessibilityAddTraits(.isHeader)
    }

    private func card(_ icon: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(LocalizedStringKey(title)).font(.subheadline.weight(.bold)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                Text(LocalizedStringKey(sub)).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(14)
            .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.soulCardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func invitationRow(_ e: PulseCircleEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(verbatim: e.circle.icon).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.circle.title ?? "").font(.headline).foregroundStyle(Theme.text)
                    Text(verbatim: String(format: NSLocalizedString("pulse.invited.by", comment: ""), pulse.name(e.invited_by ?? "")))
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                answer("pulse.join.share", primary: true) { await respond(e, "going"); sharingFor = e.circle }
                answer("pulse.join.noshare") { await respond(e, "going") }
            }
            HStack(spacing: 8) {
                answer("pulse.maybe") { await respond(e, "maybe") }
                answer("pulse.decline") { await respond(e, "declined") }
            }
        }
        .padding(14).background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14))
    }

    private func answer(_ key: String, primary: Bool = false, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(LocalizedStringKey(key)).font(.footnote.weight(.bold)).frame(maxWidth: .infinity, minHeight: 40)
                .background(primary ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(primary ? Theme.onAccent : Theme.text)
        }
        .buttonStyle(.plain)
    }

    /// Answering never shares a location: "Join & Share" answers going, then opens the share step.
    private func respond(_ e: PulseCircleEntry, _ r: String) async {
        _ = try? await APIClient.shared.pulsePost(token: token, circle: e.id, "respond", body: ["response": r])
        await pulse.reload()
    }

    private func activeRow(_ e: PulseCircleEntry) -> some View {
        let now = PulseRules.nowMs()
        let started = (e.circle.starts_at ?? 0) <= now
        let live = e.circle.isOpen && started
        return HStack(spacing: 12) {
            Text(verbatim: e.circle.icon).font(.title2).frame(width: 44, height: 44).background(Theme.active, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: e.circle.title ?? "").font(.subheadline.weight(.bold)).foregroundStyle(Theme.text).lineLimit(1)
                    if live {
                        Text("pulse.live").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.danger, in: Capsule())
                    }
                }
                Text(verbatim: String(format: NSLocalizedString("pulse.joined.sharing", comment: ""), e.going ?? 0, e.sharing ?? 0))
                    .font(.caption).foregroundStyle(Theme.muted)
                Text(verbatim: timeLine(e.circle, now: now)).font(.caption2).foregroundStyle(Theme.faint)
            }
            Spacer()
            if sharer.isSharing(e.id) { Image(systemName: "location.fill").foregroundStyle(Theme.accent) }
            Image(systemName: "chevron.forward").foregroundStyle(Theme.faint)
        }
        .padding(12).background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14))
        .opacity(e.circle.isOpen ? 1 : 0.6)
    }

    private func timeLine(_ c: PulseCircle, now: Int64) -> String {
        if !c.isOpen { return NSLocalizedString("pulse.ended", comment: "") }
        if let s = c.starts_at, s > now { return String(format: NSLocalizedString("pulse.starts.in", comment: ""), PulseRules.countdown(s - now)) }
        if let e = c.expires_at { return String(format: NSLocalizedString("pulse.ends.in", comment: ""), PulseRules.countdown(e - now)) }
        return ""
    }
}

/// "Share your live location": who sees it, until when, nothing kept. The order is the sharer's: permission, first fix,
/// consent, positions.
struct PulseShareSheet: View {
    let circle: PulseCircle
    let others: Int
    let onDone: (Bool) -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("pulse.share.title").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 8) {
                Label(String(format: NSLocalizedString("pulse.share.who", comment: ""), others), systemImage: "person.2")
                Label("pulse.share.until", systemImage: "clock")
                Label("pulse.share.kept", systemImage: "trash")
            }
            .font(.callout).foregroundStyle(Theme.muted)
            ForEach([(15, "pulse.share.15"), (60, "pulse.share.60"), (0, "pulse.share.end")], id: \.0) { m in
                Button { Task { await share(m.0) } } label: {
                    Text(LocalizedStringKey(m.1)).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if busy { ProgressView().frame(maxWidth: .infinity) }
            if let error { Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger) }
            Button("notes.cancel") { onDone(false) }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(20)
        .background(Theme.soul.ignoresSafeArea())
    }

    private func share(_ minutes: Int) async {
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
                                     onTapPlace: { name, c in pin = c; place = name })
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
