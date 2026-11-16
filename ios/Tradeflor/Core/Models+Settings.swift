import Foundation

/// GET /account/private: private account details (only the owner sees them).
struct PrivateAccount: Decodable {
    let full_name: String
    let email: String
    let email_verified: Bool
    let phone: String
    let phone_verified: Bool
    let country: String
    let created_at: Int64
    var needs_real_name: Bool? = nil
    var needs_email: Bool? = nil
}

/// GET /calls/history row.
struct CallHistoryItem: Decodable, Identifiable {
    let call_id: String
    let conversation_id: String
    let peer_id: String
    let direction: String
    let status: String
    let reason: String?
    let created_at: Int64
    let duration_ms: Int64
    var id: String { call_id }
}

/// GET /admin/me: the signed-in person's admin role ("" = none).
struct AdminMe: Decodable {
    let role: String
    let users: Bool?
    let content: Bool?
}

struct AdminUser: Decodable, Identifiable {
    let id: String
    let username: String
    let display_name: String
    let avatar_id: String
    let pin: String
    let email: String
    let email_verified: Bool
    let phone: String
    let country: String
    let created_at: Int64
    let last_active_at: Int64
    let status: String
    let type: String
    let role: String?
    let online: Bool
    let full_name: String?
    let suspend_reason: String?
}

struct AdminUsersPage: Decodable {
    let users: [AdminUser]?
    let total: Int
    let page: Int
    let limit: Int
}

struct AdminOverview: Decodable {
    let total: Int
    let today: Int
    let last_7_days: Int
    let last_30_days: Int
    let active_24h: Int
    let active_7d: Int
    let online: Int
    let verified: Int
    let unverified: Int
    let pending: Int
    let suspended: Int
    let official_live: Int
    let official_views: Int
}

struct AdminOfficialPost: Decodable, Identifiable {
    let id: String
    let kind: String
    let title: String?
    let caption: String?
    let state: String?
    let created_at: Int64
    let views: Int
}

/// GET /calendar/saved row with its reminder.
struct SavedEventFull: Decodable, Identifiable {
    let event_key: String
    let title: String
    let currency: String?
    let country_code: String?
    let impact: String?
    let event_at: Int64
    let remind_minutes: Int?
    var id: String { event_key }
}

/// GET /status/{id}/viewers row.
struct StatusViewerRow: Decodable, Identifiable {
    let user_id: String
    let username: String
    let viewed_at: Int64
    var id: String { user_id }
}

/// GET /identity/me with the extra card details the identity page shows.
struct StIdentity: Decodable {
    let user_id: String
    let username: String
    let display_name: String
    let pin: String
    let early_member: Bool?
    let original_pin_length: Int?
    let member_since: Int64?
    let username_change_available_at: Int64?
    var avatar_id: String? = nil
    var pin_class: String? = nil
    var country: String? = nil
}
