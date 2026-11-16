import SwiftUI

/// Counts for the tab bar badges (website MobileTabBar): unread chats, unread groups.
@MainActor
final class BadgeStore: ObservableObject {
    static let shared = BadgeStore()
    @Published var chats = 0
    @Published var groups = 0
}
