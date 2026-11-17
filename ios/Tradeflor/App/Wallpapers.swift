import SwiftUI

// The TRADEFLOR wallpapers (website 62-wallpaper.css, 46-chat-themes.css), night mode only; day mode keeps its light grounds.

/// Behind the Chats screen: the Tradeflor_Wallpaper_Pack artwork with the website's two navy veils (the upper wave behind
/// "Chats" calmer, the middle behind the names a little quieter; the lower wave untouched). Still while the list scrolls.
struct ChatsWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                ZStack {
                    Theme.hex(0x001B24)
                    Image("ChatsWallpaper").resizable().scaledToFill()
                    LinearGradient(stops: [
                        .init(color: Theme.hex(0x001118, 0.44), location: 0),
                        .init(color: Theme.hex(0x001118, 0.36), location: 0.13),
                        .init(color: Theme.hex(0x001118, 0.14), location: 0.24),
                        .init(color: Theme.hex(0x001118, 0), location: 0.32),
                    ], startPoint: .top, endPoint: .bottom)
                    LinearGradient(stops: [
                        .init(color: Theme.hex(0x001118, 0), location: 0.24),
                        .init(color: Theme.hex(0x001118, 0.24), location: 0.38),
                        .init(color: Theme.hex(0x001118, 0.24), location: 0.64),
                        .init(color: Theme.hex(0x001118, 0), location: 0.76),
                    ], startPoint: .top, endPoint: .bottom)
                }
            } else {
                Theme.panelGradient
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Inside a chat with no theme picked ("TRADEFLOR"): the Responsive Chat Design Kit wallpaper, calm navy/teal with a cyan
/// wave at the top and one at the bottom.
struct ChatDefaultWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                // website: veil rgba(0,15,15,.6) over the pack's phone picture on #01141B, cover, centre-bottom, raised by the
                // message bar's height (--ct-lift 68px) so the wave sits just above the bar
                GeometryReader { geo in
                    ZStack {
                        Theme.hex(0x01141B)
                        Image("ChatWallpaper").resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .offset(y: -68)
                        Color(.sRGB, red: 0, green: 15 / 255, blue: 15 / 255, opacity: 0.6)
                    }
                }
            } else {
                Starfield()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Chats header buttons on phones: a dark glass disc with a cyan ring and cyan icon (website 63-chats-polish.css).
struct GlassIconButton: View {
    let systemName: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(scheme == .dark ? Theme.hex(0x8FF6F8) : Theme.accent)
                .frame(width: 44, height: 44)
                .background(
                    scheme == .dark
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x0E5C68, 0.62), Theme.hex(0x042C36, 0.72)],
                                                       startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1)))
                        : AnyShapeStyle(Color.white),
                    in: Circle())
                .overlay(Circle().stroke(scheme == .dark ? Theme.hex(0x40E2EC, 0.5) : Theme.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.08), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
    }
}

/// A soft fade where chips are hidden off the end of a horizontal strip (website: 56 px at the end).
struct EndFade: ViewModifier {
    @Environment(\.layoutDirection) private var dir
    func body(content: Content) -> some View {
        content.mask(
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                           startPoint: dir == .rightToLeft ? .trailing : .leading, endPoint: dir == .rightToLeft ? .leading : .trailing)
        )
    }
}
