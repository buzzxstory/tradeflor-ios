import Photos
import QuickLook
import SwiftUI

// Received documents (open, preview, share / save to Files) and saving photos and videos to the photo library, like the
// website's Attachments "Save" / "Save As..." and the picture viewer's "Save to Photos".

enum MediaSaver {
    enum Outcome { case saved, denied, failed }

    /// Downloads the attachment and adds it to Photos (add-only permission).
    static func saveToPhotos(token: String, fileID: String, video: Bool) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        guard let data = await APIClient.shared.file(token: token, fileID: fileID, thumb: false) else { return .failed }
        do {
            if video {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tf-\(UUID().uuidString).mp4")
                try data.write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                try await PHPhotoLibrary.shared().performChanges {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } else {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
            }
            return .saved
        } catch {
            return .failed
        }
    }

    /// The attachment as a local file with its real name (for Quick Look and the share sheet).
    static func localFile(token: String, fileID: String, name: String?) async -> URL? {
        guard let data = await APIClient.shared.file(token: token, fileID: fileID, thumb: false) else { return nil }
        let safe = (name?.isEmpty == false ? name! : "file").replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tf-files/\(fileID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// "Save to Photos" for the full-screen viewers.
struct SaveMediaButton: View {
    let token: String
    let fileID: String
    let video: Bool
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    busy = true
                    let r = await MediaSaver.saveToPhotos(token: token, fileID: fileID, video: video)
                    busy = false
                    note = NSLocalizedString(r == .saved ? "media.saved" : (r == .denied ? "media.denied" : "media.failed"), comment: "")
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    note = nil
                }
            } label: {
                Group { if busy { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.down") } }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(busy)
            .accessibilityLabel(Text("media.save"))
            if let note {
                Text(note).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.6), in: Capsule())
            }
        }
        .padding()
    }
}

struct LocalDoc: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// A document message: icon, name, type; tap opens it.
struct FileBubble: View {
    let message: Message
    let mine: Bool
    var state: Bubble.Delivery?
    let onOpen: () -> Void

    private var name: String { message.file_name?.isEmpty == false ? message.file_name! : NSLocalizedString("file.untitled", comment: "") }
    private var ext: String { (name as NSString).pathExtension.uppercased() }
    private var icon: String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "doc.zipper"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "mp3", "m4a", "wav", "aac", "ogg": return "music.note"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        default: return "doc.text"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44).background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                        Text(ext.isEmpty ? NSLocalizedString("file.document", comment: "") : ext)
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(Theme.muted)
                }
                if !message.body.isEmpty {
                    Text(message.body).font(.system(size: 15)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let d = message.date { Text(d, style: .time).font(.system(size: 11)).foregroundStyle(Theme.muted) }
            }
            .padding(10)
            .frame(maxWidth: 280)
            .tfBubble(mine: mine)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityLabel(Text(String(format: NSLocalizedString("file.open.named", comment: ""), name)))
    }
}

/// Quick Look in a navigation controller: preview plus the system share button (Save to Files, AirDrop, other apps).
struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let q = QLPreviewController()
        q.dataSource = context.coordinator
        q.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in
            q.dismiss(animated: true)
        })
        return UINavigationController(rootViewController: q)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
