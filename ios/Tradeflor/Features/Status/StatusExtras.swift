import SwiftUI
import AVFoundation

/// The like (the heart) is a private reaction: the owner sees it in "Viewed by", nothing goes to the chat.
let statusLike = "❤️"

/// The eight big emojis that come up over the status when the reply box is tapped (WhatsApp's own set, web STATUS_QUICK).
/// One tap sends that emoji to the owner's chat as a reaction line; it does not replace the heart.
let statusQuickEmojis = ["😍", "😂", "😮", "😢", "🙏", "👏", "🎉", "💯"]

/// Reactions I sent while the app is open, by post id (web `sentReacts`): a status opened again shows the like at once,
/// even before the status list has been reloaded from the server (which also remembers it, as my_reaction).
final class StatusReactCache: @unchecked Sendable {
    static let shared = StatusReactCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()

    func get(_ postID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[postID]
    }

    func set(_ postID: String, _ emoji: String) {
        lock.lock(); defer { lock.unlock() }
        map[postID] = emoji
    }

    /// Sign-out: the next account never shows this one's likes.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        map = [:]
    }
}

/// The "seen" calls still on their way (a status or an Official post just watched). A list read waits for them first, so
/// a ring read right after the viewer closes is never the stale turquoise one.
final class StatusSeenQueue: @unchecked Sendable {
    static let shared = StatusSeenQueue()
    private var pending: [Task<Void, Never>] = []
    private let lock = NSLock()

    func add(_ work: @escaping () async -> Void) {
        let t = Task { await work() }
        lock.lock(); defer { lock.unlock() }
        pending.append(t)
    }

    func drain() async {
        let list: [Task<Void, Never>] = {
            lock.lock(); defer { lock.unlock() }
            let l = pending
            pending = []
            return l
        }()
        for t in list { await t.value }
    }
}

/// How far the story on screen has played (0…1). Kept out of the viewer's own state: the clock moves it 30 times a second,
/// and only what reads it (the bars, a voice status's art) is redrawn, not the whole viewer with its reply box and sheets.
final class StatusClock: ObservableObject {
    @Published var progress: Double = 0
}

/// Draws `content` with the clock's progress; the only view that follows the clock.
struct StatusClockReader<Content: View>: View {
    @ObservedObject var clock: StatusClock
    @ViewBuilder let content: (Double) -> Content

    var body: some View { content(clock.progress) }
}

/// The story bars on top (one per post; the ones before full, the one on screen filling with the clock).
struct StatusBars: View {
    let count: Int
    let current: Int
    @ObservedObject var clock: StatusClock

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(0, count), id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule().fill(.white)
                            .frame(width: geo.size.width * (i < current ? 1 : (i == current ? clock.progress : 0)))
                    }
                }
                .frame(height: 3)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
}

extension Notification.Name {
    /// A status was watched, posted or deleted: every status list (the row on Chats, the rings on the chat rows, the
    /// TradeFlor cards) reads the feed again at once (web "tf-status").
    static let tfStatusChanged = Notification.Name("tf.status.changed")
    /// A status is gone (deleted by its owner, or the server refused it): an open viewer leaves it (web onStatusGone).
    static let tfStatusGone = Notification.Name("tf.status.gone")
}

/// Statuses that are gone while the app runs (web statusMedia.ts markStatusGone / isStatusGone): deleted (the server's live
/// "status" event, or a 404 when one is opened) or past its 24 hours. Never shown again from what a screen still holds.
final class StatusGone: @unchecked Sendable {
    static let shared = StatusGone()
    private var ids: Set<String> = []
    private let lock = NSLock()

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }

    /// Marks it gone, forgets its kept picture / poster, and tells an open viewer (on the main thread).
    func mark(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        let isNew = ids.insert(id).inserted
        lock.unlock()
        guard isNew else { return }
        APIClient.shared.avatarCache.removeObject(forKey: "status/\(id)/false" as NSString)
        APIClient.shared.avatarCache.removeObject(forKey: "status/\(id)/true" as NSString)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .tfStatusGone, object: id) }
    }

    /// Sign-out: the next account starts clean.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        ids = []
    }

    /// Past its own 24 hours by this phone's clock (expires_at in seconds or milliseconds).
    static func expired(_ expiresAt: Int64?, now: Date = Date()) -> Bool {
        guard let e = expiresAt, let d = serverDate(e) else { return false }
        return d <= now
    }
}

enum StatusSeenAt {
    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }
    private static let timeF = template("jmm")
    private static let dayF = template("dMMM")

    /// When a viewer watched a status, as WhatsApp lists it: "today 12:31 AM", "yesterday 8:02 PM", or "16 Nov 8:02 PM".
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = timeF.string(from: d)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days <= 0 { return String(format: NSLocalizedString("stv.today", comment: ""), time) }
        if days == 1 { return String(format: NSLocalizedString("stv.yesterday", comment: ""), time) }
        return dayF.string(from: d) + " " + time
    }
}

/// "1 view" / "N views".
func statusViewsTitle(_ n: Int) -> String {
    n == 1 ? NSLocalizedString("stv.view.one", comment: "") : String(format: NSLocalizedString("stv.views", comment: ""), n)
}

/// Where the story's picture or video really is inside the screen (aspect-fit), so a tap on the dark area around it can
/// close the viewer. nil when the story fills the screen (text, voice, still loading): there is no dark area then.
func statusFittedRect(kind: String?, image: UIImage?, player: AVPlayer?, in size: CGSize) -> CGRect? {
    let bounds = CGRect(origin: .zero, size: size)
    var media: CGSize = .zero
    switch kind {
    case "image": media = image?.size ?? .zero
    case "video":
        // the video's own size once it is known, else its poster's (shown while the video loads)
        media = player?.currentItem?.presentationSize ?? .zero
        if media.width <= 0 || media.height <= 0 { media = image?.size ?? .zero }
    default: return nil
    }
    guard media.width > 0, media.height > 0, size.width > 0, size.height > 0 else { return nil }
    return AVMakeRect(aspectRatio: media, insideRect: bounds)
}

// MARK: story video (no system player)

/// A status (or Official) video, set up to start fast: it plays as soon as a little has arrived instead of waiting for a
/// big buffer (AVPlayer then stops on a stall instead of waiting, so the viewer's clock resumes it; see `resumeIfStalled`).
enum StatusVideo {
    static func player(token: String, id: String, muted: Bool) -> AVPlayer {
        let asset = AVURLAsset(url: APIClient.shared.statusMediaURL(id: id),
                               options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(token)"]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
        p.isMuted = muted
        return p
    }

    /// Without automatic waiting a stalled player stays stopped: play again once enough has arrived.
    static func resumeIfStalled(_ p: AVPlayer) {
        guard p.rate == 0, let item = p.currentItem, item.status == .readyToPlay,
              item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull else { return }
        let d = item.duration.seconds
        if d.isFinite, d > 0, p.currentTime().seconds >= d - 0.1 { return } // at the end: not a stall
        p.play()
    }
}

/// Set by AVPlayerItemDidPlayToEndTime, read by the viewer's clock.
final class StatusEndFlag: @unchecked Sendable {
    var ended = false
}

final class StatusPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The story video's picture, drawn by an AVPlayerLayer: no AirPlay, no skip buttons, no scrubber, no menu (WhatsApp and
/// the web show only the story's own bars). It takes no touches: the viewer's taps, hold and swipes stay in charge.
struct StatusVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> StatusPlayerUIView {
        let v = StatusPlayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: StatusPlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }

    static func dismantleUIView(_ v: StatusPlayerUIView, coordinator: ()) {
        v.playerLayer.player = nil
    }
}

/// A clear full-screen cover (iOS 16.4+), so what is underneath shows through while a story is swiped down.
struct StatusClearCover: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            content
        }
    }

    static var seeThrough: Bool {
        if #available(iOS 16.4, *) { return true }
        return false
    }
}

/// The swipe-down-to-close look (web swipeDismiss): the story follows the finger, shrinks a little, and the dark
/// backdrop fades with the distance.
enum StatusSwipe {
    static let closeDistance: CGFloat = 120
    /// a quick flick closes from a shorter drag: where the finger's speed would carry the story
    static let flickPredicted: CGFloat = 320
    static let flickMin: CGFloat = 40

    static func scale(_ offset: CGFloat, height: CGFloat) -> CGFloat {
        let k = min(1, max(0, offset) / max(1, height))
        return 1 - min(0.2, k * 0.3)
    }

    static func backdrop(_ offset: CGFloat, height: CGFloat) -> Double {
        guard StatusClearCover.seeThrough else { return 1 } // the cover cannot be see-through: stay dark
        let k = min(1, max(0, offset) / max(1, height))
        return 1 - min(0.85, Double(k) * 1.6)
    }

    static func shouldClose(_ v: DragGesture.Value) -> Bool {
        let dy = v.translation.height
        return dy >= closeDistance || (dy >= flickMin && v.predictedEndTranslation.height >= flickPredicted)
    }
}

/// WhatsApp's quick reactions: the status dims and eight big emojis come up while the reply box is focused. A tap beside
/// the emojis puts them away (the keyboard goes down).
struct StatusQuickGrid: View {
    let onPick: (String) -> Void
    let onDismiss: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            // web .status-quick: rgba(0, 6, 9, .58); 4 columns, 24 pt between rows; 58 pt buttons with a 42 pt emoji on phones
            Theme.hex(0x000609, 0.58)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 24) {
                ForEach(Array(statusQuickEmojis.enumerated()), id: \.element) { k, e in
                    Button { onPick(e) } label: {
                        Text(e).font(.system(size: 42)).frame(width: 58, height: 58)
                            .shadow(color: .black.opacity(0.45), radius: 7, y: 6)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(shown ? 1 : 0.5)
                    .offset(y: shown ? 0 : 14)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.62).delay(Double(k) * 0.022), value: shown)
                    .accessibilityLabel(Text(String(format: NSLocalizedString("stx.react.with", comment: ""), e)))
                }
            }
            .padding(.horizontal, 18)
        }
        .onAppear { shown = true }
    }
}

/// A viewer row in my status's views list: avatar with a red heart badge when they liked it, the name (and any other
/// reaction), and when they watched ("today 12:31 AM").
struct StatusViewerLine: View {
    let token: String
    let viewer: StatusViewerEntry

    var body: some View {
        HStack(spacing: 12) {
            Avatar(token: token, userID: viewer.user_id, avatarID: nil, title: viewer.username, size: 42)
                .overlay(alignment: .bottomTrailing) {
                    if viewer.reaction == statusLike {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.red, in: Circle())
                            .overlay(Circle().stroke(Theme.panel, lineWidth: 2))
                            .offset(x: 3, y: 3)
                            .accessibilityLabel(Text("stv.liked"))
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(viewer.username).font(.body.weight(.semibold))
                    if let r = viewer.reaction, !r.isEmpty, r != statusLike {
                        Text(r).accessibilityLabel(Text(String(format: NSLocalizedString("stx.reacted", comment: ""), r)))
                    }
                }
                if let d = serverDate(viewer.viewed_at) {
                    Text(StatusSeenAt.text(d)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: the web phone viewer's look (18-status.css, 54-status-instant.css, 60-status-react.css, 53-admin.css)

/// When a status was posted, as the web viewer's head says it: "just now", "12 min ago", "6 h ago".
func statusAgo(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return NSLocalizedString("ux2.ago.now", comment: "") }
    if s < 3600 { return String(format: NSLocalizedString("ux2.ago.min", comment: ""), s / 60) }
    return String(format: NSLocalizedString("ux2.ago.h", comment: ""), s / 3600)
}

/// web .status-head .status-icon: a 44 pt round button, dark glass (rgba(0,0,0,.35)), a white line icon.
struct StatusHeadButton: View {
    let systemName: String
    let label: LocalizedStringKey
    var size: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.35), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// web .official-face: the TRADEFLOR mark on a dark round disc; in the viewer's head 38 pt with a turquoise ring.
struct OfficialFace: View {
    var size: CGFloat = 38
    var ring = true

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.hex(0x0F3340), Theme.hex(0x04141B)], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 0, endRadius: size * 0.75))
            Image("BrandMark").resizable().scaledToFit().frame(width: size * 0.68, height: size * 0.68)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { if ring { Circle().stroke(Theme.hex(0x2FD9DC, 0.7), lineWidth: 1.5) } }
        .accessibilityHidden(true)
    }
}

/// The web's VerifiedBadge: a blue (#1DA1F2) seal with a white tick.
struct StatusVerifiedSeal: View {
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Theme.hex(0x1DA1F2))
            .font(.system(size: size))
            .accessibilityLabel(Text("adm.verified"))
    }
}

/// web .status-caption: not a bubble but a full-width band at the bottom, white 16 pt centred words over a dark fade.
/// With `maxHeight` (Official captions, up to 500 characters) a long text scrolls inside its band.
struct StatusCaptionBand: View {
    let text: String
    var maxHeight: CGFloat? = nil

    var body: some View {
        Group {
            if let maxHeight {
                ViewThatFits(in: .vertical) {
                    words
                    ScrollView(showsIndicators: false) { words }
                }
                .frame(maxHeight: maxHeight)
            } else {
                words
            }
        }
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    private var words: some View {
        Text(text)
            .font(.system(size: 16))
            .lineSpacing(5)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
    }
}

/// web .status-burst: the reaction comes up big (104 pt), overshoots a little, then floats up and fades.
struct StatusBurstView: View {
    let emoji: String
    @State private var phase = 0

    var body: some View {
        Text(emoji)
            .font(.system(size: 104))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 10)
            .scaleEffect(phase == 0 ? 0.4 : (phase == 1 ? 1.15 : 0.9))
            .offset(y: phase == 0 ? 30 : (phase == 1 ? 0 : -96))
            .opacity(phase == 1 ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) { phase = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.9)) { phase = 2 }
                }
            }
    }
}

/// web VoiceStatusArt: the speaker's picture in the middle with rings breathing out and a mic badge, a row of bars lit up to
/// where it has played (moving while it plays), and "0:12 / 0:40"; on the web's deep teal radial backdrop.
struct StatusVoiceArt<Face: View>: View {
    let playing: Bool
    let progress: Double
    let durationMs: Int64
    @ViewBuilder let face: () -> Face

    private static var bars: [CGFloat] {
        [0.35, 0.6, 0.9, 0.55, 0.75, 1, 0.5, 0.8, 0.45, 0.95, 0.65, 0.4, 0.85, 0.6, 0.3, 0.7, 0.95, 0.5, 0.75, 0.4, 0.9, 0.55, 0.7, 0.35]
    }

    var body: some View {
        ZStack {
            RadialGradient(stops: [.init(color: Theme.hex(0x07374A), location: 0), .init(color: Theme.hex(0x031E29), location: 0.55),
                                   .init(color: Theme.hex(0x011016), location: 1)],
                           center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 560)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { tl in
                art(at: tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func art(at t: Double) -> some View {
        let lit = Int((progress * Double(Self.bars.count)).rounded())
        return VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { k in
                    Circle()
                        .stroke(Theme.hex(0x00D4DF, 0.55), lineWidth: 2)
                        .frame(width: 124, height: 124)
                        .scaleEffect(0.82 + 0.68 * ringPhase(t, k))
                        .opacity(playing ? 0.75 * (1 - ringPhase(t, k)) : 0)
                }
                face()
                    .frame(width: 108, height: 108)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.hex(0x00D4DF, 0.7), lineWidth: 3))
                    .shadow(color: Theme.hex(0x00D4DF, 0.28), radius: 14)
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.hex(0x04151C), lineWidth: 3))
                    .offset(x: 38, y: 40)
            }
            .frame(width: 168, height: 168)
            HStack(spacing: 4) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { k, h in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(k < lit ? Theme.accent : Theme.hex(0xA9B9C5, 0.32))
                        .frame(maxWidth: 6)
                        .frame(height: max(5, 56 * h * barWave(t, k)))
                }
            }
            .frame(width: 270, height: 56)
            Text(durationMs > 0 ? "\(Self.clock(progress * Double(durationMs))) / \(Self.clock(Double(durationMs)))"
                                : NSLocalizedString("stx.tile.voice", comment: ""))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.hex(0xCFE3EE))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    /// 0…1 through a ring's 2.4 s breath (the three rings 0.8 s apart).
    private func ringPhase(_ t: Double, _ k: Int) -> CGFloat {
        CGFloat((t + Double(k) * 0.8).truncatingRemainder(dividingBy: 2.4) / 2.4)
    }

    /// A bar's height factor while it plays (0.45…1 over 1.05 s); still bars at full height when paused.
    private func barWave(_ t: Double, _ k: Int) -> CGFloat {
        guard playing else { return 1 }
        return CGFloat(0.45 + 0.55 * (0.5 + 0.5 * sin((t + Double(k % 7) * 0.09) * 2 * Double.pi / 1.05)))
    }

    private static func clock(_ ms: Double) -> String {
        let s = max(0, Int((ms / 1000).rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
