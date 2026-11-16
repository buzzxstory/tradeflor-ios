import SwiftUI

/// The status row under the search pill (website StatusBar.tsx): "My status" (dashed ring and a + when empty),
/// the verified "TRADEFLOR Official" ring, then each contact with statuses (accent ring = new, grey = seen).
struct StatusStrip: View {
    @EnvironmentObject private var store: SessionStore
    @State private var groups: [StatusGroup] = []
    @State private var official: OfficialChannel?
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                item(name: NSLocalizedString("status.mine", comment: ""), ring: mine.map { $0.posts.isEmpty ? .none : .seen } ?? .none, plus: true) {
                    Avatar(token: token, userID: me, avatarID: myAvatar, title: store.session?.username ?? "?", size: 49)
                } action: {
                    if let m = mine, !m.posts.isEmpty { open = StatusOpen(groups: [m], index: 0) } else { manage = true }
                }
                if let o = official, let posts = o.posts, !posts.isEmpty {
                    item(name: "TRADEFLOR", sub: "Official", verified: true, ring: o.all_seen ? .seen : .unseen) {
                        ZStack { Theme.card; Image("BrandFlower").resizable().scaledToFit().padding(7) }
                            .frame(width: 49, height: 49).clipShape(Circle())
                    } action: { openOfficial = true }
                }
                ForEach(others) { g in
                    item(name: g.title, ring: g.all_seen ? .seen : .unseen) {
                        Avatar(token: token, userID: g.user_id, avatarID: nil, title: g.title, size: 49)
                    } action: {
                        if let i = others.firstIndex(of: g) { open = StatusOpen(groups: others, index: i) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .task { await load() }
        .fullScreenCover(item: $open) { o in
            StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) { Task { await load() } }
        }
        .fullScreenCover(isPresented: $openOfficial, onDismiss: { Task { await load() } }) {
            OfficialViewer(token: token, posts: official?.posts ?? [])
        }
        .sheet(isPresented: $manage, onDismiss: { Task { await load() } }) { StatusCreatorSheet { Task { await load() } } }
    }

    enum Ring { case none, seen, unseen }

    private func item<A: View>(name: String, sub: String? = nil, verified: Bool = false, ring: Ring, plus: Bool = false,
                               @ViewBuilder avatar: () -> A, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    avatar()
                        .padding(2.5)
                        .overlay(
                            Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: ring == .none ? [4, 3] : []))
                                .foregroundStyle(ring == .unseen ? Theme.accent : (ring == .seen ? Theme.faint.opacity(0.35) : Theme.hex(0x288CAF, 0.55)))
                        )
                        .shadow(color: ring == .unseen ? Theme.accent.opacity(0.3) : .clear, radius: 6)
                    if plus {
                        Image(systemName: "plus").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.onAccent)
                            .frame(width: 21, height: 21).background(Theme.accent, in: Circle())
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }
                VStack(spacing: 0) {
                    Text(name).font(.system(size: 11, weight: sub == nil ? .regular : .bold)).foregroundStyle(sub == nil ? Theme.faint : Theme.text)
                    if let sub {
                        HStack(spacing: 2) {
                            Text(sub).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                            if verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(Theme.verified) }
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: sub != nil, vertical: false)
                .frame(maxWidth: sub != nil ? 80 : 66)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard !token.isEmpty else { return }
        async let feed = APIClient.shared.statusFeed(token: token)
        async let off = APIClient.shared.official(token: token)
        async let prof = APIClient.shared.profile(token: token)
        groups = (try? await feed) ?? groups
        official = (try? await off) ?? official
        if let p = try? await prof { myAvatar = p.avatar_id.isEmpty ? nil : p.avatar_id }
    }
}
