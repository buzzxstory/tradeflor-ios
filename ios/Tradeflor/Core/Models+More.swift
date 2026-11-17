import Foundation

struct GroupDetail: Decodable {
    let conversation_id: String
    let name: String
    let description: String
    let privacy: String
    let avatar_id: String?
    let handle: String?
    let owner_id: String
    let member_count: Int
    let my_role: String?
    let can_invite: Bool?

    var isAdmin: Bool { my_role == "owner" || my_role == "admin" }
}

struct GroupMemberFull: Decodable, Identifiable {
    let user_id: String
    let username: String
    let display_name: String?
    let avatar_id: String?
    let role: String
    var id: String { user_id }
    var title: String { (display_name?.isEmpty == false ? display_name : nil) ?? username }
}

struct ChatSettings: Decodable {
    let disappear_secs: Int
    let restricted: Bool
}

struct ScheduledMessage: Decodable, Identifiable {
    let id: String
    let conversation_id: String
    let body: String
    let send_at: Int64
    let repeat_rule: String?
    let status: String
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case id, conversation_id, body, send_at, status, reason
        case repeat_rule = "repeat"
    }

    var date: Date { Date(timeIntervalSince1970: Double(send_at)) }
}

struct LivePosition: Decodable, Identifiable {
    let conversation_id: String
    let user_id: String
    let message_id: String
    let lat: Double
    let lon: Double
    let accuracy: Double?
    let until: Int64
    let stopped: Bool?
    var id: String { message_id + user_id }
}

/// A Smart Folder (desktop/src/shared/lib/folderRules.ts): chats added by hand, chats kept out, and optional rules.
struct ChatFolder: Decodable, Identifiable, Hashable {
    struct Condition: Decodable, Hashable {
        let type: String
        let value: String?
        let values: [String]?
        let enabled: Bool?
    }
    struct Rules: Decodable, Hashable {
        let on: Bool
        let match: String?
        let conditions: [Condition]?
    }

    let id: String
    let name: String
    let items: [String]?
    let exclude: [String]?
    let rules: Rules?

    /// Same order as the website: excluded -> out; listed -> in; else the enabled rules (all / any).
    func contains(id cid: String, title: String, unread: Bool) -> Bool {
        if exclude?.contains(cid) == true { return false }
        if items?.contains(cid) == true { return true }
        guard let r = rules, r.on else { return false }
        let active = (r.conditions ?? []).filter { $0.enabled ?? true }
        guard !active.isEmpty else { return false }
        let results = active.map { c -> Bool in
            switch c.type {
            case "kind": return (c.value == "group") == cid.hasPrefix("grp_")
            case "name_contains":
                let t = Self.fold(title)
                return (c.values ?? []).contains { !$0.isEmpty && t.contains(Self.fold($0)) }
            case "in_list": return (c.values ?? []).contains(cid)
            case "unread": return (c.value == "yes") == unread
            default: return false // muted / pinned need prefs the app does not load yet
            }
        }
        return r.match == "any" ? results.contains(true) : !results.contains(false)
    }

    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for (a, b) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي")] { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }
}

struct OfficialPost: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let mime: String?
    let title: String?
    let caption: String?
    let cta_label: String?
    let cta_url: String?
    let created_at: Int64
    let seen: Bool
    let poster: Bool?
    var expires_at: Int64? = nil
}

struct OfficialChannel: Codable {
    let name: String
    let posts: [OfficialPost]?
    let all_seen: Bool
}

struct CalendarEvent: Decodable, Identifiable, Equatable {
    let id: String
    let date_time: String
    let country: String
    let country_code: String
    let currency: String
    let event: String
    let impact: String
    let previous: String?
    let forecast: String?
    let actual: String?

    /// Made once (a new formatter on every read, inside the calendar's sorts and filters, made the page hang).
    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var date: Date? { Self.iso.date(from: date_time) ?? Self.isoFrac.date(from: date_time) }
}

struct SavedEvent: Decodable, Identifiable {
    let event_key: String
    let title: String
    let event_at: Int64
    var id: String { event_key }
}

/// Per-chat preferences (GET /prefs): pinned (newest pin first), muted until, archived, marked unread.
struct ConversationPrefs: Decodable {
    let conversation_id: String
    let pinned_at: Int64?
    let muted_until: Int64?
    let archived: Bool?
    let marked_unread: Bool?

    var pinned: Bool { (pinned_at ?? 0) > 0 }
    var muted: Bool { (muted_until ?? 0) > Int64(Date().timeIntervalSince1970) }
}


/// The last TRADEFLOR Official feed this phone saw (web a67ca84): shown at once on the next start, so the circle never
/// vanishes while the server answers. The posts are the same for every account; only "seen" is mine and the server's
/// answer replaces it a moment later. Posts that have expired since are left out.
enum OfficialFeedCache {
    private static let key = "tf.official.feed"

    static func load() -> OfficialChannel? {
        guard let d = UserDefaults.standard.data(forKey: key), let f = try? JSONDecoder().decode(OfficialChannel.self, from: d) else { return nil }
        let now = Int64(Date().timeIntervalSince1970)
        let posts = (f.posts ?? []).filter { ($0.expires_at ?? 0) == 0 || ($0.expires_at ?? 0) > now }
        return posts.isEmpty ? nil : OfficialChannel(name: f.name, posts: posts, all_seen: f.all_seen)
    }

    static func keep(_ f: OfficialChannel) {
        if (f.posts ?? []).isEmpty { UserDefaults.standard.removeObject(forKey: key); return }
        if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: key) }
    }
}
