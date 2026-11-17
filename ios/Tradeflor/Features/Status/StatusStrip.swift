import SwiftUI

/// The status row under the search pill (website StatusBar.tsx): "My status" (dashed ring and a + when empty),
/// the verified "TRADEFLOR Official" ring, then each contact with statuses (accent ring = new, grey = seen).
struct StatusStrip: View {
    @EnvironmentObject private var store: SessionStore
    @State private var groups: [StatusGroup] = []
    @State private var official: OfficialChannel? = OfficialFeedCache.load()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var officialRetry = 0
    @State private var myAvatar: String?
    @State private var open: StatusOpen?
    @State private var openOfficial = false
    @State private var manage = false

    private var token: String { store.session?.token ?? "" }
    private var me: String { store.session?.userID ?? "" }
    private var mine: StatusGroup? { groups.first { $0.isMine && $0.group_id == nil } }
    private var others: [StatusGroup] {
        groups.filter { !($0.isMine && $0.group_id == nil) && !$0.posts.isEmpty }
            .sorted { ($0.all_seen ? 1 : 0, -$0.latest) < ($1.all_seen ? 1 : 0, -$1.latest) }
    }

    // website phone sizes (63-chats-polish.css .sidebar .status-*): a 52 pt ring (2 pt line, 2.5 pt gap, 43 pt picture),
    // 60 pt per item, 10 pt apart, the row padded 8 / 14 / 4; names 11 pt on one 15 pt line
    private let ringSize: CGFloat = 52
    private let faceSize: CGFloat = 43

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                // the ring opens my status (the creator when I have none); the + always adds one (web StatusBar)
                item(name: NSLocalizedString("status.mine", comment: ""), ring: mine.map { $0.posts.isEmpty ? .none : .seen } ?? .none,
                     onPlus: { manage = true }) {
                    Avatar(token: token, userID: me, avatarID: myAvatar, title: store.session?.username ?? "?", size: faceSize)
                } action: {
                    if let m = mine, !m.posts.isEmpty { open = StatusOpen(groups: [m], index: 0) } else { manage = true }
                }
                if let o = official, let posts = o.posts, !posts.isEmpty {
                    officialItem(o)
                }
                ForEach(others) { g in
                    item(name: g.title, ring: g.all_seen ? .seen : .unseen) {
                        Avatar(token: token, userID: g.user_id, avatarID: nil, title: g.title, size: faceSize)
                    } action: {
                        if let i = others.firstIndex(of: g) { open = StatusOpen(groups: others, index: i) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .task { await load() }
        // the web re-reads every two minutes and when the app comes back to the front
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if Task.isCancelled { return }
                await load()
            }
        }
        .onChange(of: scenePhase) { p in if p == .active { Task { await load() } } }
        // a status watched, posted or deleted anywhere (the viewers post this once their "seen" calls have arrived): the
        // rings change at once, not two minutes later
        .onReceive(NotificationCenter.default.publisher(for: .tfStatusChanged)) { _ in Task { await load() } }
        .fullScreenCover(item: $open) { o in
            StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) {}
        }
        .fullScreenCover(isPresented: $openOfficial) {
            OfficialViewer(token: token, posts: official?.posts ?? [])
        }
        .fullScreenCover(isPresented: $manage) {
            StatusCreatorSheet { NotificationCenter.default.post(name: .tfStatusChanged, object: nil) }
        }
    }

    enum Ring { case none, seen, unseen }

    private func item<A: View>(name: String, ring: Ring, onPlus: (() -> Void)? = nil,
                               @ViewBuilder avatar: () -> A, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                avatar()
                    .frame(width: faceSize, height: faceSize)
                    .frame(width: ringSize, height: ringSize)
                    .overlay(
                        // 18-status.css: accent with a soft glow = new, grey = watched, dashed blue = nothing yet
                        Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: ring == .none ? [4, 3] : []))
                            .foregroundStyle(ring == .unseen ? Theme.accent : (ring == .seen ? Theme.hex(0xA9B9C5, 0.35) : Theme.hex(0x288CAF, 0.55)))
                            .shadow(color: ring == .unseen ? Theme.hex(0x00D4DF, 0.3) : .clear, radius: 5)
                    )
                Text(name).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 15)
                    .frame(maxWidth: 60)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onPlus {
                // .status-plus: 21 pt, 37 pt from the top, 1 pt in from the ring's end, a 2 pt ring of the panel colour; its
                // own button (a 30 pt target), so it adds a status even when I already have one
                Button(action: onPlus) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.onAccent)
                        .frame(width: 21, height: 21).background(Theme.accent, in: Circle())
                        .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                        .padding(4.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: layoutDirection == .rightToLeft ? 0.5 : -0.5, y: 32.5)
                .accessibilityLabel(Text("tf.add.status"))
            }
        }
    }

    /// TRADEFLOR Official (website OfficialStatus.tsx OfficialCircle, 53-admin.css, 63-chats-polish.css): the orb on a
    /// dark radial face, a turquoise ring and a "NEW" tag while there is something unwatched, the channel's name on one
    /// line with the blue verified seal.
    private func officialItem(_ o: OfficialChannel) -> some View {
        let fresh = !o.all_seen
        return Button { openOfficial = true } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(RadialGradient(colors: [Theme.hex(0x0F3340), Theme.hex(0x04141B)],
                                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 30))
                    Image("OfficialOrb").resizable().scaledToFit().frame(width: 42 * 0.68, height: 42 * 0.68)
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                .frame(width: ringSize, height: ringSize)
                .overlay(Circle().strokeBorder(fresh ? Theme.hex(0x2FD9DC) : Theme.hex(0x44606C), lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if fresh {
                        Text("ux1.status.new")
                            .font(.system(size: 9.5, weight: .heavy)).tracking(0.4)
                            .foregroundStyle(Theme.hex(0x03222A))
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Theme.hex(0x2FD9DC), in: Capsule())
                            .overlay(Capsule().stroke(Theme.ground, lineWidth: 2))
                            .fixedSize()
                            .offset(x: layoutDirection == .rightToLeft ? -10 : 10, y: -5)
                    }
                }
                HStack(spacing: 3) {
                    Text(o.name.isEmpty ? "TRADEFLOR Official" : o.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.dyn(0xE8F2F8, 0x0F2533))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    ListVerifiedSeal(size: 13)
                }
                .frame(height: 15)
                .frame(maxWidth: 132)
            }
            .frame(minWidth: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(o.name.isEmpty ? "TRADEFLOR Official" : o.name))
    }

    private func load() async {
        guard !token.isEmpty else { return }
        await StatusSeenQueue.shared.drain() // the statuses just watched are counted as seen in this answer
        async let feed = APIClient.shared.statusFeed(token: token)
        async let off = APIClient.shared.official(token: token)
        async let prof = APIClient.shared.profile(token: token)
        groups = (try? await feed) ?? groups
        if let o = try? await off {
            official = o
            OfficialFeedCache.keep(o)
            officialRetry = 0
        } else {
            // not read now: the copy on screen stays, and the server is asked again soon (2, 4, 8 … at most 30 s)
            guard officialRetry == 0 else { return } // one retry line at a time
            officialRetry = 1
            Task {
                for n in 0..<8 {
                    try? await Task.sleep(nanoseconds: UInt64(min(30, 2 << min(n, 4))) * 1_000_000_000)
                    if let o = try? await APIClient.shared.official(token: token) {
                        official = o
                        OfficialFeedCache.keep(o)
                        break
                    }
                }
                officialRetry = 0
            }
        }
        if let p = try? await prof { myAvatar = p.avatar_id.isEmpty ? nil : p.avatar_id }
    }
}
