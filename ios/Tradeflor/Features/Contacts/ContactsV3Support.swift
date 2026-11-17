import SwiftUI

// Contacts V3 (website ContactsPanel.tsx, 2026-11-17): what the one search field holds, the "Add & Chat" call shared by
// the Contacts screen and the QR result, and the profiles (picture, name, About) of the people in my contacts.

/// What the search field holds: a PIN (digits), an @username, or a name that filters my own contacts (parseQuery).
enum ContactQuery: Equatable {
    case pin(String), username(String), name(String)

    var value: String {
        switch self {
        case .pin(let v), .username(let v), .name(let v): return v
        }
    }

    var isName: Bool { if case .name = self { return true } else { return false } }

    static func parse(_ raw: String) -> ContactQuery? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v != "@" else { return nil }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        let digits = v.replacingOccurrences(of: "[\\s#-]", with: "", options: .regularExpression)
        if matches(digits, "^[0-9]+$") {
            return matches(digits, "^[1-9][0-9]{3,11}$") ? .pin(digits) : .name(v)
        }
        let u = v.hasPrefix("@") ? String(v.dropFirst()) : v
        if matches(u, "^[A-Za-z0-9._]{3,25}$") { return .username(u) }
        return .name(v)
    }
}

/// The answer of one "Add & Chat" (save-and-open, then the chat's summary for navigation).
enum AddAndChatOutcome {
    case opened(ConversationSummary)
    /// saved, but the chat did not open: Retry is safe (the call is idempotent)
    case savedNoChat
    case failed(message: String, canRetry: Bool)
}

enum AddAndChat {
    static func run(token: String, userID: String) async -> AddAndChatOutcome {
        do {
            let r = try await APIClient.shared.ctSaveAndOpen(token: token, userID: userID)
            guard r.chat_error == nil, let cid = r.conversation_id, !cid.isEmpty else { return .savedNoChat }
            if let s = await APIClient.shared.ctSummary(token: token, conversationID: cid) { return .opened(s) }
            if let s = await APIClient.shared.ctOpenChat(token: token, userID: r.user_id) { return .opened(s) }
            return .savedNoChat
        } catch SaveAndOpenError.blocked {
            return .failed(message: NSLocalizedString("cv3.err.blocked", comment: ""), canRetry: false)
        } catch SaveAndOpenError.notFound {
            return .failed(message: NSLocalizedString("fc.nomatch", comment: ""), canRetry: false)
        } catch SaveAndOpenError.yourself {
            return .failed(message: NSLocalizedString("cv3.you", comment: ""), canRetry: false)
        } catch SaveAndOpenError.rateLimited {
            return .failed(message: NSLocalizedString("cv3.err.rate", comment: ""), canRetry: false)
        } catch APIError.rateLimited {
            return .failed(message: NSLocalizedString("cv3.err.rate", comment: ""), canRetry: false)
        } catch {
            return .failed(message: NSLocalizedString("cv3.err.add", comment: ""), canRetry: true)
        }
    }
}

/// The public profiles of my contacts (users/{id}/profile, as MemberProfileSheet): picture, display name and About.
/// Loaded once per person while the app runs.
@MainActor
final class ContactProfiles: ObservableObject {
    static let shared = ContactProfiles()
    @Published private(set) var byID: [String: Profile] = [:]
    private var loading: Set<String> = []

    func profile(_ userID: String) -> Profile? { byID[userID] }

    func load(token: String, userID: String) async {
        guard !token.isEmpty, byID[userID] == nil, !loading.contains(userID) else { return }
        loading.insert(userID)
        defer { loading.remove(userID) }
        guard let d = try? await APIClient.shared.getJSON("users/\(userID)/profile", token: token),
              let p = try? JSONDecoder().decode(Profile.self, from: d) else { return }
        byID[userID] = p
    }
}

/// The Contacts V3 palette (78-contacts-v3.css): navy/teal surfaces and turquoise accents at night, white cards by day.
enum CV3 {
    static let cyan = Theme.dyn(0x35E6F2, 0x0097A5)
    static let round = Theme.dyn(0x03161E, 0xFFFFFF, 0.72, 1)
    static let roundBorder = Theme.dyn(0x35E6F2, 0x0097A5, 0.35, 0.35)
    static let ghostBorder = Theme.dyn(0xFFFFFF, 0x0F2533, 0.14, 0.12)
    static let field = Theme.dyn(0x03121A, 0xFFFFFF, 0.8, 1)
    static let fieldBorder = Theme.dyn(0x35E6F2, 0x0097A5, 0.38, 0.38)
    static let tile = Theme.dyn(0x03161E, 0xFFFFFF, 0.72, 1)
    static let tileBorder = Theme.dyn(0x35E6F2, 0x0097A5, 0.28, 0.28)
    static let card = Theme.dyn(0x04222C, 0xFFFFFF, 0.82, 1)
    static let cardBorder = Theme.dyn(0x35E6F2, 0x0097A5, 0.45, 0.45)
    static let title = Theme.dyn(0xFFFFFF, 0x0B2530)
    static let sub = Theme.dyn(0xB8CCD5, 0x3C5668)
    static let small = Theme.dyn(0xA9C0CA, 0x5F7686)
    static let about = Theme.dyn(0xC9D8DE, 0x3C5668)
    static let muted = Theme.dyn(0x93AAB4, 0x5F7686)
    static let error = Theme.dyn(0xFFB4B4, 0xD8404A)
    static let rule = Theme.dyn(0x3C8CA5, 0x1E5A78, 0.2, 0.12)
    static let onCyan = Theme.hex(0x032029)
    static let primary = LinearGradient(colors: [Theme.hex(0xA8FBFF), Theme.hex(0x22CFE0)], startPoint: .top, endPoint: .bottom)
    static let ground = LinearGradient(colors: [Theme.dyn(0x072230, 0xF3F9FB), Theme.dyn(0x041722, 0xF3F9FB), Theme.dyn(0x03121B, 0xF3F9FB)],
                                       startPoint: .top, endPoint: .bottom)
    static let glow = Theme.dyn(0x128CA0, 0x128CA0, 0.2, 0)

    /// The screen's ground: the dark navy gradient with a teal glow at the top (day: the light ground).
    static var background: some View {
        ZStack {
            ground
            RadialGradient(colors: [glow, .clear], center: .top, startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
    }

    /// The pill button "Add & Chat" / "Message" (ct3-primary).
    static func primaryLabel(_ text: String, icon: String? = nil, wide: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 16, weight: .semibold)) }
            Text(text).font(.system(size: 15.5, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(onCyan)
        .padding(.horizontal, 18)
        .frame(maxWidth: wide ? .infinity : nil)
        .frame(height: 44)
        .background(primary, in: Capsule())
    }
}
