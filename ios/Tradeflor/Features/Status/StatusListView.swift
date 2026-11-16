import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The Status tab: my status (with a button to post), then recent updates, then ones already seen.
struct StatusListView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var groups: [StatusGroup] = []
    @State private var loading = true
    @State private var failed = false
    @State private var open: StatusOpen?
    @State private var picked: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showText = false
    @State private var showCreator = false
    @State private var posting = false
    @State private var problem: String?

    private var token: String { store.session?.token ?? "" }
    private var mine: StatusGroup? { groups.first { $0.isMine && $0.group_id == nil } }
    private var others: [StatusGroup] { groups.filter { !($0.isMine && $0.group_id == nil) && !$0.posts.isEmpty } }
    private var recent: [StatusGroup] { others.filter { !$0.all_seen }.sorted { $0.latest > $1.latest } }
    private var viewed: [StatusGroup] { others.filter { $0.all_seen }.sorted { $0.latest > $1.latest } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    myRow
                }
                Section {
                    OfficialRow(token: token)
                }
                .listRowBackground(Theme.surface)
                if !recent.isEmpty {
                    Section(header: Text("status.recent")) {
                        ForEach(recent) { g in row(g) }
                    }
                }
                if !viewed.isEmpty {
                    Section(header: Text("status.viewed")) {
                        ForEach(viewed) { g in row(g) }
                    }
                }
                if !loading && others.isEmpty {
                    Section {
                        Text(LocalizedStringKey(failed ? "status.error" : "status.empty"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .toolbarBackground(Theme.ground, for: .navigationBar)
            .navigationTitle(Text("status.title"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreator = true } label: {
                        if posting { ProgressView() } else { Image(systemName: "plus.circle.fill").font(.title3) }
                    }
                    .disabled(posting)
                    .accessibilityLabel(Text("status.post"))
                }
            }
            .refreshable { await load() }
            .overlay { if loading && groups.isEmpty { ProgressView() } }
            .sheet(isPresented: $showCreator) { StatusCreatorSheet { Task { await load() } } }
            .alert(Text(problem ?? ""), isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("chat.close", role: .cancel) {}
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await load()
        }
        .fullScreenCover(item: $open) { o in
            StatusViewerScreen(groups: o.groups, startGroup: o.index, token: token) { Task { await load() } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraStudio(allowNote: false, onPhoto: { img in Task { await postPhoto(img) } }, onVideo: { url in Task { await postVideo(url) } })
        }
        .sheet(isPresented: $showText) {
            TextStatusComposer { text, bg, font in Task { await postText(text, bg: bg, font: font) } }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            picked = nil
            Task {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    if let movie = try? await item.loadTransferable(type: PickedMovie.self) { await postVideo(movie.url) }
                } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await postPhoto(img)
                }
            }
        }
    }

    private var myRow: some View {
        Button {
            if let m = mine, !m.posts.isEmpty { open = StatusOpen(groups: [m], index: 0) } else { showCreator = true }
        } label: {
            HStack(spacing: 12) {
                StatusRing(seen: true, count: mine?.posts.count ?? 0) {
                    StatusThumb(token: token, post: mine?.posts.last, fallback: String((store.session?.username ?? "?").prefix(1)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("status.mine").font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text(LocalizedStringKey((mine?.posts.isEmpty ?? true) ? "status.mine.add" : "status.mine.view"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func row(_ g: StatusGroup) -> some View {
        Button {
            let list = recent + viewed
            if let i = list.firstIndex(of: g) { open = StatusOpen(groups: list, index: i) }
        } label: {
            HStack(spacing: 12) {
                StatusRing(seen: g.all_seen, count: g.posts.count) {
                    StatusThumb(token: token, post: g.posts.last, fallback: String(g.title.prefix(1)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.title).font(.body.weight(.semibold)).foregroundStyle(.white)
                    if let d = serverDate(g.latest) {
                        Text(d, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            groups = try await APIClient.shared.statusFeed(token: token)
            failed = false
        } catch APIError.badCredentials {
            store.sessionExpired()
        } catch {
            failed = true
        }
    }

    // MARK: posting

    private func post(_ work: () async throws -> StatusPost) async {
        posting = true
        defer { posting = false }
        do {
            _ = try await work()
            await load()
        } catch APIError.refused(let why) {
            problem = why.isEmpty ? NSLocalizedString("status.post.failed", comment: "") : why
        } catch {
            problem = NSLocalizedString("status.post.failed", comment: "")
        }
    }

    private func postPhoto(_ img: UIImage) async {
        let encoded = await Task.detached(priority: .userInitiated) { ImagePrep.jpeg(from: img) }.value
        guard let jpeg = encoded else { return }
        await post { try await APIClient.shared.postStatus(token: token, file: jpeg, fileName: "status.jpg", mime: "image/jpeg") }
    }

    private func postVideo(_ url: URL) async {
        posting = true
        guard let out = await VideoPrep.mp4(from: url, maxBytes: 29_000_000) else {
            posting = false
            problem = NSLocalizedString("status.video.toolarge", comment: "")
            return
        }
        await post { try await APIClient.shared.postStatus(token: token, file: out.data, fileName: "status.mp4", mime: "video/mp4") }
    }

    private func postText(_ text: String, bg: String, font: String) async {
        await post { try await APIClient.shared.postStatus(token: token, file: nil, text: text, bg: bg, font: font) }
    }
}

struct StatusOpen: Identifiable {
    let id = UUID()
    let groups: [StatusGroup]
    let index: Int
}

/// The ring around a status picture: accent when there is something new, grey when all seen.
struct StatusRing<Content: View>: View {
    let seen: Bool
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 50, height: 50)
            .clipShape(Circle())
            .padding(3)
            .overlay(
                Circle().stroke(count == 0 ? Color.clear : (seen ? Color.gray.opacity(0.6) : Theme.accent), lineWidth: 2.5)
            )
    }
}

/// A small picture of a status: the photo, the video's poster, or the text status's colour.
struct StatusThumb: View {
    let token: String
    let post: StatusPost?
    let fallback: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let post, post.kind == "text" {
                StatusStyle.background(post.style)
                Text(post.text ?? "").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).lineLimit(3).padding(4)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.surface
                Text(fallback.uppercased()).font(.headline).foregroundStyle(Theme.accent)
            }
        }
        .task(id: post?.id) {
            guard let post, post.kind == "image" || (post.kind == "video" && post.poster == true) else { return }
            if let d = await APIClient.shared.statusMedia(token: token, id: post.id, poster: post.kind == "video") {
                image = UIImage(data: d)
            }
        }
    }
}

/// Text status backgrounds and fonts: the ids the server accepts (backend/internal/messaging/status_extras.go),
/// colours matching desktop/src/shared/lib/statusStyles.ts.
enum StatusStyle {
    struct Bg: Identifiable { let id: String; let colors: [Color]; let ink: Color }
    struct Font: Identifiable { let id: String; let design: SwiftUI.Font.Design; let weight: SwiftUI.Font.Weight; let italic: Bool }

    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static let backgrounds: [Bg] = [
        Bg(id: "teal", colors: [hex(0x0FB7C4), hex(0x0A6F9E)], ink: .white),
        Bg(id: "midnight", colors: [hex(0x12415A), hex(0x04131C)], ink: hex(0xEAF7FB)),
        Bg(id: "gold", colors: [hex(0xF6C453), hex(0xB7791F)], ink: hex(0x1D1405)),
        Bg(id: "rose", colors: [hex(0xFF7A93), hex(0xB4365A)], ink: .white),
        Bg(id: "violet", colors: [hex(0x8F6BFF), hex(0x4A2BB5)], ink: .white),
        Bg(id: "emerald", colors: [hex(0x2BD47D), hex(0x0D7A5B)], ink: .white),
        Bg(id: "sunset", colors: [hex(0xFFB347), hex(0xFF5F6D), hex(0x6A2C70)], ink: .white),
        Bg(id: "graphite", colors: [hex(0x3A4752), hex(0x11181E)], ink: hex(0xF2F6F8)),
    ]

    static let fonts: [Font] = [
        Font(id: "display", design: .default, weight: .heavy, italic: false),
        Font(id: "text", design: .default, weight: .medium, italic: false),
        Font(id: "bold", design: .rounded, weight: .heavy, italic: false),
        Font(id: "serif", design: .serif, weight: .semibold, italic: true),
        Font(id: "mono", design: .monospaced, weight: .semibold, italic: false),
    ]

    static func parts(_ style: String?) -> (Bg, Font) {
        let p = (style ?? "").split(separator: ":").map(String.init)
        let bg = backgrounds.first { $0.id == p.first } ?? backgrounds[0]
        let font = fonts.first { $0.id == (p.count > 1 ? p[1] : "") } ?? fonts[0]
        return (bg, font)
    }

    static func background(_ style: String?) -> some View {
        let bg = parts(style).0
        // light and grain over the colour (website 58-status-creator.css .tx-surface), in the composer and the viewer
        return ZStack {
            LinearGradient(colors: bg.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.26), .clear], center: UnitPoint(x: 0.18, y: 0.12), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [.black.opacity(0.28), .clear], center: UnitPoint(x: 0.92, y: 0.92), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [.white.opacity(0.1), .clear], center: UnitPoint(x: 0.85, y: 0.18), startRadius: 0, endRadius: 200)
            StatusGrain().opacity(0.16).blendMode(.overlay)
        }
    }

    /// Large for a few words, smaller as the text grows.
    static func size(for text: String) -> CGFloat {
        let n = text.count + text.split(separator: "\n").count * 18
        switch n {
        case ..<40: return 40
        case ..<90: return 32
        case ..<180: return 26
        case ..<360: return 21
        default: return 17
        }
    }
}

/// Fine film grain over text statuses (a fixed pattern).
struct StatusGrain: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 42)
            let count = Int(size.width * size.height / 36)
            for _ in 0..<count {
                let x = rng.next() * size.width, y = rng.next() * size.height
                let v = rng.next()
                ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(v > 0.5 ? .white : .black))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
