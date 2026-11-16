import SwiftUI

@main
struct TradeflorApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var live = LiveConnection()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(live)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var calls = CallManager.shared
    @State private var tab: String = {
        #if DEBUG
        // CI only: TF_CI_TAB=status opens on the Status tab for a screenshot.
        return ProcessInfo.processInfo.environment["TF_CI_TAB"] ?? "chats"
        #else
        return "chats"
        #endif
    }()

    var body: some View {
        Group {
            if store.session != nil {
                TabView(selection: $tab) {
                    ChatListView()
                        .tabItem { Label("chats.title", systemImage: "bubble.left.and.bubble.right.fill") }
                        .tag("chats")
                    StatusListView()
                        .tabItem { Label("status.title", systemImage: "circle.dashed.inset.filled") }
                        .tag("status")
                    SettingsView()
                        .tabItem { Label("settings.title", systemImage: "gearshape.fill") }
                        .tag("settings")
                }
                .toolbarBackground(Theme.ground, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            } else {
                LoginView()
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $calls.showScreen) { CallScreen(calls: calls) }
        .onAppear {
            syncLive()
            #if DEBUG
            // CI only: TF_CI_SIGNOUT=1 ends the test account's session on the server after the screenshots,
            // so CI runs do not pile up sessions under Linked devices.
            if ProcessInfo.processInfo.environment["TF_CI_SIGNOUT"] == "1", store.session != nil {
                Task { await store.signOut() }
            }
            #endif
        }
        .onChange(of: store.session?.token) { _ in syncLive() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { live.probe() }
            // Locked chats lock again as soon as the app leaves the screen.
            if phase == .background, let token = store.session?.token {
                Task { await APIClient.shared.relockChats(token: token) }
            }
        }
    }

    private func syncLive() {
        if let s = store.session {
            live.start(token: s.token)
            CallManager.shared.attach(live: live, token: s.token, userID: s.userID)
        } else {
            CallManager.shared.detach()
            live.stop()
        }
    }
}

enum Theme {
    static let accent = Color("AccentColor")
    static let ground = Color(red: 0x00 / 255, green: 0x13 / 255, blue: 0x30 / 255)
    static let surface = Color(red: 0x05 / 255, green: 0x22 / 255, blue: 0x45 / 255)
    static let onAccent = Color(red: 0x05 / 255, green: 0x2B / 255, blue: 0x3A / 255)
}
