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
    @State private var drag: CGFloat = 0
    @State private var showViewers = false
    @State private var confirmDelete = false

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
                .onChanged { v in if v.translation.height > 0 { drag = v.translation.height } }
                .onEnded { v in if v.translation.height > 120 { close() } else { withAnimation { drag = 0 } } }
        )
        .statusBarHidden()
        .task(id: "\(g)-\(p)") { await show() }
        .sheet(isPresented: $showViewers) {
            if let post { StatusViewersSheet(token: token, postID: post.id) }
        }
        .confirmationDialog(Text("status.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("status.delete", role: .destructive) { Task { await deleteCurrent() } }
        }
        .onDisappear { player?.pause(); onClose() }
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
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text("chat.close"))
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            if let c = post?.caption, !c.isEmpty {
                Text(c)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
            if group.isMine, let post {
                HStack {
                    Button { setPaused(true); showViewers = true } label: {
                        Label("\(post.views ?? 0)", systemImage: "eye")
                    }
                    Spacer()
                    Button(role: .destructive) { setPaused(true); confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(Text("status.delete"))
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: playback

    private func show() async {
        player?.pause()
        player = nil
        image = nil
        progress = 0
        ready = false
        guard let post else { return }
        if !group.isMine && !post.seen { Task { await APIClient.shared.statusSeen(token: token, id: post.id) } }

        var seconds = photoSeconds
        switch post.kind {
        case "image":
            if let d = await APIClient.shared.statusMedia(token: token, id: post.id) { image = UIImage(data: d) }
        case "video":
            let asset = AVURLAsset(url: APIClient.shared.statusMediaURL(id: post.id),
                                   options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
            let pl = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = pl
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { seconds = min(d.seconds, 60) }
            pl.play()
        default:
            break
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
        if v { player?.pause() } else { player?.play() }
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
