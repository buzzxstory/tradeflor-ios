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
    static let moreSymbol = "chevron.down"
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
        // "+" in the reaction bar: the picker centred over the screen (web .emoji-picker.floating)
        .overlay {
            if let p = presenter.picker {
                EmojiFloating(single: true, onPick: { e in
                    presenter.picker = nil
                    p.onPick(e)
                }, onClose: { presenter.picker = nil })
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

    let barH: CGFloat = 60
    let rowH: CGFloat = 46
    let pad: CGFloat = 6

    var body: some View {
        let card = layout()
        ZStack(alignment: .topLeading) {
            backdrop
            menuCard
                .frame(width: card.width, height: card.height)
                .environment(\.layoutDirection, direction)
                .scaleEffect(shown ? 1 : 0.96, anchor: card.midY > space.size.height / 2 ? .bottom : .top)
                .opacity(shown ? 1 : 0)
                .position(x: card.midX, y: card.midY)
        }
        .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close(nil) }
    }

    /// .msg-menu-backdrop on phones: the chat dimmed; a tap anywhere outside the menu closes it.
    private var backdrop: some View {
        MessageMenuStyle.dim
            .opacity(shown ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { close(nil) }
            .accessibilityLabel(Text("chat.close"))
            .accessibilityAddTraits(.isButton)
    }

    /// The web phone menu: one card, the quick reactions in a row (and ⌄ for all emoji), a rule, then the actions.
    private var menuCard: some View {
        let c = request.content
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(c.reactions, id: \.self) { e in
                    Button { close { c.onReact(e) } } label: {
                        Text(e)
                            .font(.system(size: 25))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(c.active.contains(e) ? Theme.hex(0x00D4DF, 0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MenuEmojiButtonStyle())
                .accessibilityLabel(Text("chat.more.reactions"))
            }
            .padding(.horizontal, 8)
            .frame(height: barH)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(request.content.items) { item in
                    Button { close(item.action) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 16))
                                .foregroundStyle(item.destructive ? Theme.danger : Theme.text)
                                .frame(width: 22)
                            Text(item.title)
                                .font(.system(size: 16))
                                .foregroundStyle(item.destructive ? Theme.danger : Theme.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: rowH)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowButtonStyle(pressed: Theme.hex(0x163845), radius: 10))
                }
            }
            .padding(pad)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .shadow(color: MessageMenuStyle.shadow, radius: 22, y: 12)
    }

    /// Where the card goes: under the pressed message when it fits there, else over it, else as near as the screen allows;
    /// its side follows the bubble (mine on the trailing side), kept 12 pt inside the screen.
    private func layout() -> CGRect {
        let w = space.size.width
        let cardW = min(w - 24, 300)
        let itemsH = CGFloat(request.content.items.count) * rowH + pad * 2
        let cardH = min(barH + 1 + itemsH, space.bottom - space.top)
        let src = request.frame.map { $0.offsetBy(dx: -space.origin.x, dy: -space.origin.y) }
        let trailing = request.content.mine.map { $0 != (direction == .rightToLeft) } ?? ((src?.midX ?? w / 2) > w / 2)
        let gap: CGFloat = 8
        var y: CGFloat
        if let src {
            if src.maxY + gap + cardH <= space.bottom { y = src.maxY + gap }
            else if src.minY - gap - cardH >= space.top { y = src.minY - gap - cardH }
            else { y = space.bottom - cardH }   // a tall message: the card rests at the bottom, over it
        } else {
            y = (space.top + space.bottom - cardH) / 2
        }
        y = max(min(y, space.bottom - cardH), space.top)
        var x: CGFloat
        if let src { x = trailing ? src.maxX - cardW : src.minX } else { x = (w - cardW) / 2 }
        x = min(max(x, 12), w - 12 - cardW)
        return CGRect(x: x, y: y, width: cardW, height: cardH)
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
