import SwiftUI

@main
struct TradeflorApp: App {
    @StateObject private var store = SessionStore()
    @AppStorage("tf.night") private var night = true
    @StateObject private var live = LiveConnection()

    init() {
        Theme.applyAppearance()
        #if DEBUG
        // CI screenshots: TF_CI_DAY=1 shows the day look; every other CI launch the night look
        let env = ProcessInfo.processInfo.environment
        if env["TF_CI"] != nil {
            UserDefaults.standard.set(env["TF_CI_DAY"] == nil, forKey: "tf.night")
            UserDefaults.standard.set(false, forKey: "tf.ci.groupOpened")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(live)
                .preferredColorScheme(store.session == nil ? .light : (night ? .dark : .light)) // sign-in is light, like the website
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var live: LiveConnection
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var calls = CallManager.shared
    @ObservedObject private var badges = BadgeStore.shared
    @ObservedObject private var notifier = LocalNotifier.shared
    @ObservedObject private var links = DeepLinks.shared
    @ObservedObject private var flash = FlashHub.shared
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
                        .badge(badges.chats)
                        .tag("chats")
                    GroupsListView()
                        .tabItem { Label("groups.title", systemImage: "person.2") }
                        .badge(badges.groups)
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
        .onOpenURL { url in DeepLinks.shared.handle(url) }
        // Tradeflor links tapped inside the app open here instead of the browser
        .environment(\.openURL, OpenURLAction { url in DeepLinks.shared.handle(url) ? .handled : .systemAction })
        .sheet(item: $links.pending) { p in DeepLinkSheet(target: p.target).environmentObject(store) }
        // someone scanned my connect code: Connection Request (Accept / Decline) wherever I am
        .sheet(item: Binding(get: { flash.screens == 0 && links.pending == nil ? flash.request : nil },
                             set: { if $0 == nil, let r = flash.request { flash.answered(r.id) } })) { r in
            ConnectionRequestSheet(request: r) { chat in LocalNotifier.shared.tappedConversation = chat.conversation_id }
                .environmentObject(store)
        }
        .onChange(of: notifier.tappedConversation) { id in
            // a tapped notification: the right tab; the list there opens the chat
            if let id { tab = id.hasPrefix("grp_") ? "groups" : "chats" }
        }
        .confirmationDialog(Text(String(format: NSLocalizedString("call.confirm.title", comment: ""), calls.confirming?.peerName ?? "")),
                            isPresented: Binding(get: { calls.confirming != nil }, set: { if !$0 { calls.confirming = nil } }),
                            titleVisibility: .visible) {
            Button("call.confirm.go") {
                if let c = calls.confirming { calls.start(conversationID: c.conversationID, peerName: c.peerName, peerID: c.peerID, confirmed: true) }
                calls.confirming = nil
            }
            Button("grp.cancel", role: .cancel) { calls.confirming = nil }
        }
        .fullScreenCover(isPresented: $calls.showScreen) { CallScreen(calls: calls).environmentObject(store).preferredColorScheme(.dark) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !calls.showScreen && calls.phase != .idle && calls.phase != .ended {
                Button { calls.showScreen = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                        Text(calls.peerName).fontWeight(.semibold)
                        Spacer()
                        if calls.phase == .active, let t = calls.connectedAt { Text(t, style: .timer).monospacedDigit() }
                        else { Text("call.return") }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.green.opacity(0.85))
                }
                .accessibilityLabel(Text("call.return"))
            } else if !calls.showScreen && calls.phase == .ended {
                // end-of-call notice (website CallOverlay): a compact card with the person's picture, name and outcome
                HStack(spacing: 10) {
                    if let pid = calls.peerID {
                        Avatar(token: store.session?.token ?? "", userID: pid, avatarID: nil, title: calls.peerName, size: 36)
                    } else {
                        Image(systemName: "phone.down.fill").frame(width: 36, height: 36).background(Theme.card, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(calls.peerName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(CallScreen.endedKey(calls.endReason)))
                            if let d = calls.lastDuration, d >= 1 { Text("· " + VoiceBubble.length(Int64(d * 1000))).monospacedDigit() }
                        }
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.horizontal, 12).padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
            }
        }
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
            if phase == .active { live.probe(); Task { await FlashHub.shared.askPending() } }
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
            LocalNotifier.shared.attach(live: live, token: s.token, userID: s.userID)
            DeliveryStats.shared.attach(live, me: s.userID)
            FlashHub.shared.attach(live: live, token: s.token)
        } else {
            FlashHub.shared.detach()
            CallManager.shared.detach()
            LocalNotifier.shared.detach()
            live.stop()
        }
    }
}


