import Foundation

// Edit a message (server 86beee5): POST /messages/{id}/edit {Body}. Only my own plain text message, within 15 minutes;
// the server answers 409 when it is too late, 403 when it may not be edited. Everyone sees the new text live (the
// usual "message" event carries it, with edited_at).
extension APIClient {
    func editMessage(token: String, messageID: String, body: String, mentions: [[String: Any]] = []) async throws -> Message {
        let id = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        var payload: [String: Any] = ["Body": body]
        if !mentions.isEmpty { payload["Mentions"] = mentions }
        let data = try await postJSON("messages/\(id)/edit", token: token, body: payload)
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
    }
}

/// Attachment files kept on this phone (Caches), so a picture already downloaded is never asked for again: not after
/// leaving the chat, and not after the app went to the background (iOS empties NSCache when memory runs low). Only
/// files up to 8 MB (pictures and thumbnails); cleared on sign-out with the lists (ListCache.clear).
enum FileDiskCache {
    static let maxBytes = 8 << 20

    private static var dir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tf-files", isDirectory: true)
    }

    /// "fileID/t" -> a file name that is safe on disk.
    private static func url(_ key: String) -> URL? {
        let safe = String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        return dir?.appendingPathComponent(safe)
    }

    static func load(_ key: String) -> Data? {
        guard let u = url(key) else { return nil }
        return try? Data(contentsOf: u)
    }

    /// The whole folder may hold this much; the oldest files go first when it grows past it.
    static let totalLimit: Int64 = 150 << 20
    private static var savesSinceTrim = 0
    private static let trimLock = NSLock()

    static func save(_ key: String, _ data: Data) {
        guard data.count <= maxBytes, let d = dir, let u = url(key) else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        trimLock.lock()
        savesSinceTrim += 1
        let due = savesSinceTrim >= 25
        if due { savesSinceTrim = 0 }
        trimLock.unlock()
        if due { DispatchQueue.global(qos: .utility).async { trim() } }
    }

    /// Size of the copy kept for `key` (0 when there is none).
    static func size(_ key: String) -> Int64 {
        guard let u = url(key), let n = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return 0 }
        return Int64(n)
    }

    /// Deletes the copy kept for `key` (Clear chat / Free up storage).
    static func remove(_ key: String) {
        if let u = url(key) { try? FileManager.default.removeItem(at: u) }
    }

    /// Keeps the folder under `totalLimit`: oldest files (by modification date) are removed first.
    static func trim() {
        guard let d = dir,
              let items = try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = items.map {
            let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return ($0, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > totalLimit else { return }
        entries.sort { $0.date < $1.date }
        for e in entries where total > totalLimit {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }

    static func clear() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }
}

extension APIClient {
    /// A photo I just sent shows at once from my own copy (web seedPhoto): no spinner after the upload.
    func seedFile(fileID: String, data: Data) {
        let key = "\(fileID)/t"
        avatarCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        FileDiskCache.save(key, data)
    }

    /// What is already here, without a request (a cached picture shows at once, no spinner): memory first, then the
    /// copy kept on this phone (which is then remembered in memory again).
    func cachedFile(fileID: String, thumb: Bool) -> Data? {
        let key = "\(fileID)/\(thumb ? "t" : "f")"
        if let hit = avatarCache.object(forKey: key as NSString) { return hit as Data }
        guard let kept = FileDiskCache.load(key) else { return nil }
        avatarCache.setObject(kept as NSData, forKey: key as NSString, cost: kept.count)
        return kept
    }
}

enum ChatEdit {
    static let window: Int64 = 15 * 60

    /// Seconds since 1970, whether the server sent seconds or milliseconds.
    static func secs(_ t: Int64) -> Int64 { t > 100_000_000_000 ? t / 1000 : t }

    static func canEdit(_ m: Message, me: String) -> Bool {
        guard m.sender_id == me, m.kind == "text", !m.isDeleted, m.forwarded != true,
              (m.signal ?? "").isEmpty, (m.expires_at ?? 0) == 0 || (m.expires_at ?? 0) > Int64(Date().timeIntervalSince1970) else { return false }
        return Int64(Date().timeIntervalSince1970) - secs(m.created_at) < window
    }

    /// The message names me (or everyone), or answers me.
    static func mentions(_ m: Message, me: String) -> Bool {
        if m.reply_sender_id == me { return true }
        guard let raw = m.mentions, let d = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return false }
        return list.contains { ($0["user_id"] as? String) == me || ($0["user_id"] as? String) == "all" }
    }
}


/// Mentions from the @usernames written in a group message (server Mentions: [{user_id, username}]).
enum MentionsBuilder {
    static func build(_ text: String, members: [GroupMember]) -> [[String: Any]] {
        guard text.contains("@") else { return [] }
        var out: [[String: Any]] = []
        var seen: Set<String> = []
        let byName = Dictionary(members.map { ($0.username.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for word in text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "!" || $0 == "?" }) where word.hasPrefix("@") {
            let name = word.dropFirst().lowercased()
            if let m = byName[name], !seen.contains(m.user_id) {
                seen.insert(m.user_id)
                out.append(["user_id": m.user_id, "username": m.username])
            }
        }
        return out
    }
}


/// The last Chats and Groups lists of this account, kept on this phone (Caches) and shown at once on the next launch or
/// tab visit, then refreshed from the server -- as WhatsApp does. Only for the signed-in session (a hash of its token
/// names the file); another session's copy is never read, and a sign-out leaves it unreadable.
enum ListCache {
    private static var dir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tf-lists", isDirectory: true)
    }

    private static func tag(_ token: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in token.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    /// Chat Lock: the chats the server says are locked. The last-message text of these is never written to disk.
    private static let lockedLock = NSLock()
    private static var _locked: Set<String>?
    static func noteLocked(_ ids: Set<String>, token: String) {
        lockedLock.lock(); _locked = ids; lockedLock.unlock()
        if let d = try? JSONEncoder().encode(Array(ids)) { save("locked", token: token, d) }
        // lists already on disk lose the text of a chat that has just been locked
        for kind in ["conversations", "groups"] { if let d = load(kind, token: token) { save(kind, token: token, d) } }
    }
    private static func lockedIDs(token: String) -> Set<String> {
        lockedLock.lock(); let hit = _locked; lockedLock.unlock()
        if let hit { return hit }
        guard let d = load("locked", token: token), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Set(a)
    }
    private static func sealed(_ kind: String, token: String, _ data: Data) -> Data {
        guard kind == "conversations" || kind == "groups" else { return data }
        let ids = lockedIDs(token: token)
        guard !ids.isEmpty, var arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return data }
        for i in arr.indices {
            if let c = arr[i]["conversation_id"] as? String, ids.contains(c) { arr[i]["last_message"] = "" }
        }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? data
    }

    static func save(_ kind: String, token: String, _ data: Data) {
        guard let dir else { return }
        let data = sealed(kind, token: token, data)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // one copy per kind: an older session's file goes
        if let old = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in old where f.hasPrefix(kind + "-") && f != "\(kind)-\(tag(token)).json" {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        try? data.write(to: dir.appendingPathComponent("\(kind)-\(tag(token)).json"), options: [.atomic, .completeFileProtection])
    }

    static func load(_ kind: String, token: String) -> Data? {
        guard let dir, !token.isEmpty else { return nil }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(kind)-\(tag(token)).json")) else { return nil }
        return sealed(kind, token: token, d)
    }

    static func conversations(token: String) -> [ConversationSummary] {
        guard let d = load("conversations", token: token) else { return [] }
        return (((try? JSONDecoder().decode([LenientItem<ConversationSummary>]?.self, from: d)) ?? nil) ?? []).compactMap(\.value)
    }

    static func groups(token: String) -> [GroupSummary] {
        guard let d = load("groups", token: token) else { return [] }
        struct Lenient: Decodable {
            let value: GroupSummary?
            init(from decoder: Decoder) throws { value = try? GroupSummary(from: decoder) }
        }
        return ((try? JSONDecoder().decode([Lenient].self, from: d)) ?? []).compactMap(\.value)
    }

    static func clear() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        FileDiskCache.clear()
    }
}
