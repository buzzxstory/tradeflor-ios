import SwiftUI
import UIKit

// The editor's panels: crop & rotate (free crop with corner handles, aspect presets), text entry, sticker picker.

// MARK: - Crop & rotate

enum EdCrop {
    static let minSide: CGFloat = 0.08

    /// Drags one corner (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) by a normalised delta; the opposite
    /// corner stays put. `ratio` (normalised width / height) keeps the shape when an aspect is chosen.
    static func dragCorner(_ start: CGRect, corner: Int, dx: CGFloat, dy: CGFloat, ratio: CGFloat?) -> CGRect {
        let left = corner == 0 || corner == 2
        let top = corner == 0 || corner == 1
        let ax = left ? start.maxX : start.minX
        let ay = top ? start.maxY : start.minY
        let mx = min(max((left ? start.minX : start.maxX) + dx, 0), 1)
        let my = min(max((top ? start.minY : start.maxY) + dy, 0), 1)
        let maxW = left ? ax : 1 - ax
        let maxH = top ? ay : 1 - ay
        var w = min(max(left ? ax - mx : mx - ax, minSide), maxW)
        var h = min(max(top ? ay - my : my - ay, minSide), maxH)
        if let r = ratio, r > 0 {
            h = w / r
            if h > maxH { h = maxH; w = h * r }
            if h < minSide { h = min(minSide, maxH); w = min(h * r, maxW) }
        }
        return CGRect(x: left ? ax - w : ax, y: top ? ay - h : ay, width: w, height: h)
    }

    static func move(_ start: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: min(max(start.minX + dx, 0), 1 - start.width), y: min(max(start.minY + dy, 0), 1 - start.height),
               width: start.width, height: start.height)
    }

    /// The largest centred crop of that aspect.
    static func apply(_ aspect: EditAspect, to edit: inout MediaEdit, imageSize: CGSize) {
        edit.aspect = aspect
        let rotated = EditGeometry(size: imageSize, edit: edit, cropped: false).rotated
        guard let r = aspect.ratio(for: rotated), rotated.width > 0, rotated.height > 0 else {
            if aspect == .free { return }
            edit.crop = MediaEdit.fullCrop
            return
        }
        var w = rotated.width, h = rotated.width / r
        if h > rotated.height { h = rotated.height; w = h * r }
        let nw = w / rotated.width, nh = h / rotated.height
        edit.crop = CGRect(x: (1 - nw) / 2, y: (1 - nh) / 2, width: nw, height: nh)
    }

    /// A quarter turn clockwise; the crop turns with the picture.
    static func rotate(_ edit: inout MediaEdit) {
        let c = edit.crop
        edit.crop = CGRect(x: 1 - c.minY - c.height, y: c.minX, width: c.height, height: c.width)
        edit.turns = (edit.turns + 1) % 4
    }
}

struct CropStage: View {
    let image: UIImage
    @Binding var edit: MediaEdit
    @State private var startCrop: CGRect?

    var body: some View {
        GeometryReader { geo in
            let g = EditGeometry(size: image.size, edit: edit, cropped: false)
            let avail = CGSize(width: max(1, geo.size.width - 48), height: max(1, geo.size.height - 48))
            let fit = edFit(g.output, in: avail)
            let s = max(0.0001, fit.width / max(g.output.width, 1))
            let r = CGRect(x: edit.crop.minX * fit.width, y: edit.crop.minY * fit.height,
                           width: edit.crop.width * fit.width, height: edit.crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                EdRotatedImage(image: image, turns: g.q, size: fit)
                EdStrokesLayer(strokes: edit.strokes, g: g, s: s).frame(width: fit.width, height: fit.height)
                ZStack {
                    ForEach(edit.overlays) { o in
                        EdOverlayLabel(o: o, s: s)
                            .rotationEffect(.radians(Double(o.angle + g.turnAngle)))
                            .position(spot(o.center, g, s))
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // dimmed outside the crop, a frame with thirds and corner brackets
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: fit))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Path { p in
                    p.addRect(r)
                    for k in 1...2 {
                        let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
                .allowsHitTesting(false)
                brackets(r)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(1, r.width), height: max(1, r.height))
                    .position(x: r.midX, y: r.midY)
                    .gesture(moveGesture(fit))
                    .accessibilityElement()
                    .accessibilityLabel(Text("ed.crop.area"))
                ForEach(0..<4, id: \.self) { c in
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 44, height: 44)
                        .position(corner(c, r))
                        .gesture(cornerGesture(c, fit))
                        .accessibilityElement()
                        .accessibilityLabel(Text("ed.crop.corner"))
                }
            }
            .frame(width: fit.width, height: fit.height, alignment: .topLeading)
            .coordinateSpace(name: "edCrop")
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func spot(_ p: CGPoint, _ g: EditGeometry, _ s: CGFloat) -> CGPoint {
        let o = g.toOutput(p)
        return CGPoint(x: o.x * s, y: o.y * s)
    }

    private func corner(_ c: Int, _ r: CGRect) -> CGPoint {
        CGPoint(x: c == 0 || c == 2 ? r.minX : r.maxX, y: c == 0 || c == 1 ? r.minY : r.maxY)
    }

    private func brackets(_ r: CGRect) -> Path {
        Path { p in
            let l = min(22, r.width / 3, r.height / 3)
            p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
            p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
            p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
            p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        }
    }

    private func cornerGesture(_ c: Int, _ fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("edCrop"))
            .onChanged { v in
                if startCrop == nil { startCrop = edit.crop }
                guard let st = startCrop, fit.width > 0, fit.height > 0 else { return }
                let ratio: CGFloat? = edit.aspect == .free ? nil : st.width / max(st.height, 0.0001)
                edit.crop = EdCrop.dragCorner(st, corner: c, dx: v.translation.width / fit.width, dy: v.translation.height / fit.height, ratio: ratio)
            }
            .onEnded { _ in startCrop = nil }
    }

    private func moveGesture(_ fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("edCrop"))
            .onChanged { v in
                if startCrop == nil { startCrop = edit.crop }
                guard let st = startCrop, fit.width > 0, fit.height > 0 else { return }
                edit.crop = EdCrop.move(st, dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
            }
            .onEnded { _ in startCrop = nil }
    }
}

/// Under the crop stage: aspect presets, rotate 90 degrees, reset.
struct CropControls: View {
    let image: UIImage
    @Binding var edit: MediaEdit

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditAspect.allCases, id: \.self) { a in
                        Button { EdCrop.apply(a, to: &edit, imageSize: image.size) } label: {
                            Group {
                                if let k = a.labelKey { Text(LocalizedStringKey(k)) } else { Text(verbatim: a.verbatim) }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(edit.aspect == a ? Color.black : Color.white)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(edit.aspect == a ? AnyShapeStyle(Theme.hex(0x08D9D9)) : AnyShapeStyle(Color.white.opacity(0.14)), in: Capsule())
                            .frame(minHeight: 44)
                        }
                        .accessibilityAddTraits(edit.aspect == a ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 28) {
                EdRoundButton(a11y: "ed.rotate", action: { EdCrop.rotate(&edit) }) {
                    Image(systemName: "rotate.right").font(.system(size: 17, weight: .semibold))
                }
                EdRoundButton(a11y: "ed.reset", action: { edit.turns = 0; edit.crop = MediaEdit.fullCrop; edit.aspect = .free }) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .semibold))
                }
                .disabled(edit.turns % 4 == 0 && !edit.isCropped && edit.aspect == .free)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Text

/// Typing a text: over a dimmed picture, with colours and a background toggle (WhatsApp's "Aa").
struct EdTextEntry: View {
    @Binding var text: String
    @Binding var color: UInt32
    @Binding var background: Bool
    let onDone: () -> Void
    @FocusState private var focused: Bool

    private var preview: EditOverlay { EditOverlay(kind: .text, text: text, center: .zero, size: 30, angle: 0, color: color, background: background) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
                .onTapGesture { onDone() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    EdRoundButton(a11y: "ed.text.bg", on: background, action: { background.toggle() }) {
                        Image(systemName: "character.textbox").font(.system(size: 17, weight: .semibold))
                    }
                    Spacer()
                    Button { onDone() } label: {
                        Text("ed.done").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .padding(.horizontal, 16).frame(height: 34)
                            .background(Theme.hex(0x08D9D9), in: Capsule())
                            .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 10)
                Spacer(minLength: 12)
                TextField("", text: $text, prompt: Text("ed.text.placeholder").foregroundColor(.white.opacity(0.5)), axis: .vertical)
                    .lineLimit(1...6)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(EdPalette.color(EdPalette.textHex(preview)))
                    .tint(Theme.hex(0x08D9D9))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(background ? EdPalette.color(color) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .focused($focused)
                Spacer(minLength: 12)
                EdPaletteRow(selected: $color)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true } }
    }
}

// MARK: - Stickers

/// The emoji, by category (the same lists as the chat's picker), to place on the picture as a sticker.
struct EdStickerPicker: View {
    let onPick: (String) -> Void
    @State private var cat = 0

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 36, height: 5).padding(.top, 8)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(EmojiData.categories.enumerated()), id: \.offset) { i, c in
                        Button { cat = i } label: {
                            Text(c.icon).font(.system(size: 22))
                                .frame(width: 44, height: 40)
                                .background(i == cat ? Theme.hex(0x08D9D9, 0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel(Text(LocalizedStringKey(c.key)))
                        .accessibilityAddTraits(i == cat ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            Divider().overlay(Theme.soulRule)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 6) {
                    let list = EmojiData.categories.indices.contains(cat) ? EmojiData.categories[cat].emoji : []
                    ForEach(Array(list.enumerated()), id: \.offset) { _, e in
                        Button { onPick(e) } label: {
                            Text(e).font(.system(size: 30)).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel(Text(verbatim: e))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
        .background(Theme.soul.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
