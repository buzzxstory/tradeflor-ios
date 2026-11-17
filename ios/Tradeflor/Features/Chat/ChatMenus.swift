import SwiftUI

// The website's two conversation menus, drawn by the screen's menu host (`.messageMenuHost()`, MessageMenu.swift):
//
// - the header "⋯" menu (.more-menu, styles 08-groups.css): a 220 px card 6 px under the button, its right edge on the
//   button's: --bg-card, 1 px --border-strong-c, radius 12, padding 6, rows 9/10 px with radius 8, icons muted,
//   "danger" rows red, shadow 0 10px 30px rgba(0,0,0,.4).
// - the composer's "+" attach menu (.attach-menu, styles 50-activity.css): a card 8 px over the button, left edge on
//   the composer's: radius 18, padding 6, 1 px rgba(81,226,233,.35), a deep teal gradient, rows 46 px high with a
//   34 px coloured square icon (photo turquoise, document blue, location green); it rises in (tfp-rise, .18 s).
//
// Both open over a lightly dimmed screen; a tap outside closes them. Without the host they fall back to a system Menu
// with the same items.

/// One row of a conversation menu.
struct ChatMenuItem: Identifiable {
    /// The coloured square of an attach-menu row (.attach-menu-ic).
    enum Tint {
        case photo, document, location, note, poll, signal, schedule, plain

        var colors: [Color] {
            switch self {
            case .photo: return [Theme.hex(0x3CF0EE), Theme.hex(0x08B6C0)]      // web .photo
            case .document: return [Theme.hex(0x8FB3FF), Theme.hex(0x4F7CF0)]   // web .file
            case .location: return [Theme.hex(0x5FF0A8), Theme.hex(0x19B56C)]   // web .loc
            // the app-only entries share one quiet teal tile: no colours the web menu does not have
            case .note, .poll, .signal, .schedule: return [Theme.hex(0x7FE3E8), Theme.hex(0x2A9DA8)]
            case .plain: return [Theme.hex(0x9FB3BF), Theme.hex(0x5F7686)]
            }
        }
    }

    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    var destructive = false
    var tint: Tint?
    let action: () -> Void

    /// `key` is a Localizable.strings key.
    init(_ key: String, systemImage: String, destructive: Bool = false, tint: Tint? = nil, subtitle: String? = nil,
         action: @escaping () -> Void) {
        self.init(verbatim: NSLocalizedString(key, comment: ""), id: key, systemImage: systemImage,
                  destructive: destructive, tint: tint, subtitle: subtitle, action: action)
    }

    /// A title that is already localized (e.g. "Block %@" filled in).
    init(verbatim title: String, id: String, systemImage: String, destructive: Bool = false, tint: Tint? = nil,
         subtitle: String? = nil, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.destructive = destructive
        self.tint = tint
        self.action = action
    }
}

enum ChatMenuStyle {
    /// The header "⋯" menu: opens under the button.
    case header
    /// The "+" attach menu: opens over the button.
    case attach
}

struct ChatMenuRequest: Identifiable {
    let id = UUID()
    let style: ChatMenuStyle
    let items: [ChatMenuItem]
    /// The button, in window coordinates.
    let anchor: CGRect?
}

// MARK: - Drop-in buttons

/// The header "⋯" button and its menu.
struct ChatHeaderMenu<ButtonLabel: View>: View {
    let items: [ChatMenuItem]
    @ViewBuilder let label: () -> ButtonLabel

    var body: some View { ChatMenuButton(style: .header, items: items, label: label) }
}

/// The composer's "+" button and its attach menu.
struct ChatAttachMenu<ButtonLabel: View>: View {
    let items: [ChatMenuItem]
    @ViewBuilder let label: () -> ButtonLabel

    var body: some View { ChatMenuButton(style: .attach, items: items, label: label) }
}

struct ChatMenuButton<ButtonLabel: View>: View {
    let style: ChatMenuStyle
    let items: [ChatMenuItem]
    @ViewBuilder let label: () -> ButtonLabel
    @Environment(\.tfMessageMenu) private var presenter
    @State private var probe = MenuFrameProbe()

    var body: some View {
        if let presenter {
            Button {
                presenter.present(ChatMenuRequest(style: style, items: items, anchor: probe.windowFrame))
            } label: {
                label().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MenuProbeView(probe: probe))
        } else {
            Menu {
                ForEach(items) { item in
                    Button(role: item.destructive ? .destructive : nil) { item.action() } label: {
                        SwiftUI.Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                label()
            }
        }
    }
}

// MARK: - The card

struct ChatMenuOverlay: View {
    let request: ChatMenuRequest
    let space: MenuSpace
    let direction: LayoutDirection
    let shown: Bool
    let close: ((() -> Void)?) -> Void

    private var header: Bool { request.style == .header }
    private var pad: CGFloat { 6 }
    private var spacing: CGFloat { header ? 1 : 0 }
    private var cardW: CGFloat { min(space.size.width - 16, header ? 240 : 236) }

    private func rowHeight(_ item: ChatMenuItem) -> CGFloat {
        header ? (item.subtitle == nil ? 42 : 50) : 46
    }

    private var cardH: CGFloat {
        let rows = request.items.reduce(CGFloat(0)) { $0 + rowHeight($1) }
        return rows + spacing * CGFloat(max(0, request.items.count - 1)) + pad * 2
    }

    var body: some View {
        let f = placement()
        ZStack(alignment: .topLeading) {
            MessageMenuStyle.dim
                .opacity(shown ? (header ? 0.45 : 0.6) : 0)
                .contentShape(Rectangle())
                .onTapGesture { close(nil) }
                .accessibilityLabel(Text("chat.close"))
                .accessibilityAddTraits(.isButton)
            card
                .frame(width: f.rect.width, height: f.rect.height)
                .environment(\.layoutDirection, direction)
                .scaleEffect(shown ? 1 : (header ? 0.92 : 0.98), anchor: f.anchor)
                .offset(y: shown || header ? 0 : (f.above ? 10 : -10))
                .opacity(shown ? 1 : 0)
                .position(x: f.rect.midX, y: f.rect.midY)
        }
        .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close(nil) }
    }

    @ViewBuilder private var card: some View {
        if header {
            VStack(spacing: spacing) { ForEach(request.items) { row($0) } }
                .padding(pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
                .shadow(color: Theme.dyn(0x000000, 0x14324B, 0.4, 0.13), radius: 15, y: 10)
        } else {
            VStack(spacing: spacing) { ForEach(request.items) { row($0) } }
                .padding(pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(LinearGradient(colors: [Theme.dyn(0x04303C, 0xFFFFFF, 0.98, 1), Theme.dyn(0x01161F, 0xF3F7FA, 0.99, 1)],
                                           startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.dyn(0x51E2E9, 0x0097A5, 0.35, 0.28), lineWidth: 1))
                .shadow(color: Theme.dyn(0x000000, 0x14324B, 0.45, 0.14), radius: 20, y: 16)
        }
    }

    private func row(_ item: ChatMenuItem) -> some View {
        Button { close(item.action) } label: {
            HStack(spacing: header ? 10 : 12) {
                icon(item)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 15))
                        .foregroundStyle(item.destructive ? Theme.danger : (header ? Theme.text : Theme.dyn(0xF2FBFF, 0x0F2533)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if let s = item.subtitle {
                        Text(s).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight(item))
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle(pressed: header ? Theme.active : Theme.hex(0x00C9D3, 0.1), radius: header ? 8 : 12))
    }

    @ViewBuilder private func icon(_ item: ChatMenuItem) -> some View {
        if !header {
            Image(systemName: item.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.hex(0x032029))
                .frame(width: 34, height: 34)
                .background(LinearGradient(colors: (item.tint ?? .plain).colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(item.destructive ? Theme.danger : Theme.muted)
                .frame(width: 22)
        }
    }

    private struct Placement {
        var rect: CGRect
        var above: Bool
        var anchor: UnitPoint
    }

    /// Header: under the button, the card's outer edge on the button's. Attach: over the button. Either flips when
    /// there is no room, and stays 8 pt inside the screen.
    private func placement() -> Placement {
        let w = space.size.width
        let fallback = CGRect(x: header ? w - 46 : 10, y: header ? space.top : space.bottom - 44, width: 36, height: 44)
        let a = request.anchor.map { $0.offsetBy(dx: -space.origin.x, dy: -space.origin.y) } ?? fallback
        let trailing = a.midX > w / 2
        var x = trailing ? a.maxX - cardW : a.minX
        x = min(max(x, 8), w - 8 - cardW)
        let below = a.maxY + 6
        let over = a.minY - 8 - cardH
        var above = !header
        if above && over < space.top { above = false }
        if !above && below + cardH > space.bottom && over >= space.top { above = true }
        var y = above ? over : below
        y = max(min(y, space.bottom - cardH), space.top)
        let anchor: UnitPoint = above ? (trailing ? .bottomTrailing : .bottomLeading) : (trailing ? .topTrailing : .topLeading)
        return Placement(rect: CGRect(x: x, y: y, width: cardW, height: cardH), above: above, anchor: anchor)
    }
}
