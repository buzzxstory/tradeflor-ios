import SwiftUI
import UIKit

/// The website's design tokens (desktop/src/styles/01-tokens.css), one palette everywhere.
enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: a)
    }

    // grounds
    static let ground = hex(0x00131B)          // --bg-app
    static let panel = hex(0x00161F)           // --bg-panel / --surface
    static let header = hex(0x001119)          // --tf-bg-header
    static let card = hex(0x08222D)            // --bg-card / --raised
    static let surface = hex(0x0D252F)         // --bg-input
    static let bubbleIn = hex(0x112C38)        // --bg-bubble
    static let chip = hex(0x011F2B)            // --bg-chip
    static let active = hex(0x023446)          // --bg-active

    // lines
    static let border = Color(.sRGB, red: 40 / 255, green: 140 / 255, blue: 175 / 255, opacity: 0.22)   // --border-c
    static let borderStrong = hex(0x124C64)                                                         // --border-strong-c
    static let borderActive = Color(.sRGB, red: 2 / 255, green: 207 / 255, blue: 218 / 255, opacity: 0.75)
    static let rowRule = Color(.sRGB, red: 60 / 255, green: 140 / 255, blue: 170 / 255, opacity: 0.16)

    // text
    static let text = hex(0xF2F7FA)
    static let muted = hex(0xCFDBE2)
    static let faint = hex(0xA9B9C5)

    // brand
    static let accent = hex(0x00D4DF)
    static let onAccent = hex(0x052B3A)
    static let gold = hex(0xEFBE33)
    static let online = hex(0x00CC83)
    static let verified = hex(0x127DD6)
    static let wordmark = hex(0x00C5E3)
    static let danger = hex(0xF0525B)
    static let buy = hex(0x14C27A)

    // gradients
    static let panelGradient = LinearGradient(colors: [hex(0x00161F), hex(0x00141C), hex(0x001018)], startPoint: .top, endPoint: .bottom)
    static let inputGradient = LinearGradient(colors: [hex(0x0A2C39), hex(0x082835)], startPoint: .top, endPoint: .bottom)
    static let cardGradient = LinearGradient(colors: [hex(0x082F3F, 0.92), hex(0x042634, 0.92), hex(0x032330, 0.92)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let selectedGradient = LinearGradient(colors: [hex(0x023446), hex(0x012B3E), hex(0x022F42)], startPoint: .top, endPoint: .bottom)
    static let navActiveGradient = LinearGradient(colors: [hex(0x014759), hex(0x003F52), hex(0x014A5C)], startPoint: .top, endPoint: .bottom)
    static let bubbleOut = LinearGradient(colors: [hex(0x0A4756), hex(0x0A3445)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sendGradient = RadialGradient(colors: [hex(0x14D6E2), hex(0x04AEC4), hex(0x047D95)],
                                             center: UnitPoint(x: 0.4, y: 0.25), startRadius: 0, endRadius: 40)
    static let avatarGradient = RadialGradient(colors: [hex(0x1B4C60), hex(0x0E3342), hex(0x0A2A36)],
                                               center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40)

    /// Native bars styled like the website's mobile tab bar and headers.
    static func applyAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(panel)
        tab.shadowColor = UIColor(border)
        for layout in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            layout.normal.iconColor = UIColor(faint)
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor(faint), .font: UIFont.systemFont(ofSize: 10.5, weight: .medium)]
            layout.selected.iconColor = UIColor(accent)
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor(accent), .font: UIFont.systemFont(ofSize: 10.5, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(header)
        nav.shadowColor = UIColor(borderStrong)
        nav.titleTextAttributes = [.foregroundColor: UIColor(text)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(accent)
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
                         with: .color(Color(.sRGB, red: 0.55, green: 0.85, blue: 0.95, opacity: a)))
            }
        }
        .background(
            LinearGradient(colors: [Theme.hex(0x02242F), Theme.hex(0x01161F), Theme.hex(0x000F16)],
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
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint).font(.system(size: 16))
            TextField(placeholder, text: $text)
                .foregroundStyle(Theme.text)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 43)
        .background(Theme.inputGradient, in: Capsule())
        .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
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
    func tfBubble(mine: Bool) -> some View {
        self
            .background(mine ? AnyShapeStyle(Theme.bubbleOut) : AnyShapeStyle(Theme.bubbleIn), in: BubbleShape(mine: mine))
            .overlay(BubbleShape(mine: mine).stroke(mine ? Theme.hex(0x12D9E2, 0.36) : Theme.border, lineWidth: 1))
    }
}
