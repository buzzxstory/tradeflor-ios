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
    @State private var muted = false
    // swipe down to close, as in the status viewer (web swipeDismiss)
    @State private var dragY: CGFloat = 0
    @State private var vertical: Bool? // nil until the first move decides
    @State private var closing = false
    @State private var stageH: CGFloat = 800

    var body: some View {
        ZStack {
            // the dark backdrop fades while the story is swiped down, so the screen underneath shows through
            Color.black.opacity(closing ? 0 : StatusSwipe.backdrop(dragY, height: stageH)).ignoresSafeArea()
            ZStack(alignment: .topTrailing) {
                TabView(selection: $index) {
                    ForEach(Array(posts.enumerated()), id: \.element.id) { i, p in
                        // a tap on the dark area around the story closes it, as on iPhone
                        OfficialPage(token: token, post: p, active: i == index && dragY == 0 && !closing, muted: muted,
                                     onOpen: { url in openURL(url) }, onBackdrop: { dismiss() }).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                HStack(spacing: 0) {
                    if posts.indices.contains(index), posts[index].kind == "video" {
                        Button { muted.toggle() } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text(LocalizedStringKey(muted ? "stx.unmute" : "stx.mute")))
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("chat.close"))
                }
                .padding()
            }
            .scaleEffect(StatusSwipe.scale(dragY, height: stageH))
            .offset(y: dragY)
            .opacity(closing ? 0 : 1)
            // simultaneous: the pages still swipe sideways, the buttons and taps still work
            .simultaneousGesture(swipe)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { stageH = max(1, geo.size.height) }
                .onChange(of: geo.size.height) { h in stageH = max(1, h) }
        })
        .modifier(StatusClearCover())
        .onChange(of: index) { i in seen(i) }
        .onAppear { seen(0) }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height
                if vertical == nil {
                    guard !closing else { return }
                    vertical = dy > 0 && dy > abs(dx) * 1.2 // only a mostly-downward drag is ours; sideways pages
                }
                if vertical == true { dragY = max(0, dy) }
            }
            .onEnded { v in
                let was = vertical
                vertical = nil
                guard was == true, !closing else { return }
                if StatusSwipe.shouldClose(v) {
                    let to = dragY + stageH * 0.45
                    withAnimation(.easeOut(duration: 0.24)) {
                        closing = true
                        dragY = to
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 240_000_000)
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { dismiss() }
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragY = 0 }
                }
            }
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
    /// the page on screen (and not being swiped down): only it plays
    let active: Bool
    let muted: Bool
    let onOpen: (URL) -> Void
    /// A tap on the empty area around the picture, the words and the button (it must barely move: a swipe never counts).
    let onBackdrop: () -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var started = false
    @State private var userPaused = false
    @State private var live = false // `active`, readable from the running task

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Group {
                if post.kind == "video" {
                    // our own AVPlayerLayer (no system controls); the poster shows at once while it loads; a tap pauses
                    ZStack {
                        if let poster { Image(uiImage: poster).resizable().scaledToFit() }
                        if let player { StatusVideoLayer(player: player) }
                        if !started {
                            ProgressView().tint(.white)
                        } else if userPaused {
                            Image(systemName: "play.fill")
                                .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 74, height: 74).background(.black.opacity(0.42), in: Circle())
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlay() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(LocalizedStringKey(userPaused ? "stx.play" : "stx.pause")))
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .contentShape(Rectangle()).onTapGesture {} // the picture itself is not the backdrop
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxHeight: 520)
            if let t = post.title, !t.isEmpty { Text(t).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.center).onTapGesture {} }
            if let c = post.caption, !c.isEmpty { Text(c).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).onTapGesture {} }
            if let label = post.cta_label, !label.isEmpty, let s = post.cta_url, let url = URL(string: s) {
                Button(label) { onOpen(url) }
                    .font(.headline).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 26).padding(.vertical, 12).background(Theme.accent, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onBackdrop() }
        .onAppear { live = active }
        .onChange(of: active) { a in
            live = a
            applyPlay()
        }
        .onChange(of: muted) { m in player?.isMuted = m }
        .task {
            let id = "official-" + post.id
            if post.kind == "video" {
                let p = StatusVideo.player(token: token, id: id, muted: muted)
                player = p
                if active && !userPaused { p.play() } // `active` as of now (onChange(of: active) handles later changes)
                Task {
                    if let d = await APIClient.shared.statusMedia(token: token, id: id, poster: true), let img = UIImage(data: d) {
                        poster = img
                    }
                }
                // the first frame takes the spinner away; a stall (no automatic waiting) is resumed
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Task.isCancelled { break }
                    let t = p.currentTime().seconds
                    if !started, t.isFinite, t > 0.01 { started = true }
                    if live && !userPaused { StatusVideo.resumeIfStalled(p) }
                }
            } else if let d = await APIClient.shared.statusMedia(token: token, id: id) {
                image = UIImage(data: d)
            }
        }
        .onDisappear { player?.pause() }
    }

    private func applyPlay() {
        guard let player else { return }
        if live && !userPaused { player.play() } else { player.pause() }
    }

    /// A tap on the video: pause / play; at the end it starts again.
    private func togglePlay() {
        guard let player, let item = player.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite, d > 0, player.currentTime().seconds >= d - 0.1 {
            userPaused = false
            player.seek(to: .zero) { _ in DispatchQueue.main.async { applyPlay() } }
            return
        }
        userPaused.toggle()
        applyPlay()
    }
}

