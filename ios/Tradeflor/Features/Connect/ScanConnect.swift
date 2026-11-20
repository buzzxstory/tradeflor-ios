import SwiftUI
import Combine

// Scan & Connect V2 (website FlashConnect.tsx + MutualConnect.tsx, 9256375; contract docs/SCAN_CONNECT_API.md):
// Scan → Confirm → Connect. A code only asks; the host always answers (Accept / Decline). The socket event "flash" is a
// notification only: after it, or after a reconnect, the truth is GET /connect/sessions/{id} (guest) or /connect/pending (host).

/// Someone scanned my code: one request at a time, shown wherever I am (website FlashHost "approve").
@MainActor
final class FlashHub: ObservableObject {
    static let shared = FlashHub()

    struct Request: Identifiable, Equatable {
        let id: String // session_id
        let guest: IdentityDetail
        static func == (a: Request, b: Request) -> Bool { a.id == b.id }
    }

    @Published var request: Request?
    /// The Flash Connect screens open now, newest last; the newest shows the request itself (a sheet can't open over a
    /// sheet or a full-screen cover from below). None open: the root shows it.
    @Published private(set) var presenters: [String] = []
    /// Raw "flash" events, for a guest waiting on its own session.
    let events = PassthroughSubject<[String: Any], Never>()
    /// The live connection (re)opened: a guest re-reads its session.
    let reopened = PassthroughSubject<Void, Never>()
    private weak var live: LiveConnection?
    var liveConnected: Bool { live?.connected ?? false }

    private var token = ""
    private var answered: Set<String> = []
    /// The request this phone is answering now: its own "decided" echo must not close the "You're Connected!" screen.
    var deciding: String?
    private var subs: Set<AnyCancellable> = []

    func attach(live: LiveConnection, token: String) {
        guard self.token != token else { return }
        self.token = token
        self.live = live
        subs.removeAll()
        live.flash.receive(on: RunLoop.main).sink { [weak self] d in self?.handle(d) }.store(in: &subs)
        live.opened.receive(on: RunLoop.main).sink { [weak self] in
            self?.reopened.send()
            Task { await self?.askPending() }
        }.store(in: &subs)
        Task { await askPending() }
    }

    func detach() {
        subs.removeAll()
        token = ""
        request = nil
    }

    func present(_ id: String) { presenters.removeAll { $0 == id }; presenters.append(id) }
    func unpresent(_ id: String) { presenters.removeAll { $0 == id } }
    /// The request, for the screen `id` if it is the one that shows it now.
    func request(for id: String?) -> Request? { presenters.last == id ? request : nil }
    /// A binding for .sheet(item:): closing it without answering hides it here (it stays waiting on the server).
    func binding(for id: String?) -> Binding<Request?> {
        Binding(get: { self.request(for: id) }, set: { if $0 == nil, let r = self.request { self.answered(r.id) } })
    }

    /// Requests that wait for my answer (another device, a missed event, back from the background).
    func askPending() async {
        guard !token.isEmpty, request == nil,
              let list = try? await APIClient.shared.ctPendingMutual(token: token),
              let p = list.first(where: { !answered.contains($0.session_id) }) else { return }
        if request == nil { request = Request(id: p.session_id, guest: p.guest) }
    }

    func answered(_ id: String) {
        answered.insert(id)
        if request?.id == id { request = nil }
    }

    private func handle(_ d: [String: Any]) {
        events.send(d)
        let action = d["action"] as? String ?? ""
        let sid = d["session_id"] as? String ?? ""
        switch action {
        case "claimed":
            guard !sid.isEmpty, !answered.contains(sid), request?.id != sid,
                  let g = d["guest"] as? [String: Any], let guest = Self.card(g) else { return }
            request = Request(id: sid, guest: guest)
        case "decided":
            guard sid != deciding else { return }
            answered.insert(sid)
            if request?.id == sid { request = nil } // answered on another device
        default:
            break
        }
    }

    static func card(_ obj: [String: Any]) -> IdentityDetail? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(IdentityDetail.self, from: data)
    }

    /// The server's short answers (contract: 404 not valid, 410 expired, 409 used, 400 own code, 429, 403).
    static func errText(_ e: Error) -> String {
        guard let a = e as? APIError else { return NSLocalizedString("sc.err.generic", comment: "") }
        switch a {
        case .refused(let why) where !why.isEmpty && why.count < 140: return why
        case .server(status: 410): return NSLocalizedString("sc.err.expired", comment: "")
        case .server(status: 409): return NSLocalizedString("sc.err.used", comment: "")
        case .server(status: 404): return NSLocalizedString("sc.err.invalid", comment: "")
        case .rateLimited: return NSLocalizedString("sc.err.rate", comment: "")
        case .badCredentials: return NSLocalizedString("sc.err.signin", comment: "")
        case .network: return NSLocalizedString("sc.err.offline", comment: "")
        default: return NSLocalizedString("sc.err.generic", comment: "")
        }
    }
}

// MARK: shared look (website .fc-person / .fc-chip / .fc-btn)

struct ScanPerson: View {
    let card: IdentityDetail
    var size: CGFloat = 88
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(spacing: 6) {
            Avatar(token: store.session?.token ?? "", userID: card.user_id, avatarID: card.avatar_id, title: card.title, size: size)
                .padding(.bottom, 4)
            Text(card.title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.center)
            Text("@" + card.username).font(.system(size: 14)).foregroundStyle(Theme.faint)
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ScanChip: View {
    let key: String
    var tint: Color = Theme.accent
    var body: some View {
        Text(LocalizedStringKey(key)).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

struct ScanButton: View {
    let key: String
    var icon: String?
    var primary = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(primary ? Theme.onAccent : Theme.accent) }
                else if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)) }
                Text(LocalizedStringKey(key)).font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(primary ? Theme.onAccent : Theme.text)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(primary ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear), in: Capsule())
            .overlay(Capsule().stroke(primary ? Color.clear : Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: You're Connected! (both sides)

struct ConnectedCard: View {
    let peer: IdentityDetail
    let onOpenChat: () -> Void
    let onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @State private var opening = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 76, height: 76).background(Theme.online, in: Circle())
                .shadow(color: Theme.online.opacity(0.45), radius: 16)
                .padding(.top, 6)
            Text("sc.connected.title").font(.system(size: 24, weight: .heavy)).foregroundStyle(Theme.text)
            Text("sc.connected.sub").font(.system(size: 14)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
            Text(String(format: NSLocalizedString("sc.connected.pair", comment: ""), peer.title))
                .font(.system(size: 14)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            HStack(spacing: 0) {
                Avatar(token: store.session?.token ?? "", userID: store.session?.userID ?? "", avatarID: nil,
                       title: store.session?.username ?? "", size: 56)
                Rectangle().fill(LinearGradient(colors: [Theme.accent.opacity(0.2), Theme.accent, Theme.accent.opacity(0.2)],
                                                startPoint: .leading, endPoint: .trailing))
                    .frame(width: 64, height: 2)
                Avatar(token: store.session?.token ?? "", userID: peer.user_id, avatarID: peer.avatar_id, title: peer.title, size: 56)
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
            ScanButton(key: "sc.open.chat", icon: "bubble.left.and.bubble.right.fill", busy: opening) {
                opening = true
                onOpenChat()
            }
            .disabled(opening)
            ScanButton(key: "sc.done", primary: false, action: onDone)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
    }
}

// MARK: Connection Request (host)

struct ConnectionRequestSheet: View {
    let request: FlashHub.Request
    let onOpen: (ConversationSummary) -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var peer: IdentityDetail?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let peer {
                    ConnectedCard(peer: peer, onOpenChat: { Task { await openChat(peer) } }, onDone: close)
                } else {
                    VStack(spacing: 14) {
                        ScanPerson(card: request.guest)
                        Text(String(format: NSLocalizedString("fc.scanned.wants", comment: ""), request.guest.title))
                            .font(.system(size: 15)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                        if let error { Text(error).font(.system(size: 13)).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                        HStack(spacing: 12) {
                            ScanButton(key: "sc.decline", primary: false) { Task { await decide(false) } }
                            ScanButton(key: "sc.accept", busy: busy) { Task { await decide(true) } }
                        }
                        .disabled(busy)
                        .padding(.top, 4)
                    }
                    .padding(22)
                }
            }
            .clipped() // the bar and status bar show the page itself: rows stop under them, never a band of another colour
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(peer == nil ? "sc.request.title" : "sc.connected.nav")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)) }
                        .accessibilityLabel(Text("chat.close"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tfColorScheme()
    }

    private func close() {
        FlashHub.shared.deciding = nil
        FlashHub.shared.answered(request.id)
        dismiss()
    }

    private func decide(_ accept: Bool) async {
        busy = true
        error = nil
        FlashHub.shared.deciding = request.id
        defer { busy = false }
        do {
            let r = try await APIClient.shared.ctDecideMutual(token: token, sessionID: request.id, accept: accept)
            if accept && r.state == "accepted" {
                peer = r.peer ?? request.guest
            } else {
                close()
            }
        } catch {
            self.error = FlashHub.errText(error)
        }
    }

    private func openChat(_ p: IdentityDetail) async {
        let c = await APIClient.shared.ctOpenChat(token: token, userID: p.user_id)
        FlashHub.shared.deciding = nil
        FlashHub.shared.answered(request.id)
        dismiss()
        if let c { onOpen(c) }
    }
}

// MARK: the guest: confirm card → waiting → connected / declined / expired

struct MutualGuestView: View {
    let tok: String
    let onOpen: (ConversationSummary) -> Void
    let onDone: () -> Void
    @EnvironmentObject private var store: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var host: IdentityDetail?
    @State private var sessionID = ""
    @State private var state = "peek" // peek | waiting | declined | expired | connected
    @State private var until: Date?
    @State private var now = Date()
    @State private var busy = false
    @State private var error: String?
    @State private var peer: IdentityDetail?
    @State private var opening = false

    private var token: String { store.session?.token ?? "" }
    private var left: Int { until.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? 0 }

    var body: some View {
        VStack(spacing: 14) {
            if state == "connected", let p = peer ?? host {
                ConnectedCard(peer: p, onOpenChat: { Task { await openChat(p.user_id) } }, onDone: onDone)
            } else {
                if let error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.danger).multilineTextAlignment(.center) }
                if host == nil && error == nil {
                    HStack(spacing: 8) { ProgressView().tint(Theme.accent); Text("sc.checking").foregroundStyle(Theme.faint) }
                        .padding(.top, 30)
                }
                if let h = host { card(h) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .task { await peek() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
                // the decision window ended: ask once; and a safety net while the live connection is down
                if state == "waiting", let u = until, now.timeIntervalSince(u) > 0.8, now.timeIntervalSince(u) < 2 { await recheck() }
                if state == "waiting", !FlashHub.shared.liveConnected, Int(now.timeIntervalSince1970) % 4 == 0 { await recheck() }
            }
        }
        .onReceive(FlashHub.shared.events) { d in
            if (d["session_id"] as? String) == sessionID, !sessionID.isEmpty { Task { await recheck() } }
        }
        .onReceive(FlashHub.shared.reopened) { Task { await recheck() } }
        .onChange(of: scenePhase) { p in if p == .active { Task { await recheck() } } }
    }

    @ViewBuilder private func card(_ h: IdentityDetail) -> some View {
        ScanPerson(card: h)
        ScanChip(key: "fc.user")
        switch state {
        case "peek" where h.relation == "contact":
            ScanChip(key: "sc.already", tint: Theme.online)
            ScanButton(key: "sc.open.chat", icon: "bubble.left.and.bubble.right.fill", busy: opening) {
                opening = true
                Task { await openChat(h.user_id) }
            }
            .padding(.top, 6)
        case "peek" where h.relation == "self":
            Text("fc.own").font(.system(size: 14)).foregroundStyle(Theme.faint)
        case "peek":
            ScanChip(key: "sc.notyet", tint: Theme.gold)
            ScanButton(key: busy ? "sc.sending" : (until != nil && left == 0 ? "mc.expired.title" : "sc.connect"), busy: busy) {
                Task { await claim() }
            }
            .disabled(busy || (until != nil && left == 0))
            .accessibilityIdentifier("sc.connect")
            .padding(.top, 6)
            ScanButton(key: "sc.cancel", primary: false, action: onDone).disabled(busy)
            Text(LocalizedStringKey(until == nil || left > 0 ? "sc.they.accept" : "sc.ask.again"))
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
        case "waiting":
            VStack(spacing: 8) {
                ProgressView().tint(Theme.accent).scaleEffect(1.2)
                Text(String(format: NSLocalizedString("sc.waiting", comment: ""), h.title))
                    .font(.system(size: 15)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                if left > 0 { Text("\(left)s").font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.faint) }
            }
            .padding(.top, 10)
        case "declined":
            Text("fc.not.confirmed").font(.system(size: 14)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
        case "expired":
            Text("sc.noanswer").font(.system(size: 14)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    private func peek() async {
        do {
            let r = try await APIClient.shared.ctPeekMutual(token: token, tok: tok)
            host = r.host
            if let e = r.expires_at { until = Date(timeIntervalSince1970: Double(e)) }
        } catch {
            self.error = FlashHub.errText(error)
        }
    }

    private func claim() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let r = try await APIClient.shared.ctClaimMutual(token: token, tok: tok)
            sessionID = r.session_id
            if let e = r.expires_at { until = Date(timeIntervalSince1970: Double(e)) }
            state = r.state == "accepted" ? "connected" : "waiting"
            if let p = r.peer { peer = p }
        } catch {
            self.error = FlashHub.errText(error)
        }
    }

    private func recheck() async {
        guard !sessionID.isEmpty, state == "waiting",
              let s = try? await APIClient.shared.ctMutualStatus(token: token, sessionID: sessionID) else { return }
        switch s.state {
        case "accepted":
            peer = s.peer ?? host
            state = "connected"
        case "declined": state = "declined"
        case "expired": state = "expired"
        default: break
        }
    }

    private func openChat(_ userID: String) async {
        if let c = await APIClient.shared.ctOpenChat(token: token, userID: userID) { onOpen(c) } else { opening = false }
    }
}
