import SwiftUI
import UIKit

/// Photos from the iPhone are often HEIC and 12+ MP; the server takes JPG/PNG/WEBP up to 10 MB.
/// Everything sent is redrawn to at most 2560 px on the long side and encoded as JPEG (this also drops
/// location and other metadata from the original file).
enum ImagePrep {
    static let maxSide: CGFloat = 2560

    /// Standard quality (the website's MediaSendSheet): 1600 px at JPEG 0.85. HD keeps the full size.
    static func jpeg(from image: UIImage, hd: Bool) -> Data? {
        // HD: at most 4096 px on the long side, as WhatsApp HD and the website (ff35f69), so a large photo is never refused
        if hd { return jpeg(from: image, maxSide: 4096, startQuality: 0.92) }
        return jpeg(from: image, maxSide: 1600, startQuality: 0.85)
    }

    static func jpeg(from image: UIImage) -> Data? { jpeg(from: image, maxSide: maxSide, startQuality: 0.82) }

    static func jpeg(from image: UIImage, maxSide: CGFloat, startQuality: CGFloat) -> Data? {
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
        var quality: CGFloat = startQuality
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
    @State private var attempt = 0

    /// A picture already in memory shows at once (no spinner flash), as on the web.
    init(token: String, fileID: String, thumb: Bool = true, contentMode: ContentMode = .fill) {
        self.token = token
        self.fileID = fileID
        self.thumb = thumb
        self.contentMode = contentMode
        _image = State(initialValue: APIClient.shared.cachedFile(fileID: fileID, thumb: thumb).flatMap { UIImage(data: $0) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                // a picture that did not come (sleep, a server update, a dropped connection): a calm retry, never a broken image
                VStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.title3)
                    Text("photo.retry").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { failed = false; attempt += 1 }
                .accessibilityAddTraits(.isButton)
            } else {
                ProgressView()
            }
        }
        .task(id: fileID + (thumb ? "t" : "f") + String(attempt)) {
            if image != nil && attempt == 0 { return }
            for wait in [0, 1_000_000_000, 3_000_000_000] as [UInt64] {
                if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
                if Task.isCancelled { return }
                if let d = await APIClient.shared.file(token: token, fileID: fileID, thumb: thumb), let img = UIImage(data: d) {
                    image = img
                    MediaDims.shared.set(fileID, img.size) // its shape, so the bubble keeps the right box next time
                    return
                }
            }
            failed = true
        }
    }
}

/// Full-screen photo (contact info, shared media): the WhatsApp-style media viewer (MediaViewer.swift) for one photo.
struct PhotoViewer: View {
    let token: String
    let fileID: String

    var body: some View {
        MediaViewer(token: token, items: [MediaViewerItem(fileID: fileID, video: false)])
    }
}
