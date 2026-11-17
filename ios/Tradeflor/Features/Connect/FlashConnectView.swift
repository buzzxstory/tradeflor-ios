import SwiftUI
import CoreImage.CIFilterBuiltins

/// Flash Connect (website FlashConnect.tsx): "Connect with people, groups and events instantly using QR." Tiles Scan QR,
/// My QR, Group QR, Event Connect and the Mutual Connect card.
struct FlashConnectView: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var target: FlashTarget?
    @State private var showMutual = false
    @ObservedObject private var hub = FlashHub.shared

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
                        Button { scanning = true } label: { tile("qrcode.viewfinder", "fc.scan", "fc.scan.sub") }
                        NavigationLink { MyQRView() } label: { tile("qrcode", "fc.myqr", "fc.myqr.sub") }
                        NavigationLink { GroupQRView() } label: { tile("person.3", "fc.groupqr", "fc.groupqr.sub") }
                        NavigationLink { EventConnectView(onOpen: open) } label: { tile("calendar.badge.plus", "fc.event", "fc.event.sub") }
                    }
                    .buttonStyle(.plain)
                    NavigationLink { MutualConnectView(onOpen: open) } label: {
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
            .navigationDestination(isPresented: $showMutual) { MutualConnectView(onOpen: open) }
        }
        .onAppear {
            hub.screenAppeared()
            #if DEBUG
            switch ProcessInfo.processInfo.environment["TF_CI_FLASH"] {
            case "scan"?: scanning = true
            case "mutual"?: showMutual = true
            default: break
            }
            #endif
        }
        .onDisappear { hub.screenGone() }
        // someone scanned my code: the Connection Request, here (a sheet can't open over this sheet from the root)
        .sheet(item: Binding(get: { hub.screens > 0 ? hub.request : nil }, set: { if $0 == nil, let r = hub.request { hub.answered(r.id) } })) { r in
            ConnectionRequestSheet(request: r, onOpen: open).environmentObject(store)
        }
        .fullScreenCover(isPresented: $scanning) {
            QRScannerView(onMutual: {
                scanning = false
                showMutual = true
            }) { text in
                scanning = false
                target = FlashTarget.parse(text)
            }
        }
    }

    private func open(_ c: ConversationSummary) {
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

/// My Connect Code (website MutualConnect.tsx, 9256375): a 60-second, single-use code for someone next to you. It renews
/// itself 1.5 s before it expires while this screen is open and the app is in front (never in the background); an older
/// answer never replaces a newer code (each request has a number); "Try again" only when renewing failed. Someone scanning
/// it only asks: the Connection Request (FlashHub) comes up and you Accept or Decline.
struct MutualConnectView: View {
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: MutualSession?
    @State private var deadline: Date?
    @State private var now = Date()
    @State private var busy = false
    @State private var error: String?
    @State private var seq = 0
    @State private var copied: String?

    private var token: String { store.session?.token ?? "" }
    private var left: Int { deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? 0 }
    private var expired: Bool { deadline != nil && left == 0 }
    private var link: String? { session?.token.flatMap { expired ? nil : "https://app.tradeflor.com/?mutual=\($0)" } }
    private let cyan = Theme.hex(0x35E6F2)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.hex(0x082231), Theme.hex(0x061A27), Theme.hex(0x04121D)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.hex(0x127080, 0.34), .clear], center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Theme.hex(0x0A5C6E, 0.32), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 320)
            VStack(spacing: 0) {
                HStack {
                    round("chevron.left", "fc.back") { dismiss() }
                    Spacer()
                    HStack(spacing: 10) {
                        Image("BrandFlower").resizable().scaledToFit().frame(width: 36, height: 36)
                        Text("TRADEFLOR").font(.system(size: 20, weight: .heavy)).tracking(3).foregroundStyle(Theme.hex(0xEEF6FA))
                    }
                    Spacer()
                    round("xmark", "chat.close") { dismiss() }
                }
                .padding(.top, 8)
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 28)).foregroundStyle(cyan)
                            (Text("mc.title.a").foregroundColor(Theme.hex(0xF2F8FB)) + Text("mc.title.b").foregroundColor(cyan))
                                .font(.system(size: 28, weight: .heavy)).minimumScaleFactor(0.7).lineLimit(1)
                        }
                        .padding(.top, 18)
                        Text("mc.lead2").font(.system(size: 15)).foregroundStyle(Theme.hex(0xC4D5DF)).multilineTextAlignment(.center)
                        stage.padding(.top, 8)
                        meta
                        if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.hex(0xFF8A8A)).multilineTextAlignment(.center) }
                    }
                    .frame(maxWidth: .infinity)
                }
                bottom.padding(.bottom, 16)
            }
            .padding(.horizontal, 22)
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await fresh() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                now = Date()
            }
        }
        // renew by itself 1.5 s before expiry, and at once when the app comes back with a code about to die; never in the background
        .task(id: "\(session?.id ?? "")|\(scenePhase == .active)") {
            guard scenePhase == .active, let d = deadline else { return }
            let wait = d.timeIntervalSinceNow - 1.5
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if Task.isCancelled || scenePhase != .active { return }
            await fresh()
        }
    }

    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.hex(0xF2F8FB))
                .frame(width: 48, height: 48).background(Theme.hex(0x041019, 0.7), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private var stage: some View {
        let side: CGFloat = min(268, UIScreen.main.bounds.width * 0.62)
        return ZStack {
            Circle().fill(RadialGradient(colors: [cyan.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: side * 0.9))
                .frame(width: side * 1.6, height: side * 1.6)
            Group {
                if let link, let qr = TFQR.image(link) {
                    Image(uiImage: qr).interpolation(.none).resizable().padding(14)
                        .overlay(Image("BrandFlower").resizable().scaledToFit().frame(width: side * 0.16)
                            .padding(5).background(.white, in: RoundedRectangle(cornerRadius: 8)))
                        .accessibilityLabel(Text("mc.qr"))
                } else if expired {
                    VStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 34)).foregroundStyle(Theme.hex(0x4A5A64))
                        Text(LocalizedStringKey(busy ? "mc.renewing" : "mc.expired.title")).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.hex(0x0B1F2A))
                        Text(LocalizedStringKey(busy ? "mc.renewing.sub" : "mc.expired.sub2")).font(.system(size: 12)).foregroundStyle(Theme.hex(0x4A5A64)).multilineTextAlignment(.center)
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.hex(0x0B6E7A))
                        Text(LocalizedStringKey(error == nil ? "mc.creating" : "mc.nocode")).font(.system(size: 13)).foregroundStyle(Theme.hex(0x4A5A64))
                    }
                }
            }
            .frame(width: side, height: side)
            .background(.white, in: RoundedRectangle(cornerRadius: 22))
            .opacity(expired ? 0.92 : 1)
            ForEach(0..<4, id: \.self) { k in
                CornerMark().stroke(cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(Double(k) * 90))
                    .offset(x: (k == 0 || k == 3 ? -1 : 1) * (side / 2 + 12), y: (k < 2 ? -1 : 1) * (side / 2 + 12))
                    .shadow(color: cyan.opacity(0.6), radius: 6)
            }
        }
        .frame(height: side + 60)
    }

    /// "Expires in 57s | Single use | Auto refresh"
    private var meta: some View {
        HStack(spacing: 10) {
            Group {
                if session != nil && !expired {
                    (Text("mc.expires.in") + Text(" \(left)s").bold()).foregroundColor(left <= 10 ? Theme.hex(0xFFB35C) : Theme.hex(0xC4D5DF))
                } else if expired {
                    Text("mc.expired").bold().foregroundColor(Theme.hex(0xFF8A8A))
                } else {
                    Text("mc.expires.dash").foregroundColor(Theme.hex(0xC4D5DF))
                }
            }
            sep
            Label("mc.single", systemImage: "checkmark.shield").foregroundStyle(Theme.hex(0xC4D5DF))
            sep
            Label(LocalizedStringKey(busy ? "mc.refreshing" : "mc.auto"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(busy ? cyan : Theme.hex(0xC4D5DF))
        }
        .font(.system(size: 13.5))
        .lineLimit(1).minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    private var sep: some View { Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 16) }

    @ViewBuilder private var bottom: some View {
        VStack(spacing: 8) {
            if error != nil {
                // renewing failed: the one moment a button is needed
                Button { Task { await fresh() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 20, weight: .semibold))
                        Text(LocalizedStringKey(busy ? "mc.trying" : "mc.tryagain")).font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(Theme.hex(0x03222B))
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(LinearGradient(colors: [Theme.hex(0x5FF2FA), Theme.hex(0x16C9DA)], startPoint: .top, endPoint: .bottom), in: Capsule())
                    .shadow(color: cyan.opacity(0.35), radius: 14, y: 6)
                }
                .disabled(busy)
            } else {
                HStack(spacing: 10) {
                    if let link, let url = URL(string: link) {
                        ShareLink(item: url, subject: Text("mc.share.title"), message: Text("mc.share.msg")) { shareLabel }
                    } else {
                        shareLabel.opacity(0.5)
                    }
                    Button {
                        guard let link else { return }
                        UIPasteboard.general.string = link
                        copied = NSLocalizedString("mc.copied", comment: "")
                        Task {
                            try? await Task.sleep(nanoseconds: 2_600_000_000)
                            copied = nil
                        }
                    } label: {
                        Label("mc.copy", systemImage: "doc.on.doc").font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(Theme.hex(0xF2F8FB))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Theme.hex(0x041019, 0.7), in: Capsule())
                            .overlay(Capsule().stroke(cyan.opacity(0.45), lineWidth: 1))
                    }
                    .disabled(link == nil)
                    .accessibilityIdentifier("mc.copy")
                }
            }
            Text(copied ?? " ").font(.system(size: 12.5)).foregroundStyle(cyan).multilineTextAlignment(.center)
        }
    }

    private var shareLabel: some View {
        Label("mc.share", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(Theme.hex(0x03222B))
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(LinearGradient(colors: [Theme.hex(0x5FF2FA), Theme.hex(0x16C9DA)], startPoint: .top, endPoint: .bottom), in: Capsule())
            .shadow(color: cyan.opacity(0.3), radius: 10, y: 4)
    }

    /// A new code; one request at a time, and an older answer is dropped. The countdown runs on the server's clock.
    private func fresh() async {
        guard !busy else { return }
        seq += 1
        let my = seq
        busy = true
        error = nil
        defer { busy = false }
        do {
            let s = try await APIClient.shared.ctStartMutual(token: token)
            guard my == seq else { return }
            guard s.token != nil else { error = NSLocalizedString("mc.err", comment: ""); return }
            let got = Date().timeIntervalSince1970
            let offset = s.server_now.map { Double($0) - got } ?? 0
            session = s
            deadline = Date(timeIntervalSince1970: Double(s.expires_at) - offset)
            now = Date()
        } catch {
            // a code still on screen stays valid until its own expiry
            guard my == seq else { return }
            switch error as? APIError {
            case .rateLimited?: self.error = NSLocalizedString("mc.err.rate", comment: "")
            case .badCredentials?: self.error = NSLocalizedString("sc.err.signin", comment: "")
            case .network?: self.error = NSLocalizedString("sc.err.offline", comment: "")
            case .refused(let why)?: self.error = why.isEmpty || why.count >= 140 ? NSLocalizedString("mc.err.403", comment: "") : why
            default: self.error = NSLocalizedString("mc.err", comment: "")
            }
        }
    }
}

/// One corner of the QR frame (top-left; rotated for the others).
private struct CornerMark: Shape {
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
