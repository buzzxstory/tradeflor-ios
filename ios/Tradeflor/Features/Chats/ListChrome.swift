import SwiftUI
import UIKit

// The Chats and Groups lists on a phone, as the website draws them at ≤760 px (desktop/src/styles/27-chats-list.css,
// 63-chats-polish.css, 08-groups.css, 18-status.css, 53-admin.css): the TRADEFLOR brand bar, the big title, the round
// header buttons, the 52 pt search pill, the folder chips with their counts, the rows with the divider after the picture,
// and the Groups screen's ambient background. Night values are the website's; day values follow the app's day palette.

enum ListLook {
    // brand bar (.list-brand)
    static let brandInk = Theme.dyn(0xF4FBFC, 0x0F2533)

    // search (.sidebar-search, phones)
    static let searchFill = Theme.dyn(0x0B343E, 0xFFFFFF, 0.88, 1)
    static let searchBorder = Theme.dyn(0x26636C, 0xD3E1EA)
    static let searchInk = Theme.dyn(0xD7E8E9, 0x3C5668)
    static let searchPlaceholder = Theme.dyn(0xB8C8CB, 0x5F7686)

    // chips (.section-tab, .section-tab-new, .section-tab-badge)
    static let chipFill = Theme.dyn(0x041C25, 0xE8F0F5, 0.85, 1)
    static let chipBorder = Theme.dyn(0x28616C, 0xD3E1EA)
    static let chipInk = Theme.dyn(0xE6F1F2, 0x3C5668)
    static let newFolderFill = Theme.dyn(0x041C25, 0xE8F0F5, 0.95, 1)
    static let newFolderInk = Theme.dyn(0xD7E8E9, 0x3C5668)
    static let chipActive = LinearGradient(colors: [Theme.hex(0x08A8AD), Theme.hex(0x00565F)],
                                           startPoint: UnitPoint(x: 0.05, y: 0.2), endPoint: UnitPoint(x: 0.95, y: 0.8))
    static let chipActiveBorder = Theme.hex(0x09E5DF)
    static let chipCountFill = Theme.hex(0x007D87)
    static let chipCountInk = Theme.hex(0xEAFFFF)

    // rows (.conv-row on phones)
    static let rowRule = Theme.dyn(0x387C84, 0x1E5A78, 0.37, 0.12)
    static let rowTime = Theme.dyn(0xA5B6BC, 0x5F7686)
    static let rowPreview = Theme.dyn(0xA9B9BE, 0x3C5668)
    static let unreadTime = Theme.dyn(0x08D9D9, 0x0097A5)
    static let pin = Theme.dyn(0x08D9D9, 0x0097A5)
    static let mute = Theme.dyn(0xAABFC2, 0x5F7686)
    static let verified = Theme.hex(0x1DA1F2)
    static let ringSeen = Theme.dyn(0xA9B9C5, 0x5F7686, 0.35, 0.45)
    static let archivedRule = Theme.dyn(0x3C8CAA, 0x1E5A78, 0.16, 0.10)

    // the Groups header's square button (.sidebar-head-actions .icon-btn)
    static let squareFill = Theme.dyn(0x011F2B, 0xFFFFFF)
    static let squareBorder = Theme.dyn(0x5AA0BE, 0xD3E1EA, 0.22, 1)
    static let squareInk = Theme.dyn(0xC7D9E3, 0x3C5668)

    /// "Chats" / "Groups": clamp(32px, 9vw, 40px).
    static var titleSize: CGFloat { min(40, max(32, UIScreen.main.bounds.width * 0.09)) }

    /// A folder's colour (37-smart-folders.css .c-*); turquoise when none was picked.
    static func folderColor(_ c: String) -> Color {
        switch c {
        case "blue": return Theme.hex(0x4B9DFF)
        case "purple": return Theme.hex(0xA57BFF)
        case "orange": return Theme.hex(0xFF9F43)
        case "pink": return Theme.hex(0xFF5C8A)
        case "gold": return Theme.hex(0xE8B84A)
        default: return Theme.hex(0x08D9D9)
        }
    }
}

/// The brand bar above "Chats" on phones (ChatScreen.tsx .list-brand): the flower and TRADEFLOR, centred.
struct ListBrandBar: View {
    var body: some View {
        HStack(spacing: 9) {
            Image("BrandFlower").resizable().scaledToFit().frame(width: 30, height: 30)
            Text(verbatim: "TRADEFLOR")
                .font(.system(size: 18, weight: .heavy))
                .tracking(18 * 0.08)
                .foregroundStyle(ListLook.brandInk)
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .accessibilityHidden(true)
    }
}

/// The big list title (.sidebar-head .wordmark on phones: 800 weight, -0.035em).
struct ListTitle: View {
    let key: LocalizedStringKey
    var body: some View {
        Text(key)
            .font(.system(size: ListLook.titleSize, weight: .heavy))
            .tracking(-ListLook.titleSize * 0.035)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A light press (the website's :active scale .96).
struct ListPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// The round header buttons of the Chats list (63-chats-polish.css): a 44 pt dark glass disc, cyan ring, cyan glyph.
struct ListDiscButton<Glyph: View>: View {
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            glyph()
                .foregroundStyle(scheme == .dark ? Theme.hex(0x8FF6F8) : Theme.accent)
                .frame(width: 44, height: 44)
                .background(
                    scheme == .dark
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.hex(0x0E5C68, 0.62), Theme.hex(0x042C36, 0.72)],
                                                       startPoint: UnitPoint(x: 0.33, y: 0), endPoint: UnitPoint(x: 0.67, y: 1)))
                        : AnyShapeStyle(Color.white),
                    in: Circle())
                .overlay(Circle().stroke(scheme == .dark ? Theme.hex(0x40E2EC, 0.5) : Theme.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.08), radius: 5, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(ListPressStyle())
    }
}

/// The Groups header's 43 pt rounded-square button face (06-voice.css .sidebar-head-actions .icon-btn).
struct ListSquareFace<Glyph: View>: View {
    @ViewBuilder let glyph: () -> Glyph
    var body: some View {
        glyph()
            .foregroundStyle(ListLook.squareInk)
            .frame(width: 43, height: 43)
            .background(ListLook.squareFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ListLook.squareBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - glyphs (the website's inline SVGs, 24 x 24 grid)

private struct Grid24 {
    let s: CGFloat, ox: CGFloat, oy: CGFloat
    init(_ r: CGRect) {
        s = min(r.width, r.height) / 24
        ox = r.midX - 12 * s
        oy = r.midY - 12 * s
    }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: ox + (cx - r) * s, y: oy + (cy - r) * s, width: 2 * r * s, height: 2 * r * s)
    }
}

/// Scan QR (ChatScreen.tsx): four corners and a scan line.
struct ScanGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let g = Grid24(r)
        var p = Path()
        p.move(to: g.p(4, 8)); p.addLine(to: g.p(4, 5)); p.addQuadCurve(to: g.p(5, 4), control: g.p(4, 4)); p.addLine(to: g.p(8, 4))
        p.move(to: g.p(16, 4)); p.addLine(to: g.p(19, 4)); p.addQuadCurve(to: g.p(20, 5), control: g.p(20, 4)); p.addLine(to: g.p(20, 8))
        p.move(to: g.p(20, 16)); p.addLine(to: g.p(20, 19)); p.addQuadCurve(to: g.p(19, 20), control: g.p(20, 20)); p.addLine(to: g.p(16, 20))
        p.move(to: g.p(8, 20)); p.addLine(to: g.p(5, 20)); p.addQuadCurve(to: g.p(4, 19), control: g.p(4, 20)); p.addLine(to: g.p(4, 16))
        p.move(to: g.p(4, 12)); p.addLine(to: g.p(20, 12))
        return p
    }
}

/// Add contact (KitIcon "user-plus").
struct UserPlusGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let g = Grid24(r)
        var p = Path()
        p.addEllipse(in: g.circle(10, 7.5, 3.8))
        p.move(to: g.p(3, 20.5)); p.addLine(to: g.p(3, 19.7)); p.addQuadCurve(to: g.p(13.5, 13.6), control: g.p(4, 13.3))
        p.move(to: g.p(18, 14)); p.addLine(to: g.p(18, 21))
        p.move(to: g.p(14.5, 17.5)); p.addLine(to: g.p(21.5, 17.5))
        return p
    }
}

/// New group (GroupsView.tsx): a person, a second fainter head, and a plus.
struct GroupPlusGlyph: View {
    var body: some View {
        ZStack {
            GroupPlusMain().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            GroupPlusSecond().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).opacity(0.7)
        }
    }

    private struct GroupPlusMain: Shape {
        func path(in r: CGRect) -> Path {
            let g = Grid24(r)
            var p = Path()
            p.addEllipse(in: g.circle(8.5, 8, 3.2))
            p.move(to: g.p(2.5, 19.5)); p.addLine(to: g.p(2.5, 18.9)); p.addQuadCurve(to: g.p(12, 14), control: g.p(3.4, 13.4))
            p.move(to: g.p(18.5, 14)); p.addLine(to: g.p(18.5, 21))
            p.move(to: g.p(15, 17.5)); p.addLine(to: g.p(22, 17.5))
            return p
        }
    }

    private struct GroupPlusSecond: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addEllipse(in: Grid24(r).circle(15, 9, 2.6))
            return p
        }
    }
}

// MARK: - search

/// The round search field of the phone lists (27-chats-list.css .sidebar-search: 52 pt, 1 px #26636c, rgba(11,52,62,.88)).
struct ListSearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular))
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 15)).foregroundStyle(ListLook.searchPlaceholder).lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $text)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel(Text(placeholder))
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(ListLook.searchInk)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(ListLook.searchFill, in: Capsule())
        .overlay(Capsule().stroke(ListLook.searchBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }
}

// MARK: - chips

/// One folder chip (27-chats-list.css .section-tab: 36 pt pill; the active one turquoise; counts as a small circle or plain).
struct ListChip: View {
    let title: String
    var icon: String? = nil
    var iconColor: Color? = nil
    var count: Int = 0
    /// Archived / Locked / Blocked show their number as plain text, the folders and Unread in a small circle
    var plainCount = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.white : (iconColor ?? ListLook.chipInk))
                }
                Text(title).font(.system(size: 13.5, weight: selected ? .bold : .medium)).lineLimit(1)
                if count > 0 {
                    if plainCount {
                        Text(verbatim: "\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(selected ? ListLook.chipCountInk : Theme.faint)
                    } else {
                        Text(verbatim: "\(count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(selected ? Color.white : ListLook.chipCountInk)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(selected ? Color.black.opacity(0.25) : ListLook.chipCountFill, in: Capsule())
                    }
                }
            }
            .foregroundStyle(selected ? Color.white : ListLook.chipInk)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                if selected { Capsule().fill(ListLook.chipActive) } else { Capsule().fill(ListLook.chipFill) }
            }
            .overlay(Capsule().stroke(selected ? ListLook.chipActiveBorder : ListLook.chipBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "New folder" at the end of the chip row (.section-tab-new: a 36 pt circle).
struct ListNewFolderButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "folder.badge.plus").font(.system(size: 15, weight: .regular))
                .foregroundStyle(ListLook.newFolderInk)
                .frame(width: 36, height: 36)
                .background(ListLook.newFolderFill, in: Circle())
                .overlay(Circle().stroke(ListLook.chipBorder, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("folder.new"))
    }
}

/// The chip row (27-chats-list.css .chat-filter-bar): the chips scroll on their own; "new folder" follows the last chip,
/// or stays at the end of the row once the chips need to scroll (with the soft fade where they are cut).
struct ListChipBar<Chips: View>: View {
    var onNewFolder: (() -> Void)? = nil
    @ViewBuilder let chips: () -> Chips

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                HStack(spacing: 8) { chips() }.padding(.vertical, 2)
                newFolder
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { chips() }.padding(.vertical, 2)
                }
                .modifier(EndFade())
                newFolder
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var newFolder: some View {
        if let onNewFolder { ListNewFolderButton(action: onNewFolder) }
    }
}

// MARK: - rows

/// The hairline at the top of a row's text block, after the picture (.conv-main border-top on phones).
struct ListRowRule: View {
    var body: some View { Rectangle().fill(ListLook.rowRule).frame(height: 1) }
}

/// The status ring around a row's picture (18-status.css .avatar-status: 2.5 pt gap, a 2 pt ring, accent = new, grey = seen).
struct ListAvatarRing<Content: View>: View {
    let seen: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(2.5)
            .overlay(Circle().stroke(seen ? ListLook.ringSeen : Theme.accent, lineWidth: 2).padding(-1))
    }
}

/// The blue verified seal next to a name (VerifiedBadge.tsx, #1da1f2).
struct ListVerifiedSeal: View {
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size * 0.9))
            .foregroundStyle(ListLook.verified)
            .accessibilityLabel(Text("ux1.verified"))
    }
}

/// The pin / muted marks and the unread count on the right of a row's second line (27-chats-list.css .conv-meta).
struct ListRowMeta: View {
    var pinned = false
    var muted = false
    var mentions = 0
    var unreadCount = 0
    var markedUnread = false

    var body: some View {
        HStack(spacing: 6) {
            if pinned {
                Image(systemName: "pin").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ListLook.pin)
                    .rotationEffect(.degrees(45))
                    .frame(width: 17, height: 17)
                    .accessibilityLabel(Text("ux1.pinned"))
            }
            if muted {
                Image(systemName: "bell.slash").font(.system(size: 13.5, weight: .medium)).foregroundStyle(ListLook.mute)
                    .frame(width: 17, height: 17)
                    .accessibilityLabel(Text("ux1.muted"))
            }
            if mentions > 0 {
                // 08-groups.css .mention-badge: a yellow "@"
                Text(verbatim: "@").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.hex(0x3A2A00))
                    .frame(width: 19, height: 19)
                    .background(Theme.hex(0xFFD34D), in: Circle())
                    .overlay(Circle().stroke(Theme.hex(0xFFD34D, 0.18), lineWidth: 2).padding(-1))
                    .accessibilityLabel(Text(String(format: NSLocalizedString("grp.mentions.n", comment: ""), mentions)))
            }
            if unreadCount > 0 {
                UnreadBadge(count: unreadCount, muted: muted)
            } else if markedUnread {
                // "marked as unread": the badge with no number
                Circle().fill(muted ? Theme.faint : Theme.hex(0x00C6C4)).frame(width: 22, height: 22)
                    .accessibilityLabel(Text("chats.markunread"))
            }
        }
    }
}

/// An empty list's note (.conv-empty: 16 pt padding, 13 pt, faint).
struct ListEmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
    }
}

// MARK: - Groups background

/// The Groups list on phones (27-chats-list.css .sidebar: #00131b with public/brand/chat-kit/tradeflor-ambient.svg,
/// centre top, cover): a soft teal glow in the middle, a cyan arc in the top-left corner and one in the bottom-right.
struct ListAmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if scheme == .dark {
                Canvas { ctx, size in
                    // the artwork is 1440 x 2560, scaled to cover, centred horizontally, from the top
                    let s: CGFloat = max(size.width / 1440, size.height / 2560)
                    let ox: CGFloat = (size.width - 1440 * s) / 2

                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hex(0x00131B)))
                    // the radial ground: #073c47 in the middle to #00131b at the edges (an ellipse over the whole artwork)
                    var ground = ctx
                    ground.translateBy(x: ox + 720 * s, y: 1280 * s)
                    ground.scaleBy(x: 720.0 / 1280.0, y: 1)
                    let r: CGFloat = 1280 * s
                    ground.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)),
                                with: .radialGradient(Gradient(colors: [Theme.hex(0x073C47), Theme.hex(0x00131B)]),
                                                      center: .zero, startRadius: 0, endRadius: r))

                    // two cyan arcs, each a soft blurred band under a 3 px line, fading out towards the right
                    let arcs: [(cx: CGFloat, cy: CGFloat, radius: CGFloat, glow: CGFloat, glowOpacity: Double)] = [
                        (-250, -290, 750, 42, 0.32),
                        (1510, 2450, 570, 32, 0.3),
                    ]
                    for a in arcs {
                        let rr = a.radius * s
                        let rect = CGRect(x: ox + a.cx * s - rr, y: a.cy * s - rr, width: 2 * rr, height: 2 * rr)
                        let shading = GraphicsContext.Shading.linearGradient(
                            Gradient(colors: [Theme.hex(0x00F1ED), Theme.hex(0x00828E, 0)]),
                            startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY))
                        let glowWidth = a.glow * s, glowOpacity = a.glowOpacity
                        ctx.drawLayer { layer in
                            layer.opacity = glowOpacity
                            layer.addFilter(.blur(radius: 18 * s))
                            layer.stroke(Path(ellipseIn: rect), with: shading, lineWidth: glowWidth)
                        }
                        ctx.stroke(Path(ellipseIn: rect), with: shading, lineWidth: max(1, 3 * s))
                    }
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
