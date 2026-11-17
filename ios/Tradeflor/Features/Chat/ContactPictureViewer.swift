import SwiftUI
import UIKit

/// Someone's profile picture full screen (website shared/components/PictureViewer.tsx): the full-size picture (not the list
/// thumbnail), a loading ring while it comes, pinch and double-tap to zoom, drag to look around when zoomed, swipe down or the
/// close button to close.
@MainActor
struct ContactPictureViewer: View {
    let token: String
    let userID: String
    let avatarID: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pull: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(Double(1 - min(CGFloat(0.6), abs(pull) / CGFloat(600))))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(x: offset.width, y: offset.height + pull)
                        .onTapGesture(count: 2) { toggleZoom(geo.size) }
                        .gesture(magnify(geo.size))
                        .simultaneousGesture(drag(geo.size))
                        .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("civ3.picture.of", comment: ""), name)))
                        .accessibilityAddTraits(.isImage)
                } else if failed {
                    Button { Task { await load() } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise").font(.title3)
                            Text("photo.retry").font(.footnote)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 160, height: 120)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    CIV3Spinner()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel(Text("chat.close"))
        }
        .overlay(alignment: .top) {
            Text(verbatim: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 70)
                .padding(.top, 26)
                .opacity(scale > 1 ? 0 : 1)
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .task { await load() }
    }

    private func load() async {
        failed = false
        if let data = await APIClient.shared.avatar(token: token, userID: userID, avatarID: avatarID), let img = UIImage(data: data) {
            image = img
        } else {
            failed = true
        }
    }

    private func toggleZoom(_ size: CGSize) {
        withAnimation(.easeOut(duration: 0.18)) {
            if scale > 1 {
                reset()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }

    /// How far the zoomed picture may move before an edge comes into view.
    private func clamp(_ o: CGSize, _ size: CGSize) -> CGSize {
        let mx = max(0, (scale - 1) * size.width / 2)
        let my = max(0, (scale - 1) * size.height / 2)
        return CGSize(width: min(mx, max(-mx, o.width)), height: min(my, max(-my, o.height)))
    }

    private func magnify(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in scale = max(1, min(5, lastScale * v)) }
            .onEnded { _ in
                if scale <= 1.02 {
                    withAnimation(.easeOut(duration: 0.18)) { reset() }
                } else {
                    lastScale = scale
                    offset = clamp(offset, size)
                    lastOffset = offset
                }
            }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if scale > 1 {
                    offset = clamp(CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height), size)
                } else {
                    pull = v.translation.height
                }
            }
            .onEnded { v in
                if scale > 1 {
                    lastOffset = offset
                } else if v.translation.height > 120 || v.predictedEndTranslation.height > 320 {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pull = 0 }
                }
            }
    }
}

/// The website's loading ring (.picture-viewer-spin): a faint circle with a turning cyan arc.
struct CIV3Spinner: View {
    @State private var turning = false
    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.2), lineWidth: 3)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Theme.hex(0x35E6F2), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(turning ? 360 : 0))
            )
            .frame(width: 38, height: 38)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.updatesFrequently)
    }
}
