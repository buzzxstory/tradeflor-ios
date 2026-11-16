import SwiftUI
import UIKit

/// Photos from the iPhone are often HEIC and 12+ MP; the server takes JPG/PNG/WEBP up to 10 MB.
/// Everything sent is redrawn to at most 2560 px on the long side and encoded as JPEG (this also drops
/// location and other metadata from the original file).
enum ImagePrep {
    static let maxSide: CGFloat = 2560

    static func jpeg(from image: UIImage) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        var quality: CGFloat = 0.82
        var data = drawn.jpegData(compressionQuality: quality)
        while let d = data, d.count > 9_500_000, quality > 0.4 {
            quality -= 0.15
            data = drawn.jpegData(compressionQuality: quality)
        }
        return data
    }
}

/// The system camera. iOS asks for camera permission once (the first time), then never again.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.cameraCaptureMode = .photo
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// An image attachment in a bubble: the server's thumbnail first, the full picture when opened.
struct RemoteImage: View {
    let token: String
    let fileID: String
    var thumb = true
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: fileID + (thumb ? "t" : "f")) {
            if let d = await APIClient.shared.file(token: token, fileID: fileID, thumb: thumb), let img = UIImage(data: d) {
                image = img
            } else {
                failed = true
            }
        }
    }
}

/// Full-screen photo: pinch to zoom, double-tap to reset, swipe down or Done to close.
struct PhotoViewer: View {
    let token: String
    let fileID: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            RemoteImage(token: token, fileID: fileID, thumb: false, contentMode: .fit)
                .scaleEffect(scale)
                .offset(y: scale == 1 ? drag.height : 0)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, min(5, lastScale * v)) }
                        .onEnded { _ in lastScale = scale }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in if scale == 1 { drag = v.translation } }
                        .onEnded { v in
                            if scale == 1 && abs(v.translation.height) > 120 { dismiss() } else { drag = .zero }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = 1; lastScale = 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel(Text("chat.close"))
        }
    }
}
