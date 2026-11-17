import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var session: Session?

    init() {
        session = Keychain.load()
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
            await APIClient.shared.relockChats(token: token)
            await APIClient.shared.logout(token: token)
        }
        Keychain.delete()
        forgetAccount()
        session = nil
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
        ListCache.clear(); ChatMemo.clear()
        SettingsView.forgetCache()
        TradeFlorView.forgetCache()
    }
}
