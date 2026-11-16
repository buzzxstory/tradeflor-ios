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

    func signOut() async {
        if let token = session?.token {
            await APIClient.shared.relockChats(token: token)
            await APIClient.shared.logout(token: token)
        }
        Keychain.delete()
        session = nil
    }

    /// The token was revoked elsewhere (e.g. "log out all devices" on the website).
    func sessionExpired() {
        Keychain.delete()
        session = nil
    }
}
