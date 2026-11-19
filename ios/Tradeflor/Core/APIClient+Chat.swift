import Foundation

/// Conversation extras: polls, votes, signals, group comments and pins, link previews, batch delete / hide.
extension APIClient {
    func chCreatePoll(token: String, groupID: String, question: String, options: [String], multiple: Bool) async throws -> Message {
        try decode(Message.self, try await postJSON("groups/\(groupID)/polls", token: token,
                                                    body: ["Question": question, "Options": options, "Multiple": multiple],
                                                    key: UUID().uuidString.lowercased()))
    }

    func chVote(token: String, messageID: String, options: [Int]) async throws -> Message {
        try decode(Message.self, try await postJSON("messages/vote", token: token, body: ["MessageID": messageID, "Options": options]))
    }

    /// A trading signal is an ordinary message with a Signal object.
    func chSendSignal(token: String, conversationID: String, symbol: String, direction: String, entry: String,
                      stopLoss: String, takeProfit: String) async throws -> Message {
        let signal: [String: Any] = ["symbol": symbol, "direction": direction, "entry": entry, "stop_loss": stopLoss, "take_profit1": takeProfit]
        return try decode(Message.self, try await postJSON("messages", token: token,
                                                           body: ["ConversationID": conversationID, "Body": "", "ReplyToID": "", "Signal": signal],
                                                           key: UUID().uuidString.lowercased()))
    }

    /// Text with @mentions (groups): offsets are in UTF-16 code units, as the website counts them.
    func chSendText(token: String, conversationID: String, body: String, replyTo: String, mentions: [[String: Any]], key: String) async throws -> Message {
        var payload: [String: Any] = ["ConversationID": conversationID, "Body": body, "ReplyToID": replyTo]
        if !mentions.isEmpty { payload["Mentions"] = mentions }
        return try decode(Message.self, try await postJSON("messages", token: token, body: payload, key: key))
    }

    func chComments(token: String, groupID: String, postID: String) async throws -> [GroupComment] {
        try await list(GroupComment.self, "groups/\(groupID)/posts/\(postID)/comments", token: token)
    }

    func chAddComment(token: String, groupID: String, postID: String, body: String, replyTo: String) async throws {
        _ = try await postJSON("groups/\(groupID)/posts/\(postID)/comments", token: token, body: ["Body": body, "ReplyToID": replyTo])
    }

    func chDeleteComment(token: String, groupID: String, commentID: String) async throws {
        _ = try await postJSON("groups/\(groupID)/comments/\(commentID)/delete", token: token, body: [:])
    }

    func chPin(token: String, groupID: String, messageID: String, pin: Bool) async throws {
        _ = try await postJSON("groups/\(groupID)/\(pin ? "pin" : "unpin")", token: token, body: ["MessageID": messageID])
    }

    func chGroupPins(token: String, groupID: String) async -> [GroupPinRef] {
        struct G: Decodable { let pins: [GroupPinRef]?; let my_role: String? }
        guard let g = try? decode(G.self, try await getJSON("groups/\(groupID)", token: token)) else { return [] }
        return g.pins ?? []
    }

    /// `ok` is false when the group could not be read (no connection, or no longer a member): the other values are then only
    /// defaults and must not replace what the chat already knows.
    func chGroupRole(token: String, groupID: String) async -> (role: String, canSend: Bool, canSendMedia: Bool, canPostSignals: Bool, memberCount: Int,
                                                               comments: Bool, canReact: Bool, ok: Bool, gone: Bool) {
        struct G: Decodable {
            let my_role: String?; let can_send: Bool?; let can_send_media: Bool?; let can_post_signals: Bool?
            let member_count: Int?; let comments: Bool?; let can_react: Bool?
        }
        let data: Data
        do {
            data = try await getJSON("groups/\(groupID)", token: token)
        } catch APIError.refused(_) {
            return ("member", false, false, false, 0, false, false, false, true) // 403: not (or no longer) a member
        } catch APIError.server(status: 404) {
            return ("member", false, false, false, 0, false, false, false, true) // the group is gone
        } catch {
            return ("member", true, true, false, 0, false, true, false, false)
        }
        guard let g = try? decode(G.self, data) else {
            return ("member", true, true, false, 0, false, true, false, false)
        }
        return (g.my_role ?? "member", g.can_send ?? true, g.can_send_media ?? true, g.can_post_signals ?? false, g.member_count ?? 0,
                g.comments ?? false, g.can_react ?? true, true, false)
    }

    func chLinkPreview(token: String, url: String) async -> LinkPreviewData? {
        let q = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        guard let d = try? await getJSON("link-preview?url=\(q)", token: token),
              let p = try? JSONDecoder().decode(LinkPreviewData.self, from: d), !(p.title ?? "").isEmpty || !(p.description ?? "").isEmpty else { return nil }
        return p
    }

    func chLinkImage(token: String, path: String) async -> Data? {
        guard let url = URL(string: AppConfig.apiBase.absoluteString + path) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let out = try? await send(req), out.1.statusCode == 200 else { return nil }
        return out.0
    }

    /// Delete for everyone, up to 100 at once.
    func chDeleteBatch(token: String, ids: [String]) async throws {
        _ = try await postJSON("messages/delete-batch", token: token, body: ["MessageIDs": ids])
    }

    func chHideBatch(token: String, ids: [String]) async throws {
        _ = try await postJSON("messages/hide", token: token, body: ["MessageIDs": ids])
    }

    func chSendDocument(token: String, conversationID: String, data: Data, fileName: String, mime: String, caption: String, key: String) async throws -> Message {
        try await sendImage(token: token, conversationID: conversationID, jpeg: data, caption: caption, key: key, fileName: fileName, mime: mime)
    }
}

struct GroupComment: Decodable, Identifiable {
    let id: String
    let post_id: String?
    let sender_id: String
    let body: String
    let reply_to_id: String?
    let created_at: Int64
}

struct GroupPinRef: Decodable, Identifiable {
    let message_id: String
    let seq: Int64
    let kind: String
    let text: String
    var file_id: String? = nil
    var id: String { message_id }
}

struct LinkPreviewData: Decodable {
    let url: String?
    let site: String?
    let title: String?
    let description: String?
    let image: String?
}
