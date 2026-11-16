import SwiftUI

/// Links that open inside the app (website features/identity/link.ts, groups/InviteJoin.tsx, connect/flashTarget.ts):
/// - tradeflor://chat/<conversation>[/message/<id>]  (Copy Message Link)
/// - tradeflor://… and https://app.tradeflor.com/… : ?id=PIN, ?connect=code, /join/…, /g/…, mutual and event links
/// The https links open the app only when tapped inside it (universal links need a paid Apple developer account);
/// tradeflor:// links open it from anywhere.
@MainActor
final class DeepLinks: ObservableObject {
    static let shared = DeepLinks()
    struct Pending: Identifiable { let id = UUID(); let target: FlashTarget }
    @Published var pending: Pending?

    /// true when the link was handled here.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        if url.scheme == "tradeflor" {
            if url.host == "chat" {
                let parts = url.pathComponents.filter { $0 != "/" }
                if let conv = parts.first { LocalNotifier.shared.tappedConversation = conv; return true }
                return false
            }
            // tradeflor://join/x, tradeflor://?id=123 ... read as the website link
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let host = c?.host ?? ""
            c?.scheme = "https"
            c?.host = "app.tradeflor.com"
            c?.path = host.isEmpty ? (c?.path ?? "") : "/" + host + (c?.path ?? "")
            guard let web = c?.url else { return false }
            return open(web.absoluteString)
        }
        if url.host == "app.tradeflor.com" { return open(url.absoluteString) }
        return false
    }

    private func open(_ text: String) -> Bool {
        guard let t = FlashTarget.parse(text) else { return false }
        pending = Pending(target: t)
        return true
    }
}

/// The result sheet of a link: person, group, event... (the same screen as a scanned QR).
struct DeepLinkSheet: View {
    let target: FlashTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScanResultView(target: target) { chat in
                dismiss()
                LocalNotifier.shared.tappedConversation = chat.conversation_id
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("chat.close") { dismiss() } } }
        }
        .tfColorScheme()
    }
}
