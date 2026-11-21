import XCTest
@testable import Tradeflor

/// The second, deeper check of the meetup page (2026-11-21): every button, the walkie-talkie, the extras, security, speed.
final class PulsePageAuditTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: what the server sends

    /// pulse/sos.go Alert: the sender is user_id and the position is flat (no name and never the location before).
    func testSafetyAlertReadsTheServersFields() throws {
        let json = #"{"id":"al1","circle_id":"c1","user_id":"u9","kind":"safety","text":"help","lat":33.27,"lon":35.2,"accuracy":12,"created_at":5,"recipients":["me"]}"#
        let a = try JSONDecoder().decode(PulseAlert.self, from: Data(json.utf8))
        XCTAssertEqual(a.sender_id, "u9")
        XCTAssertEqual(a.position?.lat, 33.27)
        XCTAssertEqual(a.position?.accuracy, 12)
        let none = try JSONDecoder().decode(PulseAlert.self, from: Data(#"{"id":"al2","user_id":"u9","kind":"safety"}"#.utf8))
        XCTAssertNil(none.position)
    }

    func testDeliverySaysReachedWhenTheServerKnowsIt() throws {
        let d = try JSONDecoder().decode([PulseAlertDelivery].self, from: Data(#"[{"user_id":"a","delivered_at":5},{"user_id":"b","push_status":"sent"},{"user_id":"c"},{"user_id":"d","responding_at":9}]"#.utf8))
        XCTAssertTrue(d[0].reached)
        XCTAssertTrue(d[1].reached)
        XCTAssertFalse(d[2].reached)
        XCTAssertTrue(d[3].seen)
    }

    /// The activity tab: the server's kinds in the app's language (they showed raw words like "Ali · going"), times from
    /// created_at.
    func testActivityKindsAreWordedNotRaw() throws {
        let a = try JSONDecoder().decode(PulseActivityItem.self, from: Data(#"{"id":"pa_1","user_id":"u","kind":"left","created_at":77}"#.utf8))
        XCTAssertEqual(a.created_at, 77)
        for k in PulseRules.activityKinds {
            let t = PulseRules.activityText(kind: k, who: "Ali", text: "x")
            XCTAssertFalse(t.hasPrefix("pulse.log."), "\(k) has no text")
            XCTAssertNotEqual(t, k)
        }
        XCTAssertEqual(PulseRules.activityText(kind: "something-new", who: "Ali", text: ""), "something-new")
    }

    // MARK: QR

    func testTheScannerKnowsMeetupCodes() {
        XCTAssertEqual(FlashTarget.pulseCode("https://app.tradeflor.com/?pulse=AbC123_-xyz789QQ"), "AbC123_-xyz789QQ")
        XCTAssertNil(FlashTarget.pulseCode("https://evil.example.com/?pulse=AbC123_-xyz789QQ"), "only TRADEFLOR's hosts")
        XCTAssertNil(FlashTarget.pulseCode("https://app.tradeflor.com/?pulse=<script>"))
        XCTAssertNil(FlashTarget.pulseCode("https://app.tradeflor.com/?connect=AbC123_-xyz789QQ"))
    }

    func testQRSheetDrawsTheCodeOnce() throws {
        let x = try source("Tradeflor/Features/Pulse/PulseExtras.swift")
        XCTAssertFalse(x.contains("CIContext().createCGImage"))
        XCTAssertFalse(x.contains(".onReceive(Timer.publish"))
        XCTAssertTrue(x.contains("\"pulse.code.expired\""))
    }

    // MARK: walkie-talkie

    func testWebClipsAreRecognised() {
        XCTAssertTrue(PulseWalkie.isWebAudio(Data([0x1A, 0x45, 0xDF, 0xA3, 0x01])))
        XCTAssertTrue(PulseWalkie.isWebAudio(Data("OggS....".utf8)))
        XCTAssertFalse(PulseWalkie.isWebAudio(Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]))) // an .m4a (ftyp)
    }

    func testWalkieNeverRecordsWithoutAFinger() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(m.contains("@GestureState private var held"), "a cancelled touch ends the press")
        XCTAssertFalse(m.contains("await walkie.begin()"), "begin never waits (the permission prompt raced the release)")
        XCTAssertTrue(m.contains(".onDisappear { walkie.shutDown() }"))
        XCTAssertTrue(m.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(m.contains("setActive(false, options: .notifyOthersOnDeactivation)"), "the user's music comes back")
    }

    // MARK: buttons, people, safety

    func testMembersAreThePeopleOfTheMeetup() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(m.contains("$0.response == \"going\" || $0.response == \"maybe\" || $0.role == \"organizer\""))
    }

    func testNoSilentFailuresOnThePage() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        for call in ["\"bubble\", body: body)", "\"status\", body: body)", "\"respond\", body:", "\"here\", body:", "\"remove\", body:"] {
            XCTAssertFalse(m.contains("_ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, " + call), call)
        }
        XCTAssertTrue(m.contains("leaveAfterSheet = true; sheet = nil"), "the Leave / End confirmation waits for the sheet to close")
        XCTAssertTrue(m.contains("if let f = flashSince, d.timeIntervalSince(f) > 4 { flash = nil }"), "messages go away by themselves")
        XCTAssertTrue(m.contains("guard let raw = d[\"loc\"] as? [String: Any], JSONSerialization.isValidJSONObject(raw)"), "a bad frame cannot crash")
    }

    func testSafetyCenterRespectsRoleAndState() throws {
        let x = try source("Tradeflor/Features/Pulse/PulseExtras.swift")
        XCTAssertTrue(x.contains("if !isOrganizer {"), "no Leave that ends the meetup for everyone")
        XCTAssertTrue(x.contains("if !ended {"), "no alert or SOS in an ended meetup")
        XCTAssertTrue(x.contains("onSent()"))
    }

    // MARK: privacy

    func testHalfwayUsesOnlyThePositionAlreadyShared() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(m.contains("guard let mine = locations[me] else"))
        XCTAssertFalse(m.contains("if fix == nil { fix = await sharer.readOnce() }"))
    }

    func testSharingResumesOnlyOnTheDeviceThatStartedIt() throws {
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertTrue(s.contains("guard ask || Self.startedHere.contains(circle) else { return false }"))
        XCTAssertTrue(s.contains("catch APIError.badCredentials"), "a 401 stops sending")
        let p = try source("Tradeflor/Core/Pulse.swift")
        XCTAssertFalse(p.contains("if !token.isEmpty, PulseSharer.shared.isSharingAnywhere {"), "sign-out always stops on the server")
    }

    // MARK: speed and battery

    func testNoThirtyFramesASecondRebuilds() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertFalse(m.contains("TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in\n                    let t = ctx.date.timeIntervalSinceReferenceDate * (reduceMotion ? 0.7 : 1)"))
        XCTAssertTrue(m.contains("guard UIApplication.shared.applicationState == .active else { return }"), "no redraw each second in the background")
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertFalse(s.contains("@Published private(set) var lastFix"))
        XCTAssertTrue(s.contains("if manager.desiredAccuracy != want { manager.desiredAccuracy = want }"))
    }
}
