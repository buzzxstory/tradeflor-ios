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
    @Environment(\.scenePhase) private var scenePhase
    @State private var g: Int
    @State private var p: Int
    /// how far the story on screen has played: read only by the bars and a voice status's art (not this whole screen)
    @State private var clock = StatusClock()
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
    /// One Idempotency-Key per draft: a send retried after a lost answer is not delivered twice.
    @State private var replyKey: String?
    @State private var loadFailed = false
    @State private var sending = false
    @FocusState private var replyFocused: Bool
    @State private var myReacts: [String: String] = [:] // changed on this visit
    @State private var burst: (emoji: String, key: UUID)?
    @State private var reacting = false
    @State private var showEmoji = false // the full emoji panel for the reply (the button in the reply box)
    @State private var deleting = false
    /// bumped to start the same story again (a tap back on the very first one: the bar went to 0 but the clock ran on)
    @State private var round = 0
    @State private var deleteFailed = false
    /// bumped when a status is marked gone while this screen is open (redraws the "no longer available" note)
    @State private var goneTick = 0

    private let photoSeconds = 5.0
    /// How long "This status is no longer available" stays before the viewer moves on (web GONE_MS).
    private let goneSeconds = 1.4

    /// Deleted (the owner, live; or the server refused it) or past its 24 hours: never shown from what this screen holds.
    private var postGone: Bool {
        _ = goneTick
        guard let post else { return false }
        return StatusGone.shared.contains(post.id) || StatusGone.expired(post.expires_at)
    }
    /// What the viewer shows for an empty list (it closes at once): never an out-of-range read.
    private static let emptyGroup = StatusGroup(user_id: "", username: "", mine: nil, group_id: nil, group_name: nil, can_post: nil,
                                                posts: [], all_seen: true, latest: 0)

    private enum SwipeAxis { case down, up, side }

    init(groups: [StatusGroup], startGroup: Int, token: String, onClose: @escaping () -> Void) {
        self.groups = groups
        self.token = token
        self.onClose = onClose
        // never an index past the list (a list that changed between the tap and the cover opening crashed here)
        let start = min(max(0, startGroup), max(0, groups.count - 1))
        _g = State(initialValue: start)
        // as on the web: it opens on the first status not watched yet
        _p = State(initialValue: groups.indices.contains(start) ? Self.firstUnseen(groups[start]) : 0)
    }

    /// The first post of a person not watched yet (else the first).
    private static func firstUnseen(_ g: StatusGroup) -> Int {
        g.posts.firstIndex { !$0.seen } ?? 0
    }

    private var group: StatusGroup { groups.indices.contains(g) ? groups[g] : (groups.first ?? StatusViewerScreen.emptyGroup) }
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
        .task(id: "\(g)-\(p)-\(round)") { await show() }
        .onChange(of: holding) { h in
            if h { setPaused(true) } else { lastGestureAt = Date(); resume() }
        }
        // the app left the front (Home, lock): the story waits, so no sound plays and no later story is marked seen
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
        .onChange(of: reply) { _ in replyKey = nil }
        .onChange(of: showEmoji) { _ in resume() }
        .onChange(of: showViewers) { _ in resume() }
        .onChange(of: confirmDelete) { _ in resume() }
        .animation(.easeOut(duration: 0.18), value: replyFocused)
        .confirmationDialog(Text("status.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("status.delete", role: .destructive) { Task { await deleteCurrent() } }
        }
        .alert(Text("chat.action.failed"), isPresented: $deleteFailed) {
            Button("chat.close", role: .cancel) {}
        }
        .onChange(of: deleteFailed) { _ in resume() }
        // web: silent during a call (the story's sound went into the call)
        .onAppear { if CallManager.shared.lineInUse { muted = true } }
        // the story's task may have made its players before that line ran: they always follow `muted`
        .onChange(of: muted) { m in
            player?.isMuted = m
            musicPlayer?.isMuted = m
        }
        // sound comes back after a call, Siri, another app's audio, the phone returning to the front, AirPods in or out
        .modifier(StatusAudioKeeper { restoreAudio() })
        // the status on screen was deleted meanwhile: its players stop, the note shows, and the viewer moves on
        .onReceive(NotificationCenter.default.publisher(for: .tfStatusGone)) { n in
            guard let id = n.object as? String, id == post?.id else { return }
            goneTick += 1
            round += 1
        }
        .overlay {
            // web .status-burst: 104 pt, a little below the middle, floats up and fades
            if let b = burst {
                StatusBurstView(emoji: b.emoji)
                    .id(b.key)
                    .offset(y: stageH * 0.02)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear {
            // every player stops and is let go (a music track kept playing after a swipe-down before)
            player?.pause()
            player = nil
            musicPlayer?.pause()
            musicPlayer = nil
            StatusAudio.release() // other apps' music may carry on
            // the lists are read again once the "seen" calls have arrived, so no ring stays turquoise after watching
            let done = onClose
            Task { @MainActor in
                await StatusSeenQueue.shared.drain()
                done()
                NotificationCenter.default.post(name: .tfStatusChanged, object: nil)
            }
        }
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
            // VoiceOver: the taps on the sides are not reachable, so next / previous / pause are actions of the story
            .accessibilityElement()
            .accessibilityLabel(Text("stx.a11y.story"))
            .accessibilityAction(named: Text("stx.a11y.next")) { next() }
            .accessibilityAction(named: Text("stx.a11y.previous")) { previous() }
            .accessibilityAction(named: Text("stx.a11y.pause")) { userPausedToggle() }
            // WhatsApp's quick reactions: the status dims and eight big emojis come up while the reply box is focused
            if canReply && replyFocused && !showEmoji && post != nil {
                StatusQuickGrid(onPick: { e in Task { await quickReact(e) } }, onDismiss: { replyFocused = false })
                    .transition(.opacity)
            }
            // web phone: bars 10 pt below the safe area, the head 12 pt under them, both 10 pt from the sides
            VStack(spacing: 9) {
                bars
                header
                musicChip
                Spacer()
                footer
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
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
            if canManage, post != nil {
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
        userPaused || replyFocused || showEmoji || showViewers || confirmDelete || deleteFailed || deleting || holding
            || dragAxis == .down || closing
    }

    private func resume() { setPaused(mustHold) }

    private func userPausedToggle() { userPaused.toggle(); resume() }

    /// After an interruption, a route change or coming back to the front: the audio is set up again, the players follow the
    /// speaker button (`muted`) and play on unless the story is held.
    private func restoreAudio() {
        guard !closing, post != nil, !postGone else { return }
        if !muted { StatusAudio.prepare() }
        player?.isMuted = muted
        StatusAudio.full(player)
        musicPlayer?.isMuted = muted
        if !paused { player?.play(); musicPlayer?.play() }
    }

    @ViewBuilder private var content: some View {
        if postGone {
            Text("stx.gone").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center).padding(24)
        } else if let post {
            switch post.kind {
            case "text":
                let (bg, font) = StatusStyle.parts(post.style)
                ZStack {
                    StatusStyle.background(post.style)
                    Text(post.text ?? "")
                        .font(.system(size: StatusStyle.size(for: post.text ?? ""), weight: font.weight, design: font.design))
                        .italic(font.italic && !tfHasArabic(post.text ?? ""))
                        .foregroundStyle(bg.ink)
                        .multilineTextAlignment(.center)
                        .padding(28)
                }
            case "video":
                // our own AVPlayerLayer (no system controls); the poster shows at once underneath until the first frame
                ZStack {
                    if let poster { Image(uiImage: poster).resizable().scaledToFit() }
                    if let player { StatusVideoLayer(player: player) }
                    if loadFailed && poster == nil {
                        Text("stx.load.failed").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).padding(24)
                    } else if !videoStarted { ProgressView().tint(.white) }
                }
            case "image":
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loadFailed {
                    Text("stx.load.failed").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).padding(24)
                } else {
                    ProgressView().tint(.white)
                }
            case "voice":
                // web VoiceStatusArt: the speaker in the middle, breathing rings, lit bars and "0:12 / 0:40"
                StatusClockReader(clock: clock) { progress in
                    StatusVoiceArt(playing: videoStarted && !paused, progress: progress, durationMs: post.duration_ms ?? 0) {
                        Avatar(token: token, userID: group.user_id, avatarID: nil, title: group.title, groupID: group.group_id, size: 108)
                    }
                }
            default:
                Text("status.unsupported").foregroundStyle(.white.opacity(0.8)).padding()
            }
        }
    }

    private var bars: some View {
        StatusBars(count: group.posts.count, current: p, clock: clock)
    }

    /// web .status-head (phone): the picture (38 pt), the name (15 pt bold) over "6 h ago" (13 pt), then round 44 pt dark
    /// buttons: sound (a video, a voice note or music), delete (my own status, web's trash) and close. No pause button and no
    /// "more" menu on the phone (hold to pause; who viewed it is the eye at the bottom).
    private var header: some View {
        HStack(spacing: 10) {
            Avatar(token: token, userID: group.user_id, avatarID: nil, title: group.title, groupID: group.group_id, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.isMine && group.group_id == nil ? NSLocalizedString("status.mine", comment: "") : group.title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text((group.group_id != nil ? NSLocalizedString("ux2.status.group", comment: "") + " · " : "") + statusAgo(post?.date))
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if post?.kind == "video" || post?.kind == "voice" || post?.music != nil {
                StatusHeadButton(systemName: muted ? "speaker.slash" : "speaker.wave.2", label: LocalizedStringKey(muted ? "stx.unmute" : "stx.mute")) {
                    muted.toggle()
                    // turning the sound on also makes sure the phone's audio is set up for it (it was not when the story
                    // opened during a call, or with a leftover call route), then the players follow
                    if !muted { StatusAudio.prepare() }
                    player?.isMuted = muted
                    StatusAudio.full(player)
                    musicPlayer?.isMuted = muted
                }
            }
            if canManage, post != nil, !postGone {
                StatusHeadButton(systemName: "trash", label: "stx.delete") {
                    guard !deleting else { return }
                    setPaused(true)
                    confirmDelete = true
                }
            }
            StatusHeadButton(systemName: "xmark", label: "chat.close") { close() }
        }
    }

    /// web .status-music-chip: centred under the head (74 pt below the safe area), 32 pt high, dark glass.
    @ViewBuilder private var musicChip: some View {
        if let m = post?.music, !m.isEmpty, !postGone {
            Label(StatusMusic.title(m), systemImage: "music.note")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Color.black.opacity(0.35), in: Capsule())
                .frame(maxWidth: 280)
                .padding(.top, 2)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(String(format: NSLocalizedString("stx.music.on", comment: ""), StatusMusic.title(m))))
        }
    }

    /// The reply bar's turquoise (web --tq #2fd9dc).
    private var tq: Color { Theme.hex(0x2FD9DC) }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if postGone {
                EmptyView()
            } else {
            if let c = post?.caption, !c.isEmpty {
                // web .status-caption: a full-width band with a dark fade, not a bubble
                StatusCaptionBand(text: c)
                    .padding(.horizontal, -10)
                    .allowsHitTesting(false)
            }
            if canManage, let post {
                // web .status-views-wa: "^" over "eye N" on a small dark glass plate (radius 16); opens the "N views" list
                Button { setPaused(true); showViewers = true } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold)).opacity(0.8)
                        HStack(spacing: 7) {
                            Image(systemName: "eye").font(.system(size: 15, weight: .medium))
                            Text(verbatim: "\(post.views ?? 0)").font(.system(size: 15, weight: .semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                            .overlay(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.32)))
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
                .accessibilityLabel(Text(statusViewsTitle(post.views ?? 0)))
                .accessibilityHint(Text("stx.views.show"))
            } else if group.group_id == nil {
                // web .status-replybar: a 46 pt dark-teal field with a turquoise rim, the emoji button inside its end, and a
                // 46 pt round heart (or the turquoise send button once something is typed) beside it
                VStack(spacing: 8) {
                    if let replyNote {
                        Text(replyNote).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.hex(0xB8414A), in: Capsule())
                    }
                    HStack(spacing: 10) {
                        HStack(spacing: 2) {
                            TextField("", text: $reply, prompt: Text(String(format: NSLocalizedString("stx.reply.ph", comment: ""), group.username))
                                .foregroundColor(Theme.hex(0xD6E6ED, 0.55)))
                                .font(.system(size: 16))
                                .focused($replyFocused)
                                .foregroundStyle(.white)
                                .tint(tq)
                                .submitLabel(.send)
                                .onSubmit { Task { await sendReply() } }
                                .onChange(of: replyFocused) { _ in resume() }
                                .onChange(of: reply) { t in
                                    if t.count > 2000 { reply = String(t.prefix(2000)) }
                                    if replyNote != nil { replyNote = nil }
                                }
                            // the full emoji panel for the reply
                            Button {
                                setPaused(true)
                                showEmoji = true
                            } label: {
                                Image(systemName: "face.smiling").font(.system(size: 20))
                                    .foregroundStyle(showEmoji ? tq : Theme.hex(0xD6E6ED, 0.72))
                                    .frame(width: 36, height: 36)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("stv.emoji"))
                        }
                        .padding(.leading, 20).padding(.trailing, 6).frame(height: 46)
                        .background(Theme.hex(0x051A24, 0.78), in: Capsule())
                        .overlay(Capsule().stroke(replyNote != nil ? Theme.hex(0xFF8282, 0.7) : (replyFocused ? tq : tq.opacity(0.35)), lineWidth: 1))
                        .shadow(color: replyFocused ? tq.opacity(0.12) : .clear, radius: 4)
                        if !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { Task { await sendReply() } } label: {
                                Group {
                                    if sending { ProgressView().tint(Theme.hex(0x032128)) } else { Image(systemName: "paperplane.fill").font(.system(size: 18, weight: .semibold)) }
                                }
                                .foregroundStyle(Theme.hex(0x032128))
                                .frame(width: 46, height: 46)
                                .background(LinearGradient(colors: [Theme.hex(0x5BE6E8), Theme.hex(0x12A9B4)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                                .shadow(color: tq.opacity(0.5), radius: 8, y: 6)
                                .opacity(sending ? 0.38 : 1)
                            }
                            .buttonStyle(.plain)
                            .disabled(sending)
                            .accessibilityLabel(Text("stx.reply.send"))
                        } else {
                            // the one-tap like beside the reply box: a private like, no chat message
                            let liked = myReact == statusLike
                            Button { Task { await react(statusLike) } } label: {
                                Image(systemName: liked ? "heart.fill" : "heart")
                                    .font(.system(size: 20, weight: .regular))
                                    .foregroundStyle(liked ? Theme.hex(0xFF3D5F) : .white)
                                    .frame(width: 46, height: 46)
                                    .background(Theme.hex(0x051A24, 0.62), in: Circle())
                                    .overlay(Circle().stroke(liked ? Theme.hex(0xFF3D5F, 0.55) : .white.opacity(0.28), lineWidth: 1))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(LocalizedStringKey(liked ? "stx.unlike" : "stx.like")))
                            .accessibilityAddTraits(liked ? .isSelected : [])
                        }
                    }
                }
                .animation(.easeOut(duration: 0.18), value: replyFocused)
                .padding(.horizontal, 2)
                .padding(.bottom, 14)
            }
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
        clock.progress = 0
        ready = false
        reply = ""; replyNote = nil // a half-typed reply belongs to the story it was typed on
        loadFailed = false
        if CallManager.shared.lineInUse { muted = true } // a call started while the viewer is open: its sound stays out of the call
        guard let post else {
            // nothing to show (an empty list): the viewer goes instead of staying black
            if groups.allSatisfy({ $0.posts.isEmpty }) { close() }
            return
        }
        if postGone {
            // deleted or past its 24 hours: "no longer available" for a moment, then the next one (web GONE_MS)
            try? await Task.sleep(nanoseconds: UInt64(goneSeconds * 1_000_000_000))
            if !Task.isCancelled { next() }
            return
        }
        if !group.isMine && !post.seen {
            let tok = token, id = post.id
            StatusSeenQueue.shared.add { await APIClient.shared.statusSeen(token: tok, id: id) }
        }

        var seconds = photoSeconds
        var video: AVPlayer?
        switch post.kind {
        case "image":
            let d = await APIClient.shared.statusMedia(token: token, id: post.id)
            // moved on meanwhile: this picture belongs to the story before (it flashed over the next one)
            if Task.isCancelled { return }
            // decoded off the main thread, no larger than the screen (UIImage(data:) decodes on the main thread when first drawn)
            var ui: UIImage?
            if let d { ui = await AvatarImages.decode(d, maxPixels: max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale) }
            if Task.isCancelled { return }
            if let ui { image = ui } else { loadFailed = true }
        case "video", "voice":
            // heard with the ring / silent switch on silent (the default session kept a voice status mute); never during a call
            StatusAudio.prepare()
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
                    let px = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
                    guard let d = await APIClient.shared.statusMedia(token: token, id: id, poster: true),
                          let img = await AvatarImages.decode(d, maxPixels: px), self.post?.id == id else { return }
                    poster = img
                }
            }
        default:
            break
        }
        // the status's music (the app's own library): plays while it is on screen; photos and text stay 15 s to hear it
        if let m = post.music, !m.isEmpty, let url = APIClient.shared.stMusicURL(m) {
            StatusAudio.prepare() // never during a call (it would cut the microphone)
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
            let stuck = !videoStarted && !paused && Date().timeIntervalSince(opened) > 15 // no first frame: do not spin for ever
            if item.status == .failed || stuck {
                if !logged { MediaLog.record(id: post.id, ok: false, ms: Int(Date().timeIntervalSince(opened) * 1000)) }
                // it cannot play: the story still moves on, on a clock
                loadFailed = true
                videoStarted = true
                await runClock(fallback, from: fallback * clock.progress)
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
                clock.progress = min(1, max(0, t / total))
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
            p = Self.firstUnseen(groups[g])
        } else {
            close()
        }
    }

    /// Swipe up: the next person's statuses.
    private func nextPerson() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { dragY = 0 }
        if g + 1 < groups.count {
            g += 1
            p = Self.firstUnseen(groups[g])
        } else {
            close()
        }
    }

    /// Swipe right: the previous person's statuses (on the first person nothing happens).
    private func previousPerson() {
        guard g > 0, groups.indices.contains(g - 1) else { return }
        g -= 1
        p = Self.firstUnseen(groups[g])
    }

    /// Someone else's personal status: a reply or a quick reaction goes to the owner's chat.
    private var canReply: Bool { !group.isMine && group.group_id == nil }

    /// Who sees the views and may delete (web `mine`): the owner of a personal status; the people who run the group (its
    /// owner and admins, the server's can_post) for a group's status. Group admins had neither before.
    private var canManage: Bool { group.group_id != nil ? (group.can_post ?? false) : group.isMine }

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
        Task { try? await Task.sleep(nanoseconds: 1_300_000_000); if burst?.key == key { withAnimation { burst = nil } } }
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
        guard let post, !reacting else { return }
        reacting = true
        defer { reacting = false }
        showBurst(emoji)
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
            // the emoji alone, with the status: the chat draws the status small and the reaction big (WhatsApp)
            _ = what
            _ = try await APIClient.shared.sendText(token: token, conversationID: conv, body: emoji,
                                                    key: UUID().uuidString.lowercased(), statusID: post.id, statusReact: true)
            return true
        } catch {
            return false
        }
    }

    private func sendReply() async {
        guard let post, !sending else { return } // Return and the send button together sent the reply twice
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
            _ = what
            let key = replyKey ?? UUID().uuidString.lowercased()
            replyKey = key
            // the reply text alone, with the status: the chat draws the status small above it (WhatsApp)
            _ = try await APIClient.shared.sendText(token: token, conversationID: conv, body: text, key: key,
                                                    statusID: post.id, statusReact: false)
            // the viewer moved on to another story while it was sending: the reply is sent, nothing more happens here
            guard self.post?.id == post.id, !closing else { return }
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
        } else if g > 0, groups.indices.contains(g - 1) {
            g -= 1
            p = max(0, groups[g].posts.count - 1)
        } else {
            round += 1
        }
    }

    private func close() {
        player?.pause()
        musicPlayer?.pause()
        dismiss()
    }

    /// Delete my status: once (a second tap while it is on its way does nothing); a refusal is said, and the story stays.
    private func deleteCurrent() async {
        guard let post, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await APIClient.shared.statusDelete(token: token, id: post.id)
            StatusGone.shared.mark(post.id) // its kept picture goes too
            close()
        } catch {
            setPaused(true)
            deleteFailed = true
        }
    }
}

struct StatusViewersSheet: View {
    let token: String
    let postID: String
    /// The status's view count, shown in the title until the list has loaded.
    var views: Int = 0
    @Environment(\.dismiss) private var dismiss
    @State private var viewers: [StatusViewerEntry] = []
    @State private var loading = true
    @State private var failed = false

    private var count: Int { loading || failed ? views : viewers.count }

    /// web .status-sheet-card: the deep teal glass sheet with soft curved light lines, an eye tile, "N views" over "Who viewed
    /// this status", a round close button and one rounded card per viewer (a heart badge on those who liked it, the time on the right).
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Theme.hex(0x062B36), Theme.hex(0x03141C)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ProfileHeroLines().frame(height: 220).opacity(0.8).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                header.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 14)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewers) { v in
                            StatusViewerLine(token: token, viewer: v)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 24)
                }
                .overlay {
                    if loading { ProgressView().tint(.white) }
                    else if failed { Text("chat.action.failed").foregroundStyle(.white.opacity(0.7)) }
                    else if viewers.isEmpty { Text("status.noviews").foregroundStyle(.white.opacity(0.7)) }
                }
            }
        }
        .foregroundStyle(Theme.hex(0xE8F2F8))
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            // a failed read says so (it showed "no views yet" before)
            do {
                viewers = try await APIClient.shared.statusViewers(token: token, id: postID)
                failed = false
            } catch {
                failed = true
            }
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye").font(.system(size: 22)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [Theme.hex(0x12B9C4), Theme.hex(0x0B6F86)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusViewsTitle(count)).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("stv.who").font(.system(size: 15)).foregroundStyle(Theme.hex(0xA9BCC6))
            }
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.black.opacity(0.28), in: Circle())
                    .overlay(Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("chat.close"))
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
    @State private var sent = false // a quick double tap posted the same text status twice
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
                    .italic(f.italic && !tfHasArabic(text))
                    .foregroundStyle(b.ink)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .onChange(of: text) { t in if t.count > 700 { text = String(t.prefix(700)) } }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty, !sent else { return }
                        sent = true
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
