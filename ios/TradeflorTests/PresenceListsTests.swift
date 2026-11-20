import XCTest
@testable import Tradeflor

/// Last seen and online with lists (owner request 2026-11-20: a special list of who sees me online).
final class PresenceListsTests: XCTestCase {
    func testOldAnswerHasNoLists() throws {
        let p = try JSONDecoder().decode(PresencePrivacy.self, from: Data(#"{"last_seen":"contacts","online":"same"}"#.utf8))
        XCTAssertNil(p.online_only)
        XCTAssertEqual(LastSeenPrivacyView.summary(p), NSLocalizedString("ls.contacts", comment: ""))
    }

    func testListsAreRead() throws {
        let raw = #"{"last_seen":"except","online":"only","last_seen_except":["a"],"online_only":["b","c"]}"#
        let p = try JSONDecoder().decode(PresencePrivacy.self, from: Data(raw.utf8))
        XCTAssertEqual(p.last_seen_except, ["a"])
        XCTAssertEqual(p.online_only?.count, 2)
        XCTAssertTrue(LastSeenPrivacyView.summary(p).contains("2"))
    }
}
