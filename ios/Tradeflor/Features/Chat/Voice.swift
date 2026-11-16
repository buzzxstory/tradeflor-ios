import SwiftUI
import AVFoundation
import WebKit

// MARK: recording

/// Records a voice message as AAC in an .m4a file (a format the server accepts and every client plays),
/// sampling the level 10 times a second for the waveform. iOS asks for the microphone once.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [Double] = []
    @Published var denied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    nonisolated static let maxDuration: TimeInterval = 15 * 60

    func start() async {
        let session = AVAudioSession.sharedInstance()
        let granted: Bool = await withCheckedContinuation { cont in
            session.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard granted else { denied = true; return }
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: file, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: Self.maxDuration) else { return }
            recorder = r
            url = file
            levels = []
            elapsed = 0
            recording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            recording = false
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0)) // -160 ... 0
        levels.append(max(0, min(1, (db + 50) / 50)))
        elapsed = r.currentTime
        if !r.isRecording { timer?.invalidate() }
    }

    /// Stops and returns the recording, or nil if it was too short to be a message.
    func finish() -> (data: Data, durationMs: Int, waveform: [Double])? {
        guard let r = recorder, let url else { return nil }
        let duration = r.currentTime
        r.stop()
        cleanup()
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 0.7, let data = try? Data(contentsOf: url) else { return nil }
        return (data, Int(duration * 1000), Self.downsample(levels, to: 48))
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        cleanup()
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        url = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated static func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v.map { ($0 * 100).rounded() / 100 } }
        let step = Double(v.count) / Double(n)
        return (0..<n).map { i in
            let a = Int(Double(i) * step), b = max(a + 1, Int(Double(i + 1) * step))
            let slice = v[a..<min(b, v.count)]
            return ((slice.max() ?? 0) * 100).rounded() / 100
        }
    }
}

// MARK: playback

/// Plays one voice message at a time.
/// - M4A/AAC (recorded on iPhone, Safari or this app): AVAudioPlayer from memory, nothing written to disk.
/// - WebM/Ogg Opus (recorded in Chrome/Firefox on the website): iOS's AVFoundation cannot decode those, so they
///   play through a hidden WebKit audio element, using a one-minute media ticket in the URL (as the website does).
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    @Published private(set) var current: String?
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failed: Set<String> = []

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var web: WKWebView?

    func toggle(token: String, audioID: String, mime: String?) {
        if current == audioID {
            if playing { pause() } else { resume() }
            return
        }
        stop()
        current = audioID
        progress = 0
        loading = true
        let isMP4 = (mime ?? "").contains("mp4") || (mime ?? "").contains("aac") || (mime ?? "").contains("m4a")
        Task {
            if isMP4 { await playNative(token: token, audioID: audioID) } else { await playWeb(token: token, audioID: audioID) }
        }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func playNative(token: String, audioID: String) async {
        guard let data = await APIClient.shared.voice(token: token, audioID: audioID),
              current == audioID, let p = try? AVAudioPlayer(data: data) else {
            markFailed(audioID)
            return
        }
        activateSession()
        p.delegate = self
        player = p
        loading = false
        p.play()
        playing = true
        startTimer()
    }

    private func playWeb(token: String, audioID: String) async {
        guard let ticket = try? await APIClient.shared.mediaTicket(token: token), current == audioID else {
            markFailed(audioID)
            return
        }
        activateSession()
        let src = APIClient.shared.voiceURL(audioID: audioID, ticket: ticket).absoluteString
        let w = webView()
        let html = """
        <html><body><audio id="a" playsinline preload="auto" src="\(src)"></audio><script>
        const a = document.getElementById('a');
        const post = (m) => window.webkit.messageHandlers.voice.postMessage(m);
        a.addEventListener('playing', () => post({e: 'playing'}));
        a.addEventListener('timeupdate', () => post({e: 'time', p: a.duration ? a.currentTime / a.duration : 0}));
        a.addEventListener('ended', () => post({e: 'ended'}));
        a.addEventListener('error', () => post({e: 'error'}));
        a.play().catch(() => post({e: 'error'}));
        </script></body></html>
        """
        w.loadHTMLString(html, baseURL: URL(string: "https://app.tradeflor.com/"))
    }

    private func webView() -> WKWebView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(WebAudioBridge(owner: self), name: "voice")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        w.alpha = 0.01
        w.isUserInteractionEnabled = false
        // Media plays only in a web view that is in a window.
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(w)
        }
        web = w
        return w
    }

    fileprivate func webEvent(_ body: [String: Any]) {
        switch body["e"] as? String {
        case "playing": loading = false; playing = true
        case "time": progress = (body["p"] as? Double) ?? progress
        case "ended": finished()
        case "error": if let c = current { markFailed(c) }
        default: break
        }
    }

    func pause() {
        player?.pause()
        web?.evaluateJavaScript("document.getElementById('a') && document.getElementById('a').pause()")
        playing = false
    }

    private func resume() {
        if let player { player.play() } else {
            web?.evaluateJavaScript("document.getElementById('a') && document.getElementById('a').play()")
        }
        playing = true
    }

    func stop() {
        player?.stop()
        player = nil
        web?.loadHTMLString("", baseURL: nil)
        timer?.invalidate()
        timer = nil
        playing = false
        loading = false
        current = nil
        progress = 0
    }

    private func markFailed(_ id: String) {
        failed.insert(id)
        if current == id { stop() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    private func finished() {
        stop()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }
}

/// WKScriptMessageHandler retains its handler; this small bridge keeps the player out of that cycle.
private final class WebAudioBridge: NSObject, WKScriptMessageHandler {
    weak var owner: VoicePlayer?
    init(owner: VoicePlayer) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in self.owner?.webEvent(body) }
    }
}

// MARK: views

/// A voice message: play/pause, the waveform filling in as it plays, and the length.
struct VoiceBubble: View {
    let token: String
    let message: Message
    let mine: Bool
    let state: Bubble.Delivery?
    @ObservedObject private var player = VoicePlayer.shared

    private var isCurrent: Bool { player.current == message.audio_id }
    private var samples: [Double] {
        guard let w = message.waveform, let d = w.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Double].self, from: d), !arr.isEmpty else {
            return Array(repeating: 0.3, count: 32)
        }
        return VoiceRecorder.downsample(arr, to: 32)
    }

    var body: some View {
        let fg: Color = mine ? Theme.onAccent : .white
        HStack {
            if mine { Spacer(minLength: 48) }
            HStack(spacing: 10) {
                Button {
                    if let id = message.audio_id { player.toggle(token: token, audioID: id, mime: message.mime_type) }
                } label: {
                    ZStack {
                        if isCurrent && player.loading {
                            ProgressView().tint(fg)
                        } else {
                            Image(systemName: isCurrent && player.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .foregroundStyle(fg)
                }
                .accessibilityLabel(Text(isCurrent && player.playing ? "chat.pause" : "chat.play"))
                VStack(alignment: .leading, spacing: 4) {
                    Waveform(samples: samples, progress: isCurrent ? player.progress : 0, color: fg)
                        .frame(width: 150, height: 26)
                    HStack(spacing: 4) {
                        if let id = message.audio_id, player.failed.contains(id) {
                            Text("chat.voice.failed")
                        } else {
                            Text(Self.length(message.duration_ms ?? 0))
                        }
                        Spacer(minLength: 6)
                        if let d = message.date { Text(d, style: .time) }
                        if let state { Bubble.tickView(state) }
                    }
                    .font(.caption2)
                    .foregroundStyle(fg.opacity(0.7))
                    .frame(width: 150)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(mine ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !mine { Spacer(minLength: 48) }
        }
    }

    nonisolated static func length(_ ms: Int64) -> String {
        let s = Int((Double(ms) / 1000).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct Waveform: View {
    let samples: [Double]
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let n = max(samples.count, 1)
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(samples.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(color.opacity(Double(i) / Double(n) < progress ? 1 : 0.45))
                        .frame(width: w, height: max(3, geo.size.height * CGFloat(v)))
                }
            }
            .frame(maxHeight: .infinity)
            .environment(\.layoutDirection, .leftToRight) // time runs left to right, even in Arabic
        }
    }
}

/// Shown in place of the text field while recording: cancel, the running time, live level, send.
struct RecordingBar: View {
    @ObservedObject var recorder: VoiceRecorder
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.red).frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text("chat.voice.cancel"))
            Circle().fill(.red).frame(width: 8, height: 8)
            Text(VoiceBubble.length(Int64(recorder.elapsed * 1000)))
                .monospacedDigit()
                .foregroundStyle(.white)
            Waveform(samples: Array(recorder.levels.suffix(40)), progress: 1, color: Theme.accent)
                .frame(height: 26)
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel(Text("chat.send"))
        }
    }
}
