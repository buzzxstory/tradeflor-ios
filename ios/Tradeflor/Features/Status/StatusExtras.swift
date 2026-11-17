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
    case "video": media = player?.currentItem?.presentationSize ?? .zero
    default: return nil
    }
    guard media.width > 0, media.height > 0, size.width > 0, size.height > 0 else { return nil }
    return AVMakeRect(aspectRatio: media, insideRect: bounds)
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
