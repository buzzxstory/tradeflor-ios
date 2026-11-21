import Foundation

/// A full identity card (GET /identity/users/{id}, /connect/u/{code}): adds member_since and country.
struct IdentityDetail: Decodable, Equatable {
    let user_id: String
    let username: String
    let display_name: String?
    let avatar_id: String?
    let pin: String
    let early_member: Bool?
    let member_since: Int64?
    let country: String?
    let relation: String?
    var pin_class: String? = nil
    /// Contacts V3: I saved them in my contacts (one way, "Add & Chat"; server contacts.go IsSaved).
    var saved: Bool? = nil

    var title: String { (display_name?.isEmpty == false ? display_name : nil) ?? username }
}

struct ContactEntry: Decodable, Identifiable {
    let user_id: String
    let username: String
    let alias: String?
    /// Contacts V3: both sides accepted; false = saved by me only ("Add & Chat"), which I can remove.
    var mutual: Bool? = nil
    var id: String { user_id }
    var title: String { (alias?.isEmpty == false ? alias : nil) ?? username }
}

/// POST contacts/save-and-open (Contacts V3 "Add & Chat"): the contact is saved in MY contacts and the one private chat is given.
struct SaveAndOpenResult: Decodable {
    let user_id: String
    let username: String
    let conversation_id: String?
    let already_saved: Bool?
    let conversation_existed: Bool?
    let can_message: Bool?
    /// saved, but the chat could not be opened (Retry is safe: the call is idempotent)
    let chat_error: String?
}

/// The refusals of save-and-open that the screen words differently (postJSON would fold them into one `refused`).
enum SaveAndOpenError: Error {
    case notFound      // 404: no account, or not visible to me (one neutral message)
    case blocked       // 409: I blocked them
    case yourself      // 400
    case rateLimited   // 429
}

struct SentContactRequest: Decodable, Identifiable {
    let id: String
    let to_user_id: String
    let to_username: String
    let created_at: Int64
}

struct LockState: Decodable {
    struct Lock: Decodable { let conversation_id: String; let hide_previews: Bool? }
    let locks: [Lock]?
    let has_pin: Bool
    let unlocked: Bool?

    func isLocked(_ id: String) -> Bool { (locks ?? []).contains { $0.conversation_id == id } }
}

struct MutualSession: Decodable {
    let id: String
    let token: String?
    let state: String
    let expires_at: Int64
    /// The server's clock when the code was made (a phone with a wrong clock still counts down correctly).
    var server_now: Int64? = nil
}

struct MutualStatus: Decodable {
    let session_id: String
    let state: String
    let expires_at: Int64?
    let role: String?
    let peer: IdentityDetail?
}

struct MutualPeek: Decodable {
    let session_id: String
    let expires_at: Int64?
    let host: IdentityDetail
}

struct PendingMutual: Decodable, Identifiable {
    let session_id: String
    let expires_at: Int64
    let guest: IdentityDetail
    var id: String { session_id }
}

struct Meetup: Decodable, Identifiable {
    let id: String
    let token: String?
    let host_id: String
    let title: String
    let starts_at: Int64
    let expires_at: Int64
    let revoked: Bool?
    let attendees: Int
    let is_host: Bool?
}

struct MeetupPeek: Decodable {
    let meetup: Meetup
    let host: IdentityDetail?
}

/// What a scanned QR or a pasted link is (desktop/src/features/connect/flashTarget.ts). Only TRADEFLOR's own hosts.
enum FlashTarget: Equatable {
    case user(String), mutual(String), meet(String), group(String), pin(String), username(String)

    /// A Pulse Instant Circle QR (https://app.tradeflor.com/?pulse=<code>, TRADEFLOR's hosts only): its code, else nil. The
    /// scanner said "not a Tradeflor code" for these; only a link tapped in the app reached the join preview.
    static func pulseCode(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 600, let u = URLComponents(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host?.lowercased(), ["app.tradeflor.com", "tradeflor.com", "www.tradeflor.com"].contains(host),
              let code = u.queryItems?.first(where: { $0.name == "pulse" })?.value,
              code.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil else { return nil }
        return code
    }

    static func parse(_ text: String) -> FlashTarget? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 600 else { return nil }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        let code = "^[A-Za-z0-9_-]{16,64}$", pin = "^[1-9][0-9]{3,11}$"
        if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
            guard let u = URLComponents(string: t), let host = u.host?.lowercased(),
                  ["app.tradeflor.com", "tradeflor.com", "www.tradeflor.com"].contains(host) else { return nil }
            let q = u.queryItems ?? []
            func one(_ k: String) -> String? { q.first { $0.name == k }?.value.flatMap { matches($0, code) ? $0 : nil } }
            if let c = one("connect") { return .user(c) }
            if let m = one("mutual") { return .mutual(m) }
            if let e = one("meet") { return .meet(e) }
            if let id = q.first(where: { $0.name == "id" })?.value, matches(id, pin) { return .pin(id) }
            let path = u.path
            if matches(path, "^/join/[0-9a-fA-F]{32}/?$") {
                return .group(path.split(separator: "/")[1].lowercased())
            }
            if matches(path, "^/g/[A-Za-z][A-Za-z0-9_]{4,31}/?$") {
                return .group("g:" + path.split(separator: "/")[1].lowercased())
            }
            return nil
        }
        let digits = t.replacingOccurrences(of: "[\\s#-]", with: "", options: .regularExpression)
        if matches(digits, pin) { return .pin(digits) }
        let name = t.hasPrefix("@") ? String(t.dropFirst()) : t
        if matches(name, "^[A-Za-z0-9._]{3,24}$") && matches(name, "[A-Za-z]") { return .username(name) }
        return nil
    }
}
