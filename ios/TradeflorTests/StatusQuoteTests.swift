import XCTest
@testable import Tradeflor

/// A reaction or reply to a status, drawn as WhatsApp's quote card (owner request 2026-11-20).
final class StatusQuoteTests: XCTestCase {
    private func decode(_ extra: String) throws -> Message {
        let json = #"{"id":"m1","conversation_id":"dm_1","sender_id":"a","kind":"text","body":"😂","seq":1,"created_at":1"# + extra + "}"
        return try JSONDecoder().decode(Message.self, from: Data(json.utf8))
    }

    func testQuoteIsRead() throws {
        let m = try decode(#","status_quote":{"id":"s1","kind":"image","owner_id":"b","react":true}"#)
        XCTAssertEqual(m.status_quote?.id, "s1")
        XCTAssertEqual(m.status_quote?.react, true)
        let r = try decode(#","status_quote":{"id":"s2","kind":"text","owner_id":"b"}"#)
        XCTAssertNil(r.status_quote?.react, "a reply has no react")
    }

    func testPlainMessageHasNoQuote() throws {
        XCTAssertNil(try decode("").status_quote)
    }

    func testKindIcons() {
        XCTAssertEqual(StatusQuoteBubble.icon("image"), "photo")
        XCTAssertEqual(StatusQuoteBubble.icon("voice"), "mic")
        XCTAssertEqual(StatusQuoteBubble.icon("text"), "text.bubble")
    }
}
