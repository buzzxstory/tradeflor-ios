import UIKit
import PushKit
import CallKit
import Security

/// Remote push (APNs), as the server contract says (Main, 2026-11-19):
/// - alert token: `registerForRemoteNotifications` after sign-in and on every launch, sent with the session bearer to
///   POST /push/apns/register {"Token", "Env", "Kind": "alert"}; the answer {"id","secret"} is kept in the Keychain.
/// - VoIP token (PushKit): the same call with "Kind": "voip". A VoIP push is content-free ({"tf": {"id","kind":"call",
///   "call_id","conversation_id"}}) and MUST be answered at once with a CallKit incoming call; the real caller name comes
///   from the live socket as soon as it is up (CallManager.reportPushCall).
/// - POST /push/apns/unregister on sign-out. 503 = the server has no Apple key yet: tried again later, no error shown.
/// The alert pushes are content-free by design ("Tradeflor" / "New message"); nothing here reads or stores message text.
/// Without the Push Notifications capability in the signing profile the system refuses the token: nothing breaks, there
/// is simply no remote push.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    private var bearer = ""
    private var registry: PKPushRegistry?
    private var alertHex = ""
    private var voipHex = ""

    /// What the phone knows about its own push registration: shown in Settings > Notifications, so a missing notification can be
    /// told apart at once (iOS refused the token, the server has no Apple key, no connection, or all fine).
    enum State: Equatable { case waiting, ok, failed(String) }
    @Published private(set) var alertState = State.waiting
    @Published private(set) var voipState = State.waiting

    func alertFailed(_ e: Error) { alertState = .failed(e.localizedDescription) }

    private func setState(_ kind: String, _ s: State) {
        if kind == "alert" { alertState = s } else { voipState = s }
    }

    private static func describe(_ e: Error) -> String {
        if let a = e as? APIError {
            switch a {
            case .server(let s): return s == 503 ? "the server has no Apple key yet" : "server error \(s)"
            case .badCredentials: return "session refused"
            case .rateLimited: return "rate limited"
            case .refused(let b): return b.isEmpty ? "refused by the server" : b
            default: return "no connection"
            }
        }
        return "no connection"
    }

    /// "sandbox" or "production": what the app's own provisioning profile says (aps-environment), else by build type.
    private static let env: String = {
        if let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
           let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let text = String(data: raw, encoding: .isoLatin1),
           let r = text.range(of: "<key>aps-environment</key>"),
           let s = text[r.upperBound...].range(of: "<string>"),
           let e = text[s.upperBound...].range(of: "</string>") {
            let v = String(text[s.upperBound..<e.lowerBound])
            return v == "development" ? "sandbox" : "production"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()

    /// After sign-in and on every launch with a saved session.
    func start(token: String) {
        guard !token.isEmpty else { return }
        bearer = token
        UIApplication.shared.registerForRemoteNotifications()
        if registry == nil {
            let r = PKPushRegistry(queue: .main)
            r.delegate = self
            r.desiredPushTypes = [.voIP]
            registry = r
        }
        // tokens that arrived before the session was known (a launch by a push) are sent now
        if !alertHex.isEmpty { send(kind: "alert", hex: alertHex) }
        if !voipHex.isEmpty { send(kind: "voip", hex: voipHex) }
    }

    /// The app came to the front: a registration that did not succeed yet (offline, the server's Apple key came later) is sent again.
    func retryIfNeeded() {
        guard !bearer.isEmpty else { return }
        if voipState != .ok, !voipHex.isEmpty { send(kind: "voip", hex: voipHex) }
        if alertState != .ok { UIApplication.shared.registerForRemoteNotifications() } // its callback sends the token
    }

    private var inFlight = Set<String>()

    /// A VoIP push woke the app, possibly with no screen: the live socket and the calls are attached from the saved session now,
    /// so the call that is ringing reaches the app (the screens attach the same things again later; both are idempotent).
    func ensureConnected() {
        guard let s = Keychain.load() else { return }
        if bearer.isEmpty { bearer = s.token }
        // a socket from before the app was suspended looks connected for up to 35 s but is dead: a new one now, whose
        // opening asks the server for the ringing call (call.sync)
        LiveConnection.shared.start(token: s.token)
        if UIApplication.shared.applicationState == .background && !CallManager.shared.lineInUse {
            LiveConnection.shared.reconnectNow()
        } else {
            LiveConnection.shared.probe() // a working socket (the app in front, a call on) is only checked, not dropped
        }
        CallManager.shared.attach(live: LiveConnection.shared, token: s.token, userID: s.userID)
    }

    /// Sign-out: both tokens leave the server while the session is still valid (called before the logout request).
    func unregisterNow() async {
        let token = bearer
        let pairs = [("alert", alertHex), ("voip", voipHex)].filter { !$0.1.isEmpty }
        guard !token.isEmpty else { return }
        for (kind, hex) in pairs {
            _ = try? await APIClient.shared.postJSON("push/apns/unregister", token: token,
                                                     body: ["Token": hex, "Env": Self.env, "Kind": kind])
        }
        alertHex = ""
        voipHex = ""
        PushKeys.clear()
    }

    /// Sign-out or a revoked session: the server stops pushing to this phone.
    func stop() {
        let token = bearer
        let pairs = [("alert", alertHex), ("voip", voipHex)].filter { !$0.1.isEmpty }
        bearer = ""
        alertHex = ""
        voipHex = ""
        alertState = .waiting
        voipState = .waiting
        PushKeys.clear()
        UIApplication.shared.unregisterForRemoteNotifications()
        registry?.desiredPushTypes = []
        registry = nil // start() makes a new one: PushKit then hands out its token again
        guard !token.isEmpty else { return }
        Task {
            for (kind, hex) in pairs {
                _ = try? await APIClient.shared.postJSON("push/apns/unregister", token: token,
                                                         body: ["Token": hex, "Env": Self.env, "Kind": kind])
            }
        }
    }

    func alertTokenArrived(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex != alertHex || PushKeys.load("alert") == nil else { return }
        alertHex = hex
        send(kind: "alert", hex: hex)
    }

    private func send(kind: String, hex: String) {
        let token = bearer
        // one loop per (kind, device token, account): a new token or a new sign-in is never held behind an old loop's wait
        let job = "\(kind)|\(hex)|\(token.hashValue)"
        guard !token.isEmpty, !inFlight.contains(job) else { return }
        inFlight.insert(job)
        Task {
            defer { self.inFlight.remove(job) }
            // 503 (no Apple key on the server yet) and a dropped connection: again after 30 s, 2 min and 10 min, quietly
            for wait in [0, 30, 120, 600] as [UInt64] {
                if wait > 0 { try? await Task.sleep(nanoseconds: wait * 1_000_000_000) }
                if self.bearer != token { return } // signed out or another account meanwhile
                do {
                    let data = try await APIClient.shared.postJSON("push/apns/register", token: token,
                                                                   body: ["Token": hex, "Env": Self.env, "Kind": kind])
                    struct Keys: Decodable { let id: String; let secret: String }
                    if let k = try? JSONDecoder().decode(Keys.self, from: data) { PushKeys.save(kind, id: k.id, secret: k.secret) }
                    self.setState(kind, .ok)
                    return
                } catch {
                    self.setState(kind, .failed(Self.describe(error)))
                }
            }
        }
    }
}

extension PushManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            self.voipHex = hex
            self.send(kind: "voip", hex: hex)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in self.voipHex = "" }
    }

    /// iOS rule: every VoIP push is answered with a CallKit incoming call before this returns.
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                                  completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let tf = payload.dictionaryPayload["tf"] as? [String: Any]
        let callID = (tf?["call_id"] as? String) ?? ""
        Task { @MainActor in
            // CallKit first (iOS kills an app that does not report), then the socket so the call can be named
            CallManager.shared.reportPushCall(callID: callID)
            PushManager.shared.ensureConnected()
            completion()
        }
    }
}

/// The subscription id and secret the server gives for an alert / VoIP token (kept in the Keychain, this device only).
enum PushKeys {
    private static let service = "com.tradeflor.ios.push"

    static func save(_ kind: String, id: String, secret: String) {
        guard let data = try? JSONEncoder().encode(["id": id, "secret": secret]) else { return }
        delete(kind)
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: kind,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: data] as CFDictionary, nil)
    }

    static func load(_ kind: String) -> [String: String]? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: kind, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    static func delete(_ kind: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: kind] as CFDictionary)
    }

    static func clear() { delete("alert"); delete("voip") }
}

/// Receives the system's token callbacks and starts push when the app is launched (also in the background by a push).
final class TradeflorAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // a launch by a VoIP push has no screen yet: the PushKit registry must exist before the first push is delivered
        if let s = Keychain.load() { Task { @MainActor in PushManager.shared.start(token: s.token) } }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.alertTokenArrived(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // no Push Notifications in the signing profile (or no network): no remote push, nothing else changes; Settings says why
        Task { @MainActor in PushManager.shared.alertFailed(error) }
    }
}
