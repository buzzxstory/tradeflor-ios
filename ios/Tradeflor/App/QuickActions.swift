import SwiftUI
import UIKit

/// Home Screen quick actions (press and hold the app icon), as WhatsApp: Search, New Chat, Camera, My QR code.
/// The items are static (project.yml, UIApplicationShortcutItems); a press arrives through the scene delegate below and
/// the Chats screen acts on it.
@MainActor
final class QuickActions: ObservableObject {
    static let shared = QuickActions()

    enum Action: String {
        case search = "com.tradeflor.ios.search"
        case newChat = "com.tradeflor.ios.newchat"
        case camera = "com.tradeflor.ios.camera"
        case myQR = "com.tradeflor.ios.myqr"
    }

    /// The action waiting for the Chats screen (taken there, then cleared).
    @Published var pending: Action?

    /// true when the item is one of ours.
    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let a = Action(rawValue: item.type) else { return false }
        pending = a
        return true
    }
}

/// The scene delegate SwiftUI uses with the app's own scene: it only passes the quick action on (a cold launch brings it in
/// the connection options, a running app in performActionFor).
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in QuickActions.shared.handle(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in completionHandler(QuickActions.shared.handle(shortcutItem)) }
    }
}

/// Camera from the Home Screen: the photo just taken goes to the chat picked here (as WhatsApp's camera). The camera itself
/// is presented by the Chats screen before this sheet (CameraPicker closes its own presentation).
struct QuickSendSheet: View {
    let token: String
    let chats: [ConversationSummary]
    let photo: UIImage
    /// The chat the photo was sent to (the list opens it).
    let sent: (ConversationSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                if failed {
                    Text("chat.action.failed").foregroundStyle(Theme.danger)
                }
                Section {
                    ForEach(chats, id: \.conversation_id) { c in
                        Button { send(photo, to: c) } label: {
                            Text(c.title).foregroundStyle(Theme.text)
                        }
                        .disabled(sending)
                    }
                }
            }
            .navigationTitle(Text("quick.camera.sendto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
            .overlay { if sending { ProgressView() } }
        }
        .tfColorScheme()
    }

    private func send(_ img: UIImage, to c: ConversationSummary) {
        guard let jpeg = ImagePrep.jpeg(from: img, hd: false) else { failed = true; return }
        sending = true
        failed = false
        Task {
            do {
                _ = try await APIClient.shared.sendImage(token: token, conversationID: c.conversation_id, jpeg: jpeg, caption: "",
                                                         key: UUID().uuidString)
                sending = false
                dismiss()
                sent(c)
            } catch {
                sending = false
                failed = true
            }
        }
    }
}
