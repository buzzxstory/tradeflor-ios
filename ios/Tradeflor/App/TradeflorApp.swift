import SwiftUI

@main
struct TradeflorApp: App {
    @UIApplicationDelegateAdaptor(TradeflorAppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()
    @AppStorage("tf.night") private var night = true
    /// The one live connection, handed to every screen. Not observed here: its presence lists change all the time, and the
    /// app's root would be worked out again for each change.
    private let live = LiveConnection.shared

    init() {
        Theme.applyAppearance()
        LocalNotifier.bootstrap()
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
    /// Used for its events and calls only (nothing it publishes is shown here), so it is not observed: a contact coming
    /// online no longer works out the whole root again. The App still hands it to every screen (environmentObject).
    private let live = LiveConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var settling = false
    @ObservedObject private var appLock = AppLock.shared
    @ObservedObject private var calls = CallManager.shared
    @ObservedObject private var badges = BadgeStore.shared
    @ObservedObject private var notifier = LocalNotifier.shared
    @ObservedObject private var links = DeepLinks.shared
    @ObservedObject private var chrome = TabChrome.shared
    @ObservedObject private var flash = FlashHub.shared
    @State private var needsSetup = false
    /// The call screen and the "Call X?" question, presented only once no sheet is up: SwiftUI cannot present them from the
    /// root while a sheet (Contacts, Contact info, a member's profile over Group info...) is on screen, so an incoming
    /// call or a call started there had no screen at all (and no return bar either, showScreen being true).
    @State private var callCover = false
    @State private var askCall = false
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
                // the web's phone dock (MobileTabBar) instead of the system tab bar
                TabView(selection: $tab) {
                    ChatListView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag("chats")
                    GroupsListView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag("groups")
                    TradeFlorView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag("tradeflor")
                    CalendarView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag("calendar")
                    SettingsView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag("settings")
                }
                // the dock floats over the tabs; every scroll view of a tab keeps room for it (DockSpace on the scroll view
                // itself), so no row hides under it: an inset here, outside each tab's NavigationStack, never reached them
                // the animation belongs to the dock alone: on the whole TabView it also animated every tab's bottom room
                // (DockSpace) while a chat was being pushed or the keyboard came up
                .overlay(alignment: .bottom) {
                    ZStack(alignment: .bottom) {
                        if !chrome.hidden {
                            MobileTabBar(tab: $tab, chatsBadge: badges.chats, groupsBadge: badges.groups)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: chrome.hidden)
                }
            } else {
                LoginView()
            }
        }
        .tint(Theme.accent)
        // a chat unlocked with its PIN is hidden in the app switcher and while the app is not in front
        .overlay {
            if scenePhase != .active, APIClient.shared.unlockToken != nil || appLock.enabled {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
        .onOpenURL { url in DeepLinks.shared.handle(url) }
        // Tradeflor links tapped inside the app open here instead of the browser
        .environment(\.openURL, OpenURLAction { url in DeepLinks.shared.handle(url) ? .handled : .systemAction })
        .fullScreenCover(item: $links.pending) { p in DeepLinkSheet(target: p.target).environmentObject(store) }
        // someone scanned my connect code: Connection Request (Accept / Decline) wherever I am
        .sheet(item: Binding(get: { links.pending == nil ? flash.request(for: nil) : nil },
                             set: { if $0 == nil, let r = flash.request { flash.answered(r.id) } })) { r in
            ConnectionRequestSheet(request: r) { chat in LocalNotifier.shared.tappedConversation = chat.conversation_id }
                .environmentObject(store)
        }
        // only the dock's own tabs (an unknown name left the TabView on a blank page)
        .onReceive(NotificationCenter.default.publisher(for: .tfGoTab)) { n in
            if let t = n.object as? String, ["chats", "groups", "tradeflor", "calendar", "settings"].contains(t), tab != t {
                TabChrome.dismissKeyboard()
                tab = t
            }
        }
        .onChange(of: notifier.tappedConversation) { id in
            // a tapped notification: the right tab; the list there opens the chat. A sheet that is up (Contacts, Contact info,
            // New chat...) is closed first: the chat opened underneath it and nothing was seen
            if let id { afterSheets { tab = id.hasPrefix("grp_") ? "groups" : "chats" } }
        }
        .confirmationDialog(Text(String(format: NSLocalizedString("call.confirm.title", comment: ""), calls.confirming?.peerName ?? "")),
                            isPresented: $askCall,
                            titleVisibility: .visible) {
            Button("call.confirm.go") {
                if let c = calls.confirming { calls.start(conversationID: c.conversationID, peerName: c.peerName, peerID: c.peerID, confirmed: true) }
                calls.confirming = nil
            }
            Button("grp.cancel", role: .cancel) { calls.confirming = nil }
        }
        .fullScreenCover(isPresented: $callCover) { CallScreen(calls: calls).environmentObject(store).preferredColorScheme(.dark) }
        .onChange(of: calls.showScreen) { showCall($0) }
        .onChange(of: callCover) { shown in if !shown && calls.showScreen { calls.showScreen = false } }
        .onChange(of: calls.confirming?.id) { id in
            if id == nil { askCall = false } else { afterSheets { askCall = calls.confirming != nil } }
        }
        .onChange(of: askCall) { shown in if !shown && calls.confirming != nil { calls.confirming = nil } }
        // the green "return to call" bar sits above the app, which moves down under it (a safe-area inset did not reach the
        // screens inside the tab bar and navigation stacks: the chat header was hidden under the bar)
        .modifier(CallBarSpace(calls: calls))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !calls.showScreen && !calls.lineInUse && calls.phase == .ended && !calls.endedByMe {
                // end-of-call notice (website CallOverlay): a compact card with the person's picture, name and outcome, when
                // the other side, the server or the network ended the call (nothing when this phone's own End did)
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
        .fullScreenCover(isPresented: $needsSetup) { IdentitySetupView { needsSetup = false }.tfColorScheme() }
        .task(id: store.session?.token) {
            // a new account (or one that never finished) still has to pick its @username and get its PIN
            guard let token = store.session?.token else { needsSetup = false; return }
            if let me = try? await APIClient.shared.myIdentity(token: token) { needsSetup = me.needs_setup ?? false }
        }
        .onAppear {
            if let id = notifier.tappedConversation { tab = id.hasPrefix("grp_") ? "groups" : "chats" }
            syncLive()
            if calls.showScreen { showCall(true) }
            #if DEBUG
            // CI only: TF_CI_SIGNOUT=1 ends the test account's session on the server after the screenshots,
            // so CI runs do not pile up sessions under Linked devices.
            if ProcessInfo.processInfo.environment["TF_CI_SIGNOUT"] == "1", store.session != nil {
                Task { await store.signOut() }
            }
            #endif
        }
        .onChange(of: store.session?.token) { _ in syncLive() }
        // a Home Screen quick action (Search, New Chat, Camera, My QR code): the Chats tab takes it
        .onReceive(QuickActions.shared.$pending) { a in if a != nil { tab = "chats" } }
        .onReceive(live.sessionInvalid) { _ in if store.session != nil { store.sessionExpired() } }
        // the first moments after unlocking the phone: a touch that was meant for the lock screen or an animation still running
        // is not a tap on a row (it opened a chat by itself)
        .overlay {
            if settling { Color.clear.contentShape(Rectangle()).ignoresSafeArea() }
        }
        // App Lock: the lock screen is its own window above sheets and covers; a plain cover hides the app in the app switcher
        .onAppear { if appLock.locked && store.session != nil { AppLockWindow.shared.showLock(store: store) } }
        .onChange(of: calls.phase) { p in if p == .idle || p == .ended { appLock.callEnded() } }
        .onChange(of: appLock.locked) { l in
            if l && store.session != nil { AppLockWindow.shared.showLock(store: store) } else { AppLockWindow.shared.hideLock() }
        }
        .onChange(of: store.session?.token) { t in
            if t == nil { AppLockWindow.shared.hideLock(); AppLockWindow.shared.hideCover() }
            else if appLock.locked { AppLockWindow.shared.showLock(store: store) } // a session that starts while the lock is on
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { appLock.appBackgrounded() }
            if phase == .active {
                appLock.appBecameActive()
                // locked now: the lock window goes up in this very update (no frames of the app in between)
                if appLock.locked && store.session != nil { AppLockWindow.shared.showLock(store: store) }
                else { AppLockWindow.shared.hideCover() }
            } else if appLock.enabled && !appLock.locked && store.session != nil {
                AppLockWindow.shared.showCover()
            }
            if phase == .active { PushManager.shared.retryIfNeeded() }
            // armed only by a real trip to the background (locking the phone always passes through it): Control Center, the
            // notification shade, Face ID or a system alert (.inactive only) no longer leave the app deaf for 300 ms
            if phase == .background {
                settling = true // up before the app is on screen again: the touch that unlocks the phone never reaches a row
            } else if phase == .active, settling {
                Task { try? await Task.sleep(nanoseconds: 300_000_000); settling = false }
            }
            // online = the app is in front (server d4d2e77)
            live.setActive(phase != .background) // Control Center or a system sheet (.inactive) is not "offline"
            if phase == .active { live.probe(); Task { await FlashHub.shared.askPending() } }
            // Locked chats lock again as soon as the app leaves the screen.
            if phase == .background, let token = store.session?.token {
                Task { await APIClient.shared.relockChats(token: token) }
            }
        }
    }

    private func showCall(_ want: Bool) {
        guard want else { callCover = false; return }
        guard !callCover else { return }
        afterSheets { if calls.showScreen { callCover = true } }
    }

    /// Runs `then` once whatever the app presents (sheets, a dialog) is gone: dismissed here first.
    private func afterSheets(_ then: @escaping () -> Void) {
        // the app's own window, not the key one: while App Lock is up its window is the key window and never has a sheet
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        let root = windows.first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil })?.rootViewController
        // the account setup cover is never closed under the person (a call then waits for it, as before)
        guard let root, let presented = root.presentedViewController, !needsSetup else { then(); return }
        if presented.isBeingDismissed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { afterSheets(then) }
            return
        }
        // an incoming call does not wait for a sheet to slide away
        root.dismiss(animated: calls.phase != .incoming, completion: then)
    }

    private func syncLive() {
        // onChange(of: scenePhase) never runs for the first phase: a launch in the background (a VoIP push) left the socket
        // "not in front" for the whole session, and others saw the person offline while using the app (audit IOS-PRES-2).
        // .inactive (launching, Control Center) counts as in front, as in the scenePhase handler.
        live.setActive(UIApplication.shared.applicationState != .background)
        if let s = store.session {
            live.start(token: s.token)
            PushManager.shared.start(token: s.token) // alert and VoIP tokens go to the server (remote push)
            CallManager.shared.attach(live: live, token: s.token, userID: s.userID)
            LocalNotifier.shared.attach(live: live, token: s.token, userID: s.userID)
            OutboxFlusher.shared.attach(live: live, token: s.token, userID: s.userID)
            DeliveryStats.shared.attach(live, me: s.userID)
            FlashHub.shared.attach(live: live, token: s.token)
        } else {
            FlashHub.shared.detach()
            PushManager.shared.stop()
            CallManager.shared.detach()
            LocalNotifier.shared.detach()
            OutboxFlusher.shared.detach()
            live.stop()
            live.forgetPresence() // the next account never sees this one's online list or hidden last-seen (IOS-PRES-7)
        }
    }
}


