import XCTest
@testable import Tradeflor

/// Guards for the Pulse audit of 2026-11-21 (Main's read-only review of ios-app 31a62a8a): the fixes stay in the code.
final class PulseAuditTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 1: the emergency screen and a safety alert are not root covers (hidden under any sheet or the meetup cover).
    func testEmergencyScreenLivesInItsOwnWindow() throws {
        let app = try source("Tradeflor/App/TradeflorApp.swift")
        XCTAssertFalse(app.contains("PulseEmergencyScreen("))
        XCTAssertFalse(app.contains("PulseAlertScreen("))
        XCTAssertTrue(app.contains("SOSWindow.shared.attach"))
        let em = try source("Tradeflor/Features/Pulse/PulseEmergency.swift")
        XCTAssertTrue(em.contains("final class SOSWindow"))
        XCTAssertTrue(em.contains(".alert - 1"), "over sheets and covers, under App Lock")
    }

    /// 2: the Safety Center's SOS is the same countdown, never a hold or a single VoiceOver action.
    func testSafetyCenterSOSUsesTheCountdown() throws {
        let s = try source("Tradeflor/Features/Pulse/PulseExtras.swift")
        XCTAssertFalse(s.contains("onLongPressGesture(minimumDuration: 2"))
        XCTAssertFalse(s.contains("await send(\"sos\")"))
        XCTAssertTrue(s.contains("PulseSOSCountdown("))
        XCTAssertTrue(s.contains("sendFromCountdown("))
    }

    /// 3, 11: an alert's position never waits for a permission prompt or a long fix, and is never an old reading.
    func testAlertPositionIsAQuickFreshSnapshot() throws {
        let sos = try source("Tradeflor/Core/PulseSOS.swift")
        XCTAssertTrue(sos.contains("snapshotFix(maxWait: 3)"))
        let meetup = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        let extras = try source("Tradeflor/Features/Pulse/PulseExtras.swift")
        for s in [meetup, extras] {
            XCTAssertFalse(s.contains("\"position\"] = [\"lat\""), "positions go through SOSCenter.snapshot (time, source, seq)")
        }
        let sharer = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertTrue(sharer.contains("func snapshotFix"))
        XCTAssertTrue(sharer.contains("< 120"), "older than 2 minutes = no position")
    }

    /// 4: a still sharer measures again instead of sending the same reading (which shouldSend refuses).
    func testStillHeartbeatMeasuresAgain() throws {
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertTrue(s.contains("manager.requestLocation() }"))
        let r = PulseRules.Fix(lat: 1, lon: 1, accuracy: 10, speed: 0, at: 1000)
        XCTAssertFalse(PulseRules.shouldSend(r, lastSent: r, destDistance: nil), "the same reading again is never sent")
    }

    /// 20: no Timer.publish made inside a Pulse body (the countdown's seconds jittered).
    func testNoTimerMadeInsideBody() throws {
        for f in ["PulseMeetup.swift", "PulseEmergency.swift"] {
            let s = try source("Tradeflor/Features/Pulse/" + f)
            XCTAssertFalse(s.contains(".onReceive(Timer.publish"), f)
        }
    }

    /// 22: the old "everyone was alerted" wording is gone from both languages.
    func testNoEveryoneWasAlertedString() throws {
        for l in ["en", "ar"] {
            let s = try source("Tradeflor/Resources/\(l).lproj/Localizable.strings")
            XCTAssertFalse(s.contains("\"pulse.sos.mine.sub\""), l)
            XCTAssertFalse(s.contains("112\";") && s.contains("call 112"), l)
        }
    }
}
