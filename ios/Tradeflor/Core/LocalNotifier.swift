import Combine
import CryptoKit
import Foundation
import UIKit
import UserNotifications

/// A background task that is ended once, whichever comes first: the work finishing or iOS's time running out.
@MainActor
private final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Message and call notifications while the app is running (the website's shared/lib/notifications.ts decideNotification
/// rules): banner + sound for new messages, group messages and mentions, following Settings › Notifications and each
/// chat's mute; "Missed voice call" for a call that rang here unanswered. Grouped per chat (threadIdentifier), with Reply
/// and Mark as Read on messages and Call Back on missed calls, and the app icon badge = unread chats.
/// Without a paid Apple developer account there is no remote push (APNs) or VoIP push (PushKit), so only a running app
/// (in front, in its short background window, or kept alive by a call's audio or live location) can notify.
@MainActor
final class LocalNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifier()

    /// The conversation on screen (set by the chat view): its messages are not announced while the app is in front.
    var openConversation: String?
    /// A notification tapped: the conversation to show (the chat list opens it).
    @Published var tappedConversation: String?

    static let messageCategory = "tf.message"
    static let missedCallCategory = "tf.call.missed"
    static let incomingCallCategory = "tf.call.incoming"
    private static let replyAction = "tf.reply"
    private static let readAction = "tf.read"
    private static let callBackAction = "tf.callback"
    private static let messageAction = "tf.message.open"

    private var token = ""
    private var me = ""
    private var subs = Set<AnyCancellable>()
    private var appSubs = Set<AnyCancellable>()
    private var settings: [String: Bool] = [:]
    private var mutedUntil: [String: Int64] = [:]
    private var titles: [String: String] = [:]
    private var names: [String: String] = [:]
    private var peers: [String: String] = [:] // conversation -> the other person's user id (1:1 chats)
    private var loadedGroups: Set<String> = []
    private var notified: [String] = []
    /// Unread messages per chat (from the lists, plus what arrived on the socket since): the icon counts messages.
    private var unreadCounts: [String: Int] = [:]
    private var lockedChats: Set<String> = [] // Chat Lock: their notifications carry no name and no text
    private var archivedChats: Set<String> = []
    private var blockedPeers: Set<String> = []
    private var hiddenChats: Set<String> = [] // deleted from the list on this phone, no newer message yet
    private var refreshedAt = Date.distantPast
    /// Chats with unread messages (server count at the last refresh, plus every chat announced since): the icon badge.
    private var unread: Set<String> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let defaults: [String: Bool] = [
        "notifications.enabled": true, "notifications.sound": true, "notifications.previews": true,
        "notifications.when_focused": true, "notifications.groups": true, "notifications.mentions": true,
        "notifications.mentions_in_muted": true,
    ]

    override init() {
        super.init()
        // as early as possible: a notification tapped while the app was closed is delivered to this delegate at launch
        UNUserNotificationCenter.current().delegate = self
        Self.registerCategories()
        let nc = NotificationCenter.default
        nc.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.enteredBackground() }.store(in: &appSubs)
        nc.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.enteringForeground() }.store(in: &appSubs)
        // back in front: the icon shows the lists' number again (they publish only when it changes)
        nc.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, !self.token.isEmpty else { return }
                self.setIconBadge(BadgeStore.shared.chatMessages + BadgeStore.shared.groupMessages)
            }.store(in: &appSubs)
        // in front, the icon badge follows the tab bar's unread counts
        BadgeStore.shared.$chatMessages.combineLatest(BadgeStore.shared.$groupMessages)
            .map { $0 + $1 }
            .removeDuplicates()
            .map { ($0, 0) }
            .receive(on: RunLoop.main)
            .sink { [weak self] c, g in
                guard let self, UIApplication.shared.applicationState == .active, !self.token.isEmpty else { return }
                self.setIconBadge(c + g)
            }
            .store(in: &appSubs)
    }

    /// Call from the App's init so the delegate and categories are in place before launch finishes.
    static func bootstrap() { _ = shared }

    private static func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: replyAction,
                                                  title: NSLocalizedString("notif2.reply", comment: ""),
                                                  options: [],
                                                  textInputButtonTitle: NSLocalizedString("notif2.send", comment: ""),
                                                  textInputPlaceholder: NSLocalizedString("notif2.reply.placeholder", comment: ""))
        let read = UNNotificationAction(identifier: readAction, title: NSLocalizedString("notif2.markread", comment: ""), options: [])
        let message = UNNotificationCategory(identifier: messageCategory, actions: [reply, read], intentIdentifiers: [],
                                             hiddenPreviewsBodyPlaceholder: NSLocalizedString("notify.new", comment: ""),
                                             options: [])
        let callBack = UNNotificationAction(identifier: callBackAction, title: NSLocalizedString("notif2.callback", comment: ""),
                                            options: [.foreground])
        let sendMessage = UNNotificationAction(identifier: messageAction, title: NSLocalizedString("call2.message", comment: ""),
                                               options: [.foreground])
        let missed = UNNotificationCategory(identifier: missedCallCategory, actions: [callBack, sendMessage], intentIdentifiers: [],
                                            options: [])
        let incoming = UNNotificationCategory(identifier: incomingCallCategory, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([message, missed, incoming])
    }

    func attach(live: LiveConnection, token: String, userID: String) {
        guard self.token != token else { return }
        self.token = token
        me = userID
        subs.removeAll()
        UNUserNotificationCenter.current().delegate = self
        Self.registerCategories()
        var ask = true
        #if DEBUG
        // CI screenshots: no permission prompt over the screens
        if ProcessInfo.processInfo.environment["TF_CI"] != nil { ask = false }
        #endif
        // asked once signed in (the first moment there is anything to notify about); iOS shows the prompt only once
        if ask { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        live.messages.receive(on: RunLoop.main).sink { [weak self] m in Task { await self?.consider(m) } }.store(in: &subs)
        live.joinRequests.receive(on: RunLoop.main).sink { [weak self] d in Task { await self?.joinRequested(d) } }.store(in: &subs)
        Task { await refresh() }
    }

    func detach() {
        subs.removeAll()
        token = ""
        unread = []; unreadCounts = [:]; settings = [:]; mutedUntil = [:]; titles = [:]; names = [:]; peers = [:]; loadedGroups = []; notified = []; lockedChats = []; archivedChats = []; blockedPeers = []; hiddenChats = []
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        // directly: setIconBadge() does nothing once the token is gone, so the account's number stayed on the icon
        refreshedAt = .distantPast
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    private func flag(_ k: String) -> Bool { settings[k] ?? Self.defaults[k] ?? false }

    /// The account's "Sound" switch (Settings > Notifications).
    var soundOn: Bool { flag("notifications.sound") }
    /// The account's master "Notifications" switch.
    var notificationsOn: Bool { flag("notifications.enabled") }

    /// A switch saved in Settings › Notifications: in force here at once.
    func settingChanged(_ key: String, _ value: Bool) { settings[key] = value }

    private func isMuted(_ conversation: String) -> Bool {
        (mutedUntil[conversation] ?? 0) > Int64(Date().timeIntervalSince1970)
    }

    private func refresh() async {
        guard !token.isEmpty else { return }
        refreshedAt = Date()
        if let s = try? await APIClient.shared.stSettings(token: token) { settings = s }
        if let p = try? await APIClient.shared.prefs(token: token) {
            var m: [String: Int64] = [:]
            for x in p { if let u = x.muted_until { m[x.conversation_id] = u } }
            mutedUntil = m
            archivedChats = Set(p.filter { $0.archived ?? false }.map { $0.conversation_id })
        }
        if let st = try? await APIClient.shared.ctLockState(token: token) { lockedChats = Set((st.locks ?? []).map(\.conversation_id)) }
        if let b = try? await APIClient.shared.blocked(token: token) { blockedPeers = Set(b) }
        let hiddenAt = (UserDefaults.standard.dictionary(forKey: BadgeStore.hiddenKey(me)) as? [String: Double]) ?? [:]
        var hidden: Set<String> = []
        var fresh: Set<String> = []
        var counts: [String: Int] = [:]
        if let list = try? await APIClient.shared.conversations(token: token) {
            for c in list {
                titles[c.conversation_id] = c.title
                names[c.peer_id] = c.title
                peers[c.conversation_id] = c.peer_id
                if c.unread_count > 0 { fresh.insert(c.conversation_id); counts[c.conversation_id] = c.unread_count }
                if let h = hiddenAt[c.conversation_id],
                   !(Double(c.last_message_at > 100_000_000_000 ? c.last_message_at / 1000 : c.last_message_at) > h) { hidden.insert(c.conversation_id) }
            }
        }
        if let gs = try? await APIClient.shared.groups(token: token) {
            for g in gs {
                titles[g.conversation_id] = g.name
                if g.unread_count > 0 { fresh.insert(g.conversation_id); counts[g.conversation_id] = g.unread_count }
            }
        }
        hiddenChats = hidden
        unread = fresh
        unreadCounts = counts
    }

    // MARK: app in front / behind

    private func enteredBackground() {
        guard !token.isEmpty else { return }
        // the few seconds iOS grants after leaving the app: the live socket stays open, so a message that arrives
        // right after locking the phone still notifies
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "tf.notify") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        Task {
            await refresh() // mutes and unread counts as they are now
            setIconBadge(badgeCount())
        }
    }

    private func enteringForeground() {
        endBackgroundTask()
        // the counts and mutes as they are now (the socket may have been asleep); the icon at once, not after the lists
        Task { await refresh() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The app icon number: the same rule as the tab bar badges (BadgeStore.counts): unread chats that are not muted,
    /// archived, locked, blocked or deleted from the list.
    private func badgeCount() -> Int {
        unread.filter { id in
            BadgeStore.counts(unread: true, archived: archivedChats.contains(id), muted: isMuted(id), locked: lockedChats.contains(id),
                              blocked: peers[id].map { blockedPeers.contains($0) } ?? false, hidden: hiddenChats.contains(id))
        }.reduce(0) { $0 + max(1, unreadCounts[$1] ?? 1) } // unread MESSAGES, as WhatsApp's icon
    }

    private func setIconBadge(_ n: Int) {
        guard !token.isEmpty, refreshedAt != .distantPast else { return }
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(max(0, n), withCompletionHandler: nil)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = max(0, n)
        }
    }

    // MARK: messages

    private func senderName(_ m: Message, group: Bool) async -> String {
        if let n = names[m.sender_id] { return n }
        if group, !loadedGroups.contains(m.conversation_id) {
            loadedGroups.insert(m.conversation_id)
            if let ms = try? await APIClient.shared.groupMembers(token: token, groupID: m.conversation_id) {
                for x in ms { names[x.user_id] = x.title }
            }
        }
        return names[m.sender_id] ?? NSLocalizedString("notify.someone", comment: "")
    }

    private func describe(_ m: Message) -> String {
        switch m.kind {
        case "voice": return NSLocalizedString("notify.voice", comment: "")
        case "image": return m.body.isEmpty ? NSLocalizedString("notify.photo", comment: "") : "🖼 " + m.body
        case "file":
            if VideoNotePrep.isNote(m) { return NSLocalizedString("notify.videonote", comment: "") }
            if (m.file_mime ?? "").hasPrefix("video/") {
                return "🎬 " + (m.body.isEmpty ? NSLocalizedString("chats.kind.video", comment: "") : m.body)
            }
            if (m.file_mime ?? "").hasPrefix("image/") {
                return m.body.isEmpty ? NSLocalizedString("notify.photo", comment: "") : "🖼 " + m.body
            }
            return "📎 " + (m.file_name ?? NSLocalizedString("notify.file", comment: ""))
        case "signal": return NSLocalizedString("notify.signal", comment: "")
        case "poll": return NSLocalizedString("notify.poll", comment: "")
        case "location": return NSLocalizedString("notify.location", comment: "")
        default:
            let one = m.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return one.count > 140 ? String(one.prefix(139)) + "…" : one
        }
    }

    private func mentionsMe(_ m: Message) -> Bool {
        if m.reply_sender_id == me { return true }
        guard let raw = m.mentions, let d = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return false }
        return list.contains { ($0["user_id"] as? String) == me || ($0["user_id"] as? String) == "all" }
    }

    private func consider(_ m: Message) async {
        guard !token.isEmpty, m.sender_id != me, !m.isDeleted, m.kind != "notice", m.kind != "call" else { return }
        guard !notified.contains(m.id) else { return }
        let refreshedNow = Date().timeIntervalSince(refreshedAt) > 120
        if refreshedNow { await refresh() }
        guard flag("notifications.enabled") else { return }
        let secs = m.created_at > 100_000_000_000 ? Double(m.created_at) / 1000 : Double(m.created_at)
        if Date().timeIntervalSince1970 - secs > 90 { return } // an old message is not news
        let group = m.conversation_id.hasPrefix("grp_")
        let mention = group && mentionsMe(m)
        if isMuted(m.conversation_id) && !(mention && flag("notifications.mentions") && flag("notifications.mentions_in_muted")) { return }
        // in front (WhatsApp): never for the chat on screen; for another open chat yes; on the lists only when
        // "notify while the app is open" is on
        if UIApplication.shared.applicationState == .active {
            if openConversation == m.conversation_id { return }
            if openConversation == nil && !flag("notifications.when_focused") { return }
        }

        let locked = lockedChats.contains(m.conversation_id)
        let sender = locked ? "" : await senderName(m, group: group)
        let content = UNMutableNotificationContent()
        if group {
            content.title = titles[m.conversation_id] ?? NSLocalizedString("notify.group", comment: "")
            if mention && flag("notifications.mentions") {
                content.body = String(format: NSLocalizedString("notify.mentioned", comment: ""), sender)
            } else {
                guard flag("notifications.groups") else { return }
                content.body = flag("notifications.previews") ? "\(sender): \(describe(m))"
                    : String(format: NSLocalizedString("notify.sent", comment: ""), sender)
            }
        } else {
            content.title = sender
            content.body = flag("notifications.previews") ? describe(m) : NSLocalizedString("notify.new", comment: "")
        }
        if locked { content.title = "Tradeflor"; content.body = NSLocalizedString("notify.new", comment: "") }
        if flag("notifications.sound") { content.sound = MessageSound.notificationSound(group: group) }
        content.threadIdentifier = m.conversation_id
        content.categoryIdentifier = Self.messageCategory
        content.targetContentIdentifier = m.conversation_id
        content.userInfo = ["conversation_id": m.conversation_id, "message_id": m.id]
        hiddenChats.remove(m.conversation_id) // a newer message brings a deleted chat back to the list
        unread.insert(m.conversation_id)
        if !refreshedNow { unreadCounts[m.conversation_id, default: 0] += 1 } // a fresh read already has it
        content.badge = NSNumber(value: badgeCount())
        notified.append(m.id)
        if notified.count > 300 { notified.removeFirst(100) }
        let active = UIApplication.shared.applicationState == .active
        let soundWanted = content.sound != nil
        // in front the app plays the sound and the buzz itself (the system's would buzz a second time, whatever Vibrate says);
        // behind, with remote push working, the push (same id) brings the sound: this copy stays silent
        if active || PushManager.shared.alertState == .ok { content.sound = nil }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
        if active { MessageSound.incomingAlert(group: group, sound: soundWanted) }
    }

    /// Someone asked to join a group I own or run (website: one notice per request).
    private func joinRequested(_ d: [String: String]) async {
        guard let conv = d["conversation_id"] else { return }
        if Date().timeIntervalSince(refreshedAt) > 120 { await refresh() }
        // the soft two-note chime, once per request, unless sounds are off (website preferences.tsx, 3c68bec)
        if flag("notifications.sound") { JoinChime.playOnce(conversation: conv, user: d["user_id"] ?? "") }
        guard flag("notifications.enabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = d["group"] ?? titles[conv] ?? NSLocalizedString("notify.group", comment: "")
        content.body = flag("notifications.previews")
            ? String(format: NSLocalizedString("join.asked", comment: ""), d["name"] ?? NSLocalizedString("notify.someone", comment: ""))
            : NSLocalizedString("notify.generic", comment: "")
        if flag("notifications.sound") { content.sound = MessageSound.notificationSound(group: true) }
        content.threadIdentifier = conv
        content.userInfo = ["conversation_id": conv]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NoticeID.collapse("joinreq|\(conv)|\(d["user_id"] ?? "")"), content: content, trigger: nil))
    }

    // MARK: calls

    /// A call rang on this phone and nobody answered it here (CallManager.finish).
    func missedCall(name: String, peerID: String?, conversationID: String?, callID: String) {
        guard !token.isEmpty, flag("notifications.enabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? NSLocalizedString("notify.someone", comment: "") : name
        content.body = NSLocalizedString("callrow.missed", comment: "")
        if flag("notifications.sound") { content.sound = UNNotificationSound(named: MessageSound.notificationName) }
        content.categoryIdentifier = Self.missedCallCategory
        content.threadIdentifier = conversationID ?? "tf.calls"
        var info: [String: Any] = ["kind": "missed_call", "peer_name": content.title]
        if let conversationID { info["conversation_id"] = conversationID }
        if let peerID { info["peer_id"] = peerID }
        content.userInfo = info
        // the server's own "Missed call" alert has the call id as its identifier (apns-collapse-id): the same one here,
        // so the two replace each other instead of both staying
        let ident = callID.isEmpty ? "missed|" + UUID().uuidString : callID
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ident, content: content, trigger: nil)) }
    }

    /// CallKit could not ring (rare): an ordinary notification so the call is not silently lost.
    func incomingCallFallback(name: String, callID: String, conversationID: String?) {
        guard !token.isEmpty, flag("notifications.enabled"), UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = NSLocalizedString("call.incoming", comment: "")
        content.sound = .default
        content.categoryIdentifier = Self.incomingCallCategory
        content.interruptionLevel = .active
        var info: [String: Any] = ["kind": "incoming_call"]
        if let conversationID { info["conversation_id"] = conversationID }
        content.userInfo = info
        Task {
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call|\(callID)", content: content, trigger: nil))
        }
    }

    /// The call stopped ringing: its fallback notification goes.
    func clearIncomingCall(callID: String, missed: Bool = false) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["call|\(callID)"])
        // a missed call keeps the call id for its "Missed call" notice (posted just now under that identifier)
        guard !missed else { c.removeDeliveredNotifications(withIdentifiers: ["call|\(callID)"]); return }
        c.removeDeliveredNotifications(withIdentifiers: ["call|\(callID)", callID])
        // the server's "Incoming call" / silent "Call ended" alert for a call handled here can land a moment later
        Task {
            let bg = BackgroundTaskBox()
            bg.id = UIApplication.shared.beginBackgroundTask(withName: "tf.callnotice") { bg.end() }
            for ms in [2_000, 4_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [callID])
            }
            bg.end()
        }
    }

    /// Clears a chat's notifications once it is opened.
    func clear(conversation: String) {
        unread.remove(conversation)
        unreadCounts[conversation] = nil
        if UIApplication.shared.applicationState != .active { setIconBadge(badgeCount()) } // read from the lock screen
        let c = UNUserNotificationCenter.current()
        c.getDeliveredNotifications { list in
            let ids = list.filter { n in
                let info = n.request.content.userInfo
                let id = (info["conversation_id"] as? String) ?? ((info["tf"] as? [String: Any])?["conversation_id"] as? String)
                return id == conversation
            }.map(\.request.identifier)
            c.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: notification actions

    /// The session for an action that arrives before the app attached (launched in the background by Reply).
    private func currentToken() -> String {
        if !token.isEmpty { return token }
        return Keychain.load()?.token ?? ""
    }

    /// A Reply typed on the lock screen that could not be sent (no network, session gone, chat locked): saved with the chat's
    /// unsent messages, so it is sent again, with the same key, the next time that chat is opened.
    private func keepUnsentReply(id: String, body: String, conversation: String) {
        let account = me.isEmpty ? (Keychain.load()?.userID ?? "") : me
        guard !account.isEmpty else { return }
        var list = OutboxStore.load(account: account, conversation: conversation)
        guard !list.contains(where: { $0.id == id }) else { return }
        var p = PendingMessage(id: id, body: body, date: Date())
        p.failed = true
        list.append(p)
        OutboxStore.save(account: account, conversation: conversation, list)
    }

    private func postReplyFailed(conversation: String) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("priv.reply.failed", comment: "")
        content.body = titles[conversation] ?? NSLocalizedString("priv.reply.failed.body", comment: "")
        content.sound = .default
        content.threadIdentifier = conversation
        content.targetContentIdentifier = conversation
        content.userInfo = ["conversation_id": conversation]
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "replyfail|\(UUID().uuidString)", content: content, trigger: nil)) }
    }

    private func handle(action: String, info: [String: Any], text: String?) async {
        // a local notification carries the chat id itself; a remote one may carry it inside "tf" (never for a locked chat)
        let conv = (info["conversation_id"] as? String) ?? ((info["tf"] as? [String: Any])?["conversation_id"] as? String)
        switch action {
        case Self.replyAction:
            let t = currentToken()
            let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let conv, !t.isEmpty, !body.isEmpty else { return }
            let key = UUID().uuidString.lowercased()
            do {
                _ = try await APIClient.shared.sendText(token: t, conversationID: conv, body: body, key: key)
            } catch {
                // not lost: kept in this chat's unsent messages (sent again, same key, when the chat is opened) and said now
                keepUnsentReply(id: key, body: body, conversation: conv)
                postReplyFailed(conversation: conv)
                return
            }
            await APIClient.shared.markRead(token: t, conversationID: conv) // replying reads the chat (WhatsApp)
            clear(conversation: conv)
            setIconBadge(badgeCount())
        case Self.readAction:
            let t = currentToken()
            guard let conv, !t.isEmpty else { return }
            await APIClient.shared.markRead(token: t, conversationID: conv)
            clear(conversation: conv)
            setIconBadge(badgeCount())
        case Self.callBackAction:
            guard let conv else { return }
            let name = (info["peer_name"] as? String) ?? titles[conv] ?? ""
            let peer = (info["peer_id"] as? String) ?? peers[conv]
            // the app may still be starting: calls switch on once the account is attached
            for _ in 0..<20 where !CallManager.shared.enabled { try? await Task.sleep(nanoseconds: 300_000_000) }
            CallManager.shared.start(conversationID: conv, peerName: name, peerID: peer)
        default: // a tap on the notification, or "Message" on a missed call
            if let conv { tappedConversation = conv }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // in front, a missed call is already on screen (the end-of-call card): only kept in Notification Center
        if notification.request.content.userInfo["tf"] != nil {
            completionHandler([]) // a remote push ("New message"): the app in front shows the real message itself
        } else if notification.request.content.categoryIdentifier == LocalNotifier.missedCallCategory {
            completionHandler([.list])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: Any] ?? [:]
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            // a Reply sent from the lock screen runs in the background: keep the app awake until it is sent
            // out of time before it is done: the task ends there (one never ended gets the app killed)
            let bg = BackgroundTaskBox()
            bg.id = UIApplication.shared.beginBackgroundTask(withName: "tf.notify.action") { bg.end() }
            await self.handle(action: action, info: info, text: text)
            completionHandler()
            bg.end()
        }
    }
}

/// The identifier the server gives a notice (apns-collapse-id, backend apns.go NoticeCollapseID): a short plain tag as it
/// is, anything else "n-" + the first 16 bytes of its SHA-256 in hex. A local notice with the same identifier and the
/// server's push replace each other instead of both staying.
enum NoticeID {
    static func collapse(_ tag: String) -> String {
        let plain = !tag.isEmpty && tag.utf8.count <= 64 && tag.unicodeScalars.allSatisfy { c in
            (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122)
                || c == "|" || c == ":" || c == "." || c == "_" || c == "-"
        }
        if plain { return tag }
        let digest = SHA256.hash(data: Data(tag.utf8))
        return "n-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
