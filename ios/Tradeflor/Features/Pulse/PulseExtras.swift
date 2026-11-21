import SwiftUI
import CoreImage.CIFilterBuiltins
import PhotosUI

// MARK: Safety center

/// Stop here / everywhere, leave, block; an alert to chosen people (location off by default); SOS opens the same countdown
/// as the map's SOS button (one key, pauses in the background, one snapshot, audit 2); the delivery shown honestly, and the
/// emergency note: Tradeflor does not contact emergency services.
struct PulseSafetyCenter: View {
    let token: String
    let me: String
    let circleID: String
    let members: [PulseMember]
    let people: [String: PulsePerson]
    let sharingHere: Bool
    let onLeave: () -> Void
    /// the organizer has no Leave here (for them it ended the meetup for everyone, under a "Leave" label; web hides it)
    var isOrganizer = false
    /// an ended meetup: no alert and no SOS (the server answers 410)
    var ended = false
    /// an alert or an SOS went out: the meetup reloads (its banner and the SOS button come from the view)
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var to = Set<String>()
    @State private var text = ""
    @State private var withLocation = false
    @State private var sent: PulseAlert?
    @State private var delivery: [PulseAlertDelivery] = []
    @State private var sosCountdown = false
    @State private var error: String?
    @State private var blocking: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if sharingHere {
                        Button { Task { await PulseSharer.shared.stop(circleID); dismiss() } } label: { Label("pulse.safety.stophere", systemImage: "location.slash") }
                    }
                    Button { Task { await PulseSharer.shared.stopAll(); dismiss() } } label: { Label("pulse.safety.stopall", systemImage: "location.slash.fill") }
                    if !isOrganizer {
                        Button(role: .destructive) { onLeave() } label: { Label("pulse.leave", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                    Menu {
                        ForEach(members) { m in Button(name(m.user_id)) { blocking = m.user_id } }
                    } label: { Label("pulse.safety.block", systemImage: "hand.raised") }
                } header: { Text("pulse.safety.yourlocation") }

                if !ended {
                Section {
                    ForEach(members) { m in
                        Button { if to.contains(m.user_id) { to.remove(m.user_id) } else { to.insert(m.user_id) } } label: {
                            HStack {
                                Text(verbatim: name(m.user_id)).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: to.contains(m.user_id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    TextField(NSLocalizedString("pulse.safety.message", comment: ""), text: $text, axis: .vertical)
                    Toggle("pulse.safety.withloc", isOn: $withLocation)
                    Button { Task { await send("safety") } } label: { Label("pulse.safety.send", systemImage: "exclamationmark.bubble.fill") }
                        .disabled(to.isEmpty)
                    // SOS: the same countdown as the map's button (never sent by one tap)
                    Button { sosCountdown = true } label: {
                        Text("pulse.safety.sos2")
                            .font(.headline.weight(.heavy)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Theme.danger, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(SOSCenter.shared.active.contains { $0.isActive && $0.user_id == me && $0.circle_id == circleID })
                    if let error { Text(verbatim: error).foregroundStyle(Theme.danger).font(.footnote) }
                    if sent != nil {
                        ForEach(delivery, id: \.user_id) { d in
                            HStack {
                                Text(verbatim: name(d.user_id))
                                Spacer()
                                Text(LocalizedStringKey(d.seen ? "pulse.safety.seen" : d.reached ? "pulse.safety.reached" : "pulse.safety.notyet"))
                                    .font(.caption).foregroundStyle(d.seen ? Theme.online : Theme.muted)
                            }
                        }
                    }
                } header: { Text("pulse.safety.alert") }
                }

                Section {
                    Text("pulse.safety.emergency").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle(Text("pulse.safety"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .confirmationDialog(Text("pulse.safety.block.q"), isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible) {
                Button("pulse.safety.block", role: .destructive) {
                    if let u = blocking {
                        Task {
                            do {
                                try await APIClient.shared.block(token: token, userID: u)
                                await PulseStore.shared.reload()
                                onSent() // the meetup reloads without them
                                dismiss()
                            } catch {
                                self.error = NSLocalizedString("pulse.err.other", comment: "")
                            }
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $sosCountdown) {
            PulseSOSCountdown(others: members.count) { reason, key, attach in
                sosCountdown = false
                Task {
                    if await SOSCenter.shared.sendFromCountdown(circle: circleID, reason: reason, key: key, attach: attach) != nil {
                        onSent()
                        dismiss()
                    } else {
                        error = NSLocalizedString("pulse.sos.failed", comment: "")
                    }
                }
            } onCancel: { sosCountdown = false }
        }
        .task(id: sent?.id) {
            // the delivery, honestly: reached their app / saw it
            guard let a = sent else { return }
            while !Task.isCancelled {
                struct D: Decodable { var delivery: [PulseAlertDelivery]? }
                if let d = try? await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(a.id))", token: token),
                   let r = try? JSONDecoder().decode(D.self, from: d) { delivery = r.delivery ?? [] }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func name(_ id: String) -> String { people[id]?.name ?? PulseStore.shared.name(id) }

    private func send(_ kind: String) async {
        let recipients = to.isEmpty ? members.map(\.user_id) : Array(to)
        var body: [String: Any] = ["kind": kind, "text": PulseRules.runes(text, 200), "to": recipients]
        // a fresh reading only (at most 2 minutes old, with its time and source), or none (audit 11)
        if withLocation, let l = await PulseSharer.shared.snapshotFix(maxWait: 3) { body["position"] = SOSCenter.snapshot(l) }
        do {
            let d = try await APIClient.shared.pulsePost(token: token, circle: circleID, "alerts", body: body)
            struct R: Decodable { var alert: PulseAlert; var delivery: [PulseAlertDelivery]? }
            let r = try JSONDecoder().decode(R.self, from: d)
            sent = r.alert
            delivery = r.delivery ?? []
            error = nil
            onSent()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = NSLocalizedString((error as? PulseHTTPError)?.status == 429 ? "pulse.safety.toomany" : "pulse.err.other", comment: "")
        }
    }
}

/// A safety alert sent to me: over everything until "I've seen it".
struct PulseAlertScreen: View {
    let token: String
    let alert: PulseAlert
    let onSeen: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: alert.kind == "sos" ? "sos.circle.fill" : "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.white)
            Text(verbatim: String(format: NSLocalizedString(alert.kind == "sos" ? "pulse.alert.sos" : "pulse.alert.safety", comment: ""),
                                  PulseStore.shared.name(alert.sender_id ?? "")))
                .font(.title2.weight(.heavy)).multilineTextAlignment(.center)
            if let t = alert.text, !t.isEmpty { Text(verbatim: t).font(.title3).multilineTextAlignment(.center) }
            if let p = alert.position {
                Button {
                    if let u = URL(string: "http://maps.apple.com/?ll=\(p.lat),\(p.lon)&q=\(NSLocalizedString("pulse.alert.here", comment: "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") { UIApplication.shared.open(u) }
                } label: { Label("pulse.alert.location", systemImage: "map").font(.headline) }
            }
            Text("pulse.safety.emergency").font(.footnote).multilineTextAlignment(.center).opacity(0.85)
            Button {
                Task {
                    _ = try? await APIClient.shared.pulseCall("pulse/alerts/\(APIClient.pSeg(alert.id))/seen", method: "POST", token: token, body: [:])
                    onSeen()
                }
            } label: {
                Text("pulse.alert.seen").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 56)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.danger.ignoresSafeArea())
        .interactiveDismissDisabled()
    }
}

// MARK: Instant Circle

/// The QR (CoreImage), its countdown, New code, Turn off, Share link; "I approve each person" on by default; the requests.
struct PulseInstantCodeSheet: View {
    let token: String
    let circleID: String
    let people: [String: PulsePerson]
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var expires: Int64 = 0
    @State private var approval = true
    @State private var requests: [String] = []
    @State private var names: [String: PulsePerson] = [:]
    @State private var now = Date()
    @State private var error: String?
    /// The QR, drawn once per code (it was drawn again, with a new CIContext, every second the countdown ticked)
    @State private var qrImage: UIImage?
    /// one timer for the sheet (one written in body is made again on every redraw)
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var link: String { "https://app.tradeflor.com/?pulse=" + (code ?? "") }
    private var left: Int64 { max(0, expires - Int64(now.timeIntervalSince1970 * 1000)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // an expired code is not shown to be scanned (it only answered "expired"): make a new one (web)
                    if let code, !code.isEmpty, expires > 0, left == 0 {
                        Text("pulse.code.expired").font(.headline).multilineTextAlignment(.center)
                        Button { Task { await newCode() } } label: { Label("pulse.code.make", systemImage: "qrcode").frame(minHeight: 44) }.buttonStyle(.borderedProminent)
                    } else if let code, !code.isEmpty, let img = qrImage {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel(Text("pulse.code.qr"))
                        Text(verbatim: String(format: NSLocalizedString("pulse.code.valid", comment: ""), PulseRules.countdown(left))).font(.headline)
                        HStack {
                            ShareLink(item: link) { Label("pulse.code.share", systemImage: "square.and.arrow.up") }
                            Button { Task { await newCode() } } label: { Label("pulse.code.new", systemImage: "arrow.clockwise") }
                            Button(role: .destructive) {
                                Task {
                                    // shown as off only once the server turned it off (it said off even when that failed)
                                    do {
                                        try await APIClient.shared.pulseDelete(token: token, path: "pulse/circles/\(APIClient.pSeg(circleID))/code")
                                        self.code = nil
                                    } catch {
                                        self.error = NSLocalizedString("pulse.err.other", comment: "")
                                    }
                                }
                            } label: {
                                Label("pulse.code.off", systemImage: "xmark.circle")
                            }
                        }
                        .font(.footnote.weight(.semibold)).buttonStyle(.bordered)
                    } else {
                        Button { Task { await newCode() } } label: { Label("pulse.code.make", systemImage: "qrcode").frame(minHeight: 44) }.buttonStyle(.borderedProminent)
                    }
                    Toggle("pulse.code.approval", isOn: $approval).onChange(of: approval) { _ in if code != nil { Task { await newCode() } } }
                    Text("pulse.code.note").font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    if !requests.isEmpty {
                        Text("pulse.code.requests").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(requests, id: \.self) { u in
                            HStack {
                                Text(verbatim: names[u]?.name ?? people[u]?.name ?? "")
                                Spacer()
                                Button("pulse.code.letin") { Task { await decide(u, true) } }.buttonStyle(.borderedProminent)
                                Button("pulse.decline") { Task { await decide(u, false) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                    if let error { Text(verbatim: error).foregroundStyle(Theme.danger) }
                }
                .padding(20)
            }
            .navigationTitle(Text("pulse.card.instant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .onReceive(ticker) { now = $0 }
        .onChange(of: code) { c in qrImage = (c ?? "").isEmpty ? nil : Self.qr(link) }
        .onReceive(PulseStore.shared.frames.filter { [circleID] d in (d["circle_id"] as? String) == circleID && (d["e"] as? String) == "request" }) { _ in
            Task { await loadRequests() }
        }
        .task { await newCode(); await loadRequests() }
    }

    private static let qrContext = CIContext()

    static func qr(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = qrContext.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func newCode() async {
        struct C: Decodable { var token: String; var expires_at: Int64?; var approval: Bool? }
        do {
            let d = try await APIClient.shared.pulsePost(token: token, circle: circleID, "code", body: ["approval": approval, "minutes": 15])
            let c = try JSONDecoder().decode(C.self, from: d)
            code = c.token
            expires = c.expires_at ?? 0
            error = nil
        } catch {
            self.error = NSLocalizedString("pulse.err.other", comment: "")
        }
    }

    private func loadRequests() async {
        struct R: Decodable { var requests: [String]?; var people: [String: PulsePerson]? }
        guard let d = try? await APIClient.shared.pulseCall("pulse/circles/\(APIClient.pSeg(circleID))/requests", token: token),
              let r = try? JSONDecoder().decode(R.self, from: d) else { return }
        requests = r.requests ?? []
        names.merge(r.people ?? [:]) { _, n in n }
    }

    private func decide(_ u: String, _ approve: Bool) async {
        _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "requests/\(APIClient.pSeg(u))", body: ["approve": approve])
        await loadRequests()
    }
}

/// "Join a Pulse circle" from a link or a scanned code. Joining never shares a location.
struct PulseJoinSheet: View {
    let token: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var preview: PulseCodePreview?
    @State private var names: [String: PulsePerson] = [:]
    @State private var state: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("pulse.join.title").font(.headline)
            if let p = preview {
                Text(verbatim: PulseRules.activityIcon[p.activity ?? ""] ?? "📍").font(.system(size: 48))
                Text(verbatim: p.title ?? "").font(.title2.weight(.bold))
                if let d = p.dest_name, !d.isEmpty { Label(d, systemImage: "mappin") }
                Text(verbatim: String(format: NSLocalizedString("pulse.join.by", comment: ""), names[p.organizer_id ?? ""]?.name ?? "")).foregroundStyle(Theme.muted)
                Text("pulse.join.nolocation").font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if let state {
                    Text(LocalizedStringKey(state == "requested" ? "pulse.join.requested" : "pulse.join.joined")).foregroundStyle(Theme.accent)
                } else {
                    Button { Task { await join(p) } } label: {
                        Text("pulse.join.go").font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.plain)
                }
            } else if let error {
                Text(verbatim: error).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
            Button("chat.close") { dismiss() }
        }
        .padding(24)
        .presentationDetents([.medium])
        .task {
            do {
                let r = try await APIClient.shared.pulseCodePreview(token: token, code: code)
                preview = r.0
                names = r.1
            } catch let e as PulseHTTPError {
                error = NSLocalizedString(e.status == 410 ? "pulse.join.expired" : "pulse.join.invalid", comment: "")
            } catch {
                self.error = NSLocalizedString("pulse.err.other", comment: "")
            }
        }
    }

    private func join(_ p: PulseCodePreview) async {
        struct J: Decodable { var circle_id: String; var response: String? }
        do {
            let d = try await APIClient.shared.pulseCall("pulse/codes/\(APIClient.pSeg(code))/join", method: "POST", token: token, body: [:])
            let j = try JSONDecoder().decode(J.self, from: d)
            state = j.response ?? "going"
            await PulseStore.shared.reload()
            if state == "going" {
                dismiss()
                PulseStore.shared.openCircle = j.circle_id
                TradeFlorView.go("tradeflor")
            }
        } catch let e as PulseHTTPError {
            error = NSLocalizedString(e.status == 403 ? "pulse.join.removed" : e.status == 410 ? "pulse.join.expired" : "pulse.err.other", comment: "")
            preview = nil
        } catch {
            self.error = NSLocalizedString("pulse.err.other", comment: "")
        }
    }
}

/// Invite more people (organizer).
struct PulseInviteMore: View {
    let token: String
    let circleID: String
    let already: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [ConversationSummary] = []
    @State private var chosen = Set<String>()

    var body: some View {
        NavigationStack {
            List(friends.filter { !already.contains($0.peer_id) }) { f in
                Button { if chosen.contains(f.peer_id) { chosen.remove(f.peer_id) } else { chosen.insert(f.peer_id) } } label: {
                    HStack {
                        Text(verbatim: f.peer_display_name ?? f.peer_username).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: chosen.contains(f.peer_id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent)
                    }
                    .frame(minHeight: 44)
                }
            }
            .navigationTitle(Text("pulse.more.invite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("notes.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("pulse.invite.send") {
                        Task {
                            _ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, "invite", body: ["user_ids": Array(chosen)])
                            dismiss()
                        }
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
        .task { friends = ((try? await APIClient.shared.conversations(token: token)) ?? []).filter { !$0.peer_id.isEmpty && !$0.conversation_id.hasPrefix("grp_") } }
    }
}

// MARK: Time Capsule

/// The meetups that ended (and their photos), from the Pulse home.
struct PulseCapsuleList: View {
    let token: String
    let me: String
    @Environment(\.dismiss) private var dismiss
    @State private var circles: [PulseCircleEntry] = []
    @State private var open: PulseCircle?

    var body: some View {
        NavigationStack {
            List(circles) { e in
                Button { open = e.circle } label: {
                    HStack {
                        Text(verbatim: e.circle.icon)
                        Text(verbatim: e.circle.title ?? "").foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "photo.stack").foregroundStyle(Theme.accent)
                    }
                    .frame(minHeight: 44)
                }
            }
            .overlay { if circles.isEmpty { Text("pulse.capsule.none").foregroundStyle(Theme.muted) } }
            .navigationTitle(Text("pulse.card.capsule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .task { circles = (try? await APIClient.shared.pulseCircles(token: token, ended: true))?.circles ?? [] }
        .sheet(item: $open) { c in PulseCapsuleView(token: token, me: me, circleID: c.id, title: c.title ?? "") }
    }
}

/// A meetup's photos: the grid, add a photo (re-saved on the device without hidden data; the server redraws it too), remove
/// my own. Only people who took part see it, during the meetup and 7 days after.
struct PulseCapsuleView: View {
    let token: String
    let me: String
    let circleID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PulseCapsuleItem] = []
    @State private var names: [String: PulsePerson] = [:]
    @State private var images: [String: UIImage] = [:]
    @State private var pick: PhotosPickerItem?
    @State private var caption = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        PhotosPicker(selection: $pick, matching: .images) { Label("pulse.capsule.add", systemImage: "plus.circle.fill") }
                        TextField(NSLocalizedString("pulse.capsule.caption", comment: ""), text: $caption).textFieldStyle(.roundedBorder)
                    }
                    if busy { ProgressView() }
                    if let error { Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger) }
                    Text("pulse.capsule.note").font(.caption).foregroundStyle(Theme.muted)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(items) { it in
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack {
                                    Theme.card
                                    if let img = images[it.id] { Image(uiImage: img).resizable().scaledToFill() } else { ProgressView() }
                                }
                                .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(verbatim: (names[it.user_id ?? ""]?.name ?? "") + (it.caption.map { " · " + $0 } ?? "")).font(.caption).lineLimit(2)
                            }
                            .contextMenu {
                                if it.user_id == me {
                                    Button(role: .destructive) { Task { try? await APIClient.shared.pulseDelete(token: token, path: "pulse/capsule/\(APIClient.pSeg(it.id))"); await load() } } label: {
                                        Label("pulse.capsule.remove", systemImage: "trash")
                                    }
                                }
                            }
                            .task(id: it.id) { await image(it.id) }
                        }
                    }
                }
                .padding(16)
            }
            .overlay { if items.isEmpty && !busy { Text("pulse.capsule.empty").foregroundStyle(Theme.muted) } }
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .task { await load() }
        .onChange(of: pick) { p in Task { await add(p) } }
    }

    private func load() async {
        struct C: Decodable { var items: [PulseCapsuleItem]?; var people: [String: PulsePerson]? }
        do {
            let d = try await APIClient.shared.pulseCall("pulse/circles/\(APIClient.pSeg(circleID))/capsule", token: token)
            let c = try JSONDecoder().decode(C.self, from: d)
            items = c.items ?? []
            names.merge(c.people ?? [:]) { _, n in n }
        } catch let e as PulseHTTPError where e.status == 404 || e.status == 410 {
            error = NSLocalizedString("pulse.capsule.closed", comment: "")
        } catch {}
    }

    private func image(_ id: String) async {
        guard images[id] == nil, let d = try? await APIClient.shared.pulseCall("pulse/capsule/\(APIClient.pSeg(id))/media", token: token),
              let img = StickerCache.downsample(d, maxPixel: 600) else { return }
        images[id] = img
    }

    /// The photo is drawn again on the device (no EXIF, no hidden GPS) before it is sent.
    private func add(_ p: PhotosPickerItem?) async {
        guard let p, let data = try? await p.loadTransferable(type: Data.self), let src = StickerCache.downsample(data, maxPixel: 2048) else { return }
        busy = true
        defer { busy = false; pick = nil }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        let clean = UIGraphicsImageRenderer(size: src.size, format: f).jpegData(withCompressionQuality: 0.85) { _ in src.draw(at: .zero) }
        do {
            _ = try await APIClient.shared.pulseUpload(token: token, path: "pulse/circles/\(APIClient.pSeg(circleID))/capsule",
                                                       fields: ["caption": PulseRules.runes(caption, 140)], fileField: "file", fileName: "photo.jpg",
                                                       mime: "image/jpeg", data: clean)
            caption = ""
            await load()
        } catch {
            self.error = NSLocalizedString("pulse.err.other", comment: "")
        }
    }
}
