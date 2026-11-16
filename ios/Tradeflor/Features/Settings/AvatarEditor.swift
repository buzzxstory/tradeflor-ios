import SwiftUI

/// Position and zoom a new profile photo inside the circle before it is uploaded (website features/profile/AvatarEditor.tsx).
struct AvatarEditor: View {
    let image: UIImage
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height) - 48
            let base = d / max(1, min(image.size.width, image.size.height))
            let shown = CGSize(width: image.size.width * base * zoom, height: image.size.height * base * zoom)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(offset)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                // the dimmed outside and the circle
                Rectangle().fill(.black.opacity(0.55))
                    .mask(
                        ZStack {
                            Rectangle()
                            Circle().frame(width: d, height: d).position(x: geo.size.width / 2, y: geo.size.height / 2).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                    .allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: d, height: d)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2).allowsHitTesting(false)
                VStack {
                    Text("avatar.edit.hint").font(.footnote).foregroundStyle(.white.opacity(0.85)).padding(.top, 20)
                    Spacer()
                    HStack {
                        Button("grp.cancel") { dismiss() }.foregroundStyle(.white)
                        Spacer()
                        Slider(value: Binding(get: { zoom }, set: { z in
                            zoom = z; lastZoom = z
                            offset = clamp(offset, shown: CGSize(width: image.size.width * base * z, height: image.size.height * base * z), d: d)
                            lastOffset = offset
                        }), in: 1...4)
                        .tint(Theme.accent).frame(maxWidth: 160)
                        .accessibilityLabel(Text("avatar.zoom"))
                        Spacer()
                        Button { save(d: d, base: base) } label: { Text("avatar.use").bold() }.foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 22).padding(.bottom, 26)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            offset = clamp(CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height),
                                           shown: shown, d: d)
                        }
                        .onEnded { _ in lastOffset = offset },
                    MagnificationGesture()
                        .onChanged { v in
                            zoom = max(1, min(4, lastZoom * v))
                            offset = clamp(offset, shown: CGSize(width: image.size.width * base * zoom, height: image.size.height * base * zoom), d: d)
                        }
                        .onEnded { _ in lastZoom = zoom; lastOffset = offset }
                )
            )
        }
        .statusBarHidden()
    }

    /// Keeps the circle covered by the photo.
    private func clamp(_ o: CGSize, shown: CGSize, d: CGFloat) -> CGSize {
        let mx = max(0, (shown.width - d) / 2), my = max(0, (shown.height - d) / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    private func save(d: CGFloat, base: CGFloat) {
        let k = base * zoom // screen points per image point
        let shown = CGSize(width: image.size.width * k, height: image.size.height * k)
        let side = d / k
        let x = (shown.width / 2 - offset.width - d / 2) / k
        let y = (shown.height / 2 - offset.height - d / 2) / k
        let target = min(1024, side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let s = target / side
        let out = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            image.draw(in: CGRect(x: -x * s, y: -y * s, width: image.size.width * s, height: image.size.height * s))
        }
        if let jpeg = out.jpegData(compressionQuality: 0.85) { onSave(jpeg) }
        dismiss()
    }
}

struct PickedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
