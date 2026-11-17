import Combine
import Foundation
import UIKit
import UserNotifications

/// Message notifications while the app is running (the website's shared/lib/notifications.ts decideNotification rules):
/// banner + sound for new messages, group messages and mentions, following Settings › Notifications and each chat's mute.
/// Without a paid Apple developer account there is no remote push, so a closed app does not notify.
@MainActor
final class LocalNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifier()

    /// The conversation on screen (set by the chat view): its messages are not announced while the app is in front.
    var openConversation: String?
    /// A notification tapped: the conversation to show (the chat list opens it).
    @Published var tappedConversation: String?

    private var token = ""
    private var me = ""
    private var subs = Set<AnyCancellable>()
    private var settings: [String: Bool] = [:]
    private var muted: Set<String> = []
    private var titles: [String: String] = [:]
    private var names: [String: String] = [:]
    private var loadedGroups: Set<String> = []
    private var notified: [String] = []
    private var refreshedAt = Date.distantPast

    private static let defaults: [String: Bool] = [
        "notifications.enabled": true, "notifications.sound": true, "notifications.previews": true,
        "notifications.when_focused": false, "notifications.groups": true, "notifications.mentions": true,
        "notifications.mentions_in_muted": true,
    ]

    func attach(live: LiveConnection, token: String, userID: String) {
        guard self.token != token else { return }
        self.token = token
        me = userID
        subs.removeAll()
        UNUserNotificationCenter.current().delegate = self
        var ask = true
        #if DEBUG
        // CI screenshots: no permission prompt over the screens
        if ProcessInfo.processInfo.environment["TF_CI"] != nil { ask = false }
        #endif
        if ask { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        live.messages.receive(on: RunLoop.main).sink { [weak self] m in Task { await self?.consider(m) } }.store(in: &subs)
        live.joinRequests.receive(on: RunLoop.main).sink { [weak self] d in Task { await self?.joinRequested(d) } }.store(in: &subs)
        Task { await refresh() }
    }

    func detach() {
        subs.removeAll()
        token = ""
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    private func flag(_ k: String) -> Bool { settings[k] ?? Self.defaults[k] ?? false }

    private func refresh() async {
        guard !token.isEmpty else { return }
        refreshedAt = Date()
        if let s = try? await APIClient.shared.stSettings(token: token) { settings = s }
        if let p = try? await APIClient.shared.prefs(token: token) { muted = Set(p.filter { $0.muted }.map(\.conversation_id)) }
        if let list = try? await APIClient.shared.conversations(token: token) {
            for c in list { titles[c.conversation_id] = c.title; names[c.peer_id] = c.title }
        }
        if let gs = try? await APIClient.shared.groups(token: token) { for g in gs { titles[g.conversation_id] = g.name } }
    }

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
        if Date().timeIntervalSince(refreshedAt) > 120 { await refresh() }
        guard flag("notifications.enabled") else { return }
        let secs = m.created_at > 100_000_000_000 ? Double(m.created_at) / 1000 : Double(m.created_at)
        if Date().timeIntervalSince1970 - secs > 90 { return } // an old message is not news
        let group = m.conversation_id.hasPrefix("grp_")
        let mention = group && mentionsMe(m)
        if muted.contains(m.conversation_id) && !(mention && flag("notifications.mentions") && flag("notifications.mentions_in_muted")) { return }
        let focused = UIApplication.shared.applicationState == .active
        if focused && openConversation == m.conversation_id { return }
        if focused && !flag("notifications.when_focused") { return }

        let sender = await senderName(m, group: group)
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
        if flag("notifications.sound") { content.sound = .default }
        content.threadIdentifier = m.conversation_id
        content.userInfo = ["conversation_id": m.conversation_id, "message_id": m.id]
        notified.append(m.id)
        if notified.count > 300 { notified.removeFirst(100) }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
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
        if flag("notifications.sound") { content.sound = .default }
        content.userInfo = ["conversation_id": conv]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "joinreq|\(conv)|\(d["user_id"] ?? "")", content: content, trigger: nil))
    }

    /// Clears a chat's notifications once it is opened.
    func clear(conversation: String) {
        let c = UNUserNotificationCenter.current()
        c.getDeliveredNotifications { list in
            let ids = list.filter { ($0.request.content.userInfo["conversation_id"] as? String) == conversation }.map(\.request.identifier)
            c.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["conversation_id"] as? String
        Task { @MainActor in self.tappedConversation = id }
        completionHandler()
    }
}
