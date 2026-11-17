import SwiftUI
import UIKit

/// The website's design tokens (desktop/src/styles/01-tokens.css), one palette everywhere.
enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }

    /// A colour with the night value (01-tokens.css) and the day value (21-light.css); it follows the app's colour scheme.
    static func ui(_ night: UInt32, _ day: UInt32, _ na: CGFloat = 1, _ da: CGFloat = 1) -> UIColor {
        func make(_ v: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }
        let n = make(night, na), d = make(day, da)
        return UIColor { $0.userInterfaceStyle == .light ? d : n }
    }
    static func dyn(_ night: UInt32, _ day: UInt32, _ na: CGFloat = 1, _ da: CGFloat = 1) -> Color { Color(uiColor: ui(night, day, na, da)) }

    // grounds
    static let ground = dyn(0x00131B, 0xEEF3F7)          // --bg-app
    static let panel = dyn(0x00161F, 0xF3F7FA)           // --bg-panel / --surface
    static let header = dyn(0x001119, 0xF6F9FC)          // --tf-bg-header
    static let card = dyn(0x08222D, 0xFFFFFF)            // --bg-card / --raised
    static let surface = dyn(0x0D252F, 0xFFFFFF)         // --bg-input
    static let bubbleIn = dyn(0x112C38, 0xFFFFFF)        // --bg-bubble
    static let chip = dyn(0x011F2B, 0xE8F0F5)            // --bg-chip
    static let active = dyn(0x023446, 0xDFF2F5)          // --bg-active

    // one colour soul (website --tf-unified-surface and friends, night mode; day keeps its own grounds)
    static let soul = dyn(0x01141B, 0xF6F9FC)            // header, message bar, lists, poll/signal panels, Group Info
    static let soulInput = dyn(0x05151D, 0xFFFFFF)       // --tf-input-bg
    static let soulRule = dyn(0x103541, 0xD3E1EA)        // groups list separators
    static let soulCard = dyn(0x041D26, 0xFFFFFF)        // Group Info cards
    static let soulCardBorder = dyn(0x78BED2, 0xD3E1EA, 0.12, 1)
    static let soulBubbleOut = hex(0x062A33)
    static let soulBubbleIn = hex(0x041D26)

    // lines
    static let border = dyn(0x288CAF, 0x1E5A78, 0.22, 0.14)         // --border-c
    static let borderStrong = dyn(0x124C64, 0xD3E1EA)               // --border-strong-c
    static let borderActive = dyn(0x02CFDA, 0x0097A5, 0.75, 0.55)
    static let rowRule = dyn(0x3C8CAA, 0x1E5A78, 0.16, 0.10)

    // text
    static let text = dyn(0xF2F7FA, 0x0F2533)
    static let muted = dyn(0xCFDBE2, 0x3C5668)
    static let faint = dyn(0xA9B9C5, 0x5F7686)

    // brand
    static let accent = dyn(0x00D4DF, 0x0097A5)
    static let onAccent = dyn(0x052B3A, 0xFFFFFF)
    static let gold = dyn(0xEFBE33, 0xB98700)
    static let online = dyn(0x00CC83, 0x00A86C)
    static let verified = hex(0x127DD6)
    static let wordmark = dyn(0x00C5E3, 0x0093C4)
    static let danger = dyn(0xF0525B, 0xD8404A)
    static let buy = dyn(0x14C27A, 0x0C9A5F)

    // gradients
    static let panelGradient = LinearGradient(colors: [dyn(0x00161F, 0xF6F9FC), dyn(0x00141C, 0xF1F6F9), dyn(0x001018, 0xEEF4F8)], startPoint: .top, endPoint: .bottom)
    static let inputGradient = LinearGradient(colors: [dyn(0x0A2C39, 0xFFFFFF), dyn(0x082835, 0xFFFFFF)], startPoint: .top, endPoint: .bottom)
    static let cardGradient = LinearGradient(colors: [dyn(0x082F3F, 0xFFFFFF, 0.92), dyn(0x042634, 0xFFFFFF, 0.92), dyn(0x032330, 0xFFFFFF, 0.92)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let selectedGradient = LinearGradient(colors: [dyn(0x023446, 0xE3F5F7), dyn(0x012B3E, 0xDDF2F5), dyn(0x022F42, 0xD9F0F4)], startPoint: .top, endPoint: .bottom)
    static let navActiveGradient = LinearGradient(colors: [dyn(0x014759, 0xDEF3F6), dyn(0x003F52, 0xD8F0F4), dyn(0x014A5C, 0xD2EDF2)], startPoint: .top, endPoint: .bottom)
    static let bubbleOut = LinearGradient(colors: [dyn(0x0A4756, 0xD5F2F5), dyn(0x0A3445, 0xC5EBF0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sendGradient = RadialGradient(colors: [hex(0x14D6E2), hex(0x04AEC4), hex(0x047D95)],
                                             center: UnitPoint(x: 0.4, y: 0.25), startRadius: 0, endRadius: 40)
    static let avatarGradient = RadialGradient(colors: [dyn(0x1B4C60, 0xE8F3F8), dyn(0x0E3342, 0xD6E7F0), dyn(0x0A2A36, 0xCFE2EC)],
                                               center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40)

    /// Native bars styled like the website's mobile tab bar and headers.
    static func applyAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = ui(0x00161F, 0xF3F7FA)
        tab.shadowColor = ui(0x288CAF, 0x1E5A78, 0.22, 0.14)
        for layout in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            layout.normal.iconColor = ui(0xA9B9C5, 0x5F7686)
            layout.normal.titleTextAttributes = [.foregroundColor: ui(0xA9B9C5, 0x5F7686), .font: UIFont.systemFont(ofSize: 10.5, weight: .medium)]
            layout.selected.iconColor = ui(0x00D4DF, 0x0097A5)
            layout.selected.titleTextAttributes = [.foregroundColor: ui(0x00D4DF, 0x0097A5), .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = ui(0x001119, 0xF6F9FC)
        nav.shadowColor = ui(0x124C64, 0xD3E1EA)
        nav.titleTextAttributes = [.foregroundColor: ui(0xF2F7FA, 0x0F2533)]
        nav.largeTitleTextAttributes = [.foregroundColor: ui(0xF2F7FA, 0x0F2533)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = ui(0x00D4DF, 0x0097A5)
    }
}

/// The faint star dust behind conversations and pages (the website's starfield).
struct Starfield: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 7)
            let count = Int(size.width * size.height / 9000)
            for _ in 0..<count {
                let x = rng.next() * size.width, y = rng.next() * size.height
                let r = 0.6 + rng.next() * 1.0
                let a = 0.15 + rng.next() * 0.35
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(Theme.dyn(0x8CD9F2, 0x5AA9C4, a, a * 0.35)))
            }
        }
        .background(
            LinearGradient(colors: [Theme.dyn(0x02242F, 0xF3F7FA), Theme.dyn(0x01161F, 0xEEF3F7), Theme.dyn(0x000F16, 0xE9F0F5)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 33) / Double(UInt64(1) << 31))
    }
}

/// "Trade" + "flor" (cyan), the website's wordmark, with the flower mark.
struct BrandWordmark: View {
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 6) {
            Image("BrandFlower").resizable().scaledToFit().frame(width: size * 1.25, height: size * 1.25)
            (Text("Trade").foregroundColor(Theme.text) + Text("flor").foregroundColor(Theme.wordmark))
                .font(.system(size: size, weight: .heavy))
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The 43 pt rounded-square header buttons (scan, add contact, settings gear...).
struct SquareIconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 43, height: 43)
                .background(Theme.inputGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The rounded search field of the lists ("Search chats").
struct SearchPill: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    /// the one-colour-soul field (#01141B, its cyan outline marks it), as the website's Groups list
    var soul = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint).font(.system(size: 16))
            TextField(placeholder, text: $text)
                .foregroundStyle(Theme.text)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
                        .frame(width: 32, height: 32).contentShape(Rectangle()) // a 16 pt glyph was hard to hit
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("cv3.clear"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 43)
        .background(soul ? AnyShapeStyle(Theme.soul) : AnyShapeStyle(Theme.inputGradient), in: Capsule())
        .overlay(Capsule().stroke(soul ? Theme.hex(0x00C8D7, 0.22) : Theme.borderStrong, lineWidth: 1))
    }
}

/// The filter pills ("All chats", "Unread", folders).
struct FilterChip: View {
    let title: String
    var icon: String? = nil
    var iconColor: Color = Theme.gold
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(selected ? Theme.onAccent : iconColor) }
                Text(title).font(.system(size: 12.5, weight: .bold))
            }
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(selected ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x0AA9B6), Theme.hex(0x06808F)], startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(Theme.chip), in: Capsule())
            .overlay(Capsule().stroke(selected ? Theme.borderActive : Theme.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A card section like the website's settings/info cards.
struct TFCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// One settings-style row: icon, title, optional subtitle, chevron.
struct TFRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = Theme.accent
    var trailing: String? = nil
    var showChevron = true
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.faint) }
            }
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.system(size: 13)).foregroundStyle(Theme.faint) }
            if showChevron { Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// Section label ("ACCOUNT", "ACTIVITY"...).
struct TFSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

/// Message bubble shape: 17 pt corners, the tail corner 4 pt (bottom-right for mine, bottom-left for theirs).
struct BubbleShape: Shape {
    let mine: Bool
    func path(in r: CGRect) -> Path {
        let big: CGFloat = 17, small: CGFloat = 4
        let tl = big, tr = big, br = mine ? small : big, bl = mine ? big : small
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

extension View {
    /// The website's .bubble.mine / .bubble.theirs: teal gradient with a cyan hairline, or slate with a soft border.
    func tfBubble(mine: Bool) -> some View { modifier(TFBubbleLook(mine: mine)) }
}

/// One colour soul (website 46-chat-themes.css --tf-bubble-*): in the default night chat (no theme picked) sent bubbles are solid
/// #062A33 with a cyan outline and received ones #041D26; day mode and chats with a theme keep the earlier look.
struct TFBubbleLook: ViewModifier {
    let mine: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.tfChatThemed) private var themed
    func body(content: Content) -> some View {
        if scheme == .dark && !themed {
            content
                .background(mine ? Theme.soulBubbleOut : Theme.soulBubbleIn, in: BubbleShape(mine: mine))
                .overlay(BubbleShape(mine: mine).stroke(mine ? Theme.hex(0x00CAD1, 0.45) : Theme.hex(0x78BED2, 0.14), lineWidth: 1))
        } else {
            content
                .background(mine ? AnyShapeStyle(Theme.bubbleOut) : AnyShapeStyle(Theme.bubbleIn), in: BubbleShape(mine: mine))
                .overlay(BubbleShape(mine: mine).stroke(mine ? Theme.hex(0x12D9E2, 0.36) : Theme.border, lineWidth: 1))
        }
    }
}

private struct TFChatThemedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// true inside a chat that has a user-picked theme (the soul colours then stay off).
    var tfChatThemed: Bool {
        get { self[TFChatThemedKey.self] }
        set { self[TFChatThemedKey.self] = newValue }
    }
}

/// Our screens draw their own headers (the website's look) and hide the system navigation bar, which also turns
/// off the edge swipe to go back. This keeps the swipe working whenever there is a screen to go back to.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}


/// Settings › Appearance › Night Mode (on by default, like the website): the colour scheme of the signed-in app.
struct TFColorScheme: ViewModifier {
    @AppStorage("tf.night") private var night = true
    func body(content: Content) -> some View { content.preferredColorScheme(night ? .dark : .light) }
}

extension View {
    func tfColorScheme() -> some View { modifier(TFColorScheme()) }
}
