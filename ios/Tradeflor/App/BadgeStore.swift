import SwiftUI

extension Notification.Name {
    /// A chat was deleted from the list on this phone (from inside the chat): the list re-reads its hidden chats.
    static let tfHiddenChatsChanged = Notification.Name("tf.hidden.chats.changed")
}

/// Counts for the tab bar badges (website MobileTabBar): unread chats, unread groups.
@MainActor
final class BadgeStore: ObservableObject {
    static let shared = BadgeStore()
    @Published var chats = 0
    @Published var groups = 0
    /// Unread messages in the counted chats / groups: the number on the app icon (WhatsApp shows messages there).
    @Published var chatMessages = 0
    @Published var groupMessages = 0

    /// The one rule for what counts in a badge (tab bar and app icon): a chat that is unread and that the person can see and
    /// has not silenced. Archived, muted, locked, blocked and deleted-from-the-list chats never count, so the number can
    /// always be cleared from a row that is on screen.
    nonisolated static func counts(unread: Bool, archived: Bool, muted: Bool, locked: Bool, blocked: Bool, hidden: Bool) -> Bool {
        unread && !archived && !muted && !locked && !blocked && !hidden
    }

    /// "Delete chat" hides a chat on this phone until a newer message: kept per account (a second account on the same phone
    /// has its own list).
    nonisolated static func hiddenKey(_ userID: String) -> String { "tf.hiddenChats." + userID }

    /// Removes every account's hidden-chat list (sign-out, revoked session) and the old single-account key.
    nonisolated static func forgetHidden() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k == "tf.hiddenChats" || k.hasPrefix("tf.hiddenChats.") { d.removeObject(forKey: k) }
    }
}
