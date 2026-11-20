import XCTest
@testable import Tradeflor

/// IOS-PUSH-1 (no "Call ended" on the phone that answered) and IOS-PUSH-3 (a notice of another account opens no chat).
final class NotificationRoutingTests: XCTestCase {
    func testCallEndedNoticeForACallAnsweredHere() {
        let info: [AnyHashable: Any] = ["aps": ["alert": ["title": "Tradeflor", "body": "Call ended"]],
                                        "tf": ["id": "sub1", "kind": "call-ended", "call_id": "c1"]]
        XCTAssertTrue(NotificationRouting.isCallEndedNotice(identifier: "c1", info: info, forCalls: ["c1"]))
        XCTAssertFalse(NotificationRouting.isCallEndedNotice(identifier: "c1", info: info, forCalls: ["c2"]))
        // no call_id in tf: the identifier (= the call id, apns-collapse-id) decides
        let bare: [AnyHashable: Any] = ["tf": ["kind": "call-ended"]]
        XCTAssertTrue(NotificationRouting.isCallEndedNotice(identifier: "c1", info: bare, forCalls: ["c1"]))
        // a "Missed call" or "Incoming call" with the same id is not touched by this rule
        let missed: [AnyHashable: Any] = ["tf": ["kind": "call-missed", "call_id": "c1"]]
        XCTAssertFalse(NotificationRouting.isCallEndedNotice(identifier: "c1", info: missed, forCalls: ["c1"]))
    }

    func testNoticeOfAnotherAccountOpensNothing() {
        let mine: [String: Any] = ["tf": ["id": "subB", "conversation_id": "dm_1"]]
        let theirs: [String: Any] = ["tf": ["id": "subA", "conversation_id": "dm_1"]]
        XCTAssertTrue(NotificationRouting.belongsToCurrentAccount(mine, knownSubscriptionIDs: ["subB"]))
        XCTAssertFalse(NotificationRouting.belongsToCurrentAccount(theirs, knownSubscriptionIDs: ["subB"]))
        // signed in, registration not answered yet: nothing known, a remote notice is not routed
        XCTAssertFalse(NotificationRouting.belongsToCurrentAccount(theirs, knownSubscriptionIDs: []))
        // a local notice (made by this account; all removed at sign-out) and an old payload without id: as before
        XCTAssertTrue(NotificationRouting.belongsToCurrentAccount(["conversation_id": "dm_1"], knownSubscriptionIDs: []))
        XCTAssertTrue(NotificationRouting.belongsToCurrentAccount(["tf": ["conversation_id": "dm_1"]], knownSubscriptionIDs: []))
    }
}
