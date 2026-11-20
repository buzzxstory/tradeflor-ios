import SwiftUI

// WhatsApp parity pieces shared by chats and groups (website 7e5a789, ac11142, fbe88d3, 5b6f8e1, fda47e1, d454d16,
// cf87732, 8f4a9e3, 063cc7e, 03f13cf, ac48799, 1bd3569).

/// A member's name colour in a group (website GroupsView nameColour): soft colours that read on the dark cards, always the
/// same for the same person.
enum NameColour {
    private static let colours: [UInt32] = [0x53BDEB, 0xF7A26B, 0xA5D86E, 0xE88BD0, 0xFFD166, 0x7EE0C4, 0xB59CFF, 0xFF8A8A, 0x6FD3FF, 0xE9C46A]
    static func of(_ id: String) -> Color {
        var h: UInt32 = 0
        for u in id.utf16 { h = h &* 31 &+ UInt32(u) }
        return Theme.hex(colours[Int(h % UInt32(colours.count))])
    }
}

/// What sits inside the top of a text bubble (groups: the sender's name and tag; the quoted message).
private struct BubbleHeadKey: EnvironmentKey { static let defaultValue: AnyView? = nil }
extension EnvironmentValues {
    var tfBubbleHead: AnyView? {
        get { self[BubbleHeadKey.self] }
        set { self[BubbleHeadKey.self] = newValue }
    }
}

/// The round forward arrow beside a photo or video (website 4096249); nil = none.
private struct MediaForwardKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var tfMediaForward: (() -> Void)? {
        get { self[MediaForwardKey.self] }
        set { self[MediaForwardKey.self] = newValue }
    }
}

/// "Read more" (website shared/lib/readMore.ts): longer than 700 characters or 16 lines shows its beginning (about 560
/// characters / 12 lines, cut at a space or line break), then "… Read more".
enum ReadMore {
    static let maxChars = 700, keepChars = 560, maxLines = 16, keepLines = 12
    /// Texts opened with Read more stay open while the app runs (web: a module-level set), also when a row is reused.
    static var opened: Set<Int> = []

    static func cut(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard text.count > maxChars || lines.count > maxLines else { return nil }
        var cut = min(text.count, keepChars)
        if lines.count > maxLines {
            var at = 0
            for k in 0..<keepLines { at += lines[k].count + (k > 0 ? 1 : 0) }
            cut = min(cut, at)
        }
        let chars = Array(text)
        if cut < chars.count, !chars[cut].isWhitespace {
            if let space = chars[..<cut].lastIndex(where: { $0.isWhitespace }), Double(space) > Double(keepChars) * 0.6 { cut = space }
        }
        return cut >= chars.count ? nil : String(chars[..<cut])
    }
}

/// The size of a picture, by file id, learnt when it loads or when it is sent (website DIMS / tf.imgdims): the space is
/// kept before the picture arrives, so nothing jumps. Only sizes are kept, never the picture.
final class MediaDims: ObservableObject {
    static let shared = MediaDims()
    @Published private(set) var version = 0
    private let key = "tf.imgdims"
    private var map: [String: [Double]]
    private var order: [String]
    private var saveQueued = false // main thread

    private init() {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        map = d
        order = Array(d.keys)
    }

    func size(_ id: String) -> CGSize? {
        guard let v = map[id], v.count == 2, v[0] > 0, v[1] > 0 else { return nil }
        return CGSize(width: v[0], height: v[1])
    }

    func set(_ id: String, _ s: CGSize) {
        guard s.width > 0, s.height > 0, size(id) == nil else { return }
        map[id] = [Double(s.width), Double(s.height)]
        order.append(id)
        if order.count > 600 {
            for old in order.prefix(order.count - 600) { map[old] = nil }
            order = Array(order.suffix(600))
        }
        DispatchQueue.main.async {
            self.version += 1
            // written at most every 2 s (each new picture rewrote all 600 sizes while scrolling)
            guard !self.saveQueued else { return }
            self.saveQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.saveQueued = false
                UserDefaults.standard.set(self.map, forKey: self.key)
            }
        }
    }

    /// Widest a photo or video is drawn (WhatsApp iOS: about 70% of the screen, 275 pt on a 393 pt iPhone).
    static var maxWidth: CGFloat { (UIScreen.main.bounds.width * 0.70).rounded() }
    /// Tallest (about 80% of the screen width, 316 pt on a 393 pt iPhone).
    static var maxHeight: CGFloat { (UIScreen.main.bounds.width * 0.80).rounded() }

    /// The box for a photo or a video of size `s`, the same rule for both (measured on WhatsApp iOS): the media's own
    /// shape fitted inside maxWidth × maxHeight (9:16 → 177 × 316, 4:5 → 253 × 316, 3:4 → 237 × 316, landscape → full
    /// width). A very tall one never gets narrower than 40% of the screen and a very wide one never lower than 120 pt:
    /// beyond that it is cropped (the picture fills the box). Unknown shape: a square.
    static func box(_ s: CGSize?) -> CGSize {
        let screen = UIScreen.main.bounds.width
        let maxW = maxWidth, maxH = maxHeight
        let minW = (screen * 0.40).rounded(), minH: CGFloat = 120
        guard let s, s.width > 0, s.height > 0 else { return CGSize(width: maxW, height: maxW) }
        let ar = s.width / s.height
        var w = maxW, h = maxW / ar
        if h > maxH { h = maxH; w = maxH * ar }
        w = min(maxW, max(minW, w))
        h = min(maxH, max(minH, h))
        return CGSize(width: w.rounded(), height: h.rounded())
    }
}

/// Photos sent together (website shared/lib/albums.ts): same sender, plain photos (no caption, no reply, not deleted),
/// each within 90 s of the one before, the same day. Runs of 2 or more show as one album at their first message.
enum Albums {
    static let gap: Int64 = 90
    static let shown = 4

    struct Runs {
        var at: [String: [Message]] = [:]   // first id → the album's photos
        var hidden: Set<String> = []         // the others (drawn inside the album)
    }

    static func runs(_ rows: [Message], isGroup: Bool = false) -> Runs {
        var out = Runs()
        var run: [Message] = []
        func close() {
            if run.count >= 2 {
                out.at[run[0].id] = run
                for m in run.dropFirst() { out.hidden.insert(m.id) }
            }
            run = []
        }
        let cal = Calendar.current
        for m in rows {
            let ok = m.kind == "image" && !m.isDeleted && m.file_id != nil && (m.reply_to_id ?? "").isEmpty && !m.isViewOnce
                && m.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !(isGroup && m.forwarded == true) // groups leave forwarded photos out of an album (web 8f4a9e3)
            guard ok else { close(); continue }
            if let last = run.last {
                let t = ChatEdit.secs(m.created_at), lt = ChatEdit.secs(last.created_at)
                let d = t - lt
                let sameDay = cal.isDate(Date(timeIntervalSince1970: Double(t)), inSameDayAs: Date(timeIntervalSince1970: Double(lt)))
                if m.sender_id != last.sender_id || d < 0 || d > gap || !sameDay { close() }
            }
            run.append(m)
        }
        close()
        return out
    }
}

/// The time + ticks over a picture (website .media-time): a small dark chip.
struct MediaTimeChip: View {
    let date: Date?
    let state: Bubble.Delivery?
    var edited = false

    var body: some View {
        HStack(spacing: 3) {
            if edited { Text("chat.edited") }
            if let date { Text(Bubble.timeString(date)) }
            if let state { Bubble.tickView(state) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.45), in: Capsule())
    }
}

/// What each photo of an album can do: it stays its own message (menu, reactions), as on the web.
struct AlbumTileActions {
    var reply: (Message) -> Void = { _ in }
    var react: (Message, String) -> Void = { _, _ in }
    var forward: ((Message) -> Void)?
    var save: ((Message) -> Void)?
    var delete: (Message) -> Void = { _ in }
    var select: (Message) -> Void = { _ in }
}

/// An album (website 66-albums.css): 2 side by side (4:5), 3 = one wide (2:1) + two, 4+ = 2×2 with "+N" on the last;
/// one time, on the last square shown.
struct AlbumGrid: View {
    let token: String
    let photos: [Message]
    let mine: Bool
    let state: Bubble.Delivery?
    var me = ""
    var actions = AlbumTileActions()
    let onOpen: (String) -> Void

    /// As wide as a single photo (MediaDims.maxWidth) plus the 3 pt bubble edge on each side.
    private var width: CGFloat { MediaDims.maxWidth + 6 }

    var body: some View {
        let gap: CGFloat = 3
        let w = width - gap * 2
        let col = (w - gap) / 2
        let n = photos.count
        let shown = Array(photos.prefix(Albums.shown))
        VStack(spacing: gap) {
            if n == 2 {
                HStack(spacing: gap) {
                    tile(shown[0], col, col * 5 / 4, 0)
                    tile(shown[1], col, col * 5 / 4, 1)
                }
            } else if n == 3 {
                tile(shown[0], w, w / 2, 0)
                HStack(spacing: gap) {
                    tile(shown[1], col, col, 1)
                    tile(shown[2], col, col, 2)
                }
            } else {
                HStack(spacing: gap) {
                    tile(shown[0], col, col, 0)
                    tile(shown[1], col, col, 1)
                }
                HStack(spacing: gap) {
                    tile(shown[2], col, col, 2)
                    tile(shown[3], col, col, 3)
                }
            }
        }
        .padding(gap)
        .tfBubble(mine: mine)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// Each photo stays its own message: press and hold one for its menu (MessageMenu.swift).
    private func tile(_ m: Message, _ w: CGFloat, _ h: CGFloat, _ k: Int) -> some View {
        tileBody(m, w, h, k)
            .modifier(MessageMenuTrigger(enabled: true, menu: { tileMenu(m, w, h, k) }, fallback: { tileFallbackMenu(m) }))
    }

    private func tileMenu(_ m: Message, _ w: CGFloat, _ h: CGFloat, _ k: Int) -> MessageMenuContent {
        var items = [MessageMenuItem("chat.reply", systemImage: "arrowshape.turn.up.left") { actions.reply(m) }]
        if let f = actions.forward { items.append(MessageMenuItem("chat.forward", systemImage: "arrowshape.turn.up.right") { f(m) }) }
        if let s = actions.save { items.append(MessageMenuItem("chat.save.as", systemImage: "arrow.down.to.line") { s(m) }) }
        items.append(MessageMenuItem("chat.select", systemImage: "checkmark") { actions.select(m) })
        items.append(MessageMenuItem("chat.delete", systemImage: "trash", destructive: true) { actions.delete(m) })
        // "+" opens the host's own emoji picker (moreReactions nil)
        return MessageMenuContent(active: Set(m.reactionList(me: me).filter(\.mine).map(\.emoji)),
                                  onReact: { e in actions.react(m, e) },
                                  items: items, preview: AnyView(tileBody(m, w, h, k)), mine: mine)
    }

    /// The system context menu, used only when the screen has no menu host (`.messageMenuHost()`).
    @ViewBuilder private func tileFallbackMenu(_ m: Message) -> some View {
        ControlGroup {
            ForEach(MessageMenuStyle.quickEmoji, id: \.self) { e in Button(e) { actions.react(m, e) } }
        }
        .tfReactionRow()
        Button { actions.reply(m) } label: { Label("chat.reply", systemImage: "arrowshape.turn.up.left") }
        if let f = actions.forward { Button { f(m) } label: { Label("chat.forward", systemImage: "arrowshape.turn.up.right") } }
        if let s = actions.save { Button { s(m) } label: { Label("chat.save.as", systemImage: "square.and.arrow.down") } }
        Button { actions.select(m) } label: { Label("chat.select", systemImage: "checkmark.circle") }
        Divider()
        Button(role: .destructive) { actions.delete(m) } label: { Label("chat.delete", systemImage: "trash") }
    }

    private func tileBody(_ m: Message, _ w: CGFloat, _ h: CGFloat, _ k: Int) -> some View {
        let last = k == min(photos.count, Albums.shown) - 1
        return ZStack {
            RemoteImage(token: token, fileID: m.file_id ?? "")
                .frame(width: w, height: h)
                .clipped()
            if k == Albums.shown - 1 && photos.count > Albums.shown {
                Color.black.opacity(0.48)
                Text("+\(photos.count - Albums.shown)").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: w, height: h)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if last { MediaTimeChip(date: photos.last?.date, state: state).padding(6) }
        }
        .overlay(alignment: .bottomLeading) {
            // this photo's own reactions
            let rs = m.reactionList(me: me)
            if !rs.isEmpty {
                HStack(spacing: 3) {
                    ForEach(rs, id: \.emoji) { r in
                        Text(r.count > 1 ? "\(r.emoji) \(r.count)" : r.emoji).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.hex(r.mine ? 0x0F3A45 : 0x0D2A35), in: Capsule())
                            .overlay(Capsule().stroke(Theme.soul, lineWidth: 1.5))
                            .onTapGesture { actions.react(m, r.emoji) }
                    }
                }
                .padding(5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let f = m.file_id { onOpen(f) } }
    }
}

/// "N unread messages" (website unreadMark.ts): the line before the first of the last N messages from others.
enum UnreadMark {
    static func startID(_ list: [Message], unread: Int, me: String) -> String? {
        guard unread > 0, !list.isEmpty else { return nil }
        var seen = 0
        for m in list.reversed() where m.sender_id != me {
            seen += 1
            if seen == unread { return m.id }
        }
        return list.first?.id
    }
}

struct UnreadDivider: View {
    let count: Int
    var body: some View {
        Text(count == 1 ? NSLocalizedString("chat.unread.one", comment: "") : String(format: NSLocalizedString("chat.unread.n", comment: ""), count))
            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(Theme.soulCard.opacity(0.92), in: Capsule())
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(Theme.soul.opacity(0.55)).frame(height: 26))
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Swipe a message to the right to reply (website useSwipeToReply.ts): it follows the finger up to 72 pt, a reply arrow
/// fades in, and past 56 pt letting go replies (with a light tap).
struct SwipeToReply: ViewModifier {
    let enabled: Bool
    let onReply: () -> Void
    /// The finger's pull. A gesture state, so it springs back to 0 by itself even when the drag is cancelled (the list
    /// took over the touch to scroll, a call came in): a plain state stayed where it was and left the bubble shifted.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.25, dampingFraction: 0.8)))
    private var dx: CGFloat = 0
    @State private var fired = false

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .overlay(alignment: .leading) {
                if dx > 4 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32).background(Theme.card.opacity(0.9), in: Circle())
                        .opacity(Double(min(1, dx / 56)))
                        .scaleEffect(dx >= 56 ? 1.1 : 0.85)
                        .offset(x: dx - 40)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .updating($dx) { v, state, _ in state = Self.pull(v) }
                .onChanged { v in
                    if Self.pull(v) >= 56 && !fired {
                        fired = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .onEnded { v in
                    if Self.pull(v) >= 56 { onReply() }
                    fired = false
                }, including: enabled ? .all : .subviews)
            .onChange(of: dx) { d in if d == 0 { fired = false } } // a cancelled pull arms the tap again
    }

    /// How far the bubble follows: only a rightward, mostly sideways move (a scroll never pulls it).
    private static func pull(_ v: DragGesture.Value) -> CGFloat {
        let x = v.translation.width, y = v.translation.height
        guard x > 0, abs(x) > abs(y) * 1.6 else { return 0 }
        return min(72, x * 0.8)
    }
}


/// The unread count on a chat or group row (website 27-chats-list .unread-badge, 9ba9f40): 22 pt, #00c6c4 with dark
/// #002327 figures, 12.5 pt; grey when the chat is muted.
struct UnreadBadge: View {
    let count: Int
    let muted: Bool

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 12.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(muted ? Theme.hex(0x0B1F26) : Theme.hex(0x002327))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(muted ? AnyShapeStyle(Theme.faint) : AnyShapeStyle(Theme.hex(0x00C6C4)), in: Capsule())
            .accessibilityLabel(Text(String(format: NSLocalizedString("chat.unread.n", comment: ""), count)))
    }
}


extension View {
    /// The quick reactions of a long-press menu as one horizontal row of emoji (WhatsApp), where iOS allows it.
    @ViewBuilder func tfReactionRow() -> some View {
        if #available(iOS 17.0, *) { self.controlGroupStyle(.palette) }
        else if #available(iOS 16.4, *) { self.controlGroupStyle(.compactMenu) }
        else { self }
    }
}
