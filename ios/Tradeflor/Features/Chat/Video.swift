import SwiftUI
import AVKit
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// Streams an attachment with the session token in the request header (the server answers Range requests,
/// so playback starts before the whole file has arrived and seeking works). Nothing is saved to disk.
enum RemoteMedia {
    static func asset(token: String, fileID: String) -> AVURLAsset {
        let url = AppConfig.apiBase.appendingPathComponent("files").appendingPathComponent(fileID)
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
    }

    /// A still from the first second, for the bubble.
    static func poster(token: String, fileID: String) async -> UIImage? {
        let gen = AVAssetImageGenerator(asset: asset(token: token, fileID: fileID))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        return await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
    }
}

struct VideoBubble: View {
    let token: String
    let message: Message
    let mine: Bool
    let state: Bubble.Delivery?
    let onPlay: () -> Void
    @State private var poster: UIImage?

    var body: some View {
        PhotoBubble(mine: mine, date: message.date, state: state, caption: message.body) {
            ZStack {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                } else {
                    Color.black.opacity(0.4)
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .onTapGesture(perform: onPlay)
        .task(id: message.file_id) {
            guard let fid = message.file_id else { return }
            poster = await RemoteMedia.poster(token: token, fileID: fid)
        }
        .accessibilityLabel(Text("chat.video"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Full-screen system player (play/pause, scrubbing, AirPlay, picture in picture).
struct VideoScreen: View {
    let token: String
    let fileID: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .onAppear {
            VoicePlayer.shared.stop()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(playerItem: AVPlayerItem(asset: RemoteMedia.asset(token: token, fileID: fileID)))
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

/// A video picked from the library, as a temporary file (copied out of the picker's sandbox).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("pick-\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum VideoPrep {
    /// Re-encodes to H.264 MP4 (iPhone videos are often HEVC .mov, which not every browser plays) at a size that
    /// suits a chat, and keeps it under the server's 50 MB limit. Returns the MP4 bytes and the length in seconds.
    static func mp4(from source: URL, maxBytes: Int = 49_000_000) async -> (data: Data, seconds: Double)? {
        let asset = AVURLAsset(url: source)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: source)
        }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        for preset in [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: out)
            export.outputURL = out
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            await export.export()
            guard export.status == .completed, let data = try? Data(contentsOf: out) else { continue }
            if data.count <= maxBytes { return (data, seconds) }
        }
        return nil
    }
}
