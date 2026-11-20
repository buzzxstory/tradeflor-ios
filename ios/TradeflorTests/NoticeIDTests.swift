import XCTest
@testable import Tradeflor

/// The notice identifier must equal the server's apns-collapse-id (backend apns.go NoticeCollapseID).
final class NoticeIDTests: XCTestCase {
    func testLongTagIsHashedLikeTheServer() {
        let tag = "joinreq|grp_0f8e3c1a-2b4d-4e6f-8a9b-1c2d3e4f5a6b|9f959fcd-d563-4ac2-9634-51af1b8e7ae9"
        XCTAssertEqual(NoticeID.collapse(tag), "n-bec86e1ac4fc25b7b958431c5e62e30f")
    }

    func testShortPlainTagIsKept() {
        XCTAssertEqual(NoticeID.collapse("contact|abc-123"), "contact|abc-123")
    }

    func testOtherCharactersAreHashed() {
        XCTAssertTrue(NoticeID.collapse("flash request 1").hasPrefix("n-"))
        XCTAssertEqual(NoticeID.collapse("flash request 1").count, 34)
    }
}
