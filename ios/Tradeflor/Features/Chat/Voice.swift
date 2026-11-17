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
    /// Paused mid-recording (the website's VoiceComposer pause / resume).
    @Published private(set) var paused = false
    /// Stopped and waiting for Send or Delete, with a preview to listen to first.
    @Published private(set) var reviewing = false
    @Published private(set) var previewPlaying = false
    @Published private(set) var previewProgress: Double = 0

    private var recorder: AVAudioRecorder?
    private var reviewDuration: TimeInterval = 0
    private var preview: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?
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
        if !r.isRecording && !paused { timer?.invalidate() }
    }

    func pause() {
        guard let r = recorder, r.isRecording else { return }
        r.pause()
        paused = true
    }

    func resume() {
        guard let r = recorder, paused, !reviewing else { return }
        r.record()
        paused = false
    }

    /// Stop recording and listen before sending.
    func review() {
        guard let r = recorder, !reviewing else { return }
        reviewDuration = r.currentTime
        r.stop()
        timer?.invalidate()
        paused = false
        reviewing = true
        previewProgress = 0
    }

    func togglePreview() {
        guard reviewing, let url else { return }
        if previewPlaying {
            preview?.pause()
            previewPlaying = false
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        if preview == nil { preview = try? AVAudioPlayer(contentsOf: url) }
        guard let p = preview else { return }
        if p.currentTime >= p.duration - 0.05 { p.currentTime = 0 }
        p.play()
        previewPlaying = true
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let p = self.preview else { return }
                self.previewProgress = p.duration > 0 ? p.currentTime / p.duration : 0
                if !p.isPlaying { self.previewPlaying = false; if self.previewProgress > 0.97 { self.previewProgress = 1 }; return }
            }
        }
    }

    /// Stops and returns the recording, or nil if it was too short to be a message.
    func finish() -> (data: Data, durationMs: Int, waveform: [Double])? {
        guard let r = recorder, let url else { return nil }
        let duration = reviewing ? reviewDuration : r.currentTime
        if !reviewing { r.stop() }
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
        previewTask?.cancel()
        previewTask = nil
        preview?.stop()
        preview = nil
        previewPlaying = false
        previewProgress = 0
        paused = false
        reviewing = false
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
/// As in WhatsApp (website 5b6f8e1, useAudioPlayback.ts): one speed for every note (1x / 1.5x / 2x, remembered),
/// seeking from the waveform, and when a note ends the next voice note of the same conversation plays by itself.
@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    @Published private(set) var current: String?
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var failed: Set<String> = []
    /// The playback speed for every voice note (website tf.voiceSpeed).
    @Published private(set) var speed: Double = VoicePlayer.savedSpeed()
    /// Message ids of notes started on this device, so the mic badge turns from "new" to "played" (website tf.vnPlayed).
    @Published private(set) var played: Set<String> = VoicePlayer.savedPlayed()

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var web: WKWebView?
    /// The conversation and position of the note playing, to find the next one when it ends.
    private var currentSpot: (conversation: String, seq: Int64)?
    /// Where to start (0...1) once the audio is loaded, when playback starts from a tap on the waveform.
    private var startAt: Double = 0
    /// The length the server gave (seconds); WebM from the website often reports no duration of its own.
    private var knownDuration: Double = 0

    /// Every voice bubble shown registers its message here, so the player can pick the next note in the same
    /// conversation (the next higher seq) without the chat screen passing the list in.
    private struct Registered { let token: String; let message: Message }
    private var registry: [String: Registered] = [:]

    nonisolated private static let speedKey = "tf.voiceSpeed"
    nonisolated private static let playedKey = "tf.vnPlayed"

    nonisolated private static func savedSpeed() -> Double {
        let v = UserDefaults.standard.double(forKey: speedKey)
        return v == 1.5 || v == 2 ? v : 1
    }

    nonisolated private static func savedPlayed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: playedKey) ?? [])
    }

    func register(token: String, message: Message) {
        guard message.audio_id != nil, !message.isDeleted else {
            registry[message.id] = nil
            return
        }
        if registry.count > 1500 {
            registry = registry.filter { $0.value.message.conversation_id == message.conversation_id }
        }
        registry[message.id] = Registered(token: token, message: message)
    }

    /// Play / pause by audio id only (shared media list): no auto-play of the next note.
    func toggle(token: String, audioID: String, mime: String?, durationMs: Int64? = nil) {
        if current == audioID {
            if playing { pause() } else { resume() }
            return
        }
        start(token: token, audioID: audioID, mime: mime, durationMs: durationMs, from: 0, message: nil)
    }

    /// Play / pause a voice message in a chat; when it ends the next one in the conversation follows.
    func toggle(token: String, message: Message) {
        guard let id = message.audio_id else { return }
        register(token: token, message: message)
        if current == id {
            if playing { pause() } else { resume() }
            return
        }
        start(token: token, audioID: id, mime: message.mime_type, durationMs: message.duration_ms, from: 0, message: message)
    }

    /// Move to a point (0...1) in a note; a note that is not loaded starts playing from there.
    func seek(token: String, message: Message, to fraction: Double) {
        guard let id = message.audio_id else { return }
        let f = min(1, max(0, fraction))
        guard current == id else {
            register(token: token, message: message)
            start(token: token, audioID: id, mime: message.mime_type, durationMs: message.duration_ms, from: f, message: message)
            return
        }
        progress = f
        if loading { startAt = f }
        if let p = player {
            if p.duration > 0 { p.currentTime = min(p.duration, f * p.duration) }
        } else {
            web?.evaluateJavaScript("window.vnSeek && window.vnSeek(\(f))")
        }
    }

    /// 1x -> 1.5x -> 2x -> 1x, kept for every note.
    func cycleSpeed() {
        let s: Double = speed == 1 ? 1.5 : (speed == 1.5 ? 2 : 1)
        speed = s
        UserDefaults.standard.set(s, forKey: Self.speedKey)
        player?.rate = Float(s)
        web?.evaluateJavaScript("(function(){ window.vnRate = \(s); const e = document.getElementById('a'); if (e) { e.defaultPlaybackRate = \(s); e.playbackRate = \(s); } })()")
    }

    private func start(token: String, audioID: String, mime: String?, durationMs: Int64?, from fraction: Double, message: Message?) {
        stop()
        current = audioID
        currentSpot = message.map { (conversation: $0.conversation_id, seq: $0.seq) }
        startAt = fraction
        knownDuration = Double(durationMs ?? 0) / 1000
        progress = fraction
        loading = true
        if let message { markPlayed(message.id) }
        let isMP4 = (mime ?? "").contains("mp4") || (mime ?? "").contains("aac") || (mime ?? "").contains("m4a")
        Task {
            if isMP4 { await playNative(token: token, audioID: audioID) } else { await playWeb(token: token, audioID: audioID) }
        }
    }

    private func markPlayed(_ id: String) {
        guard !played.contains(id) else { return }
        played.insert(id)
        var list = UserDefaults.standard.stringArray(forKey: Self.playedKey) ?? []
        list.append(id)
        if list.count > 800 { list.removeFirst(list.count - 800) }
        UserDefaults.standard.set(list, forKey: Self.playedKey)
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
        p.enableRate = true
        p.prepareToPlay()
        p.rate = Float(speed)
        if startAt > 0, p.duration > 0 { p.currentTime = min(p.duration, startAt * p.duration) }
        startAt = 0
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
        const known = \(knownDuration);
        let startAt = \(startAt);
        window.vnRate = \(speed);
        const dur = () => (isFinite(a.duration) && a.duration > 0) ? a.duration : known;
        window.vnSeek = (f) => { const d = dur(); if (d > 0) { try { a.currentTime = f * d; } catch (e) {} } };
        a.defaultPlaybackRate = window.vnRate;
        a.playbackRate = window.vnRate;
        a.addEventListener('loadedmetadata', () => { if (startAt > 0) { window.vnSeek(startAt); startAt = 0; } });
        a.addEventListener('playing', () => { if (a.playbackRate !== window.vnRate) a.playbackRate = window.vnRate; post({e: 'playing'}); });
        a.addEventListener('timeupdate', () => { const d = dur(); post({e: 'time', p: d > 0 ? Math.min(1, a.currentTime / d) : 0}); });
        a.addEventListener('ended', () => post({e: 'ended'}));
        a.addEventListener('error', () => post({e: 'error'}));
        a.play().catch(() => post({e: 'error'}));
        </script></body></html>
        """
        startAt = 0
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
        guard current != nil else { return }
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
        if let player {
            player.rate = Float(speed)
            player.play()
        } else {
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
        currentSpot = nil
        startAt = 0
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

    /// The next voice note after the one playing, in the same conversation, among the bubbles shown so far.
    private func nextAfterCurrent() -> Registered? {
        guard let spot = currentSpot else { return nil }
        return registry.values
            .filter { r in
                guard r.message.conversation_id == spot.conversation, r.message.seq > spot.seq, !r.message.isDeleted,
                      let a = r.message.audio_id else { return false }
                return !failed.contains(a)
            }
            .min { $0.message.seq < $1.message.seq }
    }

    private func finished() {
        let next = nextAfterCurrent()
        stop()
        if let next, let id = next.message.audio_id {
            start(token: next.token, audioID: id, mime: next.message.mime_type, durationMs: next.message.duration_ms, from: 0, message: next.message)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor in
            // Only the player still in use (a stopped one never calls this, but be safe).
            guard let p = self.player, ObjectIdentifier(p) == finishedID else { return }
            self.finished()
        }
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

/// The senders' pictures for voice notes, fetched once per person (GET /users/{id}/profile) when the chat did not pass one.
@MainActor
final class VoiceFaces: ObservableObject {
    static let shared = VoiceFaces()
    @Published private(set) var profiles: [String: Profile] = [:]
    private var asked: Set<String> = []

    func load(token: String, userID: String) {
        guard !token.isEmpty, !userID.isEmpty, !asked.contains(userID) else { return }
        asked.insert(userID)
        Task {
            if let p = try? await APIClient.shared.userProfile(token: token, userID: userID) { profiles[userID] = p }
        }
    }
}

// MARK: views

/// A voice message as in WhatsApp (website VoiceMessagePlayer.tsx, 69-voice-wa.css): the sender's picture with a mic
/// badge (mine: picture first; theirs: picture at the end), play/pause, the waveform with a dot you can tap or drag,
/// and under it the length (the time played while it plays), the message time and ticks. While a note plays, the
/// picture becomes the speed button (1x, 1.5x, 2x, one setting for every note).
struct VoiceBubble: View {
    let token: String
    let message: Message
    let mine: Bool
    let state: Bubble.Delivery?
    /// The sender's picture and name when the chat already knows them; otherwise fetched once per person.
    var avatarID: String? = nil
    var name: String? = nil
    @ObservedObject private var player = VoicePlayer.shared
    @ObservedObject private var faces = VoiceFaces.shared

    private var isCurrent: Bool { player.current == message.audio_id }
    /// Playing or paused part-way: the speed button shows instead of the picture, the time played instead of the length.
    private var started: Bool { isCurrent && (player.playing || player.progress > 0) }
    private var samples: [Double] {
        guard let w = message.waveform, let d = w.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Double].self, from: d), !arr.isEmpty else {
            return Array(repeating: 0.3, count: 32)
        }
        return VoiceRecorder.downsample(arr, to: 32)
    }

    private static let barColor = Theme.dyn(0xE2F5FA, 0x1E3C46, 0.34, 0.28)
    private static let playedTheirs = Theme.dyn(0x2FD9DC, 0x0097A5)
    private static let playedMine = Theme.dyn(0x8FF3F6, 0x0097A5)
    private static let toggleColor = Theme.dyn(0xD9EEF4, 0x3D5964)
    private static let metaColor = Theme.dyn(0xDEF0F6, 0x5B7480, 0.72, 1)
    private static let badgeGround = Theme.dyn(0x0B2A33, 0xFFFFFF)

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            HStack(spacing: 8) {
                if mine { side }
                playButton
                VStack(alignment: .leading, spacing: 3) {
                    wave
                    HStack(spacing: 4) {
                        if let id = message.audio_id, player.failed.contains(id) {
                            Text("chat.voice.failed")
                        } else {
                            let total = message.duration_ms ?? 0
                            Text(Self.length(started ? Int64(Double(total) * player.progress) : total))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 6)
                        if let d = message.date { Text(d, style: .time) }
                        if let state { Bubble.tickView(state) }
                    }
                    .font(.caption2)
                    .foregroundStyle(Self.metaColor)
                    .frame(width: 150)
                }
                .padding(.top, 12)
                if !mine { side }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .tfBubble(mine: mine)
            if !mine { Spacer(minLength: 48) }
        }
        .onAppear {
            player.register(token: token, message: message)
            if avatarID == nil { faces.load(token: token, userID: message.sender_id) }
        }
    }

    private var playButton: some View {
        Button {
            player.toggle(token: token, message: message)
        } label: {
            ZStack {
                if isCurrent && player.loading {
                    ProgressView().tint(Self.toggleColor)
                } else {
                    Image(systemName: isCurrent && player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .foregroundStyle(Self.toggleColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isCurrent && player.playing ? "chat.pause" : "chat.play"))
    }

    /// The waveform: played part coloured, a dot at the play position; tap or drag along it to seek.
    private var wave: some View {
        let progress = isCurrent ? player.progress : 0
        return Waveform(samples: samples, progress: progress, color: Self.barColor,
                        playedColor: mine ? Self.playedMine : Self.playedTheirs,
                        dot: mine ? Self.playedMine : Self.playedTheirs)
            .frame(width: 150, height: 26)
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard geo.size.width > 0 else { return }
                                    player.seek(token: token, message: message, to: v.location.x / geo.size.width)
                                }
                        )
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .accessibilityElement()
            .accessibilityLabel(Text("chats.kind.voice"))
            .accessibilityValue(Text(verbatim: "\(Int((progress * 100).rounded()))%"))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: player.seek(token: token, message: message, to: progress + 0.1)
                case .decrement: player.seek(token: token, message: message, to: progress - 0.1)
                @unknown default: break
                }
            }
    }

    /// The picture with its mic badge, or the speed button while the note plays.
    @ViewBuilder private var side: some View {
        Group {
            if started {
                Button { player.cycleSpeed() } label: {
                    Text(verbatim: "\(Self.speedLabel(player.speed))×")
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 9)
                        .frame(minWidth: 42, minHeight: 28)
                        .background(Capsule().fill(Theme.text.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                face
            }
        }
        .frame(width: 50, height: 50)
    }

    private var face: some View {
        let p = faces.profiles[message.sender_id]
        let fetched: String? = (p?.avatar_id.isEmpty ?? true) ? nil : p?.avatar_id
        let title = name ?? p.map { $0.display_name.isEmpty ? $0.username : $0.display_name } ?? "?"
        let micColor: Color = mine ? Theme.dyn(0x9FB7C1, 0x5B7480)
            : (player.played.contains(message.id) ? Theme.dyn(0x53BDEB, 0x2A8FC9) : Self.playedTheirs)
        return Avatar(token: token, userID: message.sender_id, avatarID: avatarID ?? fetched, title: title, size: 50)
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(micColor)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Self.badgeGround))
                    .overlay(Circle().stroke(Self.badgeGround, lineWidth: 2))
                    .offset(x: -3, y: 1)
            }
            .accessibilityHidden(true)
    }

    private static func speedLabel(_ s: Double) -> String {
        s == 1.5 ? "1.5" : String(Int(s))
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
    /// When set, played bars take this colour and the rest `color` as is (otherwise the rest is `color` faded).
    var playedColor: Color? = nil
    /// When set, a dot of this colour marks the play position.
    var dot: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let n = max(samples.count, 1)
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let p = min(1, max(0, progress))
            ZStack {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { i, v in
                        let isPlayed = (Double(i) + 0.5) / Double(n) <= p
                        Capsule()
                            .fill(isPlayed ? (playedColor ?? color) : (playedColor == nil ? color.opacity(0.45) : color))
                            .frame(width: w, height: max(3, geo.size.height * CGFloat(min(1, v))))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .position(x: geo.size.width * CGFloat(p), y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.red).frame(width: 38, height: 40)
            }
            .accessibilityLabel(Text("chat.voice.cancel"))
            if recorder.reviewing {
                Button { recorder.togglePreview() } label: {
                    Image(systemName: recorder.previewPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent).frame(width: 34, height: 40)
                }
                .accessibilityLabel(Text(LocalizedStringKey(recorder.previewPlaying ? "chat.voice.preview.pause" : "chat.voice.preview")))
                Waveform(samples: VoiceRecorder.downsample(recorder.levels, to: 40), progress: recorder.previewProgress, color: Theme.accent)
                    .frame(height: 26)
                Text(VoiceBubble.length(Int64(recorder.elapsed * 1000))).monospacedDigit().foregroundStyle(Theme.text)
            } else {
                Circle().fill(.red).frame(width: 8, height: 8).opacity(recorder.paused ? 0.3 : 1)
                Text(VoiceBubble.length(Int64(recorder.elapsed * 1000)))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Waveform(samples: Array(recorder.levels.suffix(40)), progress: 1, color: Theme.accent)
                    .frame(height: 26)
                Button { if recorder.paused { recorder.resume() } else { recorder.pause() } } label: {
                    Image(systemName: recorder.paused ? "mic.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(recorder.paused ? Color.red : Theme.text).frame(width: 32, height: 40)
                }
                .accessibilityLabel(Text(LocalizedStringKey(recorder.paused ? "chat.voice.resume" : "chat.voice.pause")))
                Button { recorder.review() } label: {
                    Image(systemName: "stop.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text).frame(width: 32, height: 40)
                }
                .accessibilityLabel(Text("chat.voice.review"))
            }
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
