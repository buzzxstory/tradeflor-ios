import Photos
import SwiftUI
import UIKit

// WhatsApp-style photo editing before sending (MediaSendSheet): crop & rotate, emoji stickers, text, freehand drawing.
// One MediaEdit per item. Drawings and stickers live in the original picture's own units (UIImage.size, upright), so
// cropping or rotating afterwards keeps them stuck to the picture; the picture is only flattened when sent or saved
// (EditRenderer). An item nobody edited is never redrawn: it goes out exactly as before.

enum EditTool: Equatable { case none, crop, draw, text }

struct EditStroke: Equatable {
    var points: [CGPoint]   // picture units
    var color: UInt32
    var width: CGFloat      // picture units
}

struct EditOverlay: Identifiable, Equatable {
    enum Kind: Equatable { case text, sticker }
    var id = UUID()
    var kind: Kind
    var text: String
    var center: CGPoint     // picture units
    var size: CGFloat       // font size, picture units
    var angle: CGFloat      // radians in picture space (keeps it upright for the rotation it was added under)
    var color: UInt32 = 0xFFFFFF
    var background = false
}

enum EditAspect: CaseIterable, Equatable {
    case free, original, square, fourThree, sixteenNine

    var labelKey: String? {
        switch self {
        case .free: return "ed.aspect.free"
        case .original: return "ed.aspect.original"
        case .square: return "ed.aspect.square"
        case .fourThree, .sixteenNine: return nil
        }
    }

    var verbatim: String { self == .fourThree ? "4:3" : self == .sixteenNine ? "16:9" : "" }

    /// Width / height in pixels for a picture of this (rotated) size; nil = free.
    func ratio(for rotated: CGSize) -> CGFloat? {
        guard rotated.width > 0, rotated.height > 0 else { return nil }
        let landscape = rotated.width >= rotated.height
        switch self {
        case .free: return nil
        case .original: return rotated.width / rotated.height
        case .square: return 1
        case .fourThree: return landscape ? 4.0 / 3.0 : 3.0 / 4.0
        case .sixteenNine: return landscape ? 16.0 / 9.0 : 9.0 / 16.0
        }
    }
}

struct MediaEdit: Equatable {
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var turns = 0                    // quarter turns clockwise
    var crop = MediaEdit.fullCrop    // normalised, in the rotated picture
    var aspect: EditAspect = .free
    var strokes: [EditStroke] = []
    var overlays: [EditOverlay] = []

    var isCropped: Bool {
        abs(crop.minX) > 0.0005 || abs(crop.minY) > 0.0005 || abs(crop.width - 1) > 0.0005 || abs(crop.height - 1) > 0.0005
    }

    var isEmpty: Bool { turns % 4 == 0 && !isCropped && strokes.isEmpty && overlays.isEmpty }
}

/// Picture units <-> the edited output (rotated, then cropped), in picture units with the crop's corner at 0,0.
struct EditGeometry {
    let size: CGSize
    let q: Int
    let crop: CGRect

    init(size: CGSize, edit: MediaEdit, cropped: Bool = true) {
        self.size = size
        q = ((edit.turns % 4) + 4) % 4
        crop = cropped ? edit.crop : MediaEdit.fullCrop
    }

    var rotated: CGSize { q % 2 == 0 ? size : CGSize(width: size.height, height: size.width) }
    var cropPx: CGRect {
        let r = rotated
        return CGRect(x: crop.minX * r.width, y: crop.minY * r.height, width: crop.width * r.width, height: crop.height * r.height)
    }
    var output: CGSize { cropPx.size }
    var turnAngle: CGFloat { CGFloat(q) * .pi / 2 }

    func toRotated(_ p: CGPoint) -> CGPoint {
        switch q {
        case 1: return CGPoint(x: size.height - p.y, y: p.x)
        case 2: return CGPoint(x: size.width - p.x, y: size.height - p.y)
        case 3: return CGPoint(x: p.y, y: size.width - p.x)
        default: return p
        }
    }

    func fromRotated(_ r: CGPoint) -> CGPoint {
        switch q {
        case 1: return CGPoint(x: r.y, y: size.height - r.x)
        case 2: return CGPoint(x: size.width - r.x, y: size.height - r.y)
        case 3: return CGPoint(x: size.width - r.y, y: r.x)
        default: return r
        }
    }

    func toOutput(_ p: CGPoint) -> CGPoint {
        let r = toRotated(p)
        let c = cropPx
        return CGPoint(x: r.x - c.minX, y: r.y - c.minY)
    }

    func fromOutput(_ o: CGPoint) -> CGPoint {
        let c = cropPx
        return fromRotated(CGPoint(x: o.x + c.minX, y: o.y + c.minY))
    }

    /// The middle of what is visible now, in picture units (where a new sticker or text lands).
    var visibleCenter: CGPoint { fromOutput(CGPoint(x: output.width / 2, y: output.height / 2)) }
    var visibleShortSide: CGFloat { max(1, min(output.width, output.height)) }
}

struct EdColor { let hex: UInt32; let key: String }

enum EdPalette {
    static let colors: [EdColor] = [
        EdColor(hex: 0xFFFFFF, key: "ed.color.white"), EdColor(hex: 0x000000, key: "ed.color.black"),
        EdColor(hex: 0xF0525B, key: "ed.color.red"), EdColor(hex: 0xFF9F0A, key: "ed.color.orange"),
        EdColor(hex: 0xEFBE33, key: "ed.color.yellow"), EdColor(hex: 0x00CC83, key: "ed.color.green"),
        EdColor(hex: 0x08D9D9, key: "ed.color.teal"), EdColor(hex: 0x127DD6, key: "ed.color.blue"),
        EdColor(hex: 0x8E5CF7, key: "ed.color.purple"), EdColor(hex: 0xFF5FA2, key: "ed.color.pink"),
    ]
    static let accent: UInt32 = 0x08D9D9

    static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func color(_ hex: UInt32) -> Color { Color(uiColor: ui(hex)) }

    static func isLight(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.62
    }

    /// Text colour: the chosen colour, or on a coloured background black / white for contrast.
    static func textHex(_ o: EditOverlay) -> UInt32 {
        guard o.background else { return o.color }
        return isLight(o.color) ? 0x000000 : 0xFFFFFF
    }
}

// MARK: - Flattening (send / save)

enum EditRenderer {
    static func attributed(_ o: EditOverlay) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let font: UIFont = o.kind == .sticker ? .systemFont(ofSize: max(1, o.size)) : .systemFont(ofSize: max(1, o.size), weight: .bold)
        return NSAttributedString(string: o.text, attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: EdPalette.ui(EdPalette.textHex(o)),
        ])
    }

    /// The text's own box in picture units (wraps past twelve font sizes wide).
    static func textBox(_ o: EditOverlay) -> CGSize {
        let r = attributed(o).boundingRect(with: CGSize(width: max(1, o.size * 12), height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static func padding(_ o: EditOverlay) -> CGSize { CGSize(width: o.size * 0.3, height: o.size * 0.18) }

    /// Rotation, crop, drawing, stickers and text, at most `maxSide` px on the long side.
    static func render(_ image: UIImage, _ edit: MediaEdit, maxSide: CGFloat) -> UIImage {
        let g = EditGeometry(size: image.size, edit: edit)
        let out = g.output
        guard out.width >= 1, out.height >= 1 else { return image }
        let k = min(1, maxSide / max(out.width, out.height))
        let target = CGSize(width: max(1, (out.width * k).rounded()), height: max(1, (out.height * k).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor.black.setFill()
            c.fill(CGRect(origin: .zero, size: target))
            c.scaleBy(x: target.width / out.width, y: target.height / out.height)
            let crop = g.cropPx
            c.translateBy(x: -crop.minX, y: -crop.minY)
            let w = image.size.width, h = image.size.height
            switch g.q {
            case 1: c.translateBy(x: h, y: 0); c.rotate(by: .pi / 2)
            case 2: c.translateBy(x: w, y: h); c.rotate(by: .pi)
            case 3: c.translateBy(x: 0, y: w); c.rotate(by: -.pi / 2)
            default: break
            }
            image.draw(in: CGRect(origin: .zero, size: image.size))
            drawAnnotations(edit, in: c)
        }
    }

    /// For sending: the render kept as JPEG data (lazily decoded), so thirty edited pictures do not sit in memory as bitmaps.
    static func flattened(_ image: UIImage, _ edit: MediaEdit, maxSide: CGFloat) -> UIImage {
        autoreleasepool {
            let drawn = render(image, edit, maxSide: maxSide)
            if let data = drawn.jpegData(compressionQuality: 0.95), let img = UIImage(data: data) { return img }
            return drawn
        }
    }

    private static func drawAnnotations(_ edit: MediaEdit, in c: CGContext) {
        for s in edit.strokes {
            guard let first = s.points.first else { continue }
            let path = UIBezierPath()
            path.move(to: first)
            if s.points.count == 1 { path.addLine(to: first) } else { for p in s.points.dropFirst() { path.addLine(to: p) } }
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            EdPalette.ui(s.color).setStroke()
            path.stroke()
        }
        for o in edit.overlays where !o.text.isEmpty {
            c.saveGState()
            c.translateBy(x: o.center.x, y: o.center.y)
            c.rotate(by: o.angle)
            let box = textBox(o)
            if o.kind == .text && o.background {
                let pad = padding(o)
                let r = CGRect(x: -box.width / 2 - pad.width, y: -box.height / 2 - pad.height,
                               width: box.width + pad.width * 2, height: box.height + pad.height * 2)
                EdPalette.ui(o.color).setFill()
                UIBezierPath(roundedRect: r, cornerRadius: o.size * 0.3).fill()
            }
            attributed(o).draw(with: CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            c.restoreGState()
        }
    }
}

// MARK: - Save to Photos

enum EdSaver {
    /// Adds the item (with its edits) to Photos; returns the toast's key (media.saved / media.denied / media.failed).
    static func save(image: UIImage?, edit: MediaEdit, videoURL: URL?) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return "media.denied" }
        do {
            if let url = videoURL {
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } else if let img = image {
                let out = edit.isEmpty ? img : EditRenderer.render(img, edit, maxSide: 8192)
                guard let data = out.jpegData(compressionQuality: 0.95) else { return "media.failed" }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            } else {
                return "media.failed"
            }
            return "media.saved"
        } catch {
            return "media.failed"
        }
    }
}

// MARK: - Shared views

func edFit(_ content: CGSize, in box: CGSize) -> CGSize {
    guard content.width > 0, content.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let k = min(box.width / content.width, box.height / content.height)
    return CGSize(width: content.width * k, height: content.height * k)
}

/// The whole picture turned by quarter turns, drawn at `size` (the rotated size).
struct EdRotatedImage: View {
    let image: UIImage
    let turns: Int
    let size: CGSize

    var body: some View {
        let odd = turns % 2 == 1
        Image(uiImage: image).resizable()
            .frame(width: odd ? size.height : size.width, height: odd ? size.width : size.height)
            .rotationEffect(.degrees(Double(turns) * 90))
            .frame(width: size.width, height: size.height)
    }
}

/// Strokes (and the one being drawn) in canvas coordinates.
struct EdStrokesLayer: View {
    let strokes: [EditStroke]
    let g: EditGeometry
    let s: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for st in strokes {
                let pts = st.points.map { p -> CGPoint in let o = g.toOutput(p); return CGPoint(x: o.x * s, y: o.y * s) }
                guard let f = pts.first else { continue }
                var path = Path()
                path.move(to: f)
                if pts.count == 1 { path.addLine(to: f) } else { for p in pts.dropFirst() { path.addLine(to: p) } }
                ctx.stroke(path, with: .color(EdPalette.color(st.color)),
                           style: StrokeStyle(lineWidth: max(1, st.width * s), lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A sticker or a text as it will be drawn (same font, box and background as EditRenderer).
struct EdOverlayLabel: View {
    let o: EditOverlay
    let s: CGFloat

    var body: some View {
        if o.kind == .sticker {
            Text(o.text).font(.system(size: max(1, o.size * s))).fixedSize()
        } else {
            let box = EditRenderer.textBox(o)
            let pad = EditRenderer.padding(o)
            Text(o.text)
                .font(.system(size: max(1, o.size * s), weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundColor(EdPalette.color(EdPalette.textHex(o)))
                .frame(width: box.width * s + 2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, pad.width * s).padding(.vertical, pad.height * s)
                .background(o.background ? EdPalette.color(o.color) : Color.clear,
                            in: RoundedRectangle(cornerRadius: o.size * 0.3 * s))
        }
    }
}

struct EdPaletteRow: View {
    @Binding var selected: UInt32

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(EdPalette.colors, id: \.hex) { c in
                    Button { selected = c.hex } label: {
                        Circle().fill(EdPalette.color(c.hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                            .overlay(Circle().stroke(Theme.hex(0x08D9D9), lineWidth: 3).padding(-4).opacity(selected == c.hex ? 1 : 0))
                            .frame(width: 38, height: 44)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey(c.key)))
                    .accessibilityAddTraits(selected == c.hex ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

/// A round toolbar button (WhatsApp's dark circles), teal when on.
struct EdRoundButton<Label: View>: View {
    let a11y: LocalizedStringKey
    var on = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 38, height: 38)
                .background(on ? AnyShapeStyle(Theme.hex(0x08D9D9)) : AnyShapeStyle(Color.white.opacity(0.14)), in: Circle())
                .frame(width: 42, height: 44)
        }
        .accessibilityLabel(Text(a11y))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Canvas: viewing, moving / pinching stickers and text, drawing

private struct EditLayout {
    let g: EditGeometry
    let fit: CGSize
    let origin: CGPoint
    let s: CGFloat
    let area: CGSize

    /// where a dragged sticker or text is dropped to delete it (bottom middle of the area)
    var trash: CGPoint { CGPoint(x: area.width / 2, y: max(40, area.height - 44)) }

    func view(_ p: CGPoint) -> CGPoint { let o = g.toOutput(p); return CGPoint(x: o.x * s, y: o.y * s) }
    func inArea(_ p: CGPoint) -> CGPoint { let v = view(p); return CGPoint(x: v.x + origin.x, y: v.y + origin.y) }
    func picture(fromArea a: CGPoint) -> CGPoint { g.fromOutput(CGPoint(x: (a.x - origin.x) / s, y: (a.y - origin.y) / s)) }
}

struct EditCanvas: View {
    let image: UIImage
    @Binding var edit: MediaEdit
    let tool: EditTool
    let drawColor: UInt32
    @Binding var selected: UUID?
    let onEditText: (EditOverlay) -> Void
    let onCommit: () -> Void
    /// +1 when swiped towards the left of the screen, -1 towards the right (the sheet turns it for RTL)
    let onSwipe: (Int) -> Void

    @State private var live: EditStroke?
    @State private var dragging: UUID?
    @State private var dragStart: CGPoint?
    @State private var overTrash = false
    @State private var pinchStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let L = layout(geo.size)
            ZStack(alignment: .topLeading) {
                canvas(L)
                    .frame(width: L.fit.width, height: L.fit.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: L.origin.x, y: L.origin.y)
                if dragging != nil {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(overTrash ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Color.black.opacity(0.55)), in: Circle())
                        .scaleEffect(overTrash ? 1.15 : 1)
                        .position(L.trash)
                        .accessibilityLabel(Text("ed.trash"))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture(L), including: tool == .none ? .all : .subviews)
            .gesture(canvasGesture(L), including: tool == .none || tool == .draw ? .all : .subviews)
            .accessibilityElement(children: tool == .draw ? .ignore : .contain)
            .accessibilityLabel(tool == .draw ? Text("ed.draw.area") : Text(""))
        }
        .coordinateSpace(name: "edArea")
        .environment(\.layoutDirection, .leftToRight) // picture coordinates never mirror
    }

    private func layout(_ area: CGSize) -> EditLayout {
        let g = EditGeometry(size: image.size, edit: edit)
        let fit = edFit(g.output, in: area)
        let s = max(0.0001, fit.width / max(g.output.width, 1))
        return EditLayout(g: g, fit: fit, origin: CGPoint(x: (area.width - fit.width) / 2, y: (area.height - fit.height) / 2), s: s, area: area)
    }

    @ViewBuilder private func canvas(_ L: EditLayout) -> some View {
        let full = CGSize(width: L.g.rotated.width * L.s, height: L.g.rotated.height * L.s)
        let crop = L.g.cropPx
        ZStack(alignment: .topLeading) {
            EdRotatedImage(image: image, turns: L.g.q, size: full)
                .offset(x: -crop.minX * L.s, y: -crop.minY * L.s)
                .frame(width: L.fit.width, height: L.fit.height, alignment: .topLeading)
            EdStrokesLayer(strokes: edit.strokes + (live.map { [$0] } ?? []), g: L.g, s: L.s)
                .frame(width: L.fit.width, height: L.fit.height)
            ZStack {
                ForEach(edit.overlays) { o in
                    overlayView(o, L)
                }
            }
            .frame(width: L.fit.width, height: L.fit.height)
            .allowsHitTesting(tool == .none)
        }
    }

    private func overlayView(_ o: EditOverlay, _ L: EditLayout) -> some View {
        let label = o.kind == .text
            ? String(format: NSLocalizedString("ed.overlay.text", comment: ""), o.text)
            : String(format: NSLocalizedString("ed.overlay.sticker", comment: ""), o.text)
        return EdOverlayLabel(o: o, s: L.s)
            .padding(6)
            .contentShape(Rectangle())
            .rotationEffect(.radians(Double(o.angle + L.g.turnAngle)))
            .opacity(dragging == o.id && overTrash ? 0.5 : 1)
            .onTapGesture {
                selected = o.id
                if o.kind == .text { onEditText(o) }
            }
            .gesture(overlayDrag(o, L))
            .position(L.view(o.center))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(o.kind == .text ? .isButton : [])
            .accessibilityAction { if o.kind == .text { onEditText(o) } }
            .accessibilityAction(named: Text("ed.delete")) { remove(o.id) }
            .accessibilityAdjustableAction { dir in
                guard let i = edit.overlays.firstIndex(where: { $0.id == o.id }) else { return }
                let k: CGFloat = dir == .increment ? 1.15 : (dir == .decrement ? 1 / 1.15 : 1)
                edit.overlays[i].size = clampSize(edit.overlays[i].size * k, L)
                onCommit()
            }
    }

    private func overlayDrag(_ o: EditOverlay, _ L: EditLayout) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("edArea"))
            .onChanged { v in
                guard let i = edit.overlays.firstIndex(where: { $0.id == o.id }) else { return }
                if dragging != o.id {
                    dragging = o.id
                    selected = o.id
                    dragStart = edit.overlays[i].center
                }
                guard let start = dragStart else { return }
                let a = L.inArea(start)
                edit.overlays[i].center = L.picture(fromArea: CGPoint(x: a.x + v.translation.width, y: a.y + v.translation.height))
                overTrash = trashHit(v.location, L)
            }
            .onEnded { v in
                if trashHit(v.location, L) { remove(o.id) }
                dragging = nil
                dragStart = nil
                overTrash = false
                onCommit()
            }
    }

    private func trashHit(_ p: CGPoint, _ L: EditLayout) -> Bool {
        hypot(p.x - L.trash.x, p.y - L.trash.y) < 46
    }

    private func remove(_ id: UUID) {
        edit.overlays.removeAll { $0.id == id }
        if selected == id { selected = nil }
        onCommit()
    }

    private func clampSize(_ v: CGFloat, _ L: EditLayout) -> CGFloat {
        let side = L.g.visibleShortSide
        return min(max(v, side * 0.02), side * 1.2)
    }

    /// Draw mode: a stroke follows the finger. Otherwise: a sideways swipe moves to the next or previous item.
    private func canvasGesture(_ L: EditLayout) -> some Gesture {
        DragGesture(minimumDistance: tool == .draw ? 0 : 30, coordinateSpace: .named("edArea"))
            .onChanged { v in
                guard tool == .draw else { return }
                let p = L.picture(fromArea: v.location)
                if var st = live {
                    if let last = st.points.last, hypot(last.x - p.x, last.y - p.y) * L.s < 1 { return }
                    st.points.append(p)
                    live = st
                } else {
                    live = EditStroke(points: [p], color: drawColor, width: L.g.visibleShortSide * 0.012)
                }
            }
            .onEnded { v in
                if tool == .draw {
                    if let st = live { edit.strokes.append(st) }
                    live = nil
                    onCommit()
                } else if tool == .none {
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                    onSwipe(dx < 0 ? 1 : -1)
                }
            }
    }

    private func pinchGesture(_ L: EditLayout) -> some Gesture {
        MagnificationGesture()
            .onChanged { m in
                guard let id = selected, let i = edit.overlays.firstIndex(where: { $0.id == id }) else { return }
                if pinchStart == nil { pinchStart = edit.overlays[i].size }
                edit.overlays[i].size = clampSize((pinchStart ?? edit.overlays[i].size) * m, L)
            }
            .onEnded { _ in
                if pinchStart != nil { onCommit() }
                pinchStart = nil
            }
    }
}

