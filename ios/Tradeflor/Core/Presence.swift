import SwiftUI

// Last seen and online, as in WhatsApp (server d4d2e77; website shared/lib/lastSeen.ts, LastSeenPrivacy.tsx):
// online = the app is in front; "last seen today at 4:23 AM" … or nothing when it is hidden or unknown. Never "Offline".

struct PresenceInfo: Decodable {
    let user_id: String?
    let online: Bool?
    let last_seen: Int64?
    let hidden: Bool?
}

struct PresencePrivacy: Codable, Equatable {
    var last_seen: String // everyone | contacts | nobody
    var online: String    // everyone | same
}

extension APIClient {
    /// What I may see of someone: 404 (nil) when nothing is shared with me.
    func presence(token: String, userID: String) async -> PresenceInfo? {
        let id = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let data = try? await getJSON("presence/\(id)", token: token) else { return nil }
        return try? JSONDecoder().decode(PresenceInfo.self, from: data)
    }

    func presencePrivacy(token: String) async throws -> PresencePrivacy {
        let data = try await getJSON("privacy/presence", token: token)
        do { return try JSONDecoder().decode(PresencePrivacy.self, from: data) } catch { throw APIError.decoding }
    }

    func setPresencePrivacy(token: String, _ p: PresencePrivacy) async throws {
        _ = try await postJSON("privacy/presence", token: token, body: ["last_seen": p.last_seen, "online": p.online])
    }
}

enum LastSeen {
    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    /// "last seen today at 4:23 AM", "… yesterday at …", "… Monday at …" (within a week), "… Nov 2 at …" (+ year).
    static func text(_ at: Int64, now: Date = Date()) -> String? {
        guard at > 0 else { return nil }
        let d = Date(timeIntervalSince1970: Double(ChatEdit.secs(at)))
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0
        let t = clock(d)
        if days <= 0 { return String(format: NSLocalizedString("ls.today", comment: ""), t) }
        if days == 1 { return String(format: NSLocalizedString("ls.yesterday", comment: ""), t) }
        let f = DateFormatter()
        if days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            f.setLocalizedDateFormatFromTemplate(cal.component(.year, from: d) == cal.component(.year, from: now) ? "MMMd" : "yMMMd")
        }
        return String(format: NSLocalizedString("ls.on", comment: ""), f.string(from: d), t)
    }

    /// What goes under a name: "online", "last seen …", or nil (show nothing).
    static func line(online: Bool, lastSeen: Int64?, hidden: Bool, now: Date = Date()) -> String? {
        if online { return NSLocalizedString("ls.online", comment: "") }
        if hidden { return nil }
        return lastSeen.flatMap { text($0, now: now) }
    }
}

/// Settings > Privacy > Last seen and online (website LastSeenPrivacy.tsx): saved at once, the old value back on failure.
struct LastSeenPrivacyView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var value: PresencePrivacy?
    @State private var error: String?

    private var token: String { store.session?.token ?? "" }

    var body: some View {
        SettingsPage(title: NSLocalizedString("ls.row", comment: "")) {
            if let v = value {
                group("ls.who.lastseen", [("everyone", "ls.everyone"), ("contacts", "ls.contacts"), ("nobody", "ls.nobody")],
                      v.last_seen) { pick in save(PresencePrivacy(last_seen: pick, online: v.online)) }
                group("ls.who.online", [("everyone", "ls.everyone"), ("same", "ls.same")], v.online) { pick in
                    save(PresencePrivacy(last_seen: v.last_seen, online: pick))
                }
                Text("ls.note").font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(.horizontal, 4)
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.danger) }
            } else if let error {
                Text(error).foregroundStyle(Theme.faint)
            } else {
                ProgressView().tint(Theme.accent).frame(maxWidth: .infinity)
            }
        }
        .task {
            do { value = try await APIClient.shared.presencePrivacy(token: token) } catch {
                self.error = NSLocalizedString("ls.failed", comment: "")
            }
        }
    }

    private func group(_ title: String, _ options: [(String, String)], _ current: String, _ onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TFSectionLabel(text: NSLocalizedString(title, comment: ""))
            TFCard {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        Button { if o.0 != current { onPick(o.0) } } label: {
                            HStack {
                                Text(LocalizedStringKey(o.1)).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: o.0 == current ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(o.0 == current ? Theme.accent : Theme.faint)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(o.0 == current ? [.isSelected] : [])
                        if i < options.count - 1 { Divider().overlay(Theme.borderStrong) }
                    }
                }
            }
        }
    }

    private func save(_ next: PresencePrivacy) {
        let old = value
        value = next
        error = nil
        Task {
            do { try await APIClient.shared.setPresencePrivacy(token: token, next) } catch {
                value = old
                self.error = NSLocalizedString("ls.save.failed", comment: "")
            }
        }
    }

    static func summary(_ p: PresencePrivacy?) -> String {
        guard let p else { return "" }
        let label = NSLocalizedString(p.last_seen == "contacts" ? "ls.contacts" : (p.last_seen == "nobody" ? "ls.nobody" : "ls.everyone"), comment: "")
        // "My contacts, online: Everyone" when online is shared more widely than last seen (website summary())
        if p.online == "everyone" && p.last_seen != "everyone" { return String(format: NSLocalizedString("ls.summary.online", comment: ""), label) }
        return label
    }
}
