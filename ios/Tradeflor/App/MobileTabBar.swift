import SwiftUI
import Combine

// The phone tab bar of the web app (App.tsx MobileTabBar; styles 27-chats-list.css, 51-tradeflor.css): a floating,
// rounded dock (radius 30, #28636c edge, rgba(4,37,47,.97), deep shadow), the open section in a turquoise pill, and
// TradeFlor in the middle as a raised orb with its own ring. Hidden inside a conversation and while the keyboard is up,
// as on the web (one region at a time; html.kb-open).

/// When the dock steps aside: a conversation is open, or the keyboard is up.
@MainActor
final class TabChrome: ObservableObject {
    static let shared = TabChrome()
    @Published private(set) var conversations = 0
    @Published private(set) var keyboard = false
    private var subs: Set<AnyCancellable> = []

    var hidden: Bool { conversations > 0 || keyboard }

    /// A screenshot taken while no keyboard was up: iOS gives the last text field its focus back when the screenshot
    /// preview goes, and the keyboard would pop up by itself. Within a few seconds of the shot it is sent away again.
    private var shotAt: Date?
    private var keyboardAtShot = false

    private init() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if let t = self.shotAt, Date().timeIntervalSince(t) < 6, !self.keyboardAtShot {
                    self.shotAt = nil
                    DispatchQueue.main.async { Self.dismissKeyboard() }
                    return
                }
                // written only when it changes: this fires on every keyboard frame change (predictions, emoji), and each
                // write redrew the root view and the dock
                if !self.keyboard { self.keyboard = true }
            }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in if self?.keyboard == true { self?.keyboard = false } }.store(in: &subs)
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.shotAt = Date()
                self.keyboardAtShot = self.keyboard
            }.store(in: &subs)
    }

    /// Sends the keyboard away (whatever field has it).
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func conversationOpened() { conversations += 1 }
    func conversationClosed() { conversations = max(0, conversations - 1) }
}

struct MobileTabBar: View {
    @Binding var tab: String
    var chatsBadge = 0
    var groupsBadge = 0

    var body: some View {
        HStack(spacing: 2) {
            item("chats", "bubble.left", "chats.title", chatsBadge)
            item("groups", "person.2", "groups.title", groupsBadge)
            orb
            item("calendar", "calendar", "calendar.title", 0)
            item("settings", "gearshape", "settings.title", 0)
        }
        .padding(6)
        .background(Theme.hex(0x04252F, 0.97), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.hex(0x28636C), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 15, y: 10)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private func item(_ id: String, _ icon: String, _ key: String, _ badge: Int) -> some View {
        let on = tab == id
        return Button { if tab != id { tab = id } } label: {
            VStack(spacing: 4) {
                Image(systemName: on && icon != "calendar" ? icon + ".fill" : icon).font(.system(size: 19, weight: .medium))
                    .foregroundStyle(on ? Theme.hex(0x08D9D9) : Theme.hex(0xE7F2F4))
                    .frame(height: 22)
                Text(LocalizedStringKey(key)).font(.system(size: 10.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .white : Theme.hex(0xE7F2F4)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.hex(0x00646F), Theme.hex(0x052D36)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hex(0x00AAB1), lineWidth: 1))
                }
            }
            .overlay(alignment: .top) {
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.hex(0x00181B))
                        .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                        .background(Theme.hex(0x00D7CE), in: Capsule())
                        .offset(x: 14, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(key)))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// TradeFlor: the raised orb (58 pt, conic ring #3cf0ee → #08b6c0 → #f3c95c), its label in the gradient.
    private var orb: some View {
        let on = tab == "tradeflor"
        return Button { if tab != "tradeflor" { tab = "tradeflor" } } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(AngularGradient(colors: [Theme.hex(0x3CF0EE), Theme.hex(0x08B6C0), Theme.hex(0xF3C95C), Theme.hex(0x3CF0EE)],
                                                  center: .center, startAngle: .degrees(200), endAngle: .degrees(560)))
                    Circle().fill(RadialGradient(colors: [Theme.hex(0x123C47), Theme.hex(0x04151C)], center: UnitPoint(x: 0.35, y: 0.3),
                                                 startRadius: 0, endRadius: 30))
                        .padding(3)
                    Image("BrandFlower").resizable().scaledToFit().frame(width: 36, height: 36)
                        .shadow(color: Theme.hex(0x3CF0EE, 0.45), radius: 6)
                }
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.5), radius: 11, y: 8)
                .shadow(color: Theme.hex(0x3CF0EE, on ? 0.6 : 0.3), radius: on ? 13 : 10)
                .offset(y: -22)
                .padding(.bottom, -22)
                Text("TradeFlor").font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(LinearGradient(colors: [Theme.hex(0x3CF0EE), Theme.hex(0xF3C95C)], startPoint: .leading, endPoint: .trailing))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("TradeFlor"))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}


/// Room at the bottom of a tab for the floating dock: its real height (52 pt items + 6 pt padding each side + 4 pt
/// above and below) plus the TradeFlor orb's lift, above the home indicator's safe area. None in a conversation or
/// with the keyboard up (the dock steps aside then).
struct DockSpace: ViewModifier {
    @ObservedObject private var chrome = TabChrome.shared
    static let height: CGFloat = 52 + 12 + 8 + 6

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: chrome.hidden ? 0 : Self.height).allowsHitTesting(false)
        }
    }
}
