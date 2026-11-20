import Foundation
import Security
import UserNotifications

/// Notification Service Extension (WhatsApp way): Apple's push carries no name and no word of a message ("Tradeflor / New
/// message"); before iOS shows it, this extension asks Tradeflor's own server, on the phone, for the real text
/// (GET /push/peek with the subscription id and secret the app was given at registration) and writes it into the notice.
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
        let want = PeekMatch(identifier: request.identifier,
                             conversation: tf["conversation_id"] as? String,
                             kind: (tf["kind"] as? String) ?? "",
                             callID: tf["call_id"] as? String)
        // what an earlier wake-up already fetched (the server hands each notice out once per device)
        if let hit = PeekCache.find(want) {
            finish(apply(hit, to: content))
            return
        }
        guard let keys = SharedPushKeys.load(), let url = Self.peekURL(id: keys.id, secret: keys.secret) else {
            finish(content)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
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
        // one stack per chat in Notification Center, as WhatsApp
        if let c = n.conversation_id, !c.isEmpty { content.threadIdentifier = c }
        return content
    }

    private func finish(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }

    /// The server's address: the same TFAPIBase build setting as the app.
    static func peekURL(id: String, secret: String) -> URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TFAPIBase") as? String) ?? ""
        let base = raw.isEmpty ? "https://app.tradeflor.com/api" : raw
        guard var c = URLComponents(string: base.hasSuffix("/") ? base + "push/peek" : base + "/push/peek") else { return nil }
        c.queryItems = [URLQueryItem(name: "all", value: "1"), URLQueryItem(name: "id", value: id), URLQueryItem(name: "k", value: secret)]
        return c.url
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
    let conversation: String?
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

    static func find(_ want: PeekMatch, now: Date = Date()) -> PeekNotice? {
        let list = load()
        if let exact = list.last(where: { want.matches($0) }) { return exact }
        // a message push whose id the notice does not carry: the newest notice of the same chat, fetched just now
        guard want.kind.isEmpty, let c = want.conversation, !c.isEmpty else { return nil }
        return list.last { $0.conversation_id == c && ($0.kind ?? "").isEmpty && now.timeIntervalSince($0.fetched ?? .distantPast) < 120 }
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
