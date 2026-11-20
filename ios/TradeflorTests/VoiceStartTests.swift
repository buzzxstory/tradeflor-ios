import XCTest
@testable import Tradeflor

/// A voice note must start at once on the first tap (owner, 2026-11-20: a website note showed a spinner before playing).
final class VoiceStartTests: XCTestCase {
    func testFormatPicksThePlayer() {
        XCTAssertTrue(VoicePlayer.isNative("audio/mp4"))
        XCTAssertTrue(VoicePlayer.isNative("audio/aac"))
        XCTAssertTrue(VoicePlayer.isNative("audio/x-m4a"))
        XCTAssertFalse(VoicePlayer.isNative("audio/webm;codecs=opus"))
        XCTAssertFalse(VoicePlayer.isNative("audio/ogg"))
        XCTAssertFalse(VoicePlayer.isNative(nil))
    }

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tradeflor/Features/Chat/Voice.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sources not reachable") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The web player page is loaded once (not a new page per note), website notes are prefetched too, and the web player
    /// is warmed when such a note comes on screen.
    func testWebPlayerStaysWarm() throws {
        let s = try source()
        XCTAssertFalse(s.contains("loadHTMLString(html"), "a new page per note reloads WebKit on every tap")
        XCTAssertFalse(s.contains("loadHTMLString(\"\""), "stopping must not unload the player page")
        XCTAssertTrue(s.contains("if !Self.isNative(message.mime_type) { warmWeb() }"))
        XCTAssertTrue(s.contains("hasOrLoadsVoice(audioID: audioID)"))
    }
}
