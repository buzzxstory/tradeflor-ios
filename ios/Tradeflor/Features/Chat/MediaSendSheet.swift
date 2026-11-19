import AVFoundation
import AVKit
import ImageIO
import PhotosUI
import SwiftUI

// Sending photos and videos like WhatsApp (website shared/components/MediaSendSheet.tsx): pick several, review them full screen,
// a caption for each, add more (+) or remove one, HD (the original size) or standard (1600 px), Send with the count.
// Photos can be edited first like WhatsApp iOS (MediaEditor.swift): crop & rotate, stickers, text, drawing; Save to Photos.

struct MediaDraft: Identifiable {
    let id = UUID()
    var image: UIImage?      // a photo, or a video's first frame
    /// A small copy for the strip (the strip drew every full-size photo at once: hundreds of MB).
    var thumb: UIImage? = nil
    var videoURL: URL?
    var caption = ""
    var isVideo: Bool { videoURL != nil }
}

enum MediaDrafts {
    static func load(_ items: [PhotosPickerItem]) async -> [MediaDraft] {
        var out: [MediaDraft] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    out.append(MediaDraft(image: await poster(movie.url), videoURL: movie.url))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                if let d = photoDraft(data) { out.append(d) }
            }
        }
        return out
    }

    /// The longest side the app ever sends (HD is fitted to 4096 px, standard to 1600): a bigger original (48 MP, ProRAW)
    /// is held at this size, not at 8-75 MB of picture data for each of up to 30 photos.
    private static let heldSide = 4096

    /// A photo draft built through ImageIO: the strip's small picture is decoded straight at its size (the whole picture
    /// was decoded for it before: hundreds of MB at once with a few big photos), and an oversize original is cut down once.
    private static func photoDraft(_ data: Data) -> MediaDraft? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            // not readable by ImageIO: the old way
            return UIImage(data: data).map { MediaDraft(image: $0, thumb: nil) }
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let thumb = scaled(src, maxPixel: 240)
        var image: UIImage?
        if max(w, h) > heldSide, let big = scaled(src, maxPixel: heldSide),
           let jpeg = big.jpegData(compressionQuality: 0.92), let again = UIImage(data: jpeg) {
            image = again
        } else {
            image = UIImage(data: data)
        }
        guard let image else { return nil }
        return MediaDraft(image: image, thumb: thumb)
    }

    /// The picture upright, at most `maxPixel` on its longer side, decoded at that size.
    private static func scaled(_ src: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    static func poster(_ url: URL) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 900, height: 900)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map(UIImage.init(cgImage:)))
            }
        }
    }
}

struct MediaSendSheet: View {
    /// At most this many photos and videos at a time (website MediaSendSheet MAX_MEDIA, 34a8e2a).
    static let maxItems = 30

    @State var items: [MediaDraft]
    let title: String
    let onSend: ([MediaDraft], _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction
    /// "Up to 30 photos and videos at a time." when a pick went past the limit (website Attachments addMedia)
    @State private var notice: String?

    init(items: [MediaDraft], title: String, onSend: @escaping ([MediaDraft], _ hd: Bool) -> Void) {
        _items = State(initialValue: Array(items.prefix(Self.maxItems)))
        _notice = State(initialValue: items.count > Self.maxItems ? Self.limitText : nil)
        self.title = title
        self.onSend = onSend
    }

    private static var limitText: String { String(format: NSLocalizedString("gp2.media.max", comment: ""), maxItems) }

    /// A video copied out of the picker into tmp ("pick-…"): deleted when it will not be sent.
    private static func removePickedCopy(_ d: MediaDraft) {
        guard let u = d.videoURL, u.lastPathComponent.hasPrefix("pick-") else { return }
        try? FileManager.default.removeItem(at: u)
    }
    private var room: Int { max(0, Self.maxItems - items.count) }
    @State private var index = 0
    @State private var hd = false
    @State private var adding: [PhotosPickerItem] = []
    @State private var showAdd = false
    @State private var player: AVPlayer?

    // WhatsApp-style editing (MediaEditor.swift): one edit per photo, flattened only when sent or saved
    @State private var edits: [UUID: MediaEdit] = [:]
    @State private var thumbs: [UUID: UIImage] = [:]
    @State private var tool: EditTool = .none
    @State private var cropBefore: MediaEdit?
    @State private var selectedOverlay: UUID?
    @State private var drawColor: UInt32 = EdPalette.accent
    @State private var showStickers = false
    @State private var textDraft = ""
    @State private var textColor: UInt32 = 0xFFFFFF
    @State private var textBackground = false
    @State private var textEditing: UUID?
    @State private var sending = false
    @State private var toast: String?
    /// More photos are being read from the picker (it takes a moment with big ones): a spinner in the strip meanwhile.
    @State private var loadingMore = false
    /// The items went to the chat (it deletes a video's temporary copy itself); otherwise they are deleted when this closes.
    @State private var handedOver = false

    private var current: MediaDraft? { items.indices.contains(index) ? items[index] : nil }
    private var currentIsPhoto: Bool { current.map { !$0.isVideo && $0.image != nil } ?? false }
    private var anyPhoto: Bool { items.contains { !$0.isVideo } }

    private var currentEdit: Binding<MediaEdit> {
        let id = current?.id
        return Binding(get: { id.flatMap { edits[$0] } ?? MediaEdit() },
                       set: { v in if let id = id { edits[id] = v } })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = notice, tool == .none {
                    Text(notice).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .padding(.top, 6)
                }
                bottom
            }
            if tool == .text {
                EdTextEntry(text: $textDraft, color: $textColor, background: $textBackground, onDone: finishText)
                    .transition(.opacity)
            }
            if sending {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.hex(0x08D9D9))
                        Text("ed.preparing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let toast = toast {
                Text(LocalizedStringKey(toast)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.card.opacity(0.95), in: Capsule())
                    .overlay(Capsule().stroke(Theme.hex(0x08D9D9, 0.5), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .photosPicker(isPresented: $showAdd, selection: $adding, maxSelectionCount: max(1, room), matching: .any(of: [.images, .videos]))
        .onChange(of: adding) { picked in
            guard !picked.isEmpty else { return }
            adding = []
            Task {
                loadingMore = true
                let loaded = await MediaDrafts.load(picked)
                loadingMore = false
                let more = Array(loaded.prefix(room))
                // picked past the limit: their temporary copies are not needed
                for d in loaded.dropFirst(more.count) { Self.removePickedCopy(d) }
                notice = loaded.count > more.count ? Self.limitText : nil
                items.append(contentsOf: more)
                if !more.isEmpty { index = items.count - more.count }
            }
        }
        .onChange(of: index) { _ in
            player?.pause(); player = nil
            tool = .none
            cropBefore = nil
            selectedOverlay = nil
        }
        .onDisappear {
            // closed without sending: the videos copied out of the picker (tmp) are deleted
            if !handedOver { for d in items { Self.removePickedCopy(d) } }
        }
        .sheet(isPresented: $showStickers) {
            EdStickerPicker { e in
                addSticker(e)
                showStickers = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: top bar (WhatsApp: close, then Save, HD, Crop, Sticker, Aa, Draw)

    @ViewBuilder private var topBar: some View {
        switch tool {
        case .none, .text:
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("grp.cancel"))
                Spacer(minLength: 4)
                EdRoundButton(a11y: "media.save", action: save) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 16, weight: .semibold))
                }
                .disabled(current == nil)
                if anyPhoto {
                    EdRoundButton(a11y: LocalizedStringKey(hd ? "media.hd.on" : "media.hd.off"), on: hd, action: { hd.toggle() }) {
                        Text(verbatim: "HD").font(.system(size: 13, weight: .heavy))
                    }
                }
                if currentIsPhoto {
                    EdRoundButton(a11y: "ed.crop", action: beginCrop) {
                        Image(systemName: "crop.rotate").font(.system(size: 16, weight: .semibold))
                    }
                    EdRoundButton(a11y: "ed.sticker", action: { showStickers = true }) {
                        Image(systemName: "face.smiling").font(.system(size: 17, weight: .semibold))
                    }
                    EdRoundButton(a11y: "ed.text", action: beginNewText) {
                        Text(verbatim: "Aa").font(.system(size: 15, weight: .bold))
                    }
                    EdRoundButton(a11y: "ed.draw", action: { selectedOverlay = nil; tool = .draw }) {
                        Image(systemName: "pencil").font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 6)
            .opacity(tool == .text ? 0 : 1)
            .accessibilityHidden(tool == .text)
        case .draw:
            HStack {
                EdRoundButton(a11y: "ed.undo", action: undoStroke) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 16, weight: .semibold))
                }
                .disabled(currentEdit.wrappedValue.strokes.isEmpty)
                .opacity(currentEdit.wrappedValue.strokes.isEmpty ? 0.45 : 1)
                Spacer()
                doneButton { tool = .none; refreshThumb() }
            }
            .padding(.horizontal, 8)
        case .crop:
            HStack {
                Button {
                    if let before = cropBefore { currentEdit.wrappedValue = before }
                    cropBefore = nil
                    tool = .none
                } label: {
                    Text("ed.cancel").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(minHeight: 44)
                }
                Spacer()
                doneButton { cropBefore = nil; tool = .none; refreshThumb() }
            }
            .padding(.horizontal, 8)
        }
    }

    private func doneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("ed.done").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 16).frame(height: 34)
                .background(Theme.hex(0x08D9D9), in: Capsule())
                .frame(minHeight: 44)
        }
    }

    // MARK: the picture / video

    @ViewBuilder private var stage: some View {
        if let d = current {
            if d.videoURL != nil {
                page(d)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                        let dx = v.translation.width
                        guard abs(dx) > 60, abs(dx) > abs(v.translation.height) * 1.5 else { return }
                        swipe(dx < 0 ? 1 : -1)
                    })
                    .id(d.id)
            } else if let img = d.image {
                Group {
                    if tool == .crop {
                        CropStage(image: img, edit: currentEdit)
                    } else {
                        EditCanvas(image: img, edit: currentEdit, tool: tool, drawColor: drawColor, selected: $selectedOverlay,
                                   onEditText: beginTextEdit, onCommit: refreshThumb, onSwipe: swipe)
                    }
                }
                .id(d.id)
            } else {
                Color.black
            }
        } else {
            Color.black
        }
    }

    @ViewBuilder private func page(_ d: MediaDraft) -> some View {
        if let url = d.videoURL {
            ZStack {
                if let p = player, current?.id == d.id {
                    VideoPlayer(player: p)
                } else {
                    if let img = d.image { Image(uiImage: img).resizable().scaledToFit() }
                    Button {
                        let p = AVPlayer(url: url)
                        player = p
                        p.play()
                    } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundStyle(.white.opacity(0.9))
                    }
                    .accessibilityLabel(Text("media.play"))
                }
            }
        } else if let img = d.image {
            Image(uiImage: img).resizable().scaledToFit()
        }
    }

    /// +1 = the swipe went towards the screen's left: the next item (the previous one in Arabic).
    private func swipe(_ step: Int) {
        guard tool == .none else { return }
        let next = index + (direction == .rightToLeft ? -step : step)
        if items.indices.contains(next) { index = next }
    }

    // MARK: bottom

    @ViewBuilder private var bottom: some View {
        switch tool {
        case .none, .text:
            VStack(spacing: 0) {
                strip
                if !title.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.forward").font(.system(size: 11, weight: .bold))
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                }
                captionBar
            }
            .opacity(tool == .text ? 0 : 1)
            .accessibilityHidden(tool == .text)
        case .draw:
            EdPaletteRow(selected: $drawColor)
                .padding(.vertical, 12)
        case .crop:
            if let img = current?.image {
                CropControls(image: img, edit: currentEdit)
            }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                    ZStack(alignment: .topTrailing) {
                        Button { index = i } label: {
                            ZStack {
                                if let img = thumbs[d.id] ?? d.thumb ?? d.image { Image(uiImage: img).resizable().scaledToFill() } else { Color.gray }
                                if d.isVideo { Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white).padding(4)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading) }
                            }
                            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(i == index ? Theme.hex(0x08D9D9) : .clear, lineWidth: 2))
                        }
                        .accessibilityLabel(Text(String(format: NSLocalizedString("media.item", comment: ""), i + 1, items.count)))
                        .accessibilityAddTraits(i == index ? .isSelected : [])
                        // the last one too: taking it out closes the screen (website remove(): no items -> onClose)
                        if i == index {
                            Button {
                                player?.pause(); player = nil
                                let gone = items[i].id
                                Self.removePickedCopy(items[i])
                                items.remove(at: i)
                                edits[gone] = nil
                                thumbs[gone] = nil
                                notice = nil
                                if items.isEmpty { dismiss(); return }
                                index = min(index, items.count - 1)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel(Text("media.remove"))
                        }
                    }
                }
                if loadingMore {
                    ProgressView().tint(.white)
                        .frame(width: 56, height: 56).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(Text("ed.preparing"))
                }
                if items.count < Self.maxItems {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(Text("media.add"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var captionBar: some View {
        HStack(spacing: 10) {
            TextField("", text: Binding(get: { current?.caption ?? "" }, set: { v in if items.indices.contains(index) { items[index].caption = v } }),
                      prompt: Text("media.caption").foregroundColor(.white.opacity(0.55)), axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(.white)
                .tint(Theme.hex(0x08D9D9))
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
            Button(action: send) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 50, height: 50).background(Theme.sendGradient, in: Circle())
                    if items.count > 1 {
                        Text("\(items.count)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20).background(.white, in: Capsule()).offset(x: 4, y: -4)
                    }
                }
            }
            .disabled(items.isEmpty || sending)
            .accessibilityLabel(Text(String(format: NSLocalizedString("media.send.n", comment: ""), items.count)))
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: editing

    private func beginCrop() {
        cropBefore = currentEdit.wrappedValue
        selectedOverlay = nil
        tool = .crop
    }

    private func undoStroke() {
        var e = currentEdit.wrappedValue
        guard !e.strokes.isEmpty else { return }
        e.strokes.removeLast()
        currentEdit.wrappedValue = e
        refreshThumb()
    }

    private func beginNewText() {
        textEditing = nil
        textDraft = ""
        textColor = 0xFFFFFF
        textBackground = false
        withAnimation(.easeOut(duration: 0.15)) { tool = .text }
    }

    private func beginTextEdit(_ o: EditOverlay) {
        textEditing = o.id
        textDraft = o.text
        textColor = o.color
        textBackground = o.background
        withAnimation(.easeOut(duration: 0.15)) { tool = .text }
    }

    private func finishText() {
        let t = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var e = currentEdit.wrappedValue
        if let id = textEditing, let i = e.overlays.firstIndex(where: { $0.id == id }) {
            if t.isEmpty {
                e.overlays.remove(at: i)
            } else {
                e.overlays[i].text = t
                e.overlays[i].color = textColor
                e.overlays[i].background = textBackground
            }
        } else if !t.isEmpty, let img = current?.image {
            let g = EditGeometry(size: img.size, edit: e)
            let o = EditOverlay(kind: .text, text: t, center: g.visibleCenter, size: g.visibleShortSide * 0.075,
                                angle: -g.turnAngle, color: textColor, background: textBackground)
            e.overlays.append(o)
            selectedOverlay = o.id
        }
        currentEdit.wrappedValue = e
        textEditing = nil
        withAnimation(.easeOut(duration: 0.15)) { tool = .none }
        refreshThumb()
    }

    private func addSticker(_ emoji: String) {
        guard currentIsPhoto, let img = current?.image else { return }
        var e = currentEdit.wrappedValue
        let g = EditGeometry(size: img.size, edit: e)
        let o = EditOverlay(kind: .sticker, text: emoji, center: g.visibleCenter, size: g.visibleShortSide * 0.2, angle: -g.turnAngle)
        e.overlays.append(o)
        currentEdit.wrappedValue = e
        selectedOverlay = o.id
        refreshThumb()
    }

    /// The strip shows the edited picture (a small render, off the main thread).
    private func refreshThumb() {
        guard let d = current, !d.isVideo, let img = d.image else { return }
        let id = d.id
        let e = edits[id] ?? MediaEdit()
        if e.isEmpty { thumbs[id] = nil; return }
        Task { @MainActor in
            let t = await Task.detached(priority: .utility) { EditRenderer.render(img, e, maxSide: 180) }.value
            if edits[id] == e { thumbs[id] = t }
        }
    }

    // MARK: save / send

    private func showToast(_ key: String) {
        withAnimation { toast = key }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == key { withAnimation { toast = nil } }
        }
    }

    /// Saves the item on screen to Photos, with its edits (add-only permission, NSPhotoLibraryAddUsageDescription).
    private func save() {
        guard let d = current else { return }
        let e = edits[d.id] ?? MediaEdit()
        Task { @MainActor in
            showToast(await EdSaver.save(image: d.image, edit: e, videoURL: d.videoURL))
        }
    }

    /// Unedited items go out exactly as before; an edited photo is flattened (HD: full size, standard: 1600 px) and
    /// handed to the same send path in place of the original.
    private func send() {
        guard !sending, !items.isEmpty else { return }
        player?.pause()
        handedOver = true
        let snapshot = items
        let allEdits = edits
        let quality = hd
        let edited = snapshot.contains { !$0.isVideo && !(allEdits[$0.id]?.isEmpty ?? true) }
        guard edited else {
            sending = true // a second tap while the screen closes must not send everything twice
            onSend(snapshot, quality)
            dismiss()
            return
        }
        sending = true
        Task { @MainActor in
            var out = snapshot
            for i in out.indices {
                guard !out[i].isVideo, let e = allEdits[out[i].id], !e.isEmpty, let img = out[i].image else { continue }
                let maxSide: CGFloat = quality ? 4096 : 1600
                let flat = await Task.detached(priority: .userInitiated) { EditRenderer.flattened(img, e, maxSide: maxSide) }.value
                out[i].image = flat
            }
            onSend(out, quality)
            sending = false
            dismiss()
        }
    }
}

struct MediaBatch: Identifiable {
    let id = UUID()
    let items: [MediaDraft]
}
