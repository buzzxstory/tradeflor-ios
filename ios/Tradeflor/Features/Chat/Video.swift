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
        let image: UIImage? = await withCheckedContinuation { cont in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.5, preferredTimescale: 600))]) { _, cg, _, _, _ in
                cont.resume(returning: cg.map { UIImage(cgImage: $0) })
            }
        }
        withExtendedLifetime(gen) {}
        return image
    }

    // Memory only (never on disk): a video's cover picture and its length, by file id.
    private static let covers: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 150
        return c
    }()
    private static let lengths = NSCache<NSString, NSNumber>()

    static func cachedCover(_ fileID: String) -> UIImage? { covers.object(forKey: fileID as NSString) }
    static func cachedLength(_ fileID: String) -> Double? { lengths.object(forKey: fileID as NSString)?.doubleValue }

    /// The video's cover (website e0f0b7a): first the picture the sender's device made (`GET files/{id}?thumb=1`;
    /// an older video answers 404), else a frame read from the video itself.
    static func cover(token: String, fileID: String) async -> UIImage? {
        if let hit = cachedCover(fileID) { return hit }
        var image: UIImage?
        if let data = await APIClient.shared.file(token: token, fileID: fileID, thumb: true) { image = UIImage(data: data) }
        if image == nil { image = await poster(token: token, fileID: fileID) }
        if let image { covers.setObject(image, forKey: fileID as NSString) }
        return image
    }

    /// The video's length in seconds, read from the file (only its header is fetched).
    static func length(token: String, fileID: String) async -> Double? {
        if let hit = cachedLength(fileID) { return hit }
        guard let d = try? await asset(token: token, fileID: fileID).load(.duration),
              d.seconds.isFinite, d.seconds > 0 else { return nil }
        lengths.setObject(NSNumber(value: d.seconds), forKey: fileID as NSString)
        return d.seconds
    }

    /// 0:07, 12:34, 1:02:03.
    static func clock(_ seconds: Double) -> String {
        let t = seconds.isFinite && seconds > 0 ? Int(seconds.rounded(.down)) : 0
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A video in the chat, as in WhatsApp iOS: its cover with a round play button in the middle, a camera and the length
/// bottom-left, the time and ticks bottom-right, in the same bubble and box as a photo (PhotoBubble, MediaDims.box). It
/// never plays inline: a tap opens the full-screen viewer.
struct VideoBubble: View {
    let token: String
    let message: Message
    let mine: Bool
    let state: Bubble.Delivery?
    let onPlay: () -> Void
    @State private var cover: UIImage?
    @State private var seconds: Double?

    init(token: String, message: Message, mine: Bool, state: Bubble.Delivery?, onPlay: @escaping () -> Void) {
        self.token = token
        self.message = message
        self.mine = mine
        self.state = state
        self.onPlay = onPlay
        let fid = message.file_id
        _cover = State(initialValue: fid.flatMap { RemoteMedia.cachedCover($0) })
        if let ms = message.duration_ms, ms > 0 {
            _seconds = State(initialValue: Double(ms) / 1000)
        } else {
            _seconds = State(initialValue: fid.flatMap { RemoteMedia.cachedLength($0) })
        }
    }

    /// Drawn by PhotoBubble, exactly like a photo (same box rule, same rim, same time over a soft shade), plus the play
    /// button and the length. The cover's shape is remembered in MediaDims, so the box is right the next time.
    var body: some View {
        PhotoBubble(mine: mine, date: message.date, state: state, caption: message.body, fileID: message.file_id,
                    size: cover?.size ?? message.file_id.flatMap { MediaDims.shared.size($0) },
                    video: true, seconds: seconds) {
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                Color.black.opacity(0.35)
            }
        }
        .onTapGesture(perform: onPlay)
        .task(id: message.file_id) {
            guard let fid = message.file_id else { return }
            if cover == nil, let c = await RemoteMedia.cover(token: token, fileID: fid) { cover = c }
            if let c = cover { MediaDims.shared.set(fid, c.size) }
            if seconds == nil { seconds = await RemoteMedia.length(token: token, fileID: fid) }
        }
    }
}

// MARK: - full-screen player

/// The video's picture, drawn by an AVPlayerLayer (no system controls, no system full screen).
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Hands the drawing view out once it exists (the media viewer's Picture in Picture uses its layer).
    var onView: (@MainActor (PlayerLayerUIView) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false // the SwiftUI layer above takes the taps and the swipe
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        if let onView { Task { @MainActor in onView(v) } }
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Playback state for VideoScreen.
@MainActor
final class VideoPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var playing = false
    @Published private(set) var buffering = false
    @Published private(set) var ended = false
    @Published private(set) var ready = false
    @Published private(set) var failed = false
    @Published private(set) var muted = false
    @Published private(set) var total: Double = 0
    @Published var current: Double = 0
    /// Playback speed (the viewer's 1× / 1.5× / 2×); kept from one video to the next while the viewer is open.
    @Published private(set) var rate: Float = 1
    /// While the finger is on the seek bar the clock follows the finger, not the player.
    var scrubbing = false

    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?

    func load(token: String, fileID: String) {
        guard player.currentItem == nil else { return }
        // a fresh start (the viewer reuses one playback for each video it shows)
        ready = false
        ended = false
        failed = false
        buffering = false
        total = 0
        current = 0
        player.defaultRate = rate // play() starts at this speed (iOS 16+)
        let asset = RemoteMedia.asset(token: token, fileID: fileID)
        let item = AVPlayerItem(asset: asset)
        // start as soon as a little is there (WhatsApp-like), instead of buffering ahead first
        item.preferredForwardBufferDuration = 1.5
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        if let known = RemoteMedia.cachedLength(fileID) { total = known }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            let s = t.seconds
            Task { @MainActor in
                guard let self, !self.scrubbing else { return }
                self.current = s.isFinite ? max(0, s) : 0
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                self?.playing = status != .paused
                self?.buffering = status == .waitingToPlayAtSpecifiedRate
            }
        })
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] it, _ in
            let status = it.status
            let d = it.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                if status == .readyToPlay {
                    self.ready = true
                    if d.isFinite, d > 0 { self.total = d }
                } else if status == .failed {
                    self.failed = true
                }
            }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ended = true
                self.playing = false
                if self.total > 0 { self.current = self.total }
            }
        }
        Task { [weak self] in
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 { self?.total = d.seconds }
        }
        player.play()
    }

    /// Play / pause; at the end it starts again from the beginning.
    func toggle() {
        if ended {
            ended = false
            current = 0
            player.seek(to: .zero) { [weak self] _ in Task { @MainActor in self?.player.play() } }
            return
        }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(to seconds: Double, exact: Bool) {
        ended = false
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if exact {
            player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: t)
        }
    }

    /// 1× → 1.5× → 2× → 1×.
    func cycleRate() {
        let next: Float = rate < 1.25 ? 1.5 : (rate < 1.75 ? 2 : 1)
        rate = next
        player.defaultRate = next
        if player.timeControlStatus != .paused { player.rate = next }
    }

    func pause() { player.pause() }

    func toggleMute() {
        player.isMuted.toggle()
        muted = player.isMuted
    }

    func stop() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        playing = false
        buffering = false
    }
}

/// Full-screen video (contact info, shared media): the WhatsApp-style media viewer (MediaViewer.swift) for one video.
struct VideoScreen: View {
    let token: String
    let fileID: String

    var body: some View {
        MediaViewer(token: token, items: [MediaViewerItem(fileID: fileID, video: true)])
    }
}

/// A clear cover background (iOS 16.4+), so the chat shows through while the video is swiped down.
struct ClearCover: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            content
        }
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

    /// The video's cover picture to send with it (website e0f0b7a): one early frame of a local video, upright, at most
    /// `maxSide` pixels on its longer side, as a JPEG of at most 512 KB. Nil when no frame can be read.
    /// Call it before `mp4(from:)`, which deletes the source file when it finishes.
    static func poster(for url: URL, maxSide: CGFloat = 480) async -> Data? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        var frame: CGImage?
        for seconds in [0.1, 0.0] where frame == nil {
            frame = await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]) { _, cg, _, _, _ in
                    cont.resume(returning: cg)
                }
            }
        }
        withExtendedLifetime(gen) {}
        guard let frame else { return nil }
        let image = UIImage(cgImage: frame)
        for quality in [0.8, 0.65, 0.5, 0.35] as [CGFloat] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 512 * 1024 { return data }
        }
        return nil
    }
}
