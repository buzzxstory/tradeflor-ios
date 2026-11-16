import SwiftUI

/// Tap a member's picture or name in a group (or in the members list) to see their profile, like Telegram: picture, name,
/// @username, PIN card details, and Message / Add contact (the same screen as a scanned QR, by username).
struct MemberProfileRef: Identifiable {
    let userID: String
    let username: String
    var id: String { userID }
}

struct MemberProfileSheet: View {
    let member: MemberProfileRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScanResultView(target: .username(member.username)) { chat in
                dismiss()
                // open the private chat with them (the Chats tab opens it)
                LocalNotifier.shared.tappedConversation = chat.conversation_id
            }
            .navigationTitle(Text("@" + member.username))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .tfColorScheme()
    }
}
