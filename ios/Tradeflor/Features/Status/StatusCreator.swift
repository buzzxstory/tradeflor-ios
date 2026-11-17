import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// The phone status creator (website MobileStatusCreator.tsx): "New status" / "Share a moment" with the tiles
/// Photos & videos, Camera, Text, Layout and Voice note; a queue with a caption per item; Add music; Post status.
struct StatusCreatorSheet: View {
    let onPosted: () -> Void
    /// A status for this group (its owner and admins), else my own.
    var groupID: String? = nil
    var groupName: String? = nil
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    struct Item: Identifiable {
        let id = UUID()
        var image: UIImage?
        var videoURL: URL?
        var caption = ""
    }

    @State private var items: [Item] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var layoutPicked: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showText = false
    @State private var showVoice = false
    @State private var showMusic = false
    @State private var layoutImages: [UIImage] = []
    @State private var music: String?
    @State private var posting = false
    @State private var progress = ""
    @State private var problem: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // v2 start (website 58-status-creator.css): the market behind the moment and a lit ring around me
                    StatusCreatorHero(token: token, userID: store.session?.userID ?? "", name: store.session?.username ?? "?")
                    Text("stx.share").font(.system(size: 14)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(Theme.accent)
                                .frame(width: 44, height: 44).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("stx.tile.media").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                                Text("stx.tile.media.sub2").font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            // a small photo stack
                            ZStack {
                                ForEach(0..<3, id: \.self) { k in
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(LinearGradient(colors: [Theme.hex(0x2FD9DC, 0.5 - Double(k) * 0.12), Theme.hex(0x0A3445)], startPoint: .top, endPoint: .bottom))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.3), lineWidth: 1))
                                        .frame(width: 30, height: 38)
                                        .rotationEffect(.degrees(Double(k - 1) * 10))
                                        .offset(x: CGFloat(k - 1) * 8)
                                }
                            }
                            .frame(width: 60)
                        }
                        .padding(14)
                        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderActive, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        Button { showCamera = true } label: { tile("camera", "stx.tile.camera", "stx.tile.camera.sub", Theme.hex(0x2FD9DC)) }
                        Button { showText = true } label: { tile("textformat", "stx.tile.text", "stx.tile.text.sub", Theme.hex(0xF2C14E)) }
                        PhotosPicker(selection: $layoutPicked, maxSelectionCount: 6, matching: .images) {
                            tile("square.grid.2x2", "stx.tile.layout", "stx.tile.layout.sub", Theme.hex(0xA78BFA))
                        }
                        Button { showVoice = true } label: { tile("mic", "stx.tile.voice", "stx.tile.voice.sub", Theme.hex(0xF472B6)) }
                    }
                    .buttonStyle(.plain)

                    if !items.isEmpty {
                        TFSectionLabel(text: String(format: NSLocalizedString("stx.queue", comment: ""), items.count))
                        ForEach($items) { $it in
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    if let img = it.image { Image(uiImage: img).resizable().scaledToFill() }
                                    else { Theme.card; Image(systemName: "video.fill").foregroundStyle(Theme.accent) }
                                }
                                .frame(width: 64, height: 86).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField("stx.caption", text: $it.caption, axis: .vertical).lineLimit(1...3)
                                        .foregroundStyle(Theme.text).padding(8)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                                    Button(role: .destructive) { items.removeAll { $0.id == it.id } } label: {
                                        Label("stx.remove.one", systemImage: "trash").font(.system(size: 12))
                                    }
                                }
                            }
                        }
                        Button { showMusic = true } label: {
                            Label(music.map { String(format: NSLocalizedString("stx.music.on", comment: ""), StatusMusic.title($0)) }
                                    ?? NSLocalizedString("stx.music.add", comment: ""), systemImage: "music.note")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14).frame(height: 38).overlay(Capsule().stroke(Theme.borderActive, lineWidth: 1))
                        }
                        Button { Task { await postAll() } } label: {
                            HStack {
                                Spacer()
                                if posting { ProgressView().tint(Theme.onAccent); Text(progress) } else { Text("stx.post").bold() }
                                Spacer()
                            }
                            .foregroundStyle(Theme.onAccent).frame(height: 48).background(Theme.accent, in: Capsule())
                        }
                        .disabled(posting)
                    }
                    if let problem { Text(problem).font(.system(size: 13)).foregroundStyle(Theme.danger) }
                    Text("stx.footer").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity).padding(.top, 8)
                }
                .padding(16)
            }
            .background(Starfield())
            .navigationTitle(groupName.map { Text(String(format: NSLocalizedString("stx.new.group", comment: ""), $0)) } ?? Text("stx.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .onChange(of: picked) { list in
            guard !list.isEmpty else { return }
            picked = []
            Task {
                for item in list {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let m = try? await item.loadTransferable(type: PickedMovie.self) { items.append(Item(videoURL: m.url)) }
                    } else if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                        items.append(Item(image: img))
                    }
                }
            }
        }
        .onChange(of: layoutPicked) { list in
            guard !list.isEmpty else { return }
            layoutPicked = []
            Task {
                var imgs: [UIImage] = []
                for item in list {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { imgs.append(img) }
                }
                if imgs.count >= 2 { layoutImages = imgs } else { problem = NSLocalizedString("stx.layout.min", comment: "") }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraStudio(allowNote: false, onPhoto: { img in items.append(Item(image: img)) }, onVideo: { url in items.append(Item(videoURL: url)) })
        }
        .sheet(isPresented: $showText) {
            TextStatusComposer { text, bg, font in
                Task {
                    do {
                        try await APIClient.shared.stPostTextStatus(token: token, groupID: groupID, text: text, bg: bg, font: font, music: music)
                        onPosted()
                        dismiss()
                    } catch APIError.refused(let why) {
                        problem = why
                    } catch {
                        problem = NSLocalizedString("status.post.failed", comment: "")
                    }
                }
            }
        }
        .sheet(isPresented: $showVoice) {
            VoiceStatusRecorder { data, ms in
                Task {
                    do {
                        try await APIClient.shared.stPostStatus(token: token, groupID: groupID, file: data, fileName: "voice.m4a", mime: "audio/mp4", voiceMs: ms)
                        onPosted()
                        dismiss()
                    } catch APIError.refused(let why) {
                        problem = why
                    } catch {
                        problem = NSLocalizedString("status.post.failed", comment: "")
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showMusic) { MusicPickerSheet(selection: $music) }
        .sheet(isPresented: Binding(get: { !layoutImages.isEmpty }, set: { if !$0 { layoutImages = [] } })) {
            LayoutBuilder(images: layoutImages) { img in
                items.append(Item(image: img))
                layoutImages = []
            }
        }
    }

    private func tile(_ icon: String, _ title: String, _ sub: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(tint)
                .frame(width: 40, height: 40).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(LocalizedStringKey(sub)).font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .padding(12)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) { Capsule().fill(tint.opacity(0.8)).frame(height: 2).padding(.horizontal, 18) }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private func postAll() async {
        posting = true
        problem = nil
        defer { posting = false }
        let list = items
        for (i, it) in list.enumerated() {
            progress = "\(i + 1)/\(list.count)"
            do {
                if let img = it.image {
                    let encoded = await Task.detached(priority: .userInitiated) { ImagePrep.jpeg(from: img) }.value
                    guard let jpeg = encoded else { continue }
                    try await APIClient.shared.stPostStatus(token: token, groupID: groupID, file: jpeg, fileName: "status.jpg", mime: "image/jpeg",
                                                            caption: it.caption, music: music)
                } else if let url = it.videoURL {
                    guard let out = await VideoPrep.mp4(from: url, maxBytes: 29_000_000) else {
                        problem = NSLocalizedString("status.video.toolarge", comment: "")
                        continue
                    }
                    try await APIClient.shared.stPostStatus(token: token, groupID: groupID, file: out.data, fileName: "status.mp4", mime: "video/mp4",
                                                            caption: it.caption, music: nil)
                }
                items.removeAll { $0.id == it.id }
            } catch APIError.refused(let why) {
                problem = why.isEmpty ? NSLocalizedString("status.post.failed", comment: "") : why
                return
            } catch {
                problem = NSLocalizedString("status.post.failed", comment: "")
                return
            }
        }
        onPosted()
        dismiss()
    }
}

/// The app's music library for statuses ("Made for TRADEFLOR · free to use").
enum StatusMusic {
    struct Track: Identifiable { let id: String; let title: String; let mood: String }
    static let tracks: [Track] = [
        Track(id: "calm-market", title: "Calm Market", mood: "Soft piano · 84 BPM"),
        Track(id: "gold-rush", title: "Gold Rush", mood: "Bright & upbeat · 120 BPM"),
        Track(id: "night-session", title: "Night Session", mood: "Lo-fi · 88 BPM"),
        Track(id: "breakout", title: "Breakout", mood: "Driving · 126 BPM"),
        Track(id: "sunrise", title: "Sunrise", mood: "Warm & hopeful · 100 BPM"),
        Track(id: "deep-focus", title: "Deep Focus", mood: "Ambient · 66 BPM"),
    ]
    static func title(_ id: String) -> String { tracks.first { $0.id == id }?.title ?? id }
}

struct MusicPickerSheet: View {
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playing: String?

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("stx.music.footer")) {
                    Button { selection = nil; dismiss() } label: {
                        HStack { Text("stx.music.none").foregroundStyle(Theme.text); Spacer(); if selection == nil { Image(systemName: "checkmark").foregroundStyle(Theme.accent) } }
                    }
                    ForEach(StatusMusic.tracks) { t in
                        HStack(spacing: 12) {
                            Button { toggle(t.id) } label: {
                                Image(systemName: playing == t.id ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(t.mood).font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Spacer()
                            Button { selection = t.id; player?.pause(); dismiss() } label: {
                                Image(systemName: selection == t.id ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.accent).font(.system(size: 20))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("stx.music"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { player?.pause(); dismiss() } } }
        }
        .onDisappear { player?.pause() }
    }

    private func toggle(_ id: String) {
        if playing == id { player?.pause(); playing = nil; return }
        guard let url = APIClient.shared.stMusicURL(id) else { return }
        if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setCategory(.playback) } // never cut a running call's microphone
        let p = AVPlayer(url: url)
        player?.pause()
        player = p
        playing = id
        p.play()
    }
}

/// 2 to 6 photos placed into one 1080 x 1920 picture (the website's layouts); tap two photos to swap them.
struct LayoutBuilder: View {
    let images: [UIImage]
    let onUse: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Int] = []
    @State private var layout = 0
    @State private var swapFrom: Int?

    struct Layout { let label: String; let cells: [CGRect] }
    static let all: [Int: [Layout]] = [
        2: [Layout(label: "Stacked", cells: [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]),
            Layout(label: "Side by side", cells: [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])],
        3: [Layout(label: "One big", cells: [CGRect(x: 0, y: 0, width: 1, height: 0.55), CGRect(x: 0, y: 0.55, width: 0.5, height: 0.45), CGRect(x: 0.5, y: 0.55, width: 0.5, height: 0.45)]),
            Layout(label: "Three rows", cells: [CGRect(x: 0, y: 0, width: 1, height: 1 / 3), CGRect(x: 0, y: 1 / 3, width: 1, height: 1 / 3), CGRect(x: 0, y: 2 / 3, width: 1, height: 1 / 3)])],
        4: [Layout(label: "Grid", cells: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]),
            Layout(label: "One big", cells: [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1 / 3, height: 0.5), CGRect(x: 1 / 3, y: 0.5, width: 1 / 3, height: 0.5), CGRect(x: 2 / 3, y: 0.5, width: 1 / 3, height: 0.5)])],
        5: [Layout(label: "Mosaic", cells: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0, y: 0.5, width: 1 / 3, height: 0.5), CGRect(x: 1 / 3, y: 0.5, width: 1 / 3, height: 0.5), CGRect(x: 2 / 3, y: 0.5, width: 1 / 3, height: 0.5)])],
        6: [Layout(label: "Grid", cells: [CGRect(x: 0, y: 0, width: 0.5, height: 1 / 3), CGRect(x: 0.5, y: 0, width: 0.5, height: 1 / 3), CGRect(x: 0, y: 1 / 3, width: 0.5, height: 1 / 3), CGRect(x: 0.5, y: 1 / 3, width: 0.5, height: 1 / 3), CGRect(x: 0, y: 2 / 3, width: 0.5, height: 1 / 3), CGRect(x: 0.5, y: 2 / 3, width: 0.5, height: 1 / 3)])],
    ]

    private var choices: [Layout] { Self.all[min(6, images.count)] ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let l = choices.indices.contains(layout) ? choices[layout] : choices.first {
                    GeometryReader { g in
                        let w = g.size.width, h = g.size.height
                        ZStack(alignment: .topLeading) {
                            Color.black
                            ForEach(Array(l.cells.enumerated()), id: \.offset) { i, c in
                                let idx = order.indices.contains(i) ? order[i] : i
                                Image(uiImage: images[min(idx, images.count - 1)]).resizable().scaledToFill()
                                    .frame(width: c.width * w - 4, height: c.height * h - 4)
                                    .clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(swapFrom == i ? Theme.accent : .clear, lineWidth: 3))
                                    .offset(x: c.minX * w + 2, y: c.minY * h + 2)
                                    .onTapGesture { tap(i) }
                            }
                        }
                    }
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("stx.layout.swap").font(.system(size: 12)).foregroundStyle(Theme.faint)
                HStack(spacing: 8) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { i, l in
                        FilterChip(title: l.label, selected: layout == i) { layout = i }
                    }
                }
                Button {
                    if let img = render() { onUse(img); dismiss() }
                } label: {
                    Text("stx.layout.use").bold().foregroundStyle(Theme.onAccent).frame(maxWidth: .infinity, minHeight: 46).background(Theme.accent, in: Capsule())
                }
            }
            .padding(16)
            .background(Theme.ground.ignoresSafeArea())
            .navigationTitle(Text("stx.tile.layout"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .onAppear { order = Array(0..<min(6, images.count)) }
    }

    private func tap(_ i: Int) {
        if let from = swapFrom, from != i, order.indices.contains(from), order.indices.contains(i) {
            order.swapAt(from, i)
            swapFrom = nil
        } else {
            swapFrom = i
        }
    }

    /// Draws the chosen layout into one 1080 x 1920 JPEG-ready image (cover-cropped cells, 8 px gaps).
    private func render() -> UIImage? {
        guard choices.indices.contains(layout) else { return nil }
        let l = choices[layout]
        let W: CGFloat = 1080, H: CGFloat = 1920, gap: CGFloat = 8
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            for (i, c) in l.cells.enumerated() {
                let idx = order.indices.contains(i) ? order[i] : i
                let img = images[min(idx, images.count - 1)]
                let x0 = (c.minX * W).rounded() + (c.minX == 0 ? gap : gap / 2)
                let y0 = (c.minY * H).rounded() + (c.minY == 0 ? gap : gap / 2)
                let x1 = (c.maxX * W).rounded() - (c.maxX >= 0.999 ? gap : gap / 2)
                let y1 = (c.maxY * H).rounded() - (c.maxY >= 0.999 ? gap : gap / 2)
                let cell = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                let s = max(cell.width / img.size.width, cell.height / img.size.height)
                let dw = img.size.width * s, dh = img.size.height * s
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: cell)
                img.draw(in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
                ctx.cgContext.restoreGState()
            }
        }
    }
}

/// A voice status: tap to record, up to 1 minute, listen, post.
struct VoiceStatusRecorder: View {
    let onPost: (Data, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()
    @State private var done: (data: Data, ms: Int)?
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        VStack(spacing: 18) {
            Text("stx.tile.voice").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            Text("stx.voice.hint").font(.system(size: 12)).foregroundStyle(Theme.faint)
            Text(VoiceBubble.length(Int64((done.map { Double($0.ms) / 1000 } ?? recorder.elapsed) * 1000)))
                .font(.system(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
            if recorder.recording {
                Waveform(samples: Array(recorder.levels.suffix(40)), progress: 1, color: Theme.accent).frame(height: 30)
            }
            HStack(spacing: 24) {
                if done != nil {
                    Button { listen() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 56, height: 56).background(Theme.card, in: Circle())
                    }
                    Button { done = nil } label: {
                        Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(Theme.danger)
                            .frame(width: 56, height: 56).background(Theme.card, in: Circle())
                    }
                    Button { if let d = done { player?.stop(); onPost(d.data, d.ms); dismiss() } } label: {
                        Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(Theme.sendGradient, in: Circle())
                    }
                } else {
                    Button {
                        if recorder.recording { stop() } else { Task { await recorder.start() } }
                    } label: {
                        Image(systemName: recorder.recording ? "stop.fill" : "mic.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(recorder.recording ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.sendGradient), in: Circle())
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .onChange(of: recorder.elapsed) { t in if t >= 60 { stop() } }
        .onDisappear { if recorder.recording { recorder.cancel() }; player?.stop() }
    }

    private func stop() {
        if let r = recorder.finish() { done = (r.data, r.durationMs) }
    }

    private func listen() {
        guard let d = done else { return }
        if playing { player?.pause(); playing = false; return }
        if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setCategory(.playback) } // never cut a running call's microphone
        player = try? AVAudioPlayer(data: d.data)
        player?.play()
        playing = true
    }
}


/// The status creator's start: a soft market line and candles behind a slowly rotating lit ring around my picture.
struct StatusCreatorHero: View {
    let token: String
    let userID: String
    let name: String
    @State private var spin = false

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / 390 * w, y: y / 300 * h) }
                var line = Path()
                line.move(to: pt(0, 210))
                line.addCurve(to: pt(90, 196), control1: pt(40, 200), control2: pt(60, 220))
                line.addCurve(to: pt(170, 168), control1: pt(120, 172), control2: pt(140, 150))
                line.addCurve(to: pt(250, 132), control1: pt(200, 186), control2: pt(220, 120))
                line.addCurve(to: pt(340, 84), control1: pt(280, 144), control2: pt(310, 70))
                line.addCurve(to: pt(390, 48), control1: pt(370, 98), control2: pt(380, 52))
                var area = line
                area.addLine(to: pt(390, 300)); area.addLine(to: pt(0, 300)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [Theme.hex(0x2FD9DC, 0.16), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(line, with: .linearGradient(Gradient(stops: [.init(color: Theme.hex(0x2FD9DC, 0), location: 0), .init(color: Theme.hex(0x2FD9DC, 0.55), location: 0.35),
                                                                        .init(color: Theme.hex(0xF2C14E, 0.45), location: 1)]),
                                                       startPoint: .zero, endPoint: CGPoint(x: w, y: 0)), lineWidth: 2)
                let candles: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(28, 176, 30, 0x2BD47D), (58, 168, 22, 0xF0525B), (300, 64, 34, 0x2BD47D), (326, 58, 26, 0xF2C14E), (352, 40, 30, 0x2BD47D)]
                for (x, y, ch, c) in candles {
                    var wick = Path(); wick.move(to: pt(x, y - 8)); wick.addLine(to: pt(x, y + ch + 8))
                    ctx.stroke(wick, with: .color(Theme.hex(c, 0.5)), lineWidth: 1.2)
                    ctx.fill(Path(roundedRect: CGRect(origin: pt(x - 4, y), size: CGSize(width: 8 / 390 * w, height: ch / 300 * h)), cornerRadius: 1.5), with: .color(Theme.hex(c, 0.5)))
                }
            }
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors: [Theme.hex(0x2FD9DC), Theme.hex(0xF2C14E), Theme.hex(0x2FD9DC, 0.1), Theme.hex(0x2FD9DC)], center: .center), lineWidth: 3)
                    .frame(width: 104, height: 104)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .shadow(color: Theme.hex(0x2FD9DC, 0.5), radius: 10)
                Avatar(token: token, userID: userID, avatarID: nil, title: name, size: 90)
            }
            .offset(y: -6)
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { spin = true } }
    }
}
