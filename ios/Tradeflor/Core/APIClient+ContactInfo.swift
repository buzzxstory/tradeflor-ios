import Foundation

// Contact info V3 (website features/profile/ContactInfo.tsx, db83951): groups in common, one page of a chat's shared media,
// and "Clear chat" (server messaging/hides.go: my view only, on all my devices; nothing is deleted on the server).

/// GET /users/{id}/common-groups: the groups I share with someone, as far as I may already know they are there.
struct CommonGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatar_id: String?
    let member_count: Int
}

enum ClearChatError: Error {
    /// 404: I am not (or no longer) in this conversation.
    case notMember
}

extension APIClient {
    func civ3CommonGroups(token: String, userID: String) async throws -> [CommonGroup] {
        try await list(CommonGroup.self, "users/\(userID)/common-groups", token: token)
    }

    /// One page of a conversation's shared items, newest first. category: media | links | files | voice;
    /// `before`: the seq of the oldest item already shown.
    func civ3MediaPage(token: String, conversationID: String, category: String, before: Int64?, limit: Int) async throws -> [Message] {
        var path = "conversations/\(conversationID)/media?category=\(category)&limit=\(limit)"
        if let before { path += "&before=\(before)" }
        return try await list(Message.self, path, token: token)
    }

    /// "Clear chat": every message leaves my view (all my devices get the "hidden" update). Returns how many were cleared.
    func civ3ClearChat(token: String, conversationID: String) async throws -> Int {
        let (data, http) = try await send(request("conversations/\(conversationID)/clear", method: "POST", token: token, body: [:]))
        if http.statusCode == 404 { throw ClearChatError.notMember }
        try check(http, data)
        struct Out: Decodable { let cleared: Int? }
        return (try? JSONDecoder().decode(Out.self, from: data))?.cleared ?? 0
    }
}
