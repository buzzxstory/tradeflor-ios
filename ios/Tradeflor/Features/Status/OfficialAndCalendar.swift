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

/// TRADEFLOR Official as the web phone shows it (features/official/OfficialStatus.tsx, 18-status.css, 53-admin.css): a story
/// like a person's, not a gallery. Progress bars on top; the orb, "TRADEFLOR Official" with the blue seal over "2 h ago", and
/// round sound (videos) / pause / close buttons; the picture or video letterboxed over the whole screen; the caption in a band
/// at the bottom with the turquoise button under it. No page dots and no title (the title is the admin's label).
/// Tap the right two thirds for the next post and the left third for the one before, hold to pause, swipe sideways for the
/// next / previous post, swipe down to close; a tap on the dark area around the picture closes it. Photos stay 6 s, videos
/// their length; after the last one it closes. It opens on the first post not seen yet.
struct OfficialViewer: View {
    let token: String
    let posts: [OfficialPost]
    /// The channel's name (the server's); read from the server when not given.
    var name: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var index: Int
    /// bumped to start the same post again (a tap back on the first post)
    @State private var round = 0
    /// how far the post on screen has played: read only by the bars (not this whole screen, 30 times a second)
    @State private var clock = StatusClock()
    @State private var paused = false
    @State private var userPaused = false
    @State private var muted = false
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var videoStarted = false
    @State private var loadFailed = false
    @State private var channelName: String?
    // swipe down to close, as in the status viewer (web swipeDismiss)
    @State private var dragY: CGFloat = 0
    @State private var dragAxis: SwipeAxis?
    @State private var closing = false
    @State private var stageH: CGFloat = 800
    @State private var stageW: CGFloat = 390
    /// when a hold or a swipe last ended: the tap the finger may end with is not a tap on a zone
    @State private var lastGestureAt = Date.distantPast
    @GestureState private var holding = false
    @GestureState private var touching = false

    private let imageSeconds = 6.0 // web OfficialStatus IMAGE_MS

    private enum SwipeAxis { case down, up, side }

    init(token: String, posts: [OfficialPost], name: String? = nil) {
        self.token = token
        self.posts = posts
        self.name = name
        _index = State(initialValue: posts.firstIndex { !$0.seen } ?? 0)
    }

    private var post: OfficialPost? { posts.indices.contains(index) ? posts[index] : nil }

    var body: some View {
        ZStack {
            // the dark backdrop fades while the story is swiped down, so the screen underneath shows through
            Color.black.opacity(closing ? 0 : StatusSwipe.backdrop(dragY, height: stageH)).ignoresSafeArea()
            stage
                .scaleEffect(StatusSwipe.scale(dragY, height: stageH))
                .offset(y: dragY)
                .opacity(closing ? 0 : 1)
                // simultaneous: the taps, the hold and the buttons keep working
                .simultaneousGesture(swipe)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { stageH = max(1, geo.size.height); stageW = max(1, geo.size.width) }
                .onChange(of: geo.size) { s in stageH = max(1, s.height); stageW = max(1, s.width) }
        })
        .modifier(StatusClearCover())
        .statusBarHidden()
        .onAppear { if CallManager.shared.lineInUse { muted = true } } // web: silent during a call
        .task(id: "\(index)-\(round)") { await show() }
        .task {
            guard name == nil, channelName == nil else { return }
            channelName = (try? await APIClient.shared.official(token: token))?.name
        }
        .onChange(of: holding) { h in
            if h { setPaused(true) } else { lastGestureAt = Date(); resume() }
        }
        .onChange(of: scenePhase) { ph in
            if ph == .active { resume() } else { setPaused(true) }
        }
        .onChange(of: touching) { t in
            // a drag the system cancelled (no onEnded): put the story back
            guard !t else { return }
            DispatchQueue.main.async {
                guard dragAxis != nil, !closing else { return }
                dragAxis = nil
                springBack()
            }
        }
        .onChange(of: muted) { m in player?.isMuted = m }
        .modifier(StatusAudioKeeper { restoreAudio() })
        .onDisappear {
            player?.pause()
            player = nil
            StatusAudio.release() // other apps' music may carry on
            // the Official ring and every status list are read again once the "seen" calls have arrived
            Task { @MainActor in
                await StatusSeenQueue.shared.drain()
                NotificationCenter.default.post(name: .tfStatusChanged, object: nil)
            }
        }
    }

    /// The story itself (what moves with the finger).
    private var stage: some View {
        ZStack {
            media
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            // tap zones: left third back, the rest forward; a tap on the dark area around the picture closes; holding pauses
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in tapStage(at: v.location, in: geo.size) })
            }
            .ignoresSafeArea()
            .environment(\.layoutDirection, .leftToRight)
            .simultaneousGesture(hold)
            // VoiceOver: the taps on the sides are not reachable, so next / previous / pause are actions of the story
            .accessibilityElement()
            .accessibilityLabel(Text("stx.a11y.story"))
            .accessibilityAction(named: Text("stx.a11y.next")) { next() }
            .accessibilityAction(named: Text("stx.a11y.previous")) { previous() }
            .accessibilityAction(named: Text("stx.a11y.pause")) { userPausedToggle() }
            VStack(spacing: 9) {
                bars
                header
                Spacer()
                footer
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
    }

    // MARK: look

    @ViewBuilder private var media: some View {
        if let post {
            ZStack {
                if post.kind == "video" {
                    // our own AVPlayerLayer (no system controls); the poster shows at once underneath until the first frame
                    if let poster { Image(uiImage: poster).resizable().scaledToFit() }
                    if let player { StatusVideoLayer(player: player) }
                    if !videoStarted { ProgressView().tint(.white) }
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loadFailed {
                    // web: the orb, dimmed, on a dark radial backdrop
                    ZStack {
                        RadialGradient(colors: [Theme.hex(0x0B2A35), .black], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 360)
                        OfficialFace(size: 104, ring: false).opacity(0.55)
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
    }

    private var bars: some View {
        StatusBars(count: posts.count, current: index, clock: clock)
    }

    /// web .status-head in the Official viewer: the orb (38 pt, turquoise ring), the name with the seal over "2 h ago", then
    /// sound (videos), pause / play and close as round 44 pt dark buttons.
    private var header: some View {
        HStack(spacing: 10) {
            OfficialFace(size: 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name ?? channelName ?? "TRADEFLOR Official")
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    StatusVerifiedSeal(size: 15)
                }
                Text(statusAgo(post.flatMap { serverDate($0.created_at) }))
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if post?.kind == "video" {
                StatusHeadButton(systemName: muted ? "speaker.slash" : "speaker.wave.2", label: LocalizedStringKey(muted ? "stx.unmute" : "stx.mute")) {
                    muted.toggle()
                    if !muted { StatusAudio.prepare() }
                    player?.isMuted = muted
                    StatusAudio.full(player)
                }
            }
            StatusHeadButton(systemName: userPaused ? "play.fill" : "pause", label: LocalizedStringKey(userPaused ? "stx.play" : "stx.pause"), size: 16) {
                userPaused.toggle()
                resume()
            }
            StatusHeadButton(systemName: "xmark", label: "chat.close") { close() }
        }
    }

    /// web .status-caption (a band, scrolling past a third of the screen) and .official-cta (a turquoise pill, 44 pt high,
    /// dark 15 pt heavy words, 18 pt above the bottom; the caption sits 12 pt above it).
    @ViewBuilder private var footer: some View {
        if let post {
            VStack(spacing: 12) {
                if let c = post.caption, !c.isEmpty {
                    StatusCaptionBand(text: c, maxHeight: stageH * 0.34)
                        .padding(.horizontal, -10)
                }
                if let s = post.cta_url, !s.isEmpty, let url = URL(string: s) {
                    Button {
                        userPaused = true // web: the story waits while the link is open
                        resume()
                        openURL(url)
                    } label: {
                        Text(post.cta_label.flatMap { $0.isEmpty ? nil : $0 } ?? NSLocalizedString("ux2.official.learn", comment: ""))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(Theme.hex(0x03222A))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 24)
                            .frame(minHeight: 44)
                            .background(Theme.hex(0x2FD9DC), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: stageW * 0.8)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: gestures

    /// Hold to pause: paused from the moment the hold is recognised until the finger lifts.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { v, state, _ in
                if case .second(true, _) = v { state = true }
            }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { v in
                let dx = v.translation.width
                let dy = v.translation.height
                if dragAxis == nil {
                    guard !closing else { return }
                    // the first move decides: mostly vertical is a drag down / up, anything else is sideways
                    dragAxis = abs(dy) > abs(dx) * 1.2 ? (dy > 0 ? SwipeAxis.down : SwipeAxis.up) : SwipeAxis.side
                    if dragAxis == .down { setPaused(true) } // the story waits while it is dragged
                }
                if dragAxis == .down { dragY = max(0, dy) } // follows the finger 1:1
            }
            .onEnded { v in
                let axis = dragAxis
                dragAxis = nil
                lastGestureAt = Date()
                guard let axis, !closing else { return }
                let dx = v.translation.width
                switch axis {
                case .down:
                    if StatusSwipe.shouldClose(v) { closeBySwipe() } else { springBack() }
                case .up:
                    break
                case .side:
                    let pdx = v.predictedEndTranslation.width
                    if dx <= -60 || (dx < -20 && pdx <= -220) { next() } else if dx >= 60 || (dx > 20 && pdx >= 220) { previous() }
                }
            }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragY = 0 }
        resume()
    }

    /// Far enough or a flick: the story slides on down and fades with the backdrop, then the viewer goes.
    private func closeBySwipe() {
        player?.pause()
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
    }

    private func tapStage(at pt: CGPoint, in size: CGSize) {
        // the finger was holding the story or swiping it: its lift is not a tap
        if holding || dragAxis != nil || closing || Date().timeIntervalSince(lastGestureAt) < 0.35 { return }
        if let r = statusFittedRect(kind: post?.kind, image: post?.kind == "video" ? poster : image, player: player, in: size),
           !r.insetBy(dx: -1, dy: -1).contains(pt) {
            close()
            return
        }
        if pt.x < size.width / 3 { previous() } else { next() }
    }

    // MARK: playback

    /// Whether something still holds the story (the pause button, a finger, a drag).
    private var mustHold: Bool { userPaused || holding || dragAxis == .down || closing }

    private func resume() { setPaused(mustHold) }

    private func userPausedToggle() { userPaused.toggle(); resume() }

    /// After an interruption, a route change or coming back to the front: sound as the speaker button says, play on unless held.
    private func restoreAudio() {
        guard !closing, post?.kind == "video" else { return }
        if !muted { StatusAudio.prepare() }
        player?.isMuted = muted
        StatusAudio.full(player)
        if !paused { player?.play() }
    }

    private func setPaused(_ v: Bool) {
        paused = v
        if v { player?.pause() } else { player?.play() }
    }

    private func next() {
        if index + 1 < posts.count { index += 1 } else { close() }
    }

    private func previous() {
        if index > 0 { index -= 1 } else { round += 1 } // on the first post: it starts again
    }

    private func close() {
        player?.pause()
        dismiss()
    }

    private func show() async {
        player?.pause()
        player = nil
        image = nil
        poster = nil
        videoStarted = false
        loadFailed = false
        if CallManager.shared.lineInUse { muted = true }
        clock.progress = 0
        guard let post else {
            if posts.isEmpty { close() } else { index = 0; round += 1 } // never stuck black on an index past the list
            return
        }
        if StatusGone.expired(post.expires_at) {
            // past its time while the viewer was open (or a list kept too long): the dimmed orb a moment, then the next one
            loadFailed = true
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled { next() }
            return
        }
        // asked every time it is opened, as on the web (it is idempotent)
        let pid = post.id
        let tok = token
        StatusSeenQueue.shared.add { await APIClient.shared.officialSeen(token: tok, id: pid) }
        let id = "official-" + post.id
        if post.kind == "video" {
            StatusAudio.prepare() // this viewer never set the phone's audio up: silent on silent, or a leftover quiet route
            let pl = StatusVideo.player(token: token, id: id, muted: muted)
            player = pl
            if !paused { pl.play() }
            Task {
                let px = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
                guard let d = await APIClient.shared.statusMedia(token: token, id: id, poster: true),
                      let img = await AvatarImages.decode(d, maxPixels: px), self.post?.id == pid else { return }
                poster = img
            }
            prefetchNext()
            await runVideo(pl)
        } else {
            let d = await APIClient.shared.statusMedia(token: token, id: id)
            // moved on meanwhile: this picture belongs to the post before (it flashed over the next one)
            if Task.isCancelled { return }
            // decoded off the main thread, no larger than the screen (UIImage(data:) decodes on the main thread when first drawn)
            var decoded: UIImage?
            if let d { decoded = await AvatarImages.decode(d, maxPixels: max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale) }
            if Task.isCancelled { return }
            if let img = decoded {
                image = img
            } else {
                loadFailed = true
            }
            prefetchNext()
            await runClock(imageSeconds)
        }
    }

    /// Photos (and a video that cannot play): advance on a clock (pausing holds it).
    private func runClock(_ seconds: Double, from already: Double = 0) async {
        let start = Date()
        var pausedFor: TimeInterval = 0
        var pausedAt: Date?
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            if paused || UIAccessibility.isVoiceOverRunning {
                if pausedAt == nil { pausedAt = Date() }
                continue
            }
            if let pa = pausedAt { pausedFor += Date().timeIntervalSince(pa); pausedAt = nil }
            let t = already + Date().timeIntervalSince(start) - pausedFor
            clock.progress = min(1, t / max(0.1, seconds))
            if t >= seconds { next(); return }
        }
    }

    /// A video: the bar follows the player's own time, and the next post comes when the video ends.
    private func runVideo(_ pl: AVPlayer) async {
        guard let item = pl.currentItem else { return }
        let end = StatusEndFlag()
        let obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            end.ended = true
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        let opened = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            // no first frame after 15 s (not held): it will not play, the spinner must not stay for ever
            if item.status == .failed || (!videoStarted && !paused && Date().timeIntervalSince(opened) > 15) {
                // it cannot play: the story still moves on, on a clock
                videoStarted = true
                await runClock(imageSeconds, from: imageSeconds * clock.progress)
                return
            }
            let t = pl.currentTime().seconds
            if !videoStarted, t.isFinite, t > 0.01 { videoStarted = true } // the first frame is up: the spinner goes
            if paused { continue }
            let d = item.duration.seconds
            if d.isFinite, d > 0, t.isFinite {
                clock.progress = min(1, max(0, t / d))
                if end.ended || t >= d - 0.04 { next(); return }
            } else if end.ended {
                next()
                return
            }
            StatusVideo.resumeIfStalled(pl)
        }
    }

    /// The next post's picture (or video poster) is fetched while this one is watched.
    private func prefetchNext() {
        guard posts.indices.contains(index + 1) else { return }
        let n = posts[index + 1]
        let id = "official-" + n.id
        let tok = token
        Task(priority: .utility) { _ = await APIClient.shared.statusMedia(token: tok, id: id, poster: n.kind == "video") }
    }
}
