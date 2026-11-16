import Foundation

/// Group permissions (backend messaging.GroupPermissions, snake_case JSON).
struct GrpPermissions: Codable, Equatable {
    var allow_chat: Bool
    var allow_media: Bool
    var allow_reactions: Bool
    var members_can_invite: Bool
    var signal_permission: String // owner_only | owner_admins | all_members
    var chat_permission: String   // everyone | admins_only | restricted

    var dict: [String: Any] {
        ["allow_chat": allow_chat, "allow_media": allow_media, "allow_reactions": allow_reactions,
         "members_can_invite": members_can_invite, "signal_permission": signal_permission, "chat_permission": chat_permission]
    }
}

/// The full group as GET /groups/{id} describes it to me (types.ts Group).
struct GrpInfo: Decodable {
    let conversation_id: String
    let name: String
    let description: String
    let privacy: String
    let avatar_id: String?
    let verified: Bool?
    let handle: String?
    let slow_mode: Int?
    let join_approval: Bool?
    let comments: Bool?
    let owner_id: String
    let permissions: GrpPermissions?
    let member_count: Int
    let history_visible_to_new_members: Bool?
    let muted_until: Int64?
    let my_role: String?
    let can_invite: Bool?

    var isOwner: Bool { my_role == "owner" }
    var isAdmin: Bool { my_role == "owner" || my_role == "admin" }
    var isMuted: Bool { (muted_until ?? 0) > Int64(Date().timeIntervalSince1970) }
}

/// One row of the groups list with the extra fields the list shows (types.ts Group).
struct GrpListExtra: Decodable {
    let conversation_id: String
    let verified: Bool?
    let unread_mentions: Int?
    let locked: Bool?
}

struct GrpMember: Decodable, Identifiable {
    let user_id: String
    let username: String
    let display_name: String?
    let avatar_id: String?
    let role: String
    let active: Bool?
    let muted_until: Int64?
    var id: String { user_id }
    var title: String { (display_name?.isEmpty == false ? display_name : nil) ?? username }
    var isMuted: Bool { (muted_until ?? 0) > Int64(Date().timeIntervalSince1970) }
}

struct GrpBan: Decodable, Identifiable {
    let user_id: String
    let username: String
    let created_at: Int64
    var id: String { user_id }
}

struct GrpInvite: Decodable, Identifiable {
    let id: String
    let created_at: Int64
    let expires_at: Int64?
    let max_uses: Int?
    let uses: Int
}

struct GrpJoinRequest: Decodable, Identifiable {
    let user_id: String
    let username: String
    let display_name: String?
    let created_at: Int64
    var id: String { user_id }
}

struct GrpAudit: Decodable, Identifiable {
    let id: Int64
    let actor_id: String
    let action: String
    let target_user_id: String?
    let detail: String?
    let created_at: Int64
}

struct GrpMediaStats: Decodable {
    let photos: Int?
    let videos: Int?
    let files: Int?
    let voice: Int?
    let links: Int?
    let polls: Int?
}

struct GrpDiscover: Decodable, Identifiable {
    let handle: String
    let name: String
    let description: String?
    let member_count: Int
    let has_avatar: Bool
    let verified: Bool?
    let needs_approval: Bool?
    let already_member: Bool?
    var id: String { handle }
}

struct GrpInvitePreview: Decodable {
    let name: String
    let `public`: Bool?
    let needs_approval: Bool?
    let request_pending: Bool?
    let member_count: Int
    let has_avatar: Bool
    let already_member: Bool?
    let conversation_id: String?
}

struct GrpJoinResult: Decodable {
    let conversation_id: String
    let pending: Bool?
}
