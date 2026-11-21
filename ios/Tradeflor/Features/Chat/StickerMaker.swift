import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import Vision
import UniformTypeIdentifiers
import ImageIO
import CoreImage

// Create sticker (IOS-STICKER-008/009): a still sticker made on the device from a photo (only the finished PNG is uploaded),
// or an animated one from a short video or a GIF (the clip is uploaded to be converted; only the sticker is kept).

/// Pure rules of the Maker, tested on their own.
enum StickerClip {
    /// A clip's part: inside the clip, 0.3 to 3 seconds (shorter clips: the whole clip).
    static func clamp(start: Double, duration: Double, total: Double) -> (start: Double, duration: Double) {
        let total = max(0, total)
        let d = min(3, max(0.3, duration), total > 0 ? total : 3)
        let s = min(max(0, start), max(0, total - d))
        return (s, d)
    }

    /// "Square (centre)": the crop as fractions 0..1 of the picture, for any picture shape.
    static func squareCrop(width: CGFloat, height: CGFloat) -> CGRect {
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if width >= height {
            let w = height / width
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = width / height
        return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

enum StickerExport {
    /// The smallest rectangle holding every pixel that is not (almost) transparent; nil when nothing is drawn.
    static func opaqueBounds(_ cg: CGImage, threshold: UInt8 = 8) -> CGRect? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where buf[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// iOS 17: Vision's subject lifting (the person, pet or object in front), done on the device.
    static func liftSubject(_ img: UIImage) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        if #available(iOS 17.0, *) {
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg)
            guard (try? handler.perform([req])) != nil, let obs = req.results?.first,
                  let buf = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false) else { return nil }
            let ci = CIImage(cvPixelBuffer: buf)
            guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        }
        return nil
    }

    /// A plain, even background made transparent: pixels close to the corners' colour (strength = how close).
    static func removePlain(_ img: UIImage, strength: Double) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0, g = 0, b = 0
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            let i = (y * w + x) * 4
            r += Int(buf[i]); g += Int(buf[i + 1]); b += Int(buf[i + 2])
        }
        r /= 4; g /= 4; b /= 4
        let limit = Int(strength * 255 * 1.7)
        for i in stride(from: 0, to: buf.count, by: 4) {
            let d = abs(Int(buf[i]) - r) + abs(Int(buf[i + 1]) - g) + abs(Int(buf[i + 2]) - b)
            if d < limit { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = 0 }
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out)
    }

    /// The finished sticker: trimmed to what is drawn, longest side at most 512, PNG with transparency.
    static func png(_ image: UIImage, maxSide: CGFloat = 512) -> Data? {
        guard let cg = image.cgImage, let r = opaqueBounds(cg), let cut = cg.cropping(to: r) else { return nil }
        let k = min(1, maxSide / CGFloat(max(cut.width, cut.height)))
        let size = CGSize(width: max(1, (CGFloat(cut.width) * k).rounded()), height: max(1, (CGFloat(cut.height) * k).rounded()))
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in
            UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }
}

/// What the Maker draws (a step of undo / redo).
struct StickerEdit: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var quarterTurns = 0
    var removeBackground = false
    var strength: Double = 0.35
    var outline = false
    var text = ""
    var textColor = 0
    var textTop = false
}

struct StickerMakerSheet: View {
    let token: String
    let onMade: (Sticker) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StickerStore.shared
    @State private var mode: Mode?
    enum Mode { case still, animated }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .still: StillStickerMaker(token: token, onMade: done)
                case .animated: AnimatedStickerMaker(token: token, onMade: done)
                case nil: chooser
                }
            }
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text("stk.create"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("notes.cancel") { dismiss() } } }
        }
        .tint(Theme.accent)
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            choice("stk.make.still", "stk.make.still.sub", "photo") { mode = .still }
            if store.config.animated {
                choice("stk.make.animated", "stk.make.animated.sub", "film") { mode = .animated }
            }
            Spacer()
        }
        .padding(20)
    }

    private func choice(_ title: String, _ sub: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).font(.headline).foregroundStyle(Theme.text)
                    Text(LocalizedStringKey(sub)).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(Theme.faint)
            }
            .padding(16).frame(minHeight: 64)
            .background(Theme.soulCard, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func done(_ s: Sticker) {
        store.madeSticker(s)
        onMade(s)
        dismiss()
    }
}

// MARK: still

private struct StillStickerMaker: View {
    let token: String
    let onMade: (Sticker) -> Void
    @State private var pick: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var subject: UIImage? // iOS 17: the subject lifted by Vision
    @State private var edit = StickerEdit()
    @State private var undoStack: [StickerEdit] = []
    @State private var redoStack: [StickerEdit] = []
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var emoji = ""
    @State private var busy = false
    @State private var error: String?
    /// the photo with its plain background removed at the current strength (made once per change, not per frame)
    @State private var cutout: UIImage?

    private static let colors: [UIColor] = [.white, .black, UIColor(red: 1, green: 0.84, blue: 0.2, alpha: 1), UIColor(red: 0, green: 0.83, blue: 0.87, alpha: 1)]
    private let canvas: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(LocalizedStringKey(photo == nil ? "stk.make.pick" : "stk.make.pick.other"), systemImage: "photo.on.rectangle")
                        .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                if photo != nil {
                    preview
                    controls
                    TextField(NSLocalizedString("stk.make.emoji", comment: ""), text: $emoji)
                        .onChange(of: emoji) { v in if v.count > 2 { emoji = String(v.suffix(1)) } }
                        .textFieldStyle(.roundedBorder)
                    if let error { Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger) }
                    Button { Task { await make() } } label: {
                        HStack { if busy { ProgressView().tint(Theme.onAccent) }; Text("stk.make.go").font(.body.weight(.bold)) }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    Text("stk.make.private").font(.caption).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .onChange(of: pick) { item in Task { await load(item) } }
    }

    private var preview: some View {
        ZStack {
            Checkerboard().clipShape(RoundedRectangle(cornerRadius: 14))
            if let img = rendered(size: canvas) {
                Image(uiImage: img).resizable().frame(width: canvas, height: canvas)
            }
        }
        .frame(width: canvas, height: canvas)
        .gesture(DragGesture()
            .onChanged { v in
                if dragStart == nil { dragStart = edit.offset; remember() }
                edit.offset = CGSize(width: (dragStart?.width ?? 0) + v.translation.width, height: (dragStart?.height ?? 0) + v.translation.height)
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnificationGesture()
            .onChanged { k in
                if zoomStart == nil { zoomStart = edit.scale; remember() }
                edit.scale = min(6, max(0.2, (zoomStart ?? 1) * k))
            }
            .onEnded { _ in zoomStart = nil })
        .accessibilityLabel(Text("stk.make.preview"))
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                iconButton("rotate.left", "stk.make.rotl") { change { $0.quarterTurns = ($0.quarterTurns + 3) % 4 } }
                iconButton("rotate.right", "stk.make.rotr") { change { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } }
                Slider(value: Binding(get: { Double(edit.scale) }, set: { edit.scale = CGFloat($0) }), in: 0.2...6, onEditingChanged: { e in if e { remember() } })
                    .accessibilityLabel(Text("stk.make.zoom"))
                iconButton("arrow.uturn.backward", "stk.make.undo") { undo() }.disabled(undoStack.isEmpty)
                iconButton("arrow.uturn.forward", "stk.make.redo") { redo() }.disabled(redoStack.isEmpty)
            }
            Toggle(isOn: Binding(get: { edit.removeBackground }, set: { v in change { $0.removeBackground = v }; updateCutout() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(subjectLiftAvailable ? "stk.make.bg.subject" : "stk.make.bg.plain")).font(.callout.weight(.semibold))
                    Text(LocalizedStringKey(subjectLiftAvailable ? "stk.make.bg.subject.sub" : "stk.make.bg.plain.sub")).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if edit.removeBackground && !subjectLiftAvailable {
                Slider(value: Binding(get: { edit.strength }, set: { edit.strength = $0 }), in: 0.05...0.8, onEditingChanged: { e in
                    if e { remember() } else { updateCutout() }
                })
                    .accessibilityLabel(Text("stk.make.strength"))
            }
            Toggle("stk.make.outline", isOn: Binding(get: { edit.outline }, set: { v in change { $0.outline = v } }))
                .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                TextField(NSLocalizedString("stk.make.words", comment: ""), text: Binding(get: { edit.text }, set: { v in
                    if edit.text.isEmpty != v.isEmpty { remember() }
                    edit.text = String(v.prefix(40))
                }))
                .textFieldStyle(.roundedBorder)
                ForEach(Self.colors.indices, id: \.self) { i in
                    Button { change { $0.textColor = i } } label: {
                        Circle().fill(Color(Self.colors[i])).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(edit.textColor == i ? Theme.accent : Theme.faint, lineWidth: edit.textColor == i ? 3 : 1))
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: NSLocalizedString("stk.make.color." + String(i), comment: "")))
                }
                Button { change { $0.textTop.toggle() } } label: {
                    Image(systemName: edit.textTop ? "arrow.up.to.line" : "arrow.down.to.line").frame(width: 36, height: 44)
                }
                .accessibilityLabel(Text(LocalizedStringKey(edit.textTop ? "stk.make.top" : "stk.make.bottom")))
            }
        }
    }

    private func iconButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 44) }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    private var subjectLiftAvailable: Bool { subject != nil }

    private func remember() {
        undoStack.append(edit)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack = []
    }

    private func change(_ f: (inout StickerEdit) -> Void) {
        remember()
        f(&edit)
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(edit)
        edit = last
        updateCutout()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        edit = next
        updateCutout()
    }

    private func updateCutout() {
        guard edit.removeBackground, subject == nil, let photo else { cutout = nil; return }
        let strength = edit.strength
        Task {
            let img = await Task.detached(priority: .userInitiated) { StickerExport.removePlain(photo, strength: strength) }.value
            if edit.strength == strength { cutout = img }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        // HEIC and every other photo format: decoded on the device, downsized (the original is never uploaded)
        guard let img = StickerCache.downsample(data, maxPixel: 1200) else { error = NSLocalizedString("stk.err.422", comment: ""); return }
        photo = img
        cutout = nil
        edit = StickerEdit()
        undoStack = []; redoStack = []
        error = nil
        subject = await Task.detached(priority: .userInitiated) { StickerExport.liftSubject(img) }.value
    }

    /// The sticker as drawn on a square canvas of `size` points (the preview), or of 512 px (the export).
    private func rendered(size: CGFloat, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
        guard let photo else { return nil }
        var src = photo
        if edit.removeBackground {
            if let subject { src = subject } else if let cutout { src = cutout }
        }
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = false
        let canvasSize = CGSize(width: size, height: size)
        let k = size / canvas
        return UIGraphicsImageRenderer(size: canvasSize, format: f).image { rc in
            let ctx = rc.cgContext
            let fit = min(size / src.size.width, size / src.size.height) * edit.scale
            let drawSize = CGSize(width: src.size.width * fit, height: src.size.height * fit)
            func drawPicture() {
                ctx.saveGState()
                ctx.translateBy(x: size / 2 + edit.offset.width * k, y: size / 2 + edit.offset.height * k)
                ctx.rotate(by: CGFloat(edit.quarterTurns) * .pi / 2)
                src.draw(in: CGRect(x: -drawSize.width / 2, y: -drawSize.height / 2, width: drawSize.width, height: drawSize.height))
                ctx.restoreGState()
            }
            if edit.outline {
                // a white rim: the picture's shape drawn white, offset around, then the picture over it
                let rim = max(2, 6 * k)
                ctx.saveGState()
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8) {
                    ctx.saveGState()
                    ctx.translateBy(x: CGFloat(cos(a)) * rim, y: CGFloat(sin(a)) * rim)
                    drawPicture()
                    ctx.restoreGState()
                }
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: canvasSize))
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            drawPicture()
            let words = edit.text.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty {
                let font = UIFont.systemFont(ofSize: 34 * k, weight: .heavy)
                let color = Self.colors[min(edit.textColor, Self.colors.count - 1)]
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                                                            .strokeColor: color == .black ? UIColor.white : UIColor.black, .strokeWidth: -3]
                let s = NSAttributedString(string: words, attributes: attrs)
                let b = s.boundingRect(with: CGSize(width: size - 16 * k, height: size), options: [.usesLineFragmentOrigin], context: nil)
                let y = edit.textTop ? 10 * k : size - b.height - 10 * k
                s.draw(with: CGRect(x: (size - b.width) / 2, y: y, width: b.width, height: b.height), options: [.usesLineFragmentOrigin], context: nil)
            }
        }
    }

    private func make() async {
        busy = true
        error = nil
        defer { busy = false }
        guard let img = rendered(size: 512, scale: 1), let png = StickerExport.png(img) else {
            error = NSLocalizedString("stk.make.empty", comment: "")
            return
        }
        do {
            let s = try await APIClient.shared.stickerCreate(token: token, file: png, fileName: "sticker.png", mime: "image/png",
                                                             emoji: emoji.isEmpty ? nil : emoji)
            onMade(s)
        } catch {
            // offline or refused: the edit stays on screen to try again
            self.error = (error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: "")
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 14
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color.gray.opacity(0.22)))
                }
            }
        }
        .background(Color.gray.opacity(0.08))
    }
}

// MARK: animated

/// A file picked for an animated sticker (a video, or a GIF), copied to this app's temporary folder.
private struct PickedClip: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { r in try copy(r.file, "mov") }
        FileRepresentation(importedContentType: .gif) { r in try copy(r.file, "gif") }
    }
    private static func copy(_ src: URL, _ ext: String) throws -> PickedClip {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("tf-sticker-\(UUID().uuidString).\(src.pathExtension.isEmpty ? ext : src.pathExtension)")
        try FileManager.default.copyItem(at: src, to: dst)
        return PickedClip(url: dst)
    }
}

private struct AnimatedStickerMaker: View {
    let token: String
    let onMade: (Sticker) -> Void
    @State private var pick: PhotosPickerItem?
    @State private var clip: URL?
    @State private var isGIF = false
    @State private var total: Double = 0
    @State private var natural: CGSize = .zero
    @State private var start: Double = 0
    @State private var length: Double = 3
    @State private var square = true
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var error: String?
    @State private var gifStill: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                PhotosPicker(selection: $pick, matching: .any(of: [.videos, .images])) {
                    Label(LocalizedStringKey(clip == nil ? "stk.make.pickclip" : "stk.make.pick.other"), systemImage: "film")
                        .font(.callout.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("stk.make.animated.note").font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                if clip != nil {
                    if let player, !isGIF {
                        LoopingPlayer(player: player).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 14))
                    } else if isGIF, let gifStill {
                        Image(uiImage: gifStill).resizable().scaledToFit().frame(height: 260)
                    }
                    if !isGIF && total > 0.3 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: String(format: NSLocalizedString("stk.make.start", comment: ""), start)).font(.caption)
                            Slider(value: $start, in: 0...max(0.01, total - 0.3), onEditingChanged: { e in if !e { restartLoop() } })
                            Text(verbatim: String(format: NSLocalizedString("stk.make.length", comment: ""), length)).font(.caption)
                            Slider(value: $length, in: 0.3...min(3, max(0.31, total)), onEditingChanged: { e in if !e { restartLoop() } })
                        }
                    }
                    Picker("stk.make.area", selection: $square) {
                        Text("stk.make.square").tag(true)
                        Text("stk.make.whole").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if let error { Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger) }
                    if busy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("stk.make.converting").font(.footnote)
                            Button("notes.cancel") { work?.cancel(); busy = false }
                        }
                    } else {
                        Button { work = Task { await make() } } label: {
                            Text("stk.make.go").font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 50)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.onAccent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .onChange(of: pick) { item in Task { await load(item) } }
        .onDisappear { player?.pause(); work?.cancel() }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        error = nil
        player?.pause(); player = nil; looper = nil
        guard let picked = try? await item.loadTransferable(type: PickedClip.self) else {
            error = NSLocalizedString("stk.err.422", comment: "")
            return
        }
        clip = picked.url
        isGIF = picked.url.pathExtension.lowercased() == "gif"
        if isGIF {
            total = 3
            if let d = try? Data(contentsOf: picked.url) { gifStill = StickerCache.downsample(d, maxPixel: 600) }
            if let d = try? Data(contentsOf: picked.url), let src = CGImageSourceCreateWithData(d as CFData, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                natural = CGSize(width: (p[kCGImagePropertyPixelWidth] as? CGFloat) ?? 1, height: (p[kCGImagePropertyPixelHeight] as? CGFloat) ?? 1)
            }
            start = 0; length = 3
            return
        }
        let asset = AVURLAsset(url: picked.url)
        total = (try? await asset.load(.duration).seconds) ?? 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            natural = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let c = StickerClip.clamp(start: 0, duration: 3, total: total)
        start = c.start; length = c.duration
        restartLoop()
    }

    private func restartLoop() {
        guard let clip, !isGIF else { return }
        let c = StickerClip.clamp(start: start, duration: length, total: total)
        start = c.start; length = c.duration
        let item = AVPlayerItem(url: clip)
        let q = AVQueuePlayer()
        q.isMuted = true
        looper = AVPlayerLooper(player: q, templateItem: item,
                                timeRange: CMTimeRange(start: CMTime(seconds: c.start, preferredTimescale: 600), duration: CMTime(seconds: c.duration, preferredTimescale: 600)))
        player?.pause()
        player = q
        q.play()
    }

    private func make() async {
        guard let clip else { return }
        busy = true
        error = nil
        defer { busy = false }
        let c = StickerClip.clamp(start: start, duration: length, total: total)
        var file = clip
        var startAt = c.start
        // larger than the server takes (8 MB): cut and shrink on the device first
        let size = (try? FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int) ?? 0
        if !isGIF && size > (StickerStore.shared.config.maxUploadBytes > 0 ? StickerStore.shared.config.maxUploadBytes : 8 << 20) {
            guard let cut = await Self.shrink(clip, start: c.start, duration: c.duration) else {
                error = NSLocalizedString("stk.err.413", comment: "")
                return
            }
            file = cut
            startAt = 0
        }
        guard !Task.isCancelled, let data = try? Data(contentsOf: file) else { return }
        let crop = square ? StickerClip.squareCrop(width: natural.width, height: natural.height) : nil
        do {
            let s = try await APIClient.shared.stickerCreate(token: token, file: data, fileName: isGIF ? "clip.gif" : "clip.mp4",
                                                             mime: isGIF ? "image/gif" : "video/mp4", emoji: nil, animated: true,
                                                             start: startAt, duration: c.duration, crop: crop)
            guard !Task.isCancelled else { return }
            onMade(s)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: "")
        }
    }

    /// The chosen part only, medium quality, no sound.
    static func shrink(_ url: URL, start: Double, duration: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tf-sticker-cut-\(UUID().uuidString).mp4")
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        await ex.export()
        return ex.status == .completed ? out : nil
    }
}

private struct LoopingPlayer: UIViewRepresentable {
    let player: AVPlayer
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) { v.playerLayer.player = player }
}
