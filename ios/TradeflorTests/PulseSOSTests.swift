import XCTest
import CoreLocation
@testable import Tradeflor

/// Pulse SOS after the safety audit (2026-11-21): the sender's wording comes only from what the server knows (the web's
/// sosDeliveryText / recipientStateText, desktop/tests/pulseSOS.test.ts), the emergency numbers are a list with the device's
/// country first and never one guessed number, and the key and push routing follow PULSE_CROSS_PLATFORM_HANDOFF.md.
@MainActor
final class PulseSOSTests: XCTestCase {
    typealias S = PulseSOSRules

    private func row(_ id: String, live: Bool = false, push: String? = nil, delivered: Bool = false, seen: Bool = false, responding: Bool = false) -> PulseAlertRecipient {
        PulseAlertRecipient(user_id: id, live_at: live ? 1 : nil, push_status: push, push_at: push == nil ? nil : 1,
                            delivered_at: delivered ? 2 : nil, seen_at: seen ? 3 : nil, responding_at: responding ? 4 : nil)
    }

    private func emergency(_ rows: [PulseAlertRecipient]) -> PulseEmergency {
        PulseEmergency(id: "a1", circle_id: "c1", circle_title: "Coffee", circle_live: true, user_id: "me", kind: "sos", reason: "Accident",
                       created_at: 0, state: "active", resolved_at: nil, lat: nil, lon: nil, accuracy: nil, location_at: nil,
                       recipients: rows, total: rows.count, live: rows.filter { $0.live_at != nil }.count, push_sent: nil,
                       delivered: rows.filter { $0.delivered_at != nil }.count, seen: rows.filter { $0.seen_at != nil }.count,
                       responding: rows.filter { $0.responding_at != nil }.count)
    }

    func testDeliveryNeverSaysEveryoneWasAlerted() {
        let e = emergency([row("a", live: true, delivered: true, seen: true), row("b", push: "sent"), row("c", push: "notifications_off")])
        let d = S.deliveryText(e, responding: [])
        XCTAssertEqual(d.line, "Sent to 2 of 3 · 1 received · 1 opened")
        XCTAssertEqual(d.detail, "2 not confirmed yet · 1 can't be notified right now")
        XCTAssertFalse((d.line + d.detail).lowercased().contains("everyone"))
    }

    func testDeliveryBeforeTheServerAnsweredAndWithNobody() {
        XCTAssertEqual(S.deliveryText(nil, responding: []).line, "SOS created — notifying your circle…")
        let none = S.deliveryText(emergency([]), responding: [])
        XCTAssertEqual(none.line, "Nobody can receive this SOS")
        XCTAssertFalse(none.detail.isEmpty)
    }

    func testRespondingIsNamedButIsNotHelpArrived() {
        let e = emergency([row("a", delivered: true, responding: true), row("b", delivered: true)])
        XCTAssertEqual(S.deliveryText(e, responding: ["Rami"]).detail, "Rami is responding")
        XCTAssertEqual(S.deliveryText(e, responding: ["Rami", "Lea"]).detail, "Rami and Lea are responding")
        XCTAssertEqual(S.deliveryText(e, responding: ["Rami", "Lea", "Omar", "Sara"]).detail, "Rami, Lea and 2 more are responding")
    }

    func testRecipientStateTakesTheStrongestEvidence() {
        XCTAssertEqual(S.recipientState(row("a", push: "sent", delivered: true, seen: true, responding: true)), "Responding")
        XCTAssertEqual(S.recipientState(row("a", push: "sent", delivered: true, seen: true)), "Opened")
        XCTAssertEqual(S.recipientState(row("a", push: "sent", delivered: true)), "Received")
        XCTAssertEqual(S.recipientState(row("a", live: true)), "Sent to their open app")
        XCTAssertEqual(S.recipientState(row("a", push: "sent")), "Notification sent, not confirmed")
        XCTAssertEqual(S.recipientState(row("a", push: "partial")), "Notification sent, not confirmed")
        XCTAssertEqual(S.recipientState(row("a", push: "notifications_off")), "Has notifications off")
        XCTAssertEqual(S.recipientState(row("a", push: "no_device")), "No device to notify")
        XCTAssertEqual(S.recipientState(row("a", push: "failed")), "Notification failed")
    }

    func testEmergencyNumbersAreAListWithTheDeviceCountryFirst() {
        let lb = S.lines(region: "LB")
        XCTAssertEqual(lb.prefix(3).map(\.number), ["112", "140", "175"])
        XCTAssertTrue(lb.prefix(3).allSatisfy(\.local))
        XCTAssertEqual(S.lines(region: "GB").first?.number, "999")
        XCTAssertEqual(S.lines(region: "CA").first?.number, "911")
        XCTAssertEqual(S.lines(region: "FR").first?.label, "European Union · Emergency")
        let unknown = S.lines(region: "JP")
        XCTAssertFalse(unknown.contains(where: \.local), "no country is assumed")
        XCTAssertEqual(unknown.count, 7, "the whole list, nothing dialled by itself")
        XCTAssertEqual(S.lines(region: nil).count, 7)
    }

    func testKeyIsNewEachTimeAndValid() {
        let a = S.newKey(), b = S.newKey()
        XCTAssertNotEqual(a, b)
        for k in [a, b] {
            XCTAssertTrue((8...64).contains(k.count))
            XCTAssertTrue(k.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        }
    }

    func testAnSOSPushNamesItsAlert() {
        XCTAssertEqual(PulseRouting.alert("pulse-alert-pa_9"), "pa_9")
        XCTAssertNil(PulseRouting.alert("pulse-pc_1"))
        XCTAssertNil(PulseRouting.alert("pulse-alert-"))
    }

    func testTheSnapshotIsOnePositionWithItsTime() {
        let l = CLLocation(coordinate: .init(latitude: 33.89, longitude: 35.5), altitude: 0, horizontalAccuracy: 12, verticalAccuracy: 5,
                           timestamp: Date(timeIntervalSince1970: 1_000))
        let p = SOSCenter.snapshot(l)
        XCTAssertEqual(p["lat"] as? Double, 33.89)
        XCTAssertEqual(p["accuracy"] as? Double, 12)
        XCTAssertEqual(p["measured_at"] as? Int64, 1_000_000)
        XCTAssertEqual(p["source"] as? String, "ios")
    }

    func testAnEmergencyDecodesFromTheServer() throws {
        let json = """
        {"id":"pa_1","circle_id":"pc_1","circle_title":"Coffee","circle_live":false,"user_id":"u1","kind":"sos","reason":"I need help",
         "created_at":1700000000000,"state":"active","lat":33.9,"lon":35.5,"accuracy":20,"location_at":1700000000000,
         "recipients":[{"user_id":"u2","push_status":"sent","push_at":1700000000100,"delivered_at":1700000000200}],
         "total":1,"live":0,"push_sent":1,"delivered":1,"seen":0,"responding":0}
        """
        let e = try JSONDecoder().decode(PulseEmergency.self, from: Data(json.utf8))
        XCTAssertTrue(e.isActive)
        XCTAssertTrue(e.hasPosition)
        XCTAssertEqual(e.circle_live, false)
        XCTAssertEqual(S.recipientState(e.rows[0]), "Received")
    }
}
