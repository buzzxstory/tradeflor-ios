import Foundation
import SwiftUI

/// The "note" over a profile picture (WhatsApp's About note, in TRADEFLOR's look): a short line and an emoji, for a time
/// the person picks, seen by the people they pick. Server contract (proposed to the main engineer, 2026-11-20):
/// GET / PUT / DELETE /me/note, "note" in GET /users/{id}/profile, live event "note".
struct AboutNote: Codable, Equatable {
    var text: String
    var emoji: String
    var audience: String?
    var set_at: Int64?
    /// Unix seconds; 0 or nil = until cleared.
    var expires_at: Int64?

    /// Still to be shown (the server also drops it; a phone that kept it a while hides it on time).
    func isLive(now: Date = Date()) -> Bool {
        guard let e = expires_at, e > 0 else { return !(text.isEmpty && emoji.isEmpty) }
        return Double(e) > now.timeIntervalSince1970 && !(text.isEmpty && emoji.isEmpty)
    }

    /// "2 h left", "until you clear it".
    func timeLeft(now: Date = Date()) -> String {
        guard let e = expires_at, e > 0 else { return NSLocalizedString("note.forever.short", comment: "") }
        let secs = max(0, Double(e) - now.timeIntervalSince1970)
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = secs >= 86_400 ? [.day] : (secs >= 3600 ? [.hour] : [.minute])
        return String(format: NSLocalizedString("note.left", comment: ""), f.string(from: max(60, secs)) ?? "")
    }
}

enum NoteDuration: String, CaseIterable, Identifiable {
    case hour = "1h", eight = "8h", day = "1d", week = "1w", forever
    var id: String { rawValue }
    var label: LocalizedStringKey { LocalizedStringKey("note.d." + rawValue) }
}

enum NoteAudience: String, CaseIterable, Identifiable {
    case everyone, contacts, nobody
    var id: String { rawValue }
    var label: LocalizedStringKey { LocalizedStringKey("note.a." + rawValue) }
    var icon: String {
        switch self {
        case .everyone: return "globe"
        case .contacts: return "person.2"
        case .nobody: return "lock"
        }
    }
}

extension APIClient {
    private struct NoteAnswer: Decodable { let note: AboutNote? }

    func myNote(token: String) async throws -> AboutNote? {
        try decode(NoteAnswer.self, try await getJSON("me/note", token: token, reuseRecent: false)).note
    }

    func setNote(token: String, text: String, emoji: String, duration: NoteDuration, audience: NoteAudience) async throws -> AboutNote? {
        let req = request("me/note", method: "PUT", token: token,
                          body: ["text": text, "emoji": emoji, "duration": duration.rawValue, "audience": audience.rawValue])
        let (data, http) = try await send(req)
        try check(http, data)
        return try decode(NoteAnswer.self, data).note
    }

    func clearNote(token: String) async throws {
        let (data, http) = try await send(request("me/note", method: "DELETE", token: token, body: nil))
        try check(http, data)
    }
}

/// My own note, for the Settings card and My Profile.
@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()
    @Published private(set) var mine: AboutNote?
    /// The server has no notes yet (404): the editor says so instead of failing silently.
    @Published private(set) var unavailable = false

    func load(token: String) async {
        guard !token.isEmpty else { return }
        do {
            mine = try await APIClient.shared.myNote(token: token)
            unavailable = false
        } catch APIError.server(let s) where s == 404 || s == 405 {
            unavailable = true
        } catch {}
    }

    func set(_ n: AboutNote?) { mine = n }

    /// Live "note" event: mine from another device updates the row; anyone's is passed on to the screen showing them.
    @Published private(set) var others: [String: AboutNote?] = [:]
    func changed(userID: String, note: AboutNote?) {
        if AccountGate.isCurrent(account: userID) { mine = note } else { others[userID] = note }
    }

    func forget() { mine = nil; others = [:] }
}

/// The note as a speech bubble over a picture: frosted teal, a turquoise edge, the emoji first, a small tail pointing down.
struct NoteBubble: View {
    let note: AboutNote
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if !note.emoji.isEmpty { Text(note.emoji).font(.system(size: compact ? 12 : 15)) }
                if !note.text.isEmpty {
                    Text(note.text)
                        .font(.system(size: compact ? 11 : 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(compact ? 1 : 2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 4 : 7)
            .background(
                LinearGradient(colors: [Theme.dyn(0x0B4A56, 0xFFFFFF), Theme.dyn(0x062F3A, 0xE9F8F9)], startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(Capsule().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.55, 0.6), lineWidth: 1))
            .shadow(color: Theme.dyn(0x000000, 0x0B5E68, 0.35, 0.15), radius: 6, y: 3)
            // the tail: two little dots, as a thought bubble
            HStack(spacing: 0) {
                Circle().fill(Theme.dyn(0x062F3A, 0xE9F8F9)).overlay(Circle().stroke(Theme.dyn(0x35E6F2, 0x00A8B5, 0.55, 0.6), lineWidth: 1))
                    .frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
                    .offset(x: compact ? -6 : -10, y: 2)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
