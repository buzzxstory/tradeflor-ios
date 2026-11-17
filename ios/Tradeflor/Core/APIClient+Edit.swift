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

extension APIClient {
    /// A photo I just sent shows at once from my own copy (web seedPhoto): no spinner after the upload.
    func seedFile(fileID: String, data: Data) {
        avatarCache.setObject(data as NSData, forKey: "\(fileID)/t" as NSString, cost: data.count)
    }

    /// What is already in memory, without a request (a cached picture shows at once, no spinner).
    func cachedFile(fileID: String, thumb: Bool) -> Data? {
        avatarCache.object(forKey: "\(fileID)/\(thumb ? "t" : "f")" as NSString) as Data?
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

    static func save(_ kind: String, token: String, _ data: Data) {
        guard let dir else { return }
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
        return try? Data(contentsOf: dir.appendingPathComponent("\(kind)-\(tag(token)).json"))
    }

    static func conversations(token: String) -> [ConversationSummary] {
        guard let d = load("conversations", token: token) else { return [] }
        return ((try? JSONDecoder().decode([ConversationSummary]?.self, from: d)) ?? nil) ?? []
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
    }
}
