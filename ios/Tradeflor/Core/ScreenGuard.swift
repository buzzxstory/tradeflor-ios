import SwiftUI
import UIKit

/// "Block screenshots" for a chat (owner request 2026-11-20). iOS cannot stop the screenshot itself; what it can do is hide
/// the app from it: while a protected chat is on screen the app's window is drawn inside a secure text field's layer, which
/// iOS leaves out of screenshots, screen recordings and AirPlay mirroring (they show black). A screenshot or a recording
/// that starts there is also reported, and the chat gets "X took a screenshot" (server contract proposed to the main engineer:
/// no_screenshots in conversations/settings, POST conversations/screenshot).
///
/// Only public API: the window's layer is moved under the field's own canvas layer once, the first time a protected chat
/// opens; after that the field's isSecureTextEntry is the switch. If the canvas cannot be found (a future iOS), nothing is
/// moved and the chat still reports screenshots.
@MainActor
final class ScreenGuard {
    static let shared = ScreenGuard()

    /// The protected chats on screen now (a chat over another, a chat and its media viewer).
    private(set) var protected: Set<String> = []
    private var field: UITextField?
    /// false in unit tests: the set logic only, nothing installed in the test host's window.
    private let installs: Bool

    init(installs: Bool = true) { self.installs = installs }

    var isOn: Bool { !protected.isEmpty }
    /// The window could be put under the secure layer (false: screenshots cannot be hidden on this iOS).
    var canHide: Bool { field != nil }

    func protect(_ conversationID: String) {
        protected.insert(conversationID)
        apply()
    }

    func release(_ conversationID: String) {
        protected.remove(conversationID)
        apply()
    }

    /// Sign-out: nothing stays protected.
    func releaseAll() {
        protected = []
        apply()
    }

    private func apply() {
        guard installs else { return }
        if isOn && field == nil { install() }
        field?.isSecureTextEntry = isOn
    }

    private func install() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.windowLevel == .normal && !$0.isHidden && $0.rootViewController != nil }),
              let host = window.layer.superlayer else { return }
        let f = UITextField()
        f.isSecureTextEntry = true
        f.isUserInteractionEnabled = false
        f.isAccessibilityElement = false
        window.addSubview(f)
        f.layoutIfNeeded()
        // the canvas whose drawing iOS keeps out of captures while the entry is secure
        guard let canvas = f.subviews.first(where: { String(describing: type(of: $0)).contains("Canvas") })?.layer else {
            f.removeFromSuperview()
            return
        }
        host.addSublayer(f.layer)
        canvas.addSublayer(window.layer)
        field = f
    }
}

extension ChatSettings {
    /// Screenshots blocked in this chat (absent on a server from before the feature).
    var blocksScreenshots: Bool { no_screenshots ?? false }
}

extension APIClient {
    func setNoScreenshots(token: String, conversationID: String, on: Bool) async throws {
        _ = try await postJSON("conversations/settings", token: token, body: ["conversation_id": conversationID, "no_screenshots": on])
    }

    /// A screenshot (or a screen recording) happened while this protected chat was open: the chat is told.
    func reportScreenshot(token: String, conversationID: String) async {
        _ = try? await postJSON("conversations/screenshot", token: token, body: ["conversation_id": conversationID])
    }
}

/// A screen presented over a protected chat (its photos, videos, documents, a view-once): protected too, under its own key,
/// since presenting it makes the chat itself "disappear" for SwiftUI (which releases the chat's key).
struct ScreenGuardCover: ViewModifier {
    let id: String
    let on: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { if on { ScreenGuard.shared.protect(id + "#cover") } }
            .onDisappear { ScreenGuard.shared.release(id + "#cover") }
    }
}
