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
}

enum StatusSeenAt {
    /// When a viewer watched a status, as WhatsApp lists it: "today 12:31 AM", "yesterday 8:02 PM", or "16 Nov 8:02 PM".
    static func text(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.setLocalizedDateFormatFromTemplate("jmm")
        let time = tf.string(from: d)
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        if days <= 0 { return String(format: NSLocalizedString("stv.today", comment: ""), time) }
        if days == 1 { return String(format: NSLocalizedString("stv.yesterday", comment: ""), time) }
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("dMMM")
        return df.string(from: d) + " " + time
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
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 22) {
                ForEach(Array(statusQuickEmojis.enumerated()), id: \.element) { k, e in
                    Button { onPick(e) } label: {
                        Text(e).font(.system(size: 50)).frame(width: 70, height: 70)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(shown ? 1 : 0.4)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.62).delay(Double(k) * 0.025), value: shown)
                    .accessibilityLabel(Text(String(format: NSLocalizedString("stx.react.with", comment: ""), e)))
                }
            }
            .padding(.horizontal, 28)
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
