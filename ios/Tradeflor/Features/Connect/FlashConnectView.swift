import SwiftUI
import CoreImage.CIFilterBuiltins

/// Flash Connect (website FlashConnect.tsx): "Connect with people, groups and events instantly using QR." Tiles Scan QR,
/// My QR, Group QR, Event Connect and the Mutual Connect card.
struct FlashConnectView: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var cover: ScanTab?
    @State private var target: FlashTarget?
    @ObservedObject private var hub = FlashHub.shared
    @State private var presenterID = "flash-" + UUID().uuidString

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.fill").font(.system(size: 20)).foregroundStyle(Theme.gold)
                        Text("fc.title").font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.text)
                    }
                    Text("fc.lead").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        Button { cover = .scan } label: { tile("qrcode.viewfinder", "fc.scan", "fc.scan.sub") }
                        NavigationLink { MyQRView() } label: { tile("qrcode", "fc.myqr", "fc.myqr.sub") }
                        NavigationLink { GroupQRView() } label: { tile("person.3", "fc.groupqr", "fc.groupqr.sub") }
                        NavigationLink { EventConnectView(onOpen: open) } label: { tile("calendar.badge.plus", "fc.event", "fc.event.sub") }
                    }
                    .buttonStyle(.plain)
                    Button { cover = .code } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("fc.mutual").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                                Text("fc.mutual.sub").font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward").foregroundStyle(Theme.faint)
                        }
                        .padding(14)
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderActive, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Starfield())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .navigationDestination(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                if let t = target { ScanResultView(target: t, onOpen: open, onDone: { dismiss() }) }
            }
        }
        .onAppear {
            hub.present(presenterID)
            #if DEBUG
            switch ProcessInfo.processInfo.environment["TF_CI_FLASH"] {
            case "scan"?: cover = .scan
            case "mutual"?: cover = .code
            default: break
            }
            #endif
        }
        .onDisappear { hub.unpresent(presenterID) }
        // someone scanned my code: the Connection Request, here (a sheet can't open over this sheet from the root)
        .sheet(item: hub.binding(for: presenterID)) { r in
            ConnectionRequestSheet(request: r, onOpen: open).environmentObject(store)
        }
        // Scan & Connect: one screen, two tabs (Scan QR | My Code)
        .fullScreenCover(item: $cover) { t in
            ScanConnectScreen(initial: t, onOpen: open) { text in
                cover = nil
                target = FlashTarget.parse(text)
            }
            .environmentObject(store)
        }
    }

    private func open(_ c: ConversationSummary) {
        cover = nil
        dismiss()
        onOpen(c)
    }

    private func tile(_ icon: String, _ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Theme.accent)
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(LocalizedStringKey(sub)).font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(14)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    static func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func qrCard(_ link: String) -> some View {
        Group {
            if let img = qr(link) {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

/// What a scanned code points to: a person (Connect / Accept / Request Sent → Connected!), a group invitation, an event.
struct ScanResultView: View {
    let target: FlashTarget
    let onOpen: (ConversationSummary) -> Void
    var onDone: (() -> Void)?
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var person: IdentityDetail?
    @State private var state = "loading" // loading | person | bad | sent | connected | group | meet
    @State private var meet: MeetupPeek?
    @State private var info: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        if case .mutual(let tok) = target {
            // Scan & Connect: confirm first (Connect / Cancel); never connect on scan
            ScrollView { MutualGuestView(tok: tok, onOpen: onOpen, onDone: { (onDone ?? { dismiss() })() }) }
                .background(Theme.soul.ignoresSafeArea())
                .navigationTitle(Text("sc.connect.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.soul, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            other
        }
    }

    private var other: some View {
        SettingsPage(title: NSLocalizedString("fc.scan", comment: "")) {
            switch state {
            case "loading":
                HStack { ProgressView().tint(Theme.accent); Text("fc.looking").foregroundStyle(Theme.faint) }
            case "bad":
                Text(info ?? NSLocalizedString("fc.notours", comment: "")).foregroundStyle(Theme.faint)
            case "group":
                Text(info ?? "").foregroundStyle(Theme.text)
            case "meet":
                if let m = meet {
                    TFCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(m.meetup.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                            Text(Date(timeIntervalSince1970: Double(m.meetup.starts_at)), style: .date).foregroundStyle(Theme.faint)
                            Button { Task { await joinMeet() } } label: {
                                Text("fc.event.join").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Theme.accent, in: Capsule())
                            }
                            if let info { Text(info).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                        }
                        .padding(14)
                    }
                }
            default:
                if let p = person { personCard(p) }
            }
        }
        .task { await resolve() }
    }

    private func personCard(_ p: IdentityDetail) -> some View {
        TFCard {
            VStack(spacing: 10) {
                Text("fc.user").font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(Theme.accent)
                Avatar(token: token, userID: p.user_id, avatarID: p.avatar_id, title: p.title, size: 80)
                Text(p.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text("@\(p.username) · \(p.pin)").font(.system(size: 13)).foregroundStyle(Theme.faint)
                if state == "connected" || p.relation == "contact" {
                    Text("fc.connected").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.online)
                    Button { Task { await openChat(p.user_id) } } label: {
                        Text("ct.message").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 44).background(Theme.accent, in: Capsule())
                    }
                } else if state == "sent" || p.relation == "requested" {
                    Text("fc.request.sent").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.faint)
                } else if p.relation == "self" {
                    Text("fc.own").foregroundStyle(Theme.faint)
                } else {
                    Button { Task { await connect(p) } } label: {
                        Text(LocalizedStringKey(p.relation == "incoming" ? "ct.accept.their" : "fc.connect")).bold().foregroundStyle(Theme.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 44).background(Theme.accent, in: Capsule())
                    }
                }
                if let info { Text(info).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private func resolve() async {
        do {
            switch target {
            case .user(let code): person = try await APIClient.shared.ctResolveCode(token: token, code: code); state = "person"
            case .pin(let pin): person = try await APIClient.shared.ctLookup(token: token, pin: pin); state = "person"
            case .username(let u):
                if u.isEmpty { state = "bad"; return }
                person = try await APIClient.shared.ctLookup(token: token, username: u); state = "person"
            case .mutual:
                return // MutualGuestView
            case .meet(let tok):
                meet = try await APIClient.shared.ctPeekMeetup(token: token, tok: tok)
                state = "meet"
            case .group(let tok):
                let id = try await APIClient.shared.joinGroup(token: token, link: tok.hasPrefix("g:")
                    ? "https://app.tradeflor.com/g/" + tok.dropFirst(2) : "https://app.tradeflor.com/join/" + tok)
                info = NSLocalizedString(id.isEmpty ? "group.join.pending" : "fc.group.joined", comment: "")
                state = "group"
            }
        } catch APIError.refused(let why) {
            info = why.isEmpty ? nil : why
            state = "bad"
        } catch {
            info = NSLocalizedString("fc.nomatch", comment: "")
            state = "bad"
        }
    }

    private func connect(_ p: IdentityDetail) async {
        do {
            try await APIClient.shared.ctConnect(token: token, userID: p.user_id)
            state = p.relation == "incoming" ? "connected" : "sent"
        } catch {
            info = NSLocalizedString("fc.send.failed", comment: "")
        }
    }

    private func joinMeet() async {
        guard case .meet(let tok) = target else { return }
        if (try? await APIClient.shared.ctJoinMeetup(token: token, tok: tok)) != nil {
            info = NSLocalizedString("fc.event.joined", comment: "")
        } else {
            info = NSLocalizedString("fc.event.inactive", comment: "")
        }
    }

    private func openChat(_ userID: String) async {
        if let s = await APIClient.shared.ctOpenChat(token: token, userID: userID) { onOpen(s) }
    }
}

/// My QR: my opaque connect code as a QR and link (never the PIN); reset makes old codes stop working.
struct MyQRView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var code: String?
    @State private var note: String?
    @State private var confirmReset = false

    private var link: String { "https://app.tradeflor.com/?connect=\(code ?? "")" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("fc.myqr", comment: "")) {
            VStack(spacing: 14) {
                if code != nil {
                    FlashConnectView.qrCard(link)
                    Text("@" + (store.session?.username ?? "")).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                    HStack(spacing: 10) {
                        ShareLink(item: link, message: Text("fc.share.msg")) {
                            Label("identity.share", systemImage: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.onAccent).padding(.horizontal, 16).frame(height: 40).background(Theme.accent, in: Capsule())
                        }
                        Button {
                            UIPasteboard.general.string = link
                            note = NSLocalizedString("fc.link.copied", comment: "")
                        } label: {
                            Label("fc.copy", systemImage: "doc.on.doc").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.accent).padding(.horizontal, 16).frame(height: 40)
                                .overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                        }
                    }
                    Button { confirmReset = true } label: { Text("fc.reset").font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent) }
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .confirmationDialog(Text("fc.reset"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button("fc.reset", role: .destructive) { Task { await reset() } }
        } message: { Text("fc.reset.msg") }
        .task { code = try? await APIClient.shared.ctMyCode(token: store.session?.token ?? "") }
    }

    private func reset() async {
        if let c = try? await APIClient.shared.ctRotateCode(token: store.session?.token ?? "") {
            code = c
            note = NSLocalizedString("fc.reset.done", comment: "")
        }
    }
}

/// One corner of the QR frame (top-left; rotated for the others).
struct CornerMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 8))
        p.addQuadCurve(to: CGPoint(x: r.minX + 8, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Group QR: choose a group, how long it works and how many may join, optional admin approval.
struct GroupQRView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var groups: [GroupSummary] = []
    @State private var groupID = ""
    @State private var hours = 24
    @State private var maxUses = 0
    @State private var approval = false
    @State private var link: String?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        SettingsPage(title: NSLocalizedString("fc.groupqr", comment: "")) {
            TFCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("fc.group", selection: $groupID) {
                        Text("fc.choose.group").tag("")
                        ForEach(groups) { g in Text(g.name).tag(g.conversation_id) }
                    }
                    .tint(Theme.accent)
                    Picker("fc.works.for", selection: $hours) {
                        Text("fc.1h").tag(1)
                        Text("fc.1d").tag(24)
                        Text("fc.7d").tag(168)
                        Text("fc.never").tag(0)
                    }
                    .tint(Theme.accent)
                    Picker("fc.max.joins", selection: $maxUses) {
                        Text("fc.nolimit").tag(0)
                        Text("1").tag(1)
                        Text("10").tag(10)
                        Text("100").tag(100)
                    }
                    .tint(Theme.accent)
                    Toggle(isOn: $approval) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("fc.approval").foregroundStyle(Theme.text)
                            Text("fc.approval.sub").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                    }
                    .tint(Theme.accent)
                }
                .foregroundStyle(Theme.text)
                .padding(14)
            }
            Button { Task { await create() } } label: {
                Text(busy ? NSLocalizedString("fc.creating", comment: "") : NSLocalizedString(link == nil ? "fc.create.group" : "fc.newcode", comment: ""))
                    .bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 46).background(Theme.accent, in: Capsule())
            }
            .disabled(groupID.isEmpty || busy)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            if let link {
                VStack(spacing: 10) {
                    FlashConnectView.qrCard(link)
                    ShareLink(item: link) { Label("identity.share", systemImage: "square.and.arrow.up").foregroundStyle(Theme.accent) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task { groups = (try? await APIClient.shared.groups(token: store.session?.token ?? "")) ?? [] }
    }

    private func create() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            link = try await APIClient.shared.ctGroupInvite(token: store.session?.token ?? "", groupID: groupID, hours: hours, maxUses: maxUses, approval: approval)
        } catch {
            problem = NSLocalizedString("fc.cant.invite", comment: "")
        }
    }
}

/// Event Connect: create an event (within the next 7 days), show its code, see who joined, connect with them.
struct EventConnectView: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var events: [Meetup] = []
    @State private var title = ""
    @State private var starts = Date().addingTimeInterval(3600)
    @State private var problem: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("fc.event", comment: "")) {
            TFCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("fc.event.name", text: $title).foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).frame(height: 42).background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 10))
                    DatePicker("fc.starts", selection: $starts, in: Date()...Date().addingTimeInterval(7 * 86400)).tint(Theme.accent)
                        .foregroundStyle(Theme.text)
                    Button { Task { await create() } } label: {
                        Text("fc.event.create").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 42)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                .padding(14)
            }
            TFSectionLabel(text: NSLocalizedString("fc.your.events", comment: ""))
            if events.isEmpty {
                Text("fc.no.events").font(.system(size: 13)).foregroundStyle(Theme.faint)
            }
            ForEach(events) { e in
                NavigationLink { MeetupDetailView(meetup: e, onOpen: onOpen) } label: {
                    TFRow(icon: "calendar", title: e.title,
                          subtitle: Date(timeIntervalSince1970: Double(e.starts_at)).formatted(date: .abbreviated, time: .shortened) + " · \(e.attendees)")
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .task { await load() }
    }

    private func load() async { events = (try? await APIClient.shared.ctMeetups(token: token)) ?? [] }

    private func create() async {
        do {
            _ = try await APIClient.shared.ctCreateMeetup(token: token, title: title, startsAt: starts)
            title = ""
            await load()
        } catch {
            problem = NSLocalizedString("fc.event.check", comment: "")
        }
    }
}

struct MeetupDetailView: View {
    let meetup: Meetup
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var code: String?
    @State private var people: [IdentityDetail] = []
    @State private var revoked = false
    @State private var sent: Set<String> = []

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: meetup.title) {
            if meetup.is_host == true && !revoked {
                HStack(spacing: 10) {
                    Button { Task { code = try? await APIClient.shared.ctMeetupToken(token: token, id: meetup.id) } } label: {
                        Text(LocalizedStringKey(code == nil ? "fc.show.code" : "fc.newcode")).bold().foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 16).frame(height: 40).background(Theme.accent, in: Capsule())
                    }
                    Button {
                        Task {
                            if (try? await APIClient.shared.ctRevokeMeetup(token: token, id: meetup.id)) != nil { revoked = true; code = nil }
                        }
                    } label: { Text("fc.revoke").foregroundStyle(Theme.danger) }
                }
                if let code { FlashConnectView.qrCard("https://app.tradeflor.com/?meet=\(code)").frame(maxWidth: .infinity) }
            } else if meetup.is_host != true {
                Button { Task { try? await APIClient.shared.ctLeaveMeetup(token: token, id: meetup.id) } } label: {
                    Text("fc.leave").foregroundStyle(Theme.danger)
                }
            }
            if revoked { Text("fc.revoked").font(.system(size: 13)).foregroundStyle(Theme.faint) }
            TFSectionLabel(text: NSLocalizedString("fc.attendees", comment: ""))
            if people.isEmpty { Text("fc.nobody").font(.system(size: 13)).foregroundStyle(Theme.faint) }
            ForEach(people, id: \.user_id) { p in
                HStack(spacing: 10) {
                    Avatar(token: token, userID: p.user_id, avatarID: p.avatar_id, title: p.title, size: 40)
                    Text(p.title).foregroundStyle(Theme.text)
                    Spacer()
                    if p.relation == "contact" {
                        Button { Task { if let c = await APIClient.shared.ctOpenChat(token: token, userID: p.user_id) { onOpen(c) } } } label: {
                            Text("ct.message").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                    } else if p.relation == "requested" || sent.contains(p.user_id) {
                        Text("fc.sent").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    } else if p.relation != "self" {
                        Button {
                            Task {
                                if (try? await APIClient.shared.ctConnect(token: token, userID: p.user_id)) != nil { sent.insert(p.user_id) }
                            }
                        } label: {
                            Text(LocalizedStringKey(p.relation == "incoming" ? "new.accept" : "fc.connect")).font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.onAccent).padding(.horizontal, 12).frame(height: 30).background(Theme.accent, in: Capsule())
                        }
                    }
                }
                .padding(10)
                .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { people = (try? await APIClient.shared.ctMeetupPeople(token: token, id: meetup.id)) ?? [] }
    }
}
