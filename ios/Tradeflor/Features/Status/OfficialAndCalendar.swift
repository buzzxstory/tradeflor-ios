import SwiftUI
import AVKit

// MARK: TRADEFLOR Official

/// The verified "TRADEFLOR Official" ring in the Status tab: posts from the TRADEFLOR team (photo or video,
/// a title, a caption and sometimes a button to a link).
struct OfficialRow: View {
    let token: String
    @State private var channel: OfficialChannel?
    @State private var open = false

    var body: some View {
        Group {
            if let c = channel, let posts = c.posts, !posts.isEmpty {
                Button { open = true } label: {
                    HStack(spacing: 12) {
                        StatusRing(seen: c.all_seen, count: posts.count) {
                            ZStack {
                                Theme.surface
                                Image("BrandMark").resizable().scaledToFill()
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(c.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent).font(.caption)
                            }
                            Text("official.subtitle").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .fullScreenCover(isPresented: $open, onDismiss: { Task { await load() } }) {
                    OfficialViewer(token: token, posts: posts)
                }
            }
        }
        .task { await load() }
    }

    private func load() async { channel = try? await APIClient.shared.official(token: token) }
}

struct OfficialViewer: View {
    let token: String
    let posts: [OfficialPost]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                    OfficialPage(token: token, post: p) { url in openURL(url) }.tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .padding()
            .accessibilityLabel(Text("chat.close"))
        }
        .onChange(of: index) { i in seen(i) }
        .onAppear { seen(0) }
    }

    private func seen(_ i: Int) {
        guard posts.indices.contains(i), !posts[i].seen else { return }
        let id = posts[i].id
        Task { await APIClient.shared.officialSeen(token: token, id: id) }
    }
}

private struct OfficialPage: View {
    let token: String
    let post: OfficialPost
    let onOpen: (URL) -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Group {
                if post.kind == "video" {
                    if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxHeight: 520)
            if let t = post.title, !t.isEmpty { Text(t).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.center) }
            if let c = post.caption, !c.isEmpty { Text(c).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center) }
            if let label = post.cta_label, !label.isEmpty, let s = post.cta_url, let url = URL(string: s) {
                Button(label) { onOpen(url) }
                    .font(.headline).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 26).padding(.vertical, 12).background(Theme.accent, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .task {
            if post.kind == "video" {
                let asset = AVURLAsset(url: APIClient.shared.statusMediaURL(id: "official-" + post.id),
                                       options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = p
                p.play()
            } else if let d = await APIClient.shared.statusMedia(token: token, id: "official-" + post.id) {
                image = UIImage(data: d)
            }
        }
        .onDisappear { player?.pause() }
    }
}

