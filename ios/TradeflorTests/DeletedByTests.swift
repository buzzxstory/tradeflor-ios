import XCTest
@testable import Tradeflor

/// Who deleted a message (owner report 2026-11-20: an admin's deletion showed "You deleted this message" to the sender).
final class DeletedByTests: XCTestCase {
    private func message(sender: String, deletedBy: String?) throws -> Message {
        var json = #"{"id":"m1","conversation_id":"grp_1","sender_id":"\#(sender)","kind":"text","body":"","seq":1,"created_at":1,"deleted_at":5"#
        if let deletedBy { json += #","deleted_by":"\#(deletedBy)""# }
        json += "}"
        return try JSONDecoder().decode(Message.self, from: Data(json.utf8))
    }

    func testAdminDeletionIsNamed() throws {
        let names = ["admin": "Sara"]
        // the sender never reads "You deleted this message" for an admin's deletion
        let toSender = DeletedByTestsHelper.text(try message(sender: "me", deletedBy: "admin"), me: "me", names: names)
        XCTAssertEqual(toSender, String(format: NSLocalizedString("chat.deleted.by.admin", comment: ""), "Sara"))
        // the admin who deleted it
        let toAdmin = DeletedByTestsHelper.text(try message(sender: "ali", deletedBy: "me"), me: "me", names: names)
        XCTAssertEqual(toAdmin, NSLocalizedString("chat.deleted.byme.admin", comment: ""))
    }

    func testOwnDeletionAsBefore() throws {
        XCTAssertEqual(DeletedByTestsHelper.text(try message(sender: "me", deletedBy: nil), me: "me", names: [:]),
                       NSLocalizedString("chat.deleted.you", comment: ""))
        XCTAssertEqual(DeletedByTestsHelper.text(try message(sender: "ali", deletedBy: nil), me: "me", names: [:]),
                       NSLocalizedString("chat.deleted", comment: ""))
    }
}

enum DeletedByTestsHelper {
    static func text(_ m: Message, me: String, names: [String: String]) -> String { ChatView.deletedText(m, me: me, names: names) }
}
