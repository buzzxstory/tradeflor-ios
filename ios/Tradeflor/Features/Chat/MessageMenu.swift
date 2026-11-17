import SwiftUI
import UIKit
import Combine

// The website's message menu (shared/components/MessageContextMenu.tsx, styles 09-message-actions.css), drawn the
// way phones show it (WhatsApp): press and hold a message, the chat dims and blurs (rgba(0,8,12,.42)), the message is
// lifted above it, the quick reactions float just over it (.msg-reaction-bar) and the actions sit under it
// (.msg-context-menu-list: --surface #00161f, 1 px --border, radius 14, deep shadow, red "danger" rows).
// Tapping outside closes it (.msg-menu-backdrop). It pops in like msg-menu-pop (.16 s, from 96 %).
//
// One host per conversation screen draws every menu above the whole screen: `.messageMenuHost()` on ChatView. It also
// draws the header "⋯" menu and the "+" attach menu (ChatMenus.swift). Without the host, rows fall back to the system
// context menu, so nothing breaks while it is not wired.

enum MessageMenuStyle {
    /// The quick reactions (MessageContextMenu.tsx QUICK_REACTIONS).
    static let quickEmoji = ["❤️", "🔥", "👏", "👍", "😂", "😮", "😡"]
    /// The last button of the reaction bar (the web draws a small chevron here: "chevron.down").
    static let moreSymbol = "plus"
    /// --tf shadow of the menus (0 20px 50px rgba(0,0,0,.5); light theme rgba(20,50,75,.13)).
    static let shadow = Theme.dyn(0x000000, 0x14324B, 0.5, 0.13)
    /// .msg-menu-backdrop on phones.
    static let dim = Theme.dyn(0x00080C, 0x0F2533, 0.42, 0.16)
}

// MARK: - What a menu shows

/// One row of the action card.
struct MessageMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    /// `key` is a Localizable.strings key.
    init(_ key: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) {
        id = key
        title = NSLocalizedString(key, comment: "")
        self.systemImage = systemImage
        self.destructive = destructive
        self.action = action
    }
}

/// Everything the long-press menu of one message (or one album photo) needs.
struct MessageMenuContent {
    var reactions: [String] = MessageMenuStyle.quickEmoji
    /// The reactions that are already mine (drawn on --accent-soft, like .msg-reaction-btn.active).
    var active: Set<String> = []
    var onReact: (String) -> Void
    /// "+": the caller's own picker; nil = the host opens the emoji picker itself and reacts with onReact.
    var moreReactions: (() -> Void)? = nil
    var items: [MessageMenuItem]
    /// The pressed message, drawn again (lifted) above the dimmed chat.
    var preview: AnyView? = nil
    /// My message (the menu lines up with the bubble's side); nil = whichever half of the screen it is on.
    var mine: Bool? = nil
}

struct MessageMenuRequest: Identifiable {
    let id = UUID()
    let content: MessageMenuContent
    /// Where the pressed message is, in window coordinates.
    let frame: CGRect?
}

struct ReactionPickerRequest: Identifiable {
    let id = UUID()
    let onPick: (String) -> Void
}

// MARK: - Presenter

/// Opens and closes the menus of one conversation screen. Owned by `.messageMenuHost()`.
@MainActor
final class MessageMenuPresenter: ObservableObject {
    @Published private(set) var message: MessageMenuRequest?
    @Published private(set) var list: ChatMenuRequest?
    /// false while the menu is popping in or fading out (drives the animations).
    @Published private(set) var shown = false
    /// The full emoji picker for "+" when the caller has none of its own.
    @Published var picker: ReactionPickerRequest?
    /// The top of the keyboard (screen coordinates) while it is up: menus stay above it.
    private(set) var keyboardTop: CGFloat?
    private var closing = false
    private var subs: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .sink { [weak self] n in
                guard let r = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                self?.keyboardTop = r.minY >= UIScreen.main.bounds.height - 1 ? nil : r.minY
            }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in self?.keyboardTop = nil }
            .store(in: &subs)
    }

    var isOpen: Bool { message != nil || list != nil }

    /// The long-press menu of a message.
    func present(_ content: MessageMenuContent, from frame: CGRect?) {
        guard prepare() else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        message = MessageMenuRequest(content: content, frame: frame)
        reveal()
    }

    /// The header "⋯" menu or the "+" attach menu.
    func present(_ request: ChatMenuRequest) {
        guard prepare() else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        list = request
        reveal()
    }

    /// Fades the open menu out, and runs `action` (the chosen item) at once.
    func close(then action: (() -> Void)? = nil) {
        guard isOpen, !closing else { action?(); return }
        closing = true
        let m = message?.id, l = list?.id
        if UIAccessibility.isReduceMotionEnabled {
            shown = false
        } else {
            withAnimation(.easeOut(duration: 0.14)) { shown = false }
        }
        action?()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, self.closing else { return }
            if self.message?.id == m { self.message = nil }
            if self.list?.id == l { self.list = nil }
            self.closing = false
        }
    }

    /// Opens the full emoji picker for a reaction (after the menu has gone).
    func pickReaction(_ onPick: @escaping (String) -> Void) {
        picker = ReactionPickerRequest(onPick: onPick)
    }

    /// false when a menu is already open; a menu that is fading out is dropped at once.
    private func prepare() -> Bool {
        if closing {
            message = nil
            list = nil
            closing = false
        }
        return !isOpen
    }

    private func reveal() {
        shown = false
        // one frame later, so the menu is first drawn closed and then pops open
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self, self.isOpen, !self.closing else { return }
            if UIAccessibility.isReduceMotionEnabled {
                self.shown = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self.shown = true }
            }
        }
    }
}

private struct MessageMenuPresenterKey: EnvironmentKey {
    static let defaultValue: MessageMenuPresenter? = nil
}

extension EnvironmentValues {
    /// The menu host of this conversation screen (nil = not wired: the system menus are used).
    var tfMessageMenu: MessageMenuPresenter? {
        get { self[MessageMenuPresenterKey.self] }
        set { self[MessageMenuPresenterKey.self] = newValue }
    }
}

extension View {
    /// Hosts the message menu, the header "⋯" menu and the "+" attach menu above this screen. Put it once on the
    /// conversation's outer view.
    func messageMenuHost() -> some View { modifier(MessageMenuHostModifier()) }
}

struct MessageMenuHostModifier: ViewModifier {
    @StateObject private var presenter = MessageMenuPresenter()

    func body(content: Content) -> some View {
        content
            .environment(\.tfMessageMenu, presenter)
            .overlay { MessageMenuHost(presenter: presenter) }
    }
}

// MARK: - Where things are on screen

/// Reads a view's place in its window (window coordinates, never mirrored, so the menus line up in Arabic too).
final class MenuFrameProbe {
    weak var view: UIView?

    var windowFrame: CGRect? {
        guard let v = view, let w = v.window else { return nil }
        return v.convert(v.bounds, to: w)
    }
}

struct MenuProbeView: UIViewRepresentable {
    let probe: MenuFrameProbe

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        probe.view = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { probe.view = uiView }
}

/// The room a menu may use, in the host's own coordinates.
struct MenuSpace {
    let size: CGSize
    /// The host's top-left corner in window coordinates.
    let origin: CGPoint
    /// Below the status bar / above the home indicator and the keyboard, 8 pt in.
    let top: CGFloat
    let bottom: CGFloat
}

// MARK: - Host

struct MessageMenuHost: View {
    @ObservedObject var presenter: MessageMenuPresenter
    @Environment(\.layoutDirection) private var direction
    @State private var probe = MenuFrameProbe()

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // a 1 pt probe in the top-left corner: where the host is in its window
                MenuProbeView(probe: probe).frame(width: 1, height: 1)
                if let m = presenter.message {
                    MessageMenuOverlay(request: m, space: space(geo.size), direction: direction, shown: presenter.shown,
                                       close: { presenter.close(then: $0) },
                                       pickMore: { onPick in presenter.pickReaction(onPick) })
                }
                if let l = presenter.list {
                    ChatMenuOverlay(request: l, space: space(geo.size), direction: direction, shown: presenter.shown,
                                    close: { presenter.close(then: $0) })
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // positions are physical (window) coordinates; each card puts the reading direction back for its own content
        .environment(\.layoutDirection, .leftToRight)
        .ignoresSafeArea()
        .allowsHitTesting(presenter.isOpen)
        .accessibilityHidden(!presenter.isOpen)
        .sheet(item: $presenter.picker) { p in
            EmojiPickerSheet(single: true) { e in
                presenter.picker = nil
                p.onPick(e)
            }
        }
    }

    private func space(_ size: CGSize) -> MenuSpace {
        let origin = probe.windowFrame?.origin ?? .zero
        let window = probe.view?.window
        let insets = window?.safeAreaInsets ?? .zero
        let windowHeight = window?.bounds.height ?? size.height
        let top = max(0, insets.top - origin.y) + 8
        var bottom = min(size.height, windowHeight - insets.bottom - origin.y) - 8
        if let kb = presenter.keyboardTop { bottom = min(bottom, kb - origin.y - 8) }
        return MenuSpace(size: size, origin: origin, top: top, bottom: max(bottom, top + 120))
    }
}

// MARK: - The message menu

struct MessageMenuOverlay: View {
    let request: MessageMenuRequest
    let space: MenuSpace
    let direction: LayoutDirection
    let shown: Bool
    let close: ((() -> Void)?) -> Void
    let pickMore: (@escaping (String) -> Void) -> Void

    let barH: CGFloat = 50
    let gap: CGFloat = 8
    let rowH: CGFloat = 44
    let pad: CGFloat = 6

    private struct Layout {
        var source: CGRect?
        var message: CGRect?
        var scale: CGFloat
        var bar: CGRect
        var card: CGRect
        var trailing: Bool
    }

    var body: some View {
        let l = layout()
        ZStack(alignment: .topLeading) {
            backdrop
            if let preview = request.content.preview, let src = l.source, let dst = l.message {
                preview
                    .frame(width: src.width, height: src.height)
                    .environment(\.layoutDirection, direction)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .scaleEffect(shown ? l.scale : 1)
                    .shadow(color: MessageMenuStyle.shadow.opacity(shown ? 0.8 : 0), radius: 18, y: 8)
                    .position(x: shown ? dst.midX : src.midX, y: shown ? dst.midY : src.midY)
            }
            reactionBar
                .frame(width: l.bar.width, height: l.bar.height)
                .environment(\.layoutDirection, direction)
                .scaleEffect(shown ? 1 : 0.6, anchor: l.trailing ? .bottomTrailing : .bottomLeading)
                .opacity(shown ? 1 : 0)
                .position(x: l.bar.midX, y: l.bar.midY)
            actionCard
                .frame(width: l.card.width, height: l.card.height)
                .environment(\.layoutDirection, direction)
                .scaleEffect(shown ? 1 : 0.96, anchor: l.trailing ? .topTrailing : .topLeading)
                .opacity(shown ? 1 : 0)
                .position(x: l.card.midX, y: l.card.midY)
        }
        .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close(nil) }
    }

    /// The dimmed, blurred chat; a tap anywhere outside the menu closes it.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            MessageMenuStyle.dim
        }
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { close(nil) }
        .accessibilityLabel(Text("chat.close"))
        .accessibilityAddTraits(.isButton)
    }

    /// .msg-reaction-bar: the quick reactions in one row, then "more".
    private var reactionBar: some View {
        let c = request.content
        return HStack(spacing: 2) {
            ForEach(c.reactions, id: \.self) { e in
                Button { close { c.onReact(e) } } label: {
                    Text(e)
                        .font(.system(size: 24))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(c.active.contains(e) ? Theme.active : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(MenuEmojiButtonStyle())
                .accessibilityLabel(Text(e))
                .accessibilityAddTraits(c.active.contains(e) ? .isSelected : [])
            }
            Button {
                if let more = c.moreReactions {
                    close(more)
                } else {
                    let react = c.onReact
                    close { pickMore(react) }
                }
            } label: {
                Image(systemName: MessageMenuStyle.moreSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
                    .background(Theme.card, in: Circle())
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MenuEmojiButtonStyle())
            .accessibilityLabel(Text("chat.more.reactions"))
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .shadow(color: MessageMenuStyle.shadow, radius: 22, y: 12)
    }

    /// .msg-context-menu-list: icon (muted) + label, "danger" rows in red.
    private var actionCard: some View {
        VStack(spacing: 0) {
            ForEach(request.content.items) { item in
                Button { close(item.action) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 16))
                            .foregroundStyle(item.destructive ? Theme.danger : Theme.muted)
                            .frame(width: 22)
                        Text(item.title)
                            .font(.system(size: 15))
                            .foregroundStyle(item.destructive ? Theme.danger : Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: rowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowButtonStyle(pressed: Theme.card, radius: 9))
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .shadow(color: MessageMenuStyle.shadow, radius: 22, y: 12)
    }

    /// The reactions just over the message, the actions just under it; when that does not fit, the three move up or
    /// down together (and a very tall message is drawn smaller), like WhatsApp.
    private func layout() -> Layout {
        let w = space.size.width
        let count = CGFloat(request.content.reactions.count + 1)
        let barW = min(w - 24, count * 38 + 12)
        let cardW = min(w - 24, 260)
        let cardH = CGFloat(request.content.items.count) * rowH + pad * 2
        let src = request.frame.map { $0.offsetBy(dx: -space.origin.x, dy: -space.origin.y) }
        // which edge the bubble hangs from: mine on the trailing side (the left in Arabic)
        let trailing = request.content.mine.map { $0 != (direction == .rightToLeft) } ?? ((src?.midX ?? w / 2) > w / 2)
        let top = space.top, bottom = space.bottom

        var showMessage = false
        var scale: CGFloat = 1
        var messageH: CGFloat = 0
        if let src, request.content.preview != nil, src.height > 0 {
            let room = bottom - top - barH - cardH - gap * 2
            if room >= 40 {
                showMessage = true
                scale = min(1, room / src.height)
                messageH = src.height * scale
            }
        }
        let blockH = barH + gap + (showMessage ? messageH + gap : 0) + cardH
        var y: CGFloat
        if let src { y = src.minY - gap - barH } else { y = (top + bottom - blockH) / 2 }
        y = max(min(y, bottom - blockH), top)

        func x(_ width: CGFloat) -> CGFloat {
            guard let src else { return (w - width) / 2 }
            let raw = trailing ? src.maxX - width : src.minX
            return min(max(raw, 12), w - 12 - width)
        }
        let bar = CGRect(x: x(barW), y: y, width: barW, height: barH)
        var cardY = y + barH + gap
        var message: CGRect?
        if showMessage, let src {
            let mw = src.width * scale
            message = CGRect(x: trailing ? src.maxX - mw : src.minX, y: cardY, width: mw, height: messageH)
            cardY += messageH + gap
        }
        let card = CGRect(x: x(cardW), y: cardY, width: cardW, height: cardH)
        return Layout(source: showMessage ? src : nil, message: message, scale: scale, bar: bar, card: card, trailing: trailing)
    }
}

/// .msg-reaction-btn:hover: a little bigger while pressed.
struct MenuEmojiButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.15 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A menu row: its hover colour while pressed.
struct MenuRowButtonStyle: ButtonStyle {
    let pressed: Color
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? pressed : Color.clear,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Opening it from a message

/// Press and hold → the menu. Without a host (not wired), the system context menu `fallback` is used instead.
struct MessageMenuTrigger<Fallback: View>: ViewModifier {
    let enabled: Bool
    let menu: () -> MessageMenuContent
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.tfMessageMenu) private var presenter
    @State private var probe = MenuFrameProbe()

    @ViewBuilder func body(content: Content) -> some View {
        if let presenter {
            content
                .background(MenuProbeView(probe: probe))
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
                    .onEnded { _ in openMenu(presenter) }, including: enabled ? .all : .subviews)
                .accessibilityAction(named: Text("chat.more")) { openMenu(presenter) }
        } else {
            content.contextMenu { if enabled { fallback() } }
        }
    }

    private func openMenu(_ presenter: MessageMenuPresenter) {
        guard enabled else { return }
        presenter.present(menu(), from: probe.windowFrame)
    }
}
