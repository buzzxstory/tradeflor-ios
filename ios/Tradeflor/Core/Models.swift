import Foundation

struct Session: Codable, Equatable {
    let token: String
    let userID: String
    let username: String
}

struct LoginResponse: Decodable {
    let token: String
    let user_id: String
}

struct UnverifiedResponse: Decodable {
    let user_id: String?
}

/// Mirrors `ConversationSummary` in desktop/src/shared/api/types.ts (only the fields this screen needs).
struct ConversationSummary: Decodable, Identifiable, Hashable {
    let conversation_id: String
    let peer_id: String
    let peer_username: String
    let peer_display_name: String?
    let peer_avatar_id: String?
    let last_message: String
    let last_message_at: Int64
    let last_message_mine: Bool
    let unread_count: Int
    let last_message_kind: String?
    var last_file_type: String? = nil
    var last_duration_ms: Int64? = nil
    var last_message_status: String? = nil
    var last_call_state: String? = nil
    var disappear_secs: Int? = nil

    var id: String { conversation_id }

    var title: String {
        if let n = peer_display_name, !n.isEmpty { return n }
        return peer_username
    }

    /// Server sends unix milliseconds or seconds depending on the field's age; treat large values as ms.
    var lastDate: Date? { serverDate(last_message_at) }
}

/// Unix seconds or milliseconds (the server uses both in different places) to a Date.
func serverDate(_ v: Int64) -> Date? {
    guard v > 0 else { return nil }
    return Date(timeIntervalSince1970: v > 100_000_000_000 ? Double(v) / 1000 : Double(v))
}

/// Mirrors `Message` in desktop/src/shared/api/types.ts (the fields the chat screen uses).
struct Message: Decodable, Identifiable, Equatable {
    let id: String
    let conversation_id: String
    let sender_id: String
    let kind: String
    let body: String
    let seq: Int64
    let created_at: Int64
    let edited_at: Int64?
    let deleted_at: Int64?
    let client_key: String?
    let file_name: String?
    let file_id: String?
    let file_mime: String?
    let audio_id: String?
    let mime_type: String?
    let waveform: String?
    let reactions: String?
    let reply_to_id: String?
    let reply_sender_id: String?
    let mentions: String?
    let reply_snippet: String?
    let forwarded: Bool?
    let expires_at: Int64?
    let signal: String?
    let views: Int?
    let comments: CommentSummary?
    /// Chat Lock: the server sends only this stub for a locked chat on a device that has not unlocked it.
    let locked: Bool?
    var isSealed: Bool { locked == true }
    /// View once (server c1cb2e1): opened one time by each recipient, then gone (410).
    let view_once: Bool?
    let viewed_at: Int64?
    let view_gone: Bool?

    /// {"emoji": [userID, ...]} -> [(emoji, count, mine)] in a stable order.
    /// Remembered by (me, reactions JSON): every row read it 2-3 times per redraw, each a JSON decode.
    func reactionList(me: String) -> [Reaction] {
        guard let r = reactions, !r.isEmpty else { return [] }
        let key = me + "|" + r
        Self.reactionLock.lock()
        let hit = Self.reactionMemo[key]
        Self.reactionLock.unlock()
        if let hit { return hit }
        guard let d = r.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String]].self, from: d) else { return [] }
        let out = map.filter { !$0.value.isEmpty }
            .map { Reaction(emoji: $0.key, count: $0.value.count, mine: $0.value.contains(me)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
        Self.reactionLock.lock()
        if Self.reactionMemo.count > 1000 { Self.reactionMemo.removeAll(keepingCapacity: true) }
        Self.reactionMemo[key] = out
        Self.reactionLock.unlock()
        return out
    }
    private static let reactionLock = NSLock()
    private static var reactionMemo: [String: [Reaction]] = [:]
    let duration_ms: Int64?
    let delivered_at: Int64?
    let read_at: Int64?

    var date: Date? { serverDate(created_at) }
    var isDeleted: Bool { (deleted_at ?? 0) > 0 }
}

/// One live event from /ws: {"type": "...", "conversation_id": "...", "data": {...}}.
struct LiveEnvelope: Decodable {
    let type: String
    let conversation_id: String?
}

struct LiveMessageEvent: Decodable {
    let data: Message
}

struct TicketResponse: Decodable {
    let ticket: String
}

/// Mirrors `StatusPost` in desktop/src/shared/api/api.ts.
struct StatusPost: Decodable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let kind: String // image | video | voice | text
    let mime: String?
    let caption: String?
    let group_id: String?
    let duration_ms: Int64?
    let created_at: Int64
    let expires_at: Int64
    let seen: Bool
    let views: Int?
    let poster: Bool?
    let text: String?
    /// The quick reaction I already sent to this status (someone else's).
    var my_reaction: String? = nil
    let style: String?
    let music: String?

    var date: Date? { serverDate(created_at) }
}

/// One person's (or group's) statuses in the feed.
struct StatusGroup: Decodable, Identifiable, Equatable {
    let user_id: String
    let username: String
    let mine: Bool?
    let group_id: String?
    let group_name: String?
    let can_post: Bool?
    let posts: [StatusPost]
    let all_seen: Bool
    let latest: Int64

    var id: String { group_id.map { "g:" + $0 } ?? user_id }
    var isMine: Bool { mine ?? false }
    var title: String {
        if let g = group_name, !g.isEmpty { return g }
        return username
    }
}

struct StatusViewerEntry: Decodable, Identifiable {
    let user_id: String
    let username: String
    let viewed_at: Int64
    /// The quick reaction this viewer sent, if any.
    var reaction: String? = nil
    var id: String { user_id }
}

struct Profile: Decodable, Equatable {
    let user_id: String
    let username: String
    let display_name: String
    let bio: String
    let avatar_id: String
}

struct LinkedDevice: Decodable, Identifiable {
    let id: String
    let device: String
    let created_at: Int64
    let last_seen_at: Int64?
    let current: Bool?
    // Linked Devices V2 (server aa69255): the name the owner gave it, which client ("browser" | "desktop" | "ios"),
    // the machine ("iPhone", "Windows", "Mac"...), the browser, and whether it holds a live connection right now.
    let label: String?
    let app: String?
    let platform: String?
    let browser: String?
    let connected: Bool?
}

struct Reaction: Hashable {
    let emoji: String
    let count: Int
    let mine: Bool
}

/// Mirrors `IdentityCard` (desktop/src/shared/api/api.ts): who a PIN or @username belongs to, and how I relate to them.
struct IdentityCard: Decodable, Equatable {
    let user_id: String
    let username: String
    let display_name: String
    let avatar_id: String
    let pin: String
    let relation: String? // self | contact | requested | incoming | none
    let needs_setup: Bool?

    var title: String { display_name.isEmpty ? username : display_name }
}

struct ContactRequest: Decodable, Identifiable {
    let id: String
    let from_user_id: String
    let from_username: String
    let created_at: Int64
}

/// Mirrors `Group` (desktop/src/shared/api/types.ts): the fields the groups list and a group chat need.
struct GroupSummary: Decodable, Identifiable, Hashable {
    let conversation_id: String
    let name: String
    let avatar_id: String?
    let member_count: Int
    let my_role: String?
    let can_send: Bool
    let unread_count: Int
    let last_message: String
    let last_message_kind: String?
    let last_message_at: Int64
    let last_sender_name: String?
    // the newest message's details, as the server sends them (GET /groups, messaging/groups.go; website types.ts Group), all optional
    var last_message_sender: String? = nil
    var last_message_id: String? = nil
    /// for my own newest message: "sent", or "read" once every other member has read up to it (no "delivered" in groups)
    var last_message_status: String? = nil
    var last_duration_ms: Int64? = nil
    var last_file_type: String? = nil

    var id: String { conversation_id }
    var lastDate: Date? { serverDate(last_message_at) }

    /// The groups list's second line as a private chat's (website chatPreview, b6c3ae8 / 63f2616): the same fields, with
    /// "mine" worked out from the sender. Only for ChatRow's preview helpers; opening a group still uses asConversation.
    func previewConversation(me: String) -> ConversationSummary {
        var c = ConversationSummary(conversation_id: conversation_id, peer_id: "", peer_username: name, peer_display_name: name,
                                    peer_avatar_id: avatar_id, last_message: last_message, last_message_at: last_message_at,
                                    last_message_mine: !me.isEmpty && last_message_sender == me, unread_count: unread_count,
                                    last_message_kind: last_message_kind)
        c.last_file_type = last_file_type
        c.last_duration_ms = last_duration_ms
        c.last_message_status = last_message_status
        return c
    }

    /// A group opens in the same chat screen as a private chat.
    var asConversation: ConversationSummary {
        ConversationSummary(conversation_id: conversation_id, peer_id: "", peer_username: name, peer_display_name: name,
                            peer_avatar_id: avatar_id, last_message: last_message, last_message_at: last_message_at,
                            last_message_mine: false, unread_count: unread_count, last_message_kind: last_message_kind)
    }
}

struct GroupMember: Decodable, Identifiable {
    let user_id: String
    let username: String
    let display_name: String?
    var id: String { user_id }
    var title: String { (display_name?.isEmpty == false ? display_name : nil) ?? username }
}


struct CommentSummary: Decodable, Equatable {
    let count: Int
}
