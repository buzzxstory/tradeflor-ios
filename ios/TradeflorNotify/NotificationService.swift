import Foundation
import Security
import UserNotifications

/// Notification Service Extension (WhatsApp way): Apple's push carries no name and no word of a message ("Tradeflor / New
/// message"); before iOS shows it, this extension asks Tradeflor's own server, on the phone, for the real text
/// (GET /push/peek with the subscription id, the secret the app was given at registration in X-Push-Secret, and the
/// message id: docs/push/PUSH_PEEK_MESSAGE_CONTRACT.md on the server side) and writes it into the notice. Never a guess:
/// only the text of exactly this message.
/// The server already decided the text per person: previews off ("New message"), a locked chat ("New message in a locked
/// chat"), a mention, a group ("sender: text"). Anything that fails leaves Apple's text as it was.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?
    private var task: URLSessionDataTask?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        best = content
        let tf = (content.userInfo["tf"] as? [String: Any]) ?? [:]
        let kind = (tf["kind"] as? String) ?? ""
        let want = PeekMatch(identifier: request.identifier, kind: kind, callID: tf["call_id"] as? String)
        guard let keys = SharedPushKeys.load() else {
            finish(content)
            return
        }
        // the subscription id the push names, when it is the one whose secret is kept (else the kept one: same account)
        let subID = (tf["id"] as? String).flatMap { $0 == keys.id ? $0 : nil } ?? keys.id
        if kind.isEmpty {
            // a message: its own text, read from the stored message (server 710ed38a, PUSH_PEEK_MESSAGE_CONTRACT.md)
            peekMessage(id: subID, secret: keys.secret, messageID: request.identifier, want: want, content: content)
        } else {
            peekAll(id: subID, secret: keys.secret, want: want, content: content)
        }
    }

    /// GET /push/peek?id=&m=<message id> with the secret in X-Push-Secret. 200: this message's text. 404: it must not be
    /// shown (deleted, hidden, blocked, too old, signed out) -> the original "New message". A server from before 710ed38a
    /// answers 404 to every such request: until this phone has seen one 200, a 404 is tried once more in the older way
    /// (all notices, exact message id only).
    private func peekMessage(id: String, secret: String, messageID: String, want: PeekMatch, content: UNMutableNotificationContent) {
        if let hit = PeekCache.find(want) { finish(apply(hit, to: content)); return }
        guard let url = Self.peekURL(["id": id, "m": messageID]) else { finish(content); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(secret, forHTTPHeaderField: "X-Push-Secret")
        task = URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data, let n = try? JSONDecoder().decode(PeekNotice.self, from: data) {
                PeekServer.supportsMessagePeek = true
                // never another message's text under this push
                if (n.message_id ?? messageID) == messageID {
                    self.finish(self.apply(n, to: content))
                } else {
                    self.finish(content)
                }
                return
            }
            if status == 404 && PeekServer.supportsMessagePeek {
                self.finish(content) // must not be shown
                return
            }
            // an older server (404 for every message), or the request failed on the network: the notices way, exact only
            self.peekAll(id: id, secret: secret, want: want, content: content)
        }
        task?.resume()
    }

    /// GET /push/peek?all=1: every fresh notice not yet handed to this device (kept 10 minutes here for a burst). Only the
    /// notice of exactly this push is used (message id, tag or call id): never a guess at another message of the chat.
    private func peekAll(id: String, secret: String, want: PeekMatch, content: UNMutableNotificationContent) {
        if let hit = PeekCache.find(want) { finish(apply(hit, to: content)); return }
        // the server that is live today reads the secret only from &k= in this mode
        guard let url = Self.peekURL(["all": "1", "id": id, "k": secret]) else { finish(content); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(secret, forHTTPHeaderField: "X-Push-Secret")
        task = URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let answer = try? JSONDecoder().decode(PeekAnswer.self, from: data) {
                PeekCache.add(answer.notices)
                if let hit = PeekCache.find(want) {
                    self.finish(self.apply(hit, to: content))
                    return
                }
            }
            self.finish(content)
        }
        task?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        task?.cancel()
        if let best { finish(best) }
    }

    private func apply(_ n: PeekNotice, to content: UNMutableNotificationContent) -> UNMutableNotificationContent {
        let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = n.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { content.title = title }
        if !body.isEmpty { content.body = body }
        // one stack per chat in Notification Center, as WhatsApp (a locked chat has none: it stays unnamed)
        if let c = n.conversation_id, !c.isEmpty { content.threadIdentifier = c }
        return content
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }

    /// The server's address: the same TFAPIBase build setting as the app.
    static func peekURL(_ query: [String: String]) -> URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TFAPIBase") as? String) ?? ""
        let base = raw.isEmpty ? "https://app.tradeflor.com/api" : raw
        guard var c = URLComponents(string: base.hasSuffix("/") ? base + "push/peek" : base + "/push/peek") else { return nil }
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url
    }
}

/// What this phone learned about the server: once one message was read by its id, a 404 means "must not be shown" and
/// the older notices way is not tried again.
enum PeekServer {
    private static let key = "tf.peek.byMessage"
    static var supportsMessagePeek: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { if newValue { UserDefaults.standard.set(true, forKey: key) } }
    }
}

/// One notice of GET /push/peek?all=1 (server PushNotice).
struct PeekNotice: Codable, Equatable {
    var title: String
    var body: String
    var tag: String?
    var conversation_id: String?
    var message_id: String?
    var kind: String?
    var call_id: String?
    /// When this phone fetched it (not sent by the server).
    var fetched: Date?
}

struct PeekAnswer: Decodable {
    let notices: [PeekNotice]
}

/// Which notice a push is about. The push's identifier is its apns-collapse-id: the message id for a message, the call id
/// for a call, the notice's tag (or its hash) for anything else.
struct PeekMatch {
    let identifier: String
    let kind: String
    let callID: String?

    func matches(_ n: PeekNotice) -> Bool {
        if !kind.isEmpty, kind.hasPrefix("call") {
            guard let c = callID, !c.isEmpty else { return false }
            return n.call_id == c && (n.kind ?? "") == kind
        }
        if let m = n.message_id, !m.isEmpty, m == identifier { return true }
        if let t = n.tag, !t.isEmpty, t == identifier { return true }
        return false
    }
}

/// Notices fetched by this extension, kept a few minutes in its own container: the server gives each notice to a device
/// once, and a burst of pushes (several messages at once) is often answered by the first fetch.
enum PeekCache {
    private static var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tf-peek.json")
    }

    static func load() -> [PeekNotice] {
        guard let file, let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([PeekNotice].self, from: data)) ?? []
    }

    static func add(_ fresh: [PeekNotice], now: Date = Date()) {
        var list = load().filter { now.timeIntervalSince($0.fetched ?? .distantPast) < 600 }
        for var n in fresh {
            n.fetched = now
            list.append(n)
        }
        if list.count > 80 { list.removeFirst(list.count - 80) }
        guard let file, let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Exactly this push's notice, or nothing (never the newest of the same chat: in a burst that put one message's
    /// text under another's push).
    static func find(_ want: PeekMatch) -> PeekNotice? {
        load().last { want.matches($0) }
    }
}

/// The alert subscription's id and secret, which the app also keeps in a keychain group shared with this extension
/// (readable after the first unlock, so a locked phone still shows the text).
enum SharedPushKeys {
    static let service = "com.tradeflor.ios.push.shared"

    static func load() -> (id: String, secret: String)? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TFKeychainGroup") as? String, !group.isEmpty else { return nil }
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "alert", kSecAttrAccessGroup as String: group,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let d = try? JSONDecoder().decode([String: String].self, from: data),
              let id = d["id"], let secret = d["secret"], !id.isEmpty, !secret.isEmpty else { return nil }
        return (id, secret)
    }
}
