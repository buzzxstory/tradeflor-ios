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
        prepareRegistry()
        // the registry outlived a sign-out (it is never dropped): its token is read again here, PushKit does not hand it out twice
        if voipHex.isEmpty, let t = registry?.pushToken(for: .voIP) { voipHex = t.map { String(format: "%02x", $0) }.joined() }
        // tokens that arrived before the session was known (a launch by a push) are sent now
        if !alertHex.isEmpty { send(kind: "alert", hex: alertHex) }
        if !voipHex.isEmpty { send(kind: "voip", hex: voipHex) }
    }

    /// The PushKit registry exists in every state, signed out too, from launch on (audit IOS-APL-5): a VoIP push that was in
    /// flight across a sign-out still finds a delegate, which reports it to CallKit and ends it. Without one iOS ends the app
    /// for not reporting the call, and after repeated failures stops delivering VoIP pushes.
    func prepareRegistry() {
        guard registry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    /// No account on this phone now (signed out, or the Keychain cannot be read before the first unlock).
    var hasSession: Bool { !bearer.isEmpty || Keychain.load() != nil }

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
        // the registry stays (IOS-APL-5): a VoIP push already on its way is still reported and ended. The server no longer
        // has this token (unregister below), and start() reads it again for the next account.
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
        // No Task here: a Task runs after this method has returned, and iOS wants the CallKit report before that (it kills an
        // app that has not reported, and then stops delivering VoIP pushes). The registry's queue is the main queue, so the
        // main-actor code runs right here.
        onMainNow {
            // signed out: reported (iOS demands it) and ended at once, nothing to connect (audit IOS-APL-5)
            guard PushManager.shared.hasSession else {
                CallManager.shared.reportEndedPushCall(callID: callID)
                return
            }
            // CallKit first, then the socket so the call can be named
            CallManager.shared.reportPushCall(callID: callID)
            PushManager.shared.ensureConnected()
        }
        completion()
    }
}

/// Runs main-actor code synchronously from a callback that is not isolated but is called on the main thread (PushKit with
/// `queue: .main`). What `MainActor.assumeIsolated` does, without needing a newer iOS; from another thread it waits for the
/// main thread instead.
private func onMainNow(_ body: @MainActor () -> Void) {
    typealias Isolated = @MainActor () -> Void
    typealias Plain = () -> Void
    if Thread.isMainThread {
        withoutActuallyEscaping(body) { (fn: @escaping Isolated) -> Void in
            let raw = unsafeBitCast(fn, to: Plain.self)
            raw()
        }
    } else {
        DispatchQueue.main.sync {
            withoutActuallyEscaping(body) { (fn: @escaping Isolated) -> Void in
                let raw = unsafeBitCast(fn, to: Plain.self)
                raw()
            }
        }
    }
}

/// The subscription id and secret the server gives for an alert / VoIP token (kept in the Keychain, this device only).
enum PushKeys {
    private static let service = "com.tradeflor.ios.push"

    /// The id and secret of the latest register answer are the ones kept (a newer server returns the same pair for the same
    /// account and token; an older one a new pair every time).
    static func save(_ kind: String, id: String, secret: String) {
        guard let data = try? JSONEncoder().encode(["id": id, "secret": secret]) else { return }
        delete(kind)
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: kind,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                    kSecValueData as String: data] as CFDictionary, nil)
        remember(id)
    }

    /// Every subscription id this account was given on this phone since it signed in (the older server hands out a new one
    /// on each registration, so a notice delivered before the latest one carries an older id). A notice tapped is routed
    /// only if its tf.id is one of these (NotificationRouting.belongsToCurrentAccount). Emptied at sign-out (clear()).
    static func knownIDs() -> Set<String> {
        var ids = Set(loadHistory())
        // a build from before this list kept only the current pair
        for kind in ["alert", "voip"] { if let id = load(kind)?["id"], !id.isEmpty { ids.insert(id) } }
        return ids
    }

    private static let historyAccount = "ids"

    private static func loadHistory() -> [String] {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: historyAccount, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func remember(_ id: String) {
        guard !id.isEmpty else { return }
        var list = loadHistory()
        guard list.last != id else { return }
        list.removeAll { $0 == id }
        list.append(id)
        if list.count > 40 { list.removeFirst(list.count - 40) }
        guard let data = try? JSONEncoder().encode(list) else { return }
        delete(historyAccount)
        SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrAccount as String: historyAccount,
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

    static func clear() { delete("alert"); delete("voip"); delete(historyAccount) }
}

/// Receives the system's token callbacks and starts push when the app is launched (also in the background by a push).
final class TradeflorAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // a launch by a VoIP push has no screen yet: the PushKit registry must exist before the first push is delivered
        // the registry is made here in every state, also with no session (IOS-APL-5); assumeIsolated is iOS 17+, so the
        // same synchronous hop as the push handler
        onMainNow {
            PushManager.shared.prepareRegistry()
            if let s = Keychain.load() { PushManager.shared.start(token: s.token) }
        }
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
