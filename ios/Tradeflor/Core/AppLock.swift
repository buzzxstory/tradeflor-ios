import Foundation
import CryptoKit
import LocalAuthentication
import Security
import UIKit
import SwiftUI

/// App Lock: Tradeflor asks for a PIN or a pattern when it opens (and after the time the person chose in the background).
/// Local to this iPhone: only a salted hash is kept, in the Keychain (this device only), and never leaves the phone. It is
/// separate from Chat Lock (which protects single chats with the account's server-side PIN).
enum AppLockKind: String, Codable { case pin, pattern }

/// The rules, with no screen and no Keychain in them (tested by AppLockTests).
enum AppLockRules {
    static let pinLength = 6
    static let minPatternDots = 4
    static let iterations = 50_000

    static func validPIN(_ s: String) -> Bool { s.count == pinLength && s.allSatisfy { $0.isASCII && $0.isNumber } }

    /// A pattern is the dots 1...9 (left to right, top to bottom) each used once, at least four.
    static func validPattern(_ dots: [Int]) -> Bool {
        dots.count >= minPatternDots && Set(dots).count == dots.count && dots.allSatisfy { (1...9).contains($0) }
    }

    /// What is hashed for a pattern: "1-2-3-6-9".
    static func patternSecret(_ dots: [Int]) -> String { dots.map(String.init).joined(separator: "-") }

    /// The dot a straight stroke from `a` to `b` also passes over (as on Samsung and Android): 1 to 3 passes 2, 1 to 9 passes 5,
    /// 3 to 7 passes 5. Nil when it passes none.
    static func between(_ a: Int, _ b: Int) -> Int? {
        guard (1...9).contains(a), (1...9).contains(b), a != b else { return nil }
        let r1 = (a - 1) / 3, c1 = (a - 1) % 3, r2 = (b - 1) / 3, c2 = (b - 1) % 3
        let dr = r2 - r1, dc = c2 - c1
        guard dr % 2 == 0, dc % 2 == 0 else { return nil }
        return ((r1 + r2) / 2) * 3 + (c1 + c2) / 2 + 1
    }

    /// Seconds to wait after `failures` wrong tries in a row: none for four, then 30 s, 1, 2, 5 and 15 minutes.
    static func lockout(failures: Int) -> TimeInterval {
        switch failures {
        case ..<5: return 0
        case 5: return 30
        case 6: return 60
        case 7: return 120
        case 8: return 300
        default: return 900
        }
    }

    /// The salted, stretched hash of a secret.
    static func derive(_ secret: String, salt: Data) -> Data {
        var h = Data(SHA256.hash(data: salt + Data(secret.utf8)))
        for _ in 0..<iterations { h = Data(SHA256.hash(data: h + salt)) }
        return h
    }
}

enum AppLockStore {
    struct Record: Codable { var kind: AppLockKind; var salt: Data; var hash: Data }
    private static let service = "com.tradeflor.ios.applock"
    private static let account = "record"

    static func load() -> Record? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: d)
    }

    @discardableResult
    static func save(_ r: Record) -> Bool {
        guard let data = try? JSONEncoder().encode(r) else { return false }
        delete()
        return SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account,
                           kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                           kSecValueData as String: data] as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var enabled: Bool
    @Published private(set) var kind: AppLockKind?
    /// The lock screen is up (the app opens locked when App Lock is on).
    @Published private(set) var locked: Bool
    @Published private(set) var lockedUntil: Date?
    private var failures: Int
    private var backgroundedAt: Date?
    /// The lock was due while a call was going on: it comes when the call ends.
    private var pendingLock = false

    private static let delayKey = "tf.applock.delay"
    private static let bioKey = "tf.applock.bio"
    private static let failKey = "tf.applock.failures"
    private static let untilKey = "tf.applock.until"

    /// Seconds in the background before the lock comes back (0 = every time).
    @Published var delay: TimeInterval {
        didSet { UserDefaults.standard.set(delay, forKey: Self.delayKey) }
    }
    @Published var biometrics: Bool {
        didSet { UserDefaults.standard.set(biometrics, forKey: Self.bioKey) }
    }

    init() {
        let r = AppLockStore.load()
        enabled = r != nil
        kind = r?.kind
        locked = r != nil
        let d = UserDefaults.standard
        delay = d.object(forKey: Self.delayKey) as? Double ?? 0
        biometrics = d.object(forKey: Self.bioKey) as? Bool ?? false
        failures = d.integer(forKey: Self.failKey)
        let now = Date().timeIntervalSince1970
        let t = min(d.double(forKey: Self.untilKey), now + AppLockRules.lockout(failures: failures))
        lockedUntil = t > now ? Date(timeIntervalSince1970: t) : nil
    }

    var biometryAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    /// Turns the lock on (or changes it) with a new secret; the app stays unlocked.
    @discardableResult
    func setSecret(kind: AppLockKind, secret: String) -> Bool {
        guard kind == .pin ? AppLockRules.validPIN(secret) : !secret.isEmpty else { return false }
        var salt = Data(count: 16)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) } == errSecSuccess
        guard ok else { return false }
        guard AppLockStore.save(.init(kind: kind, salt: salt, hash: AppLockRules.derive(secret, salt: salt))) else { return false }
        enabled = true
        self.kind = kind
        locked = false
        resetFailures()
        return true
    }

    /// True when the secret is right. Wrong ones are counted: five in a row make a wait that grows.
    func verify(_ secret: String) -> Bool {
        if let until = lockedUntil, until > Date() { return false }
        guard let r = AppLockStore.load() else { return false }
        if AppLockRules.derive(secret, salt: r.salt) == r.hash {
            resetFailures()
            return true
        }
        failures += 1
        UserDefaults.standard.set(failures, forKey: Self.failKey)
        let wait = AppLockRules.lockout(failures: failures)
        if wait > 0 {
            let until = Date().addingTimeInterval(wait)
            lockedUntil = until
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.untilKey)
        }
        return false
    }

    func unlock() { resetFailures(); locked = false } // Face ID counts too: the wrong tries before it are forgiven

    func disable() {
        AppLockStore.delete()
        enabled = false
        kind = nil
        locked = false
        biometrics = false
        resetFailures()
    }

    /// Sign-out: nothing of this lock stays for the next account.
    func reset() { disable() }

    private func resetFailures() {
        failures = 0
        lockedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.failKey)
        UserDefaults.standard.removeObject(forKey: Self.untilKey)
    }

    func appBackgrounded() { if backgroundedAt == nil { backgroundedAt = Date() } }

    func appBecameActive() {
        defer { backgroundedAt = nil }
        guard enabled, !locked, let t = backgroundedAt else { return }
        let due = Date().timeIntervalSince(t) >= delay
        // a call in progress keeps its screen (mute, hang up): the lock waits until it ends (callEnded)
        if CallManager.shared.lineInUse { if due { pendingLock = true }; return }
        if due { locked = true }
    }

    func callEnded() {
        if enabled && pendingLock && !locked { locked = true }
        pendingLock = false
    }

    /// Face ID / Touch ID (when the person turned it on): true when it recognised them.
    func unlockWithBiometrics(reason: String) async -> Bool {
        guard enabled, locked, biometrics, biometryAvailable else { return false }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        return await withCheckedContinuation { c in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in c.resume(returning: ok) }
        }
    }
}

/// The lock screen lives in its own window above everything (sheets, full-screen covers), so nothing of the app shows
/// through while it is up; a plain cover hides the app in the app switcher.
@MainActor
final class AppLockWindow {
    static let shared = AppLockWindow()
    private var lockWindow: UIWindow?
    private var coverWindow: UIWindow?
    private weak var previousKey: UIWindow?

    private func scene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState != .unattached }
    }

    func showLock(store: SessionStore) {
        guard lockWindow == nil, let scene = scene() else { return }
        TabChrome.dismissKeyboard() // a keyboard of the app underneath must not stay or come back over the lock
        previousKey = scene.windows.first { $0.isKeyWindow }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 2
        let host = UIHostingController(rootView: AppLockScreen().environmentObject(store).preferredColorScheme(.dark))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true // VoiceOver stays on the lock, not on the app under it
        w.rootViewController = host
        w.makeKeyAndVisible()
        lockWindow = w
        hideCover()
    }

    func hideLock() {
        lockWindow?.isHidden = true
        lockWindow = nil
        if let k = previousKey, !k.isHidden { k.makeKey() }
        else { scene()?.windows.first { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil }?.makeKey() }
        previousKey = nil
    }

    func showCover() {
        guard coverWindow == nil, lockWindow == nil, let scene = scene() else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        let host = UIHostingController(rootView: ZStack {
            Theme.hex(0x00131B).ignoresSafeArea()
            Image("BrandFlower").resizable().scaledToFit().frame(width: 84)
        }.preferredColorScheme(.dark))
        w.rootViewController = host
        w.isHidden = false
        coverWindow = w
    }

    func hideCover() {
        coverWindow?.isHidden = true
        coverWindow = nil
    }
}
