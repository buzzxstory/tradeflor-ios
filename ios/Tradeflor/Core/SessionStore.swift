import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: Session?

    init() {
        Self.dropKeychainLeftoversAfterReinstall()
        session = Keychain.load()
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

    /// The token was revoked elsewhere (e.g. "log out all devices" on the website).
    func sessionExpired() {
        Keychain.delete()
        forgetAccount()
        session = nil
    }

    /// This account's lists, profile card, statuses and admin role leave the phone with it, so the next account to sign
    /// in never sees them (they were kept in memory across a sign-out before).
    private func forgetAccount() {
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
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("outbox", isDirectory: true))
        }
        if let items = try? FileManager.default.contentsOfDirectory(at: ResumableUploader.folder, includingPropertiesForKeys: nil) {
            for u in items { try? FileManager.default.removeItem(at: u) }
        }
        BadgeStore.forgetHidden()
        ChatDrafts.clearAll() // what was typed and not sent
        // attachments opened for Quick Look or sharing (decrypted copies, also from locked chats)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("tf-files", isDirectory: true))
        // a notification tapped before the sign-out must not open a chat of the next account
        LocalNotifier.shared.tappedConversation = nil
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
