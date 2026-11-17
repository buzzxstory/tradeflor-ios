import SwiftUI
import AVKit

/// Full-screen statuses: progress bars on top, tap right/left for next/previous, hold to pause, swipe down to close.
/// Photos and text show for 5 s, videos for their length. Someone else's status is marked seen; on my own
/// I see how many viewed it, who, and can delete it.
struct StatusViewerScreen: View {
    let groups: [StatusGroup]
    let token: String
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var g: Int
    @State private var p = 0
    @State private var progress: Double = 0
    @State private var paused = false
    @State private var ready = false
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var musicPlayer: AVPlayer?
    @State private var poster: UIImage? // a video status's poster, shown at once while the video loads
    @State private var videoStarted = false
    // swipe down to close (web swipeDismiss)
    @State private var dragY: CGFloat = 0
    @State private var dragAxis: SwipeAxis?
    @State private var closing = false
    @State private var stageH: CGFloat = 800
    /// when a hold or a swipe last ended: the tap the finger may end with is not a tap on a zone
    @State private var lastGestureAt = Date.distantPast
    @GestureState private var holding = false
    @GestureState private var touching = false
    @State private var showViewers = false
    @State private var confirmDelete = false
    @State private var muted = false
    @State private var userPaused = false
    @State private var reply = ""
    @State private var replyNote: String?
    @State private var sending = false
    @FocusState private var replyFocused: Bool
    @State private var myReacts: [String: String] = [:] // changed on this visit
    @State private var burst: (emoji: String, key: UUID)?
    @State private var reacting = false
    @State private var showEmoji = false // the full emoji panel for the reply (the button in the reply box)

    private let photoSeconds = 5.0

    private enum SwipeAxis { case down, up, side }

    init(groups: [StatusGroup], startGroup: Int, token: String, onClose: @escaping () -> Void) {
        self.groups = groups
        self.token = token
        self.onClose = onClose
        _g = State(initialValue: startGroup)
    }

    private var group: StatusGroup { groups[g] }
    private var post: StatusPost? { group.posts.indices.contains(p) ? group.posts[p] : nil }

    var body: some View {
        ZStack {
            // the dark backdrop: it fades while the story is swiped down, so the screen underneath shows through
            Color.black.opacity(closing ? 0 : StatusSwipe.backdrop(dragY, height: stageH)).ignoresSafeArea()
            stage
                .scaleEffect(StatusSwipe.scale(dragY, height: stageH))
                .offset(y: dragY)
                .opacity(closing ? 0 : 1)
                // anywhere on the story: down closes, up (my own) shows who viewed / (someone else's) the next person,
                // sideways goes to the next or previous person. Simultaneous, so the taps and the hold keep working.
                .simultaneousGesture(swipe)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { stageH = max(1, geo.size.height) }
                .onChange(of: geo.size.height) { h in stageH = max(1, h) }
        })
        .modifier(StatusClearCover())
        .statusBarHidden()
        .task(id: "\(g)-\(p)") { await show() }
        .onChange(of: holding) { h in
            if h { setPaused(true) } else { lastGestureAt = Date(); resume() }
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
        .sheet(isPresented: $showViewers) {
            if let post { StatusViewersSheet(token: token, postID: post.id, views: post.views ?? 0) }
        }
        .sheet(isPresented: $showEmoji, onDismiss: { replyFocused = true }) {
            // the full emoji panel: each pick goes into the reply (the panel stays open for more)
            EmojiPickerSheet { e in
                reply = String((reply + e).prefix(2000))
                replyNote = nil
            }
        }
        .onChange(of: showEmoji) { _ in resume() }
        .onChange(of: showViewers) { _ in resume() }
        .onChange(of: confirmDelete) { _ in resume() }
        .animation(.easeOut(duration: 0.18), value: replyFocused)
        .confirmationDialog(Text("status.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("status.delete", role: .destructive) { Task { await deleteCurrent() } }
        }
        .overlay {
            if let b = burst {
                Text(b.emoji).font(.system(size: 120)).shadow(radius: 12)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .id(b.key)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear { player?.pause(); musicPlayer?.pause(); musicPlayer = nil; onClose() }
    }

    /// The story itself (what moves with the finger): the picture / video / text, the tap zones, the bars and controls.
    private var stage: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            // tap zones: left third back, the rest forward; a tap on the dark area around the picture or video closes
            // (as on iPhone; a tap only counts when it barely moves, so drags and swipes never close); holding pauses
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in tapStage(at: v.location, in: geo.size) })
            }
            .ignoresSafeArea()
            .environment(\.layoutDirection, .leftToRight)
            .simultaneousGesture(hold)
            // WhatsApp's quick reactions: the status dims and eight big emojis come up while the reply box is focused
            if canReply && replyFocused && !showEmoji && post != nil {
                StatusQuickGrid(onPick: { e in Task { await quickReact(e) } }, onDismiss: { replyFocused = false })
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                bars
                header
                Spacer()
                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    // MARK: gestures

    /// Hold to pause: paused from the moment the hold is recognised until the finger lifts (a LongPressGesture alone
    /// ends as soon as it is recognised, which resumed the story while the finger was still down).
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
            .onChanged { v in swipeChanged(v) }
            .onEnded { v in swipeEnded(v) }
    }

    /// No swipe while the keyboard, the emoji panel, a sheet or the delete question is up.
    private var swipeAllowed: Bool { !replyFocused && !showEmoji && !showViewers && !confirmDelete && !closing }

    private func swipeChanged(_ v: DragGesture.Value) {
        let dx = v.translation.width
        let dy = v.translation.height
        if dragAxis == nil {
            guard swipeAllowed else { return }
            // the first move decides: mostly vertical is a drag down / a swipe up, anything else is sideways
            dragAxis = abs(dy) > abs(dx) * 1.2 ? (dy > 0 ? SwipeAxis.down : SwipeAxis.up) : SwipeAxis.side
            if dragAxis == .down { setPaused(true) } // the story waits while it is dragged
        }
        if dragAxis == .down { dragY = max(0, dy) } // follows the finger 1:1 (no animation while the finger is down)
    }

    private func swipeEnded(_ v: DragGesture.Value) {
        let axis = dragAxis
        dragAxis = nil
        lastGestureAt = Date()
        guard let axis, !closing else { return }
        let dx = v.translation.width
        let dy = v.translation.height
        switch axis {
        case .down:
            if StatusSwipe.shouldClose(v) { closeBySwipe() } else { springBack() }
        case .up:
            guard dy <= -70 else { return }
            if group.isMine, post != nil {
                setPaused(true) // swipe up on my own status: who viewed it (web)
                showViewers = true
            } else {
                nextPerson()
            }
        case .side:
            let pdx = v.predictedEndTranslation.width
            if dx <= -60 || (dx < -20 && pdx <= -220) { nextPerson() } else if dx >= 60 || (dx > 20 && pdx >= 220) { previousPerson() }
        }
    }

    /// A short drag: the story springs back and plays on.
    private func springBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragY = 0 }
        resume()
    }

    /// Far enough or a flick: the story slides on down and fades with the backdrop, then the viewer goes.
    private func closeBySwipe() {
        player?.pause()
        musicPlayer?.pause()
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

    /// Whether something still holds the story (the pause button, the keyboard, a panel, a finger, a drag).
    private var mustHold: Bool {
        userPaused || replyFocused || showEmoji || showViewers || confirmDelete || holding || dragAxis == .down || closing
    }

    private func resume() { setPaused(mustHold) }

    @ViewBuilder private var content: some View {
        if let post {
            switch post.kind {
            case "text":
                let (bg, font) = StatusStyle.parts(post.style)
                ZStack {
                    StatusStyle.background(post.style)
                    Text(post.text ?? "")
                        .font(.system(size: StatusStyle.size(for: post.text ?? ""), weight: font.weight, design: font.design))
                        .italic(font.italic)
                        .foregroundStyle(bg.ink)
                        .multilineTextAlignment(.center)
                        .padding(28)
                }
            case "video":
                // our own AVPlayerLayer (no system controls); the poster shows at once underneath until the first frame
                ZStack {
                    if let poster { Image(uiImage: poster).resizable().scaledToFit() }
                    if let player { StatusVideoLayer(player: player) }
                    if !videoStarted { ProgressView().tint(.white) }
                }
            case "image":
                if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().tint(.white) }
            case "voice":
                ZStack {
                    LinearGradient(colors: [Theme.hex(0x0A4756), Theme.hex(0x02161F)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 14) {
                        Image(systemName: "waveform").font(.system(size: 64, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(VoiceBubble.length(post.duration_ms ?? 0)).font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            default:
                Text("status.unsupported").foregroundStyle(.white.opacity(0.8)).padding()
            }
        }
    }

    private var bars: some View {
        HStack(spacing: 4) {
            ForEach(group.posts.indices, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * (i < p ? 1 : (i == p ? progress : 0)))
                    }
                }
                .frame(height: 3)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.isMine && group.group_id == nil ? NSLocalizedString("status.mine", comment: "") : group.title)
                    .font(.subheadline.weight(.semibold))
                if let d = post?.date { Text(d, style: .relative).font(.caption) }
            }
            .foregroundStyle(.white)
            Spacer()
            Button {
                userPaused.toggle()
                resume()
            } label: {
                Image(systemName: userPaused ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 40)
            }
            .accessibilityLabel(Text(LocalizedStringKey(userPaused ? "stx.play" : "stx.pause")))
            if post?.kind == "video" || post?.kind == "voice" || post?.music != nil {
                Button {
                    muted.toggle()
                    player?.isMuted = muted
                    musicPlayer?.isMuted = muted
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 40)
                }
                .accessibilityLabel(Text(LocalizedStringKey(muted ? "stx.unmute" : "stx.mute")))
            }
            if group.isMine {
                Menu {
                    Button { setPaused(true); showViewers = true } label: { Label("status.viewers", systemImage: "eye") }
                    Button(role: .destructive) { setPaused(true); confirmDelete = true } label: { Label("stx.delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 40)
                }
                .accessibilityLabel(Text("stx.more"))
            }
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text("chat.close"))
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            if let m = post?.music, !m.isEmpty {
                Label(StatusMusic.title(m), systemImage: "music.note")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(.black.opacity(0.45), in: Capsule())
                    .accessibilityLabel(Text(String(format: NSLocalizedString("stx.music.on", comment: ""), StatusMusic.title(m))))
            }
            if let c = post?.caption, !c.isEmpty {
                Text(c)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
            if group.isMine, let post {
                // WhatsApp: "^" over "eye N"; opens the "N views" list
                Button { setPaused(true); showViewers = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold))
                        HStack(spacing: 5) {
                            Image(systemName: "eye")
                            Text(verbatim: "\(post.views ?? 0)")
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.bottom, 12)
                .accessibilityLabel(Text(statusViewsTitle(post.views ?? 0)))
                .accessibilityHint(Text("stx.views.show"))
            } else if group.group_id == nil {
                VStack(spacing: 6) {
                    if let replyNote { Text(replyNote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)) }
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            TextField("", text: $reply, prompt: Text(String(format: NSLocalizedString("stx.reply.ph", comment: ""), group.title))
                                .foregroundColor(.white.opacity(0.6)))
                                .focused($replyFocused)
                                .foregroundStyle(.white)
                                .onChange(of: replyFocused) { _ in resume() }
                                .onChange(of: reply) { t in if t.count > 2000 { reply = String(t.prefix(2000)) } }
                            // the full emoji panel for the reply
                            Button {
                                setPaused(true)
                                showEmoji = true
                            } label: {
                                Image(systemName: "face.smiling").font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9)).frame(width: 34, height: 44)
                            }
                            .accessibilityLabel(Text("stv.emoji"))
                        }
                        .padding(.leading, 16).padding(.trailing, 6).frame(height: 44)
                        .background(.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                        if !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { Task { await sendReply() } } label: {
                                Group { if sending { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") } }
                                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 44, height: 44).background(Theme.sendGradient, in: Circle())
                            }
                            .disabled(sending)
                            .accessibilityLabel(Text("stx.reply.send"))
                        } else {
                            // the one-tap like beside the reply box: a private like, no chat message
                            Button { Task { await react(statusLike) } } label: {
                                Image(systemName: myReact == statusLike ? "heart.fill" : "heart")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(myReact == statusLike ? Color.red : .white)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(Text(LocalizedStringKey(myReact == statusLike ? "stx.unlike" : "stx.like")))
                            .accessibilityAddTraits(myReact == statusLike ? .isSelected : [])
                        }
                    }
                }
                .animation(.easeOut(duration: 0.18), value: replyFocused)
                .padding(.bottom, 10)
            }
        }
    }

    // MARK: playback

    private func show() async {
        player?.pause()
        player = nil
        musicPlayer?.pause()
        musicPlayer = nil
        image = nil
        poster = nil
        videoStarted = false
        progress = 0
        ready = false
        guard let post else { return }
        if !group.isMine && !post.seen { Task { await APIClient.shared.statusSeen(token: token, id: post.id) } }

        var seconds = photoSeconds
        var video: AVPlayer?
        switch post.kind {
        case "image":
            if let d = await APIClient.shared.statusMedia(token: token, id: post.id) { image = UIImage(data: d) }
        case "video", "voice":
            // starts at once (no waiting for the length or a big buffer); the bar follows the video's own clock below
            let pl = StatusVideo.player(token: token, id: post.id, muted: muted)
            player = pl
            video = pl
            if !paused { pl.play() }
            if let ms = post.duration_ms, ms > 0 { seconds = min(Double(ms) / 1000, 60) }
            if post.kind == "video" {
                // the poster (memory-cached; prefetched while the story before was on screen) shows while it loads
                let id = post.id
                Task {
                    guard let d = await APIClient.shared.statusMedia(token: token, id: id, poster: true),
                          let img = UIImage(data: d), self.post?.id == id else { return }
                    poster = img
                }
            }
        default:
            break
        }
        // the status's music (the app's own library): plays while it is on screen; photos and text stay 15 s to hear it
        if let m = post.music, !m.isEmpty, let url = APIClient.shared.stMusicURL(m) {
            if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers]) } // never cut a running call's microphone
            if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setActive(true) } // never cut a running call's microphone
            let mp = AVPlayer(url: url)
            mp.isMuted = muted
            musicPlayer = mp
            if post.kind != "video" && post.kind != "voice" { seconds = 15 } else { mp.volume = 0.5 }
            if !paused { mp.play() }
        }
        ready = true
        prefetchNext()
        if let video {
            await runVideo(video, post: post, fallback: seconds)
            return
        }
        await runClock(seconds)
    }

    /// Photos and text (and a video that cannot play): advance on a clock (pausing holds it).
    private func runClock(_ seconds: Double, from already: Double = 0) async {
        let start = Date()
        var pausedFor: TimeInterval = 0
        var pausedAt: Date?
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            if paused {
                if pausedAt == nil { pausedAt = Date() }
                continue
            }
            if let pa = pausedAt { pausedFor += Date().timeIntervalSince(pa); pausedAt = nil }
            let t = already + Date().timeIntervalSince(start) - pausedFor
            progress = min(1, t / seconds)
            if t >= seconds { next(); return }
        }
    }

    /// A video or voice status: the bar follows the player's own time over the real length (so it waits while the video
    /// loads or stalls), and the next story comes when the video ends (at most 60 s, as before).
    private func runVideo(_ pl: AVPlayer, post: StatusPost, fallback: Double) async {
        guard let item = pl.currentItem else { return }
        let opened = Date()
        var logged = post.kind != "video"
        let end = StatusEndFlag()
        let obs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            end.ended = true
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            if item.status == .failed {
                if !logged { MediaLog.record(id: post.id, ok: false, ms: Int(Date().timeIntervalSince(opened) * 1000)) }
                // it cannot play: the story still moves on, on a clock
                videoStarted = true
                await runClock(fallback, from: fallback * progress)
                return
            }
            let t = pl.currentTime().seconds
            if !videoStarted, t.isFinite, t > 0.01 {
                videoStarted = true // the first frame is up: the spinner goes
                if !logged {
                    logged = true
                    MediaLog.record(id: post.id, ok: true, ms: Int(Date().timeIntervalSince(opened) * 1000))
                }
            }
            if paused { continue }
            let d = item.duration.seconds
            let total = d.isFinite && d > 0 ? min(d, 60) : 0
            if total > 0, t.isFinite {
                progress = min(1, max(0, t / total))
                if end.ended || t >= total - 0.04 { next(); return }
            } else if end.ended {
                next()
                return
            }
            StatusVideo.resumeIfStalled(pl)
        }
    }

    /// Fetch the next story's photo (or video poster) while this one is on screen, so it shows at once.
    private func prefetchNext() {
        var ng = g
        var np = p + 1
        if np >= groups[ng].posts.count { ng += 1; np = 0 }
        guard groups.indices.contains(ng), groups[ng].posts.indices.contains(np) else { return }
        let n = groups[ng].posts[np]
        let id = n.id
        let tok = token
        switch n.kind {
        case "image": Task(priority: .utility) { _ = await APIClient.shared.statusMedia(token: tok, id: id) }
        case "video": Task(priority: .utility) { _ = await APIClient.shared.statusMedia(token: tok, id: id, poster: true) }
        default: break
        }
    }

    private func setPaused(_ v: Bool) {
        paused = v
        if v { player?.pause(); musicPlayer?.pause() } else { player?.play(); musicPlayer?.play() }
    }

    private func next() {
        if p + 1 < group.posts.count {
            p += 1
        } else if g + 1 < groups.count {
            g += 1
            p = 0
        } else {
            close()
        }
    }

    /// Swipe up: the next person's statuses.
    private func nextPerson() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragY = 0 }
        if g + 1 < groups.count {
            g += 1
            p = 0
        } else {
            close()
        }
    }

    /// Swipe right: the previous person's statuses (on the first person nothing happens).
    private func previousPerson() {
        guard g > 0 else { return }
        g -= 1
        p = 0
    }

    /// Someone else's personal status: a reply or a quick reaction goes to the owner's chat.
    private var canReply: Bool { !group.isMine && group.group_id == nil }

    /// A tap on the stage: on the dark area around the picture or video it closes the viewer (not while a sheet, the
    /// emoji panel or the keyboard is up); else the left third goes back and the rest forward.
    private func tapStage(at pt: CGPoint, in size: CGSize) {
        // the finger was holding the story or swiping it: its lift is not a tap
        if holding || dragAxis != nil || closing || Date().timeIntervalSince(lastGestureAt) < 0.35 { return }
        if !showViewers && !confirmDelete && !showEmoji && !replyFocused,
           let r = statusFittedRect(kind: post?.kind, image: post?.kind == "video" ? poster : image, player: player, in: size),
           !r.insetBy(dx: -1, dy: -1).contains(pt) {
            close()
            return
        }
        if pt.x < size.width / 3 { previous() } else { next() }
    }

    /// What I reacted to this status with: changed on this visit, else sent earlier this session, else what the server remembers.
    private var myReact: String {
        guard let post else { return "" }
        return myReacts[post.id] ?? StatusReactCache.shared.get(post.id) ?? post.my_reaction ?? ""
    }

    private func showBurst(_ emoji: String) {
        let key = UUID()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { burst = (emoji, key) }
        Task { try? await Task.sleep(nanoseconds: 1_100_000_000); if burst?.key == key { withAnimation { burst = nil } } }
    }

    /// The like (the heart): recorded on the status only; the owner sees it in "Viewed by" and nothing goes to the chat
    /// (WhatsApp). The heart again takes it back.
    private func react(_ emoji: String) async {
        guard let post, !reacting else { return }
        reacting = true
        defer { reacting = false }
        let prev = myReact
        let next = prev == emoji ? "" : emoji
        myReacts[post.id] = next
        if !next.isEmpty { showBurst(next) }
        do {
            _ = try await APIClient.shared.postJSON("status/\(post.id)/react", token: token, body: ["Emoji": next])
        } catch {
            myReacts[post.id] = prev // not recorded: show what is really there
            return
        }
        StatusReactCache.shared.set(post.id, next) // so the like still shows when this status is opened again
        // any reaction other than the like is also announced in the owner's chat (the heart is private)
        guard !next.isEmpty, next != statusLike else { return }
        await sendReactionLine(next, for: post)
    }

    /// A quick reaction from the big grid: the emoji floats up and goes to the owner's chat as a reaction line; the like
    /// stays as it is and the status plays on.
    private func quickReact(_ emoji: String) async {
        guard let post else { return }
        showBurst(emoji)
        reply = ""
        replyFocused = false
        if !(await sendReactionLine(emoji, for: post)) {
            replyNote = NSLocalizedString("stx.reply.failed", comment: "")
        }
    }

    /// "😂 Reacted to your status · Photo" in the owner's chat (web statusReactBody). True when it was sent.
    @discardableResult
    private func sendReactionLine(_ emoji: String, for post: StatusPost) async -> Bool {
        let cap = (post.kind == "text" ? (post.text ?? "") : (post.caption ?? "")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let what: String
        if !cap.isEmpty {
            what = "“" + (cap.count > 60 ? String(cap.prefix(59)) + "…" : cap) + "”"
        } else {
            switch post.kind {
            case "image": what = "Photo"
            case "video": what = "Video"
            case "voice": what = "Voice status"
            default: what = "Status"
            }
        }
        do {
            let conv = try await APIClient.shared.directConversation(token: token, with: group.user_id)
            _ = try await APIClient.shared.sendText(token: token, conversationID: conv, body: "\(emoji) Reacted to your status · \(what)",
                                                    key: UUID().uuidString.lowercased())
            return true
        } catch {
            return false
        }
    }

    private func sendReply() async {
        guard let post else { return }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let conv = try await APIClient.shared.directConversation(token: token, with: group.user_id)
            let what: String
            switch post.kind {
            case "text": what = "“" + String((post.text ?? "").prefix(80)) + "”"
            case "video": what = "🎬"
            case "voice": what = "🎤"
            default: what = "📷"
            }
            let body = String(format: NSLocalizedString("stx.reply.quote", comment: ""), what) + "\n" + text
            _ = try await APIClient.shared.sendText(token: token, conversationID: conv, body: body, key: UUID().uuidString.lowercased())
            reply = ""
            replyFocused = false
            replyNote = nil
            // as in WhatsApp: the reply is sent, the status closes and the chat with that person opens with the reply in it
            close()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000) // let the viewer go first
                LocalNotifier.shared.tappedConversation = conv
            }
        } catch {
            replyNote = NSLocalizedString("stx.reply.failed", comment: "")
        }
    }

    private func previous() {
        if p > 0 {
            p -= 1
        } else if g > 0 {
            g -= 1
            p = max(0, groups[g].posts.count - 1)
        } else {
            progress = 0
        }
    }

    private func close() {
        player?.pause()
        dismiss()
    }

    private func deleteCurrent() async {
        guard let post else { return }
        try? await APIClient.shared.statusDelete(token: token, id: post.id)
        close()
    }
}

struct StatusViewersSheet: View {
    let token: String
    let postID: String
    /// The status's view count, shown in the title until the list has loaded.
    var views: Int = 0
    @State private var viewers: [StatusViewerEntry] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            // WhatsApp: "N views", a heart badge on those who liked it, "today 12:31 AM"
            List(viewers) { v in StatusViewerLine(token: token, viewer: v) }
            .overlay {
                if loading { ProgressView() } else if viewers.isEmpty { Text("status.noviews").foregroundStyle(.secondary) }
            }
            .navigationTitle(Text(statusViewsTitle(loading ? views : viewers.count)))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            viewers = (try? await APIClient.shared.statusViewers(token: token, id: postID)) ?? []
            loading = false
        }
    }
}

/// Writing a text status: the words, a background and a type style (the server's allowed ids).
struct TextStatusComposer: View {
    let onPost: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var bg = StatusStyle.backgrounds[0].id
    @State private var font = StatusStyle.fonts[0].id
    @FocusState private var focused: Bool

    private var style: String { "\(bg):\(font)" }

    var body: some View {
        let (b, f) = StatusStyle.parts(style)
        ZStack {
            StatusStyle.background(style).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.bold()) }
                        .accessibilityLabel(Text("chat.close"))
                    Spacer()
                    Button {
                        let i = StatusStyle.fonts.firstIndex { $0.id == font } ?? 0
                        font = StatusStyle.fonts[(i + 1) % StatusStyle.fonts.count].id
                    } label: { Image(systemName: "textformat").font(.title3.bold()) }
                        .accessibilityLabel(Text("status.font"))
                    Button {
                        let i = StatusStyle.backgrounds.firstIndex { $0.id == bg } ?? 0
                        bg = StatusStyle.backgrounds[(i + 1) % StatusStyle.backgrounds.count].id
                    } label: { Image(systemName: "paintpalette").font(.title3.bold()) }
                        .padding(.leading, 18)
                        .accessibilityLabel(Text("status.color"))
                }
                .foregroundStyle(b.ink)
                .padding()
                Spacer()
                TextField("status.text.placeholder", text: $text, axis: .vertical)
                    .focused($focused)
                    .font(.system(size: StatusStyle.size(for: text.isEmpty ? "Aa" : text), weight: f.weight, design: f.design))
                    .italic(f.italic)
                    .foregroundStyle(b.ink)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .onChange(of: text) { t in if t.count > 700 { text = String(t.prefix(700)) } }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onPost(t, bg, font)
                        dismiss()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 54, height: 54)
                            .background(Theme.accent, in: Circle())
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text("status.post"))
                }
                .padding()
            }
        }
        .onAppear { focused = true }
    }
}
