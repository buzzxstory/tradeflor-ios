import Foundation

// Edit a message (server 86beee5): POST /messages/{id}/edit {Body}. Only my own plain text message, within 15 minutes;
// the server answers 409 when it is too late, 403 when it may not be edited. Everyone sees the new text live (the
// usual "message" event carries it, with edited_at).
extension APIClient {
    func editMessage(token: String, messageID: String, body: String) async throws -> Message {
        let id = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        let data = try await postJSON("messages/\(id)/edit", token: token, body: ["Body": body])
        do { return try JSONDecoder().decode(Message.self, from: data) } catch { throw APIError.decoding }
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
