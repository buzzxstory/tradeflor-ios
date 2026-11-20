import XCTest
@testable import Tradeflor

/// Block screenshots in a chat (owner request 2026-11-20).
final class ScreenGuardTests: XCTestCase {
    @MainActor
    func testProtectionFollowsTheChatsOnScreen() {
        let g = ScreenGuard(installs: false)
        XCTAssertFalse(g.isOn)
        g.protect("dm_a")
        XCTAssertTrue(g.isOn)
        g.protect("dm_b") // a second protected chat over the first
        g.release("dm_a")
        XCTAssertTrue(g.isOn, "still on while another protected chat is on screen")
        g.release("dm_b")
        XCTAssertFalse(g.isOn)
        g.release("dm_b") // a second release is harmless
        XCTAssertFalse(g.isOn)
    }

    @MainActor
    func testSignOutReleasesEverything() {
        let g = ScreenGuard(installs: false)
        g.protect("dm_a"); g.protect("grp_b")
        g.releaseAll()
        XCTAssertFalse(g.isOn)
    }

    func testSettingIsReadAndOldServersMeanOff() throws {
        let old = try JSONDecoder().decode(ChatSettings.self, from: Data(#"{"disappear_secs":0,"restricted":false}"#.utf8))
        XCTAssertFalse(old.blocksScreenshots)
        let on = try JSONDecoder().decode(ChatSettings.self, from: Data(#"{"disappear_secs":0,"restricted":false,"no_screenshots":true}"#.utf8))
        XCTAssertTrue(on.blocksScreenshots)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sources not reachable") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The chat protects itself, releases on leaving, and reports screenshots and recordings.
    func testChatWiring() throws {
        let s = try source("Tradeflor/Features/Chat/ChatView.swift")
        XCTAssertTrue(s.contains("ScreenGuard.shared.protect(chat.conversation_id)"))
        XCTAssertTrue(s.contains("ScreenGuard.shared.release(chat.conversation_id)"))
        XCTAssertTrue(s.contains("UIApplication.userDidTakeScreenshotNotification"))
        XCTAssertTrue(s.contains("UIScreen.capturedDidChangeNotification"))
        // only public API: no private layer keys
        let g = try source("Tradeflor/Core/ScreenGuard.swift")
        XCTAssertFalse(g.contains("disableUpdateMask"))
    }
}
