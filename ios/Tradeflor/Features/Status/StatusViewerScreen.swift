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
    @State private var drag: CGFloat = 0
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
    static let reactions = ["❤️", "😍", "😂", "😮", "😢", "👏", "🔥", "🙏"]

    private let photoSeconds = 5.0

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
            Color.black.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            // tap zones: left third back, the rest forward; holding pauses
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { previous() }
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { next() }
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { next() }
            }
            .environment(\.layoutDirection, .leftToRight)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25)
                    .onChanged { _ in setPaused(true) }
                    .onEnded { _ in setPaused(false) }
            )
            VStack(spacing: 10) {
                bars
                header
                Spacer()
                footer
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .offset(y: drag)
        .gesture(
            DragGesture()
                .onChanged { v in if v.translation.height > 0 && !replyFocused { drag = v.translation.height } }
                .onEnded { v in
                    if v.translation.height > 120 && !replyFocused { close() }
                    else if v.translation.height < -80 && !replyFocused { nextPerson() } // swipe up: the next person
                    else { withAnimation { drag = 0 } }
                }
        )
        .statusBarHidden()
        .task(id: "\(g)-\(p)") { await show() }
        .sheet(isPresented: $showViewers) {
            if let post { StatusViewersSheet(token: token, postID: post.id) }
        }
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
                if let player { VideoPlayer(player: player).disabled(true) } else { ProgressView().tint(.white) }
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
                setPaused(userPaused)
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
                Button { setPaused(true); showViewers = true } label: {
                    Label(String(format: NSLocalizedString("stx.views", comment: ""), post.views ?? 0), systemImage: "eye")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36).background(.black.opacity(0.45), in: Capsule())
                }
                .padding(.bottom, 12)
                .accessibilityLabel(Text("stx.views.show"))
            } else if group.group_id == nil {
                VStack(spacing: 6) {
                    if let replyNote { Text(replyNote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)) }
                    if replyFocused {
                        // the eight quick reactions above the reply box while typing (WhatsApp)
                        HStack(spacing: 6) {
                            ForEach(Self.reactions, id: \.self) { e in
                                Button { Task { await react(e) } } label: {
                                    Text(e).font(.system(size: 28)).frame(width: 40, height: 44)
                                        .background(myReact == e ? Color.white.opacity(0.22) : .clear, in: Circle())
                                }
                                .accessibilityLabel(Text(String(format: NSLocalizedString("stx.react.with", comment: ""), e)))
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    HStack(spacing: 8) {
                        TextField("", text: $reply, prompt: Text(String(format: NSLocalizedString("stx.reply.ph", comment: ""), group.title))
                            .foregroundColor(.white.opacity(0.6)))
                            .focused($replyFocused)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 44)
                            .background(.black.opacity(0.45), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                            .onChange(of: replyFocused) { f in setPaused(f || userPaused) }
                        if !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { Task { await sendReply() } } label: {
                                Group { if sending { ProgressView().tint(.white) } else { Image(systemName: "paperplane.fill") } }
                                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 44, height: 44).background(Theme.sendGradient, in: Circle())
                            }
                            .disabled(sending)
                            .accessibilityLabel(Text("stx.reply.send"))
                        } else {
                            // the one-tap like beside the reply box
                            Button { Task { await react("❤️") } } label: {
                                Image(systemName: myReact == "❤️" ? "heart.fill" : "heart")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(myReact == "❤️" ? Color.red : .white)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(Text(LocalizedStringKey(myReact == "❤️" ? "stx.unlike" : "stx.like")))
                            .accessibilityAddTraits(myReact == "❤️" ? .isSelected : [])
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
        progress = 0
        ready = false
        guard let post else { return }
        if !group.isMine && !post.seen { Task { await APIClient.shared.statusSeen(token: token, id: post.id) } }

        var seconds = photoSeconds
        switch post.kind {
        case "image":
            if let d = await APIClient.shared.statusMedia(token: token, id: post.id) { image = UIImage(data: d) }
        case "video", "voice":
            let asset = AVURLAsset(url: APIClient.shared.statusMediaURL(id: post.id),
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
            let pl = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            pl.isMuted = muted
            player = pl
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { seconds = min(d.seconds, 60) }
            if !paused { pl.play() }
        default:
            break
        }
        // the status's music (the app's own library): plays while it is on screen; photos and text stay 15 s to hear it
        if let m = post.music, !m.isEmpty, let url = APIClient.shared.stMusicURL(m) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let mp = AVPlayer(url: url)
            mp.isMuted = muted
            musicPlayer = mp
            if post.kind != "video" && post.kind != "voice" { seconds = 15 } else { mp.volume = 0.5 }
            if !paused { mp.play() }
        }
        ready = true
        // advance on a clock (pausing holds it)
        let start = Date()
        var pausedFor: TimeInterval = 0
        var pausedAt: Date?
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if paused {
                if pausedAt == nil { pausedAt = Date() }
                continue
            }
            if let pa = pausedAt { pausedFor += Date().timeIntervalSince(pa); pausedAt = nil }
            let t = Date().timeIntervalSince(start) - pausedFor
            progress = min(1, t / seconds)
            if t >= seconds { next(); return }
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
        withAnimation { drag = 0 }
        if g + 1 < groups.count {
            g += 1
            p = 0
        } else {
            close()
        }
    }

    /// A reply goes to the person's private chat as a message quoting the status (like the website).
    private var myReact: String {
        guard let post else { return "" }
        return myReacts[post.id] ?? post.my_reaction ?? ""
    }

    /// A quick reaction: recorded on the status (the owner sees it in Viewed by) and announced in the owner's chat.
    /// The same emoji again takes it back (no second message).
    private func react(_ emoji: String) async {
        guard let post, !reacting else { return }
        reacting = true
        defer { reacting = false }
        let prev = myReact
        let next = prev == emoji ? "" : emoji
        myReacts[post.id] = next
        if !next.isEmpty {
            let key = UUID()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { burst = (next, key) }
            Task { try? await Task.sleep(nanoseconds: 1_100_000_000); if burst?.key == key { withAnimation { burst = nil } } }
        }
        reply = ""
        replyFocused = false
        do {
            _ = try await APIClient.shared.postJSON("status/\(post.id)/react", token: token, body: ["Emoji": next])
        } catch {
            myReacts[post.id] = prev // not recorded: show what is really there
            return
        }
        guard !next.isEmpty else { return }
        // the chat line is a courtesy: if it cannot be sent, the reaction still stands
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
        if let conv = try? await APIClient.shared.directConversation(token: token, with: group.user_id) {
            _ = try? await APIClient.shared.sendText(token: token, conversationID: conv, body: "\(next) Reacted to your status · \(what)",
                                                     key: UUID().uuidString.lowercased())
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
            replyNote = String(format: NSLocalizedString("stx.reply.sent", comment: ""), group.title)
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
    @State private var viewers: [StatusViewerEntry] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List(viewers) { v in
                HStack {
                    Text(v.username)
                    if let r = v.reaction, !r.isEmpty { Text(r).accessibilityLabel(Text(String(format: NSLocalizedString("stx.reacted", comment: ""), r))) }
                    Spacer()
                    if let d = serverDate(v.viewed_at) { Text(d, style: .relative).foregroundStyle(.secondary).font(.caption) }
                }
            }
            .overlay {
                if loading { ProgressView() } else if viewers.isEmpty { Text("status.noviews").foregroundStyle(.secondary) }
            }
            .navigationTitle(Text("status.viewers"))
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
