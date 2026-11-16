import SwiftUI

@main
struct TradeflorApp: App {
    @StateObject private var store = SessionStore()
    @StateObject private var live = LiveConnection()

    init() { Theme.applyAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(live)
                .preferredColorScheme(store.session == nil ? .light : .dark) // the sign-in screens are light, like the website
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var calls = CallManager.shared
    @State private var needsSetup = false
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
                // The website's phone tab bar: Chats, Groups, TradeFlor, Calendar, Settings
                TabView(selection: $tab) {
                    ChatListView()
                        .tabItem { Label("chats.title", systemImage: "bubble.left") }
                        .tag("chats")
                    GroupsListView()
                        .tabItem { Label("groups.title", systemImage: "person.2") }
                        .tag("groups")
                    TradeFlorView()
                        .tabItem { Label { Text("TradeFlor") } icon: { Image("TabFlower") } }
                        .tag("tradeflor")
                    CalendarView()
                        .tabItem { Label("calendar.title", systemImage: "calendar") }
                        .tag("calendar")
                    SettingsView()
                        .tabItem { Label("settings.title", systemImage: "gearshape") }
                        .tag("settings")
                }
            } else {
                LoginView()
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $calls.showScreen) { CallScreen(calls: calls) }
        .fullScreenCover(isPresented: $needsSetup) { IdentitySetupView { needsSetup = false } }
        .task(id: store.session?.token) {
            // a new account (or one that never finished) still has to pick its @username and get its PIN
            guard let token = store.session?.token else { needsSetup = false; return }
            if let me = try? await APIClient.shared.myIdentity(token: token) { needsSetup = me.needs_setup ?? false }
        }
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


