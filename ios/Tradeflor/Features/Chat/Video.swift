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

/// A video in the chat, as in WhatsApp (website 3f50eb5 + 10038d8): its picture with a round play button in the middle,
/// a camera and the length at the bottom on one side, the time and ticks on the other. No bubble card: the picture is
/// the message (rounded 14 pt), at the video's own shape (9:16 ... 2:1, up to 260 x 340). It never plays inline: a tap
/// opens the full-screen player.
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

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Width / height, as the website's mediaAR: a taller video is cropped to 9:16, a wider one to 2:1; 16:9 until known.
    private var ratio: CGFloat {
        guard let c = cover, c.size.width > 0, c.size.height > 0 else { return 16.0 / 9.0 }
        return min(2, max(9.0 / 16.0, c.size.width / c.size.height))
    }

    private var box: CGSize {
        var w: CGFloat = 260
        var h = w / ratio
        if h > 340 { h = 340; w = h * ratio }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    var body: some View {
        let size = box
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                media(size)
                if !message.body.isEmpty {
                    Text(message.body)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .tfBubble(mine: mine)
                        .frame(maxWidth: size.width, alignment: mine ? .trailing : .leading)
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .task(id: message.file_id) {
            guard let fid = message.file_id else { return }
            if cover == nil, let c = await RemoteMedia.cover(token: token, fileID: fid) { cover = c }
            if seconds == nil { seconds = await RemoteMedia.length(token: token, fileID: fid) }
        }
    }

    private func media(_ size: CGSize) -> some View {
        ZStack {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.black.opacity(0.35)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.leading, 3)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.45), in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            chips
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onPlay)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("chat.video"))
        .accessibilityValue(Text(seconds.map { RemoteMedia.clock($0) } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPlay() }
    }

    /// Camera + length on one side, time + ticks on the other; when they cannot fit side by side (a narrow video, a
    /// long time format), the length goes on its own row above, so they never overlap.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                lengthChip
                Spacer(minLength: 6)
                timeChip
            }
            VStack(spacing: 4) {
                HStack(spacing: 0) { lengthChip; Spacer(minLength: 0) }
                HStack(spacing: 0) { Spacer(minLength: 0); timeChip }
            }
        }
    }

    private var lengthChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "video.fill").font(.system(size: 9, weight: .semibold)).opacity(0.9)
            if let seconds { Text(RemoteMedia.clock(seconds)).monospacedDigit() }
        }
        .modifier(VideoChip())
    }

    @ViewBuilder private var timeChip: some View {
        if message.date != nil || state != nil {
            HStack(spacing: 3) {
                if let d = message.date { Text(Self.time.string(from: d)).monospacedDigit() }
                if let state { Bubble.tickView(state) }
            }
            .modifier(VideoChip())
        }
    }
}

/// The small dark chips over a video's picture (white 11 pt on black 45 %).
private struct VideoChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - full-screen player

/// The video's picture, drawn by an AVPlayerLayer (no system controls, no system full screen).
private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false // the SwiftUI layer above takes the taps and the swipe
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
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
    /// While the finger is on the seek bar the clock follows the finger, not the player.
    var scrubbing = false

    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?

    func load(token: String, fileID: String) {
        guard player.currentItem == nil else { return }
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
    }
}

/// Full-screen video player with our own controls only (website 9092b7e + 43dac41): X and Save at the top, a big play /
/// pause in the middle (replay at the end), the time played, a seek bar, the length and sound on/off at the bottom. A tap
/// shows or hides the controls; they hide by themselves after ~3 s while it plays. Swipe the video down to go back.
struct VideoScreen: View {
    let token: String
    let fileID: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoPlayback()
    @State private var shown = true
    @State private var hideTask: Task<Void, Never>?
    @State private var drag: CGFloat = 0

    /// The chat shows through while the video is dragged down only where the cover can have a clear background.
    private var seeThrough: Bool {
        if #available(iOS 16.4, *) { return true }
        return false
    }
    private var controlsVisible: Bool { (shown || !model.playing) && drag == 0 }
    private var backdrop: Double { seeThrough ? 1 - min(1, Double(drag) / 420) : 1 }

    var body: some View {
        ZStack {
            Color.black.opacity(backdrop).ignoresSafeArea()
            video
            controls
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(.easeOut(duration: 0.2), value: controlsVisible)
        }
        .modifier(ClearCover())
        .statusBarHidden(!controlsVisible)
        .onAppear {
            VoicePlayer.shared.stop()
            if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) } // never cut a running call's microphone
            if !CallManager.shared.lineInUse { try? AVAudioSession.sharedInstance().setActive(true) } // never cut a running call's microphone
            model.load(token: token, fileID: fileID)
            keepShown()
        }
        .onDisappear {
            hideTask?.cancel()
            model.stop()
        }
        .onChange(of: model.playing) { playing in
            if playing { keepShown() } else { hideTask?.cancel(); shown = true }
        }
    }

    private var video: some View {
        ZStack {
            if !model.ready, let cover = RemoteMedia.cachedCover(fileID) {
                Image(uiImage: cover).resizable().scaledToFit()
            }
            PlayerLayerView(player: model.player)
            Color.clear.contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .scaleEffect(1 - min(0.2, drag / 1800))
        .offset(y: drag)
        .onTapGesture {
            if shown && model.playing {
                hideTask?.cancel()
                shown = false
            } else {
                keepShown()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onChanged { v in
                    let dy = v.translation.height
                    guard drag > 0 || (dy > 0 && dy > abs(v.translation.width)) else { return }
                    drag = max(0, dy)
                }
                .onEnded { v in
                    if drag > 130 || (drag > 0 && v.predictedEndTranslation.height > 360) {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                    }
                }
        )
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding()
                    .accessibilityLabel(Text("chat.close"))
                    Spacer()
                    SaveMediaButton(token: token, fileID: fileID, video: true)
                }
                .background(
                    LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                )
                Spacer(minLength: 0)
                bottomBar
            }
            centre
        }
    }

    @ViewBuilder private var centre: some View {
        if model.failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .frame(width: 74, height: 74)
                .background(.black.opacity(0.42), in: Circle())
        } else if model.buffering && !model.ended {
            ProgressView().tint(.white).scaleEffect(1.4)
                .frame(width: 74, height: 74)
                .background(.black.opacity(0.42), in: Circle())
        } else {
            Button {
                model.toggle()
                keepShown()
            } label: {
                Image(systemName: model.ended ? "arrow.counterclockwise" : (model.playing ? "pause.fill" : "play.fill"))
                    .font(.system(size: model.ended ? 28 : 30, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.leading, !model.ended && !model.playing ? 4 : 0)
                    .frame(width: 74, height: 74)
                    .background(.black.opacity(0.42), in: Circle())
            }
            .accessibilityLabel(Text(LocalizedStringKey(model.ended ? "vp.replay" : (model.playing ? "vp.pause" : "vp.play"))))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(RemoteMedia.clock(model.current))
                .modifier(PlayerClock())
            Slider(
                value: Binding(
                    get: { min(model.current, max(model.total, 0.01)) },
                    set: { v in
                        model.current = v
                        model.seek(to: v, exact: false)
                        keepShown()
                    }
                ),
                in: 0...max(model.total, 0.01),
                onEditingChanged: { editing in
                    model.scrubbing = editing
                    if !editing { model.seek(to: model.current, exact: true) }
                    keepShown()
                }
            )
            .tint(.white)
            .disabled(model.total <= 0)
            .accessibilityLabel(Text("vp.seek"))
            Text(RemoteMedia.clock(model.total))
                .modifier(PlayerClock())
            Button {
                model.toggleMute()
                keepShown()
            } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text(LocalizedStringKey(model.muted ? "vp.unmute" : "vp.mute")))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color(red: 20 / 255, green: 24 / 255, blue: 28 / 255).opacity(0.62), in: Capsule())
        .environment(\.layoutDirection, .leftToRight) // a time line runs left to right in every language
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    private func keepShown() {
        shown = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.playing, !model.scrubbing else { return }
            shown = false
        }
    }
}

private struct PlayerClock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 38)
    }
}

/// A clear cover background (iOS 16.4+), so the chat shows through while the video is swiped down.
private struct ClearCover: ViewModifier {
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
