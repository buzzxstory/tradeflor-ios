import SwiftUI
import UIKit
import ImageIO

// Stickers on screen (IOS-STICKER-001/002/004/005/006/007/012): the sticker in a chat, the Stickers side of the emoji panel,
// a pack, and the short confirmations.

/// One sticker picture: the still at once (downsampled, off the main thread, from the protected cache), the animation only
/// when it may play, the emoji in the same box when it cannot be loaded. The box comes from w/h before anything loads.
struct StickerPicture: View {
    let token: String
    let account: String
    let id: String
    var animated = false
    var w = 512
    var h = 512
    var emoji: String?
    /// the longest side, in points
    var side: CGFloat = 150
    /// the keyboard grid: still frames only
    var stillOnly = false

    @State private var still: UIImage?
    @State private var failed = false
    @State private var animation: Data?
    @State private var visible = false
    @State private var playing = false
    @State private var tapped = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var box: CGSize { StickerRef.box(w: w, h: h, side: side) }

    private var animate: Bool {
        animated && !stillOnly && animation != nil
            && StickerMotion.shouldAnimate(visible: visible, appActive: scenePhase == .active, reduceMotion: reduceMotion,
                                           lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, tapped: tapped)
    }

    var body: some View {
        ZStack {
            if let still, !(animate && playing) {
                Image(uiImage: still).resizable().interpolation(.high).scaledToFit()
            } else if failed {
                Text(verbatim: emoji ?? "🙂").font(.system(size: box.height * 0.5))
            } else if still == nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.dyn(0xFFFFFF, 0x0F2533, 0.05, 0.05))
            }
            if animate, let animation {
                AnimatedSticker(data: animation, playing: $playing)
            }
        }
        .frame(width: box.width, height: box.height)
        .contentShape(Rectangle())
        .onAppear { visible = true }
        .onDisappear { visible = false; playing = false }
        .onChange(of: animate) { on in if !on { playing = false } }
        .task(id: id) { await load() }
        .simultaneousGesture(TapGesture().onEnded {
            // Reduce Motion or Low Power: a still sticker plays when tapped
            if animated && !stillOnly && !tapped && (reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled) { tapped = true }
        })
    }

    private func load() async {
        let scale = UIScreen.main.scale
        let px = Int(max(box.width, box.height) * scale)
        if let img = await StickerCache.shared.still(token: token, account: account, id: id, animated: animated, maxPixel: px) {
            still = img
        } else {
            failed = true
        }
        guard animated, !stillOnly else { return }
        // the animation starts only once the whole file is here: never a broken frame
        if let d = await StickerCache.shared.data(token: token, account: account, id: id, still: false) { animation = d }
    }
}

/// An animated WebP played by ImageIO (CGAnimateImageDataWithBlock): frames are decoded as they are shown, so a long
/// sticker never holds all its frames in memory. It stops when the view goes (off screen, app in the background).
private struct AnimatedSticker: UIViewRepresentable {
    let data: Data
    @Binding var playing: Bool

    final class Coordinator {
        var stopped = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.backgroundColor = .clear
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let c = context.coordinator
        let playing = $playing
        var first = true
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak v] _, image, stop in
            if c.stopped || v == nil { stop.pointee = true; return }
            v?.image = UIImage(cgImage: image)
            if first {
                first = false
                DispatchQueue.main.async { if !c.stopped { playing.wrappedValue = true } }
            }
        }
        if status != noErr { c.stopped = true } // cannot be decoded: the still stays
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.stopped = true
        uiView.image = nil
    }
}

/// A sticker message: no bubble, the sticker in its own shape (longest side 150 pt), the time and ticks on a small dark pill.
struct StickerBubble: View {
    let token: String
    let account: String
    let ref: StickerRef
    let mine: Bool
    let date: Date?
    var state: Bubble.Delivery?
    var senderName: String?

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            StickerPicture(token: token, account: account, id: ref.stickerId, animated: ref.animated, w: ref.w, h: ref.h, emoji: ref.emoji)
            HStack(spacing: 3) {
                if let date { Text(date, style: .time) }
                if let state { Bubble.tickView(state) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.black.opacity(0.45), in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(ref, sender: senderName, date: date)))
        .accessibilityAddTraits(.isButton)
    }

    /// "Sticker, 😀, from Sam, 10:42"
    static func spoken(_ ref: StickerRef, sender: String?, date: Date?) -> String {
        var parts = [NSLocalizedString("stk.sticker", comment: "")]
        if let e = ref.emoji { parts.append(e) }
        if let sender, !sender.isEmpty { parts.append(String(format: NSLocalizedString("stk.from", comment: ""), sender)) }
        if let date { parts.append(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)) }
        return parts.joined(separator: ", ")
    }
}

/// A sticker being sent: the picture dimmed with the sending (or Not sent) mark.
struct PendingStickerBubble: View {
    let token: String
    let account: String
    let ref: StickerRef
    let date: Date
    let failed: Bool

    var body: some View {
        StickerBubble(token: token, account: account, ref: ref, mine: true, date: date, state: failed ? .failed : .sending)
            .opacity(failed ? 0.6 : 0.85)
    }
}

/// A pack to open (View pack).
struct StickerPackRef: Identifiable { let id: String }

// MARK: the short line over the chat

struct StickerToastView: View {
    @ObservedObject var store = StickerStore.shared

    var body: some View {
        if let t = store.toast {
            HStack(spacing: 12) {
                Text(verbatim: t.text).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                if let undo = t.undo {
                    Button {
                        store.toast = nil
                        undo()
                    } label: {
                        Text("stk.undo").font(.subheadline.weight(.bold)).foregroundStyle(Theme.hex(0x3CF0EE))
                            .frame(minWidth: 44, minHeight: 36)
                    }
                    .accessibilityLabel(Text("stk.undo"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.hex(0x062A33, 0.96), in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear { UIAccessibility.post(notification: .announcement, argument: t.text) }
            .id(t.id)
        }
    }
}

// MARK: Emoji | Stickers

/// The emoji button's panel with the switch at the top: Emoji | Stickers (the side used last is remembered). Without
/// stickers (off on this server) it is the emoji panel as before.
struct EmojiStickerPanel: View {
    let token: String
    let account: String
    var bodyHeight: CGFloat = 300
    let onEmoji: (String) -> Void
    let onSticker: (Sticker, String?) -> Void
    let onCreate: () -> Void
    let onViewPack: (String) -> Void
    let onClose: () -> Void
    @ObservedObject private var store = StickerStore.shared
    @AppStorage("tf.stickers.side") private var side = "emoji"

    var body: some View {
        VStack(spacing: 6) {
            if store.enabled {
                HStack(spacing: 0) {
                    switchButton("emoji", "stk.side.emoji")
                    switchButton("stickers", "stk.side.stickers")
                }
                .padding(3)
                .background(Theme.dyn(0x0B2833, 0xFFFFFF), in: Capsule())
                .overlay(Capsule().stroke(Theme.dyn(0x00D4DF, 0xA6E3E7, 0.18, 1), lineWidth: 1))
                .frame(maxWidth: 260)
            }
            if store.enabled && side == "stickers" {
                StickerPanel(token: token, account: account, bodyHeight: bodyHeight, onSend: onSticker, onCreate: onCreate,
                             onViewPack: onViewPack, onClose: onClose)
            } else {
                EmojiPanel(bodyHeight: bodyHeight, onPick: onEmoji, onClose: onClose)
            }
        }
    }

    private func switchButton(_ value: String, _ key: String) -> some View {
        let on = (store.enabled ? side : "emoji") == value
        return Button { side = value } label: {
            Text(LocalizedStringKey(key)).font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(on ? Theme.onAccent : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(on ? Theme.accent : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The Stickers side: ＋ Create, Favorites, Recent, My stickers, one tab per added pack, Explore. A tap sends (the panel stays
/// open); a long-press opens the small menu. Still frames only; the pictures load as their cells appear.
struct StickerPanel: View {
    let token: String
    let account: String
    var bodyHeight: CGFloat = 300
    let onSend: (Sticker, String?) -> Void
    let onCreate: () -> Void
    let onViewPack: (String) -> Void
    let onClose: () -> Void
    @ObservedObject private var store = StickerStore.shared
    @AppStorage("tf.stickers.tab") private var tab = ""
    @State private var explore: [StickerPack]?
    @State private var exploreFailed = false
    @State private var deleting: Sticker?
    @State private var editingPack: StickerPack?
    @State private var newPack = false

    /// The tab to show: the one used last while it still exists; the first time, the first one with stickers in it.
    static func chooseTab(remembered: String, library: StickerLibrary) -> String {
        let packTabs = library.packs.map { "pack:" + $0.id }
        let valid = ["favorites", "recent", "mine", "explore"] + packTabs
        if !remembered.isEmpty, valid.contains(remembered) { return remembered }
        if !library.favorites.isEmpty { return "favorites" }
        if !library.recent.isEmpty { return "recent" }
        if !library.mine.isEmpty { return "mine" }
        if let p = library.packs.first(where: { !($0.stickers ?? []).isEmpty }) { return "pack:" + p.id }
        return "favorites"
    }

    private var current: String { Self.chooseTab(remembered: tab, library: store.library) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                headerAction
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("chat.close"))
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 2)
            content.frame(height: bodyHeight)
            tabBar
        }
        .background(LinearGradient(colors: [Theme.dyn(0x0B2833, 0xFFFFFF), Theme.dyn(0x071F28, 0xF8FCFD)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.dyn(0x00D4DF, 0xA6E3E7, 0.18, 1), lineWidth: 1))
        .shadow(color: Theme.dyn(0x000000, 0x0B5E68, 0.55, 0.18), radius: 22, y: 18)
        .onAppear { store.reloadSoon() } // each time the keyboard opens
        .confirmationDialog(Text("stk.mine.delete.q"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("stk.mine.delete", role: .destructive) { if let s = deleting { store.deleteMine(s) } }
        } message: { Text("stk.mine.delete.msg") }
        .sheet(item: $editingPack) { p in StickerPackEditor(token: token, account: account, pack: p).tfColorScheme() }
        .sheet(isPresented: $newPack) { StickerPackEditor(token: token, account: account, pack: nil).tfColorScheme() }
    }

    private var title: String {
        switch current {
        case "favorites": return "stk.tab.favorites"
        case "recent": return "stk.tab.recent"
        case "mine": return "stk.tab.mine"
        case "explore": return "stk.tab.explore"
        default:
            let id = String(current.dropFirst(5))
            return store.library.packs.first { $0.id == id }?.name ?? ""
        }
    }

    @ViewBuilder private var headerAction: some View {
        switch current {
        case "recent" where !store.library.recent.isEmpty:
            Button("stk.recent.clear") { store.clearRecent() }.font(.system(size: 13, weight: .semibold)).frame(minHeight: 32)
        case "mine" where !store.library.mine.isEmpty:
            Button("stk.pack.new") { newPack = true }.font(.system(size: 13, weight: .semibold)).frame(minHeight: 32)
        default:
            if current.hasPrefix("pack:"), let p = store.library.packs.first(where: { "pack:" + $0.id == current }) {
                if p.mine {
                    Button("stk.pack.edit") { editingPack = p }.font(.system(size: 13, weight: .semibold)).frame(minHeight: 32)
                } else {
                    Button("stk.pack.remove") { tab = "favorites"; store.setPackInstalled(p, false) }
                        .font(.system(size: 13, weight: .semibold)).frame(minHeight: 32)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !store.loaded && store.loadFailed {
            VStack(spacing: 10) {
                Text("stk.load.failed").font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("stk.retry") { Task { await store.reload() } }.font(.callout.weight(.semibold))
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !store.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch current {
            case "favorites": grid(store.library.favorites, empty: "stk.empty.favorites", where: "favorites")
            case "recent": grid(store.library.recent, empty: "stk.empty.recent", where: "recent")
            case "mine":
                if store.library.mine.isEmpty {
                    VStack(spacing: 12) {
                        Text("stk.empty.mine").font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                        Button(action: onCreate) {
                            Label("stk.create", systemImage: "plus").font(.callout.weight(.semibold)).padding(.horizontal, 16)
                                .frame(minHeight: 44).background(Theme.accent, in: Capsule()).foregroundStyle(Theme.onAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    grid(store.library.mine, empty: "", where: "mine")
                }
            case "explore": exploreList
            default:
                let p = store.library.packs.first { "pack:" + $0.id == current }
                grid(p?.stickers ?? [], empty: "stk.pack.empty", where: "pack", packID: p?.id)
            }
        }
    }

    private func grid(_ list: [Sticker], empty: String, where place: String, packID: String? = nil) -> some View {
        Group {
            if list.isEmpty {
                Text(LocalizedStringKey(empty)).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(list) { s in cell(s, place: place, packID: packID) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func cell(_ s: Sticker, place: String, packID: String?) -> some View {
        let fav = store.isFavorite(s.id)
        return Button {
            guard !s.deleted else { store.show(NSLocalizedString("stk.err.410", comment: "")); return }
            store.used(s)
            onSend(s, packID)
        } label: {
            StickerPicture(token: token, account: account, id: s.id, animated: s.animated, w: s.w, h: s.h, emoji: s.emoji,
                           side: 66, stillOnly: true)
                .frame(maxWidth: .infinity, minHeight: 72)
                .opacity(s.deleted ? 0.4 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(StickerKeyStyle())
        .contextMenu {
            if fav {
                Button { store.setFavorite(s, false) } label: { Label("stk.fav.remove", systemImage: "star.slash") }
            } else if !s.deleted {
                Button { store.setFavorite(s, true) } label: { Label("stk.fav.add", systemImage: "star") }
            }
            if place == "mine" {
                Button(role: .destructive) { deleting = s } label: { Label("stk.mine.delete", systemImage: "trash") }
            }
        }
        .accessibilityLabel(Text(verbatim: NSLocalizedString("stk.sticker", comment: "") + (s.emoji.map { " " + $0 } ?? "")
                                 + (fav ? ", " + NSLocalizedString("stk.in.favorites", comment: "") : "")))
        .accessibilityHint(Text("stk.tap.send"))
        .accessibilityAction(named: Text(LocalizedStringKey(fav ? "stk.fav.remove" : "stk.fav.add"))) { store.setFavorite(s, !fav) }
    }

    @ViewBuilder private var exploreList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("stk.explore.note").font(.footnote).foregroundStyle(Theme.muted)
                if let explore {
                    if explore.isEmpty {
                        Text("stk.explore.none").font(.footnote).foregroundStyle(Theme.faint)
                    }
                    ForEach(explore) { p in
                        let added = store.library.packs.contains { $0.id == p.id }
                        HStack(spacing: 10) {
                            Button { onViewPack(p.id) } label: {
                                HStack(spacing: 10) {
                                    if let cover = p.coverId ?? p.stickers?.first?.id {
                                        StickerPicture(token: token, account: account, id: cover, side: 40, stillOnly: true)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: p.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                        Text(verbatim: String(format: NSLocalizedString("stk.pack.count", comment: ""), p.count))
                                            .font(.caption).foregroundStyle(Theme.faint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button(LocalizedStringKey(added ? "stk.pack.remove" : "stk.pack.add")) { store.setPackInstalled(p, !added) }
                                .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                        }
                    }
                } else if exploreFailed {
                    Button("stk.retry") { Task { await loadExplore() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Button {
                    StickerCache.shared.clearAll()
                    store.show(NSLocalizedString("stk.cache.cleared", comment: ""))
                } label: {
                    Label("stk.cache.clear", systemImage: "trash").font(.footnote.weight(.semibold)).frame(minHeight: 44)
                }
                .padding(.top, 6)
            }
            .padding(14)
        }
        .task { await loadExplore() }
    }

    private func loadExplore() async {
        exploreFailed = false
        do { explore = try await APIClient.shared.stickerExplore(token: token) } catch { if explore == nil { exploreFailed = true } }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button(action: onCreate) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.onAccent)
                        .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
                        .frame(minWidth: 44, minHeight: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("stk.create"))
                tabButton("favorites", icon: "star.fill", label: "stk.tab.favorites")
                tabButton("recent", icon: "clock", label: "stk.tab.recent")
                tabButton("mine", icon: "person.crop.square", label: "stk.tab.mine")
                ForEach(store.library.packs) { p in
                    let key = "pack:" + p.id
                    Button { tab = key } label: {
                        Group {
                            if let cover = p.coverId ?? p.stickers?.first?.id {
                                StickerPicture(token: token, account: account, id: cover, side: 26, stillOnly: true)
                            } else {
                                Image(systemName: "square.stack").font(.system(size: 17))
                            }
                        }
                        .frame(minWidth: 44, minHeight: 40)
                        .background(current == key ? Theme.dyn(0x00D4DF, 0x0097A5, 0.16, 0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: p.name))
                    .accessibilityAddTraits(current == key ? [.isSelected] : [])
                }
                tabButton("explore", icon: "safari", label: "stk.tab.explore")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(Theme.dyn(0x071E27, 0xF3FAFB))
        .overlay(alignment: .top) { Rectangle().fill(Theme.dyn(0xFFFFFF, 0xC4EEF1, 0.06, 1)).frame(height: 1) }
    }

    private func tabButton(_ key: String, icon: String, label: String) -> some View {
        let on = current == key
        return Button { tab = key } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Theme.faint)
                .frame(minWidth: 44, minHeight: 40)
                .background(on ? Theme.dyn(0x00D4DF, 0x0097A5, 0.16, 0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

private struct StickerKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.dyn(0x00D4DF, 0x0097A5, 0.12, 0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: a pack

/// View pack: the name, how many, the stickers. Looking adds nothing; Add pack is one tap. A tap on a sticker sends it (in
/// a chat); a long-press saves just that one.
struct StickerPackSheet: View {
    let token: String
    let account: String
    let packID: String
    var onSend: ((Sticker, String?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StickerStore.shared
    @State private var pack: StickerPack?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let pack {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(pack.stickers ?? []) { s in
                                let fav = store.isFavorite(s.id)
                                Button {
                                    guard let onSend, !s.deleted else { return }
                                    store.used(s)
                                    onSend(s, pack.id)
                                    dismiss()
                                } label: {
                                    StickerPicture(token: token, account: account, id: s.id, animated: s.animated, w: s.w, h: s.h,
                                                   emoji: s.emoji, side: 72, stillOnly: true)
                                        .frame(maxWidth: .infinity, minHeight: 80)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if fav {
                                        Button { store.setFavorite(s, false) } label: { Label("stk.fav.remove", systemImage: "star.slash") }
                                    } else if !s.deleted {
                                        Button { store.setFavorite(s, true) } label: { Label("stk.fav.add", systemImage: "star") }
                                    }
                                }
                                .accessibilityLabel(Text(verbatim: NSLocalizedString("stk.sticker", comment: "") + (s.emoji.map { " " + $0 } ?? "")))
                            }
                        }
                        .padding(16)
                    }
                    .safeAreaInset(edge: .bottom) { addBar(pack) }
                } else if let error {
                    Text(verbatim: error).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(30)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.soul.ignoresSafeArea())
            .navigationTitle(Text(verbatim: pack?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } }
                if let pack {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text(verbatim: pack.name).font(.headline)
                            Text(verbatim: String(format: NSLocalizedString("stk.pack.count", comment: ""), pack.count)).font(.caption).foregroundStyle(Theme.faint)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func addBar(_ p: StickerPack) -> some View {
        let added = store.library.packs.contains { $0.id == p.id }
        return Group {
            if !p.mine {
                Button {
                    store.setPackInstalled(p, !added)
                } label: {
                    Text(LocalizedStringKey(added ? "stk.pack.remove" : "stk.pack.add")).font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(added ? Theme.card : Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(added ? Theme.text : Theme.onAccent)
                }
                .buttonStyle(.plain)
                .padding(16)
                .background(Theme.soul)
            }
        }
    }

    private func load() async {
        do {
            pack = try await APIClient.shared.stickerPack(token: token, id: packID)
        } catch let e as StickerHTTPError {
            error = e.status == 404 ? NSLocalizedString("stk.pack.404", comment: "") : e.message
        } catch {
            self.error = NSLocalizedString("stk.err.other", comment: "")
        }
    }
}

/// New pack / Edit pack: a name, who can open it, and which of my own stickers are in it. Delete pack asks once.
struct StickerPackEditor: View {
    let token: String
    let account: String
    let pack: StickerPack?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StickerStore.shared
    @State private var name = ""
    @State private var shared = true
    @State private var chosen: [String] = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("stk.pack.name", comment: ""), text: $name)
                    Picker("stk.pack.who", selection: $shared) {
                        Text("stk.pack.onlyme").tag(false)
                        Text("stk.pack.anyone").tag(true)
                    }
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(store.library.mine.filter { !$0.deleted }) { s in
                            let on = chosen.contains(s.id)
                            Button {
                                if on { chosen.removeAll { $0 == s.id } } else if chosen.count < 120 { chosen.append(s.id) }
                            } label: {
                                StickerPicture(token: token, account: account, id: s.id, animated: s.animated, w: s.w, h: s.h, side: 60, stillOnly: true)
                                    .frame(maxWidth: .infinity, minHeight: 66)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(on ? Theme.accent : Theme.faint).font(.system(size: 18))
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                            .accessibilityLabel(Text(verbatim: NSLocalizedString("stk.sticker", comment: "") + (s.emoji.map { " " + $0 } ?? "")))
                        }
                    }
                } header: { Text("stk.pack.choose") }
                if let error { Text(verbatim: error).foregroundStyle(Theme.danger) }
                if pack != nil {
                    Button("stk.pack.delete", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(Text(LocalizedStringKey(pack == nil ? "stk.pack.new" : "stk.pack.edit")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("notes.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("notes.save") { Task { await save() } }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
                }
            }
            .confirmationDialog(Text("stk.pack.delete.q"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("stk.pack.delete", role: .destructive) { Task { await deletePack() } }
            } message: { Text("stk.pack.delete.msg") }
        }
        .onAppear {
            name = pack?.name ?? ""
            shared = (pack?.visibility ?? "shared") != "private"
            chosen = pack?.stickers?.map(\.id) ?? []
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(64))
        do {
            if let pack {
                _ = try await APIClient.shared.stickerPackUpdate(token: token, id: pack.id, name: n, visibility: shared ? "shared" : "private", ids: chosen)
            } else {
                _ = try await APIClient.shared.stickerPackCreate(token: token, name: n, visibility: shared ? "shared" : "private", ids: chosen)
            }
            await store.reload()
            dismiss()
        } catch {
            self.error = (error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: "")
        }
    }

    private func deletePack() async {
        guard let pack else { return }
        do {
            try await APIClient.shared.stickerPackDelete(token: token, id: pack.id)
            await store.reload()
            dismiss()
        } catch {
            self.error = (error as? StickerHTTPError)?.message ?? NSLocalizedString("stk.err.other", comment: "")
        }
    }
}
