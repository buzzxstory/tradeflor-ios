import XCTest
@testable import Tradeflor

/// The note over a profile picture (WhatsApp's About note, owner request 2026-11-20).
final class AboutNoteTests: XCTestCase {
    func testProfileWithAndWithoutNote() throws {
        let plain = #"{"user_id":"u1","username":"a","display_name":"A","bio":"","avatar_id":""}"#
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: Data(plain.utf8)).note)
        let with = #"{"user_id":"u1","username":"a","display_name":"A","bio":"","avatar_id":"","note":{"text":"Busy","emoji":"⏳","set_at":1,"expires_at":0}}"#
        let n = try XCTUnwrap(try JSONDecoder().decode(Profile.self, from: Data(with.utf8)).note)
        XCTAssertEqual(n.text, "Busy")
        XCTAssertTrue(n.isLive())
    }

    func testExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AboutNote(text: "x", emoji: "", expires_at: 1_000_100).isLive(now: now))
        XCTAssertFalse(AboutNote(text: "x", emoji: "", expires_at: 999_999).isLive(now: now))
        XCTAssertTrue(AboutNote(text: "x", emoji: "", expires_at: 0).isLive(now: now), "0 = until cleared")
        XCTAssertFalse(AboutNote(text: "", emoji: "", expires_at: 0).isLive(now: now), "an empty note is not shown")
    }

    func testDurationsAndAudiencesMatchTheContract() {
        XCTAssertEqual(NoteDuration.allCases.map(\.rawValue), ["1h", "8h", "1d", "1w", "forever"])
        XCTAssertEqual(NoteAudience.allCases.map(\.rawValue), ["everyone", "contacts", "nobody"])
    }
}
