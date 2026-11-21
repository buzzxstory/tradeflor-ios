import Foundation
import UIKit
import UserNotifications

/// The signed-in account as plain values any thread can read. Work that finishes after a sign-out or a 401 (a response in
/// flight, a debounced file write, a chat screen closing) asks it before it writes anything to the phone, so nothing of the
/// old account lands after the wipe and nothing is written for an account that is no longer here (audit IOS-SYNC-1 / SEC-1).
enum AccountGate {
    private static let lock = NSLock()
    private static var token = ""
    private static var userID = ""
    /// false until SessionStore (or the first read) set it: a launch by a push in the background reads the Keychain itself.
    private static var known = false

    static func set(_ s: Session?) {
        lock.lock()
        token = s?.token ?? ""
        userID = s?.userID ?? ""
        known = true
        lock.unlock()
    }

    private static func current() -> (token: String, userID: String) {
        lock.lock()
        if !known {
            let s = Keychain.load()
            token = s?.token ?? ""
            userID = s?.userID ?? ""
            known = true
        }
        let out = (token, userID)
        lock.unlock()
        return out
    }

    /// The session with this token is the one signed in now.
    static func isCurrent(token t: String) -> Bool { !t.isEmpty && current().token == t }
    /// This account is the one signed in now.
    static func isCurrent(account a: String) -> Bool { !a.isEmpty && current().userID == a }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: Session? {
        didSet { AccountGate.set(session) }
    }

    init() {
        Self.dropKeychainLeftoversAfterReinstall()
        let s = Keychain.load()
        session = s
        AccountGate.set(s) // didSet does not run inside init
    }

    /// Keychain items survive deleting the app, UserDefaults and the app's folders do not. On the first launch after an install
    /// (nothing of this app on the phone yet) a session or Face ID PIN left by the previous install is removed, so deleting the
    /// app really signs out. An update of an older build, which has files and tf.* settings here, keeps its session.
    private static func dropKeychainLeftoversAfterReinstall() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "tf.firstLaunchDone") else { return }
        defer { d.set(true, forKey: "tf.firstLaunchDone") }
        let hasSettings = d.dictionaryRepresentation().keys.contains { $0.hasPrefix("tf.") }
        var hasFiles = false
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            hasFiles = ["outbox", "uploads"].contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        }
        if !hasSettings && !hasFiles {
            Keychain.delete()
            BiometricPIN.delete()
            AppLockStore.delete() // the Keychain survives a reinstall: the old lock must not
        }
    }

    func signIn(username: String, password: String) async throws {
        let s = try await APIClient.shared.login(
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        Keychain.save(s)
        session = s
    }

    /// After sign-up and email verification: the server's session for the new account.
    func adopt(_ s: Session) {
        Keychain.save(s)
        session = s
    }

    private var signingOut = false

    func signOut() async {
        // one sign-out at a time (a second tap while the first is on its way does nothing)
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        if let token = session?.token {
            // live location shares run from this phone end first (they kept showing in the chats until they expired, and
            // the phone kept its location on for a session that no longer existed)
            await LocationSharer.shared.stopAll(token: token)
            await PulseStore.shared.signOut(token: token) // Pulse sharing stops everywhere (POST /pulse/stop-all) and measuring stops
            await APIClient.shared.relockChats(token: token)
            await PushManager.shared.unregisterNow() // no push for this phone after the session ends
            await APIClient.shared.logout(token: token)
        }
        Keychain.delete()
        forgetAccount()
        session = nil
    }

    /// The account's @username changed (Settings › My Identity or My Profile), or the name kept at sign-in was what was
    /// typed there (an email, another capitalisation): every place that shows "@username" from the session follows.
    func renamed(_ username: String) {
        // "~new-…" is the server's placeholder before the identity setup: never shown as anyone's name
        guard let s = session, !username.isEmpty, !username.hasPrefix("~"), s.username != username else { return }
        let next = Session(token: s.token, userID: s.userID, username: username)
        Keychain.save(next)
        session = next
    }

    /// The token was revoked elsewhere (e.g. "log out all devices" on the website), or the session expired (30 days unused,
    /// the 90-day cap): any 401. Several screens may see the same 401: only the first one does the work.
    func sessionExpired() {
        guard session != nil else { return }
        // the server already ended this session (its push rows are gone with it): what runs from this phone stops here
        LocationSharer.shared.stopLocally()
        Keychain.delete()
        forgetAccount()
        session = nil
    }

    /// This account's lists, profile card, statuses and admin role leave the phone with it, so the next account to sign
    /// in never sees them (they were kept in memory across a sign-out before).
    /// Sign-out checklist (audit IOS-SEC-1), where each item is done:
    /// - push unregistered (alert and VoIP): signOut -> PushManager.unregisterNow; both paths -> PushManager.stop (root view)
    /// - CallKit call ended, socket closed: CallManager.detach and LiveConnection.stop (root view, when the session goes)
    /// - delivered notifications removed, badge 0: here (and LocalNotifier.detach)
    /// - message stores, outbox, drafts, lists, files wiped: here (the iOS app keeps no sync cursor; messages are in memory only)
    /// - Keychain token removed: signOut / sessionExpired
    /// - nothing written afterwards: AccountGate is cleared first, every later write checks it
    private func forgetAccount() {
        // first: any write still on its way (a response in flight, a debounced outbox write) finds no account and writes nothing
        AccountGate.set(nil)
        // the Lock PIN kept behind Face ID belongs to this account: the next one to sign in here must not be offered it
        // (sign-out and a revoked session both come through here)
        BiometricPIN.delete()
        // the App Lock (PIN or pattern) belongs to this account's use of this phone: gone with it
        AppLock.shared.reset()
        ViewOnceSend.clearAll()
        BadgeStore.shared.chats = 0; BadgeStore.shared.groups = 0
        BadgeStore.shared.chatMessages = 0; BadgeStore.shared.groupMessages = 0
        ViewOnceSeen.clearAll()
        AppLockWindow.shared.hideLock()
        AppLockWindow.shared.hideCover()
        APIClient.shared.avatarCache.removeAllObjects()
        APIClient.shared.forgetUnlock()
        // what was waiting to be sent (photos, voice notes, videos) and the chats hidden from the list belong to this account
        // (on the outbox's own queue: a debounced write still waiting there is dropped, not written after the wipe)
        OutboxStore.wipeAll()
        if let items = try? FileManager.default.contentsOfDirectory(at: ResumableUploader.folder, includingPropertiesForKeys: nil) {
            for u in items { try? FileManager.default.removeItem(at: u) }
        }
        BadgeStore.forgetHidden()
        ChatDrafts.clearAll() // what was typed and not sent
        MediaLog.clear() // the status video log names this account's statuses (audit IOS-LC-2)
        NoteStore.shared.forget() // my note belongs to this account
        ScreenGuard.shared.releaseAll()
        NoteFileStore.forgetAll() // unsent Shared Notes changes of this account
        StickerStore.forget() // the sticker library, its last answer and every sticker picture
        PulseSharer.shared.forgetAll() // nothing keeps measuring for an account that is gone
        PulseStore.shared.clear()
        NotesConfig.shared.forget()
        LiveConnection.shared.forgetPresence() // who was online, last seen, hidden presence (audit IOS-PRES-7)
        // attachments opened for Quick Look or sharing (decrypted copies, also from locked chats)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("tf-files", isDirectory: true))
        // a notification tapped before the sign-out must not open a chat of the next account
        LocalNotifier.shared.tappedConversation = nil
        // this account's banners leave the notification centre, and its number leaves the icon
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0, withCompletionHandler: nil)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        ListCache.clear(); ChatMemo.clear()
        OfficialFeedCache.forget()
        SettingsView.forgetCache()
        TradeFlorView.forgetCache()
        // the pictures known for this account's people, and the likes it sent
        AvatarBook.shared.forget()
        StatusReactCache.shared.clear()
        StatusGone.shared.clear()
    }
}
