import SwiftUI

/// The website's chat themes (desktop/src/features/chats/chatThemes.ts + styles/46-chat-themes.css). Only you see your
/// theme; it is saved in the chat's preferences (ChatTheme).
enum ChatThemeStyle {
    struct Item: Identifiable {
        let id: String
        let name: String
        let base: UInt32
        let glow: [UInt32]
        let outA: UInt32
        let outB: UInt32
        let accent: UInt32
    }

    static let all: [Item] = [
        Item(id: "logo", name: "Tradeflor Bloom", base: 0x030F17, glow: [0x1C6C93, 0xF2C75C], outA: 0x1C6C93, outB: 0x1D4A9C, accent: 0xF2C75C),
        Item(id: "", name: "TRADEFLOR", base: 0x00131B, glow: [0x02242F, 0x000F16], outA: 0x0A4756, outB: 0x0A3445, accent: 0x00D4DF),
        Item(id: "ocean", name: "Tidal Glow", base: 0x021520, glow: [0x0C8298, 0x7FF6FF], outA: 0x0C8298, outB: 0x075B70, accent: 0x8FFBFF),
        Item(id: "market", name: "Market Pulse", base: 0x030D14, glow: [0x0B8277, 0x5FF3E0], outA: 0x0B8277, outB: 0x075F63, accent: 0x7FF6FF),
        Item(id: "ember", name: "Horizon", base: 0x020C14, glow: [0x0C7FA3, 0x0F5AA0], outA: 0x0C7FA3, outB: 0x0F5AA0, accent: 0x9FFBFF),
        Item(id: "aurora", name: "Aurora", base: 0x050816, glow: [0x6152E0, 0x3B63D2], outA: 0x6152E0, outB: 0x3B63D2, accent: 0xB9C6FF),
        Item(id: "gold", name: "Golden Orbit", base: 0x040F18, glow: [0x8D6C1F, 0xF3D078], outA: 0x8D6C1F, outB: 0x5F4712, accent: 0xF6D98A),
        Item(id: "emerald", name: "Emerald Silk", base: 0x021210, glow: [0x0D7F58, 0x6EF5C0], outA: 0x0D7F58, outB: 0x07665F, accent: 0x7DF7C8),
        Item(id: "midnight", name: "Constellation", base: 0x04070F, glow: [0x2C5FD0, 0x8CB4FF], outA: 0x2C5FD0, outB: 0x1C3B94, accent: 0xA9C6FF),
        Item(id: "rose", name: "Violet Dusk", base: 0x0A0714, glow: [0xB9458B, 0x7449C8], outA: 0xB9458B, outB: 0x7449C8, accent: 0xFFB3DC),
        Item(id: "graphite", name: "Carbon", base: 0x0A0D11, glow: [0x24424F, 0x5FE8F2], outA: 0x24424F, outB: 0x18303B, accent: 0x5FE8F2),
    ]

    static func item(_ id: String) -> Item { all.first { $0.id == id } ?? all[1] }

    /// The conversation background for a theme id ("" = the default starfield).
    static func background(_ id: String) -> AnyView {
        if id.isEmpty || id == "tradeflor" { return AnyView(ChatDefaultWallpaper()) }
        let t = item(id)
        return AnyView(
            ZStack {
                Theme.hex(t.base)
                RadialGradient(colors: [Theme.hex(t.glow[0], 0.55), .clear], center: UnitPoint(x: 0.2, y: 0.9), startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Theme.hex(t.glow[1], 0.28), .clear], center: UnitPoint(x: 0.85, y: 0.15), startRadius: 0, endRadius: 360)
                if id == "logo" {
                    Image("BrandFlower").resizable().scaledToFit().frame(width: 220).opacity(0.10)
                }
                if id == "midnight" || id == "aurora" { Starfield().opacity(0.8).blendMode(.screen) }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    /// My bubble's gradient for a theme.
    static func outGradient(_ id: String) -> LinearGradient {
        let t = item(id)
        return LinearGradient(colors: [Theme.hex(t.outA), Theme.hex(t.outB)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum ChatThemeStore {
    /// The theme saved for a chat (GET /prefs → conversations[].chat_theme), "" when none.
    static func load(token: String, conversationID: String) async -> String {
        struct P: Decodable { let conversation_id: String; let chat_theme: String? }
        struct Out: Decodable { let conversations: [P]? }
        guard let data = try? await APIClient.shared.getJSON("prefs", token: token),
              let out = try? JSONDecoder().decode(Out.self, from: data) else { return "" }
        return out.conversations?.first { $0.conversation_id == conversationID }?.chat_theme ?? ""
    }
}

/// Theme picker: a preview of a sample conversation on top, the theme cards below.
struct ChatThemePicker: View {
    let conversationID: String
    @Binding var selected: String
    @EnvironmentObject private var store: SessionStore
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ZStack {
                    ChatThemeStyle.background(selected)
                    VStack(spacing: 8) {
                        HStack {
                            Text("ci.theme.sample1").font(.system(size: 14)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 12).padding(.vertical, 8).tfBubble(mine: false)
                            Spacer()
                        }
                        HStack {
                            Spacer()
                            Text("ci.theme.sample2").font(.system(size: 14)).foregroundStyle(Theme.hex(0xF2F7FA))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(ChatThemeStyle.outGradient(selected), in: BubbleShape(mine: true))
                        }
                    }
                    .padding(16)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderStrong, lineWidth: 1))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(ChatThemeStyle.all) { t in
                        Button { Task { await pick(t.id) } } label: {
                            VStack(spacing: 6) {
                                ChatThemeStyle.background(t.id)
                                    .frame(height: 84)
                                    .overlay(alignment: .bottomTrailing) {
                                        RoundedRectangle(cornerRadius: 6).fill(ChatThemeStyle.outGradient(t.id)).frame(width: 34, height: 14).padding(8)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == t.id ? Theme.accent : Theme.borderStrong,
                                                                                      lineWidth: selected == t.id ? 2 : 1))
                                Text(t.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("ci.theme.note").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .padding(16)
        }
        .background(Theme.panelGradient.ignoresSafeArea())
        .navigationTitle(Text("ci.theme"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if saving { ProgressView().tint(Theme.accent) } }
    }

    private func pick(_ id: String) async {
        saving = true
        defer { saving = false }
        if (try? await APIClient.shared.ctSetTheme(token: store.session?.token ?? "", conversationID: conversationID, theme: id)) != nil {
            selected = id
        }
    }
}
