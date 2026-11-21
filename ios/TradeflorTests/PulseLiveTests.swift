import XCTest
@testable import Tradeflor

/// The live-line audit of 2026-11-21 (the owner's screenshots: "You · Last seen 2 min ago" while sharing in front, and the
/// dashed line to the place coming and going, because the line is drawn only for a position that is not stale).
final class PulseLiveTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A 409 "an older position arrived after a newer one" drops one reading; it no longer stops sharing on the phone while
    /// the server still shows it on. "Not sharing", ended and gone still stop.
    func testOnlyARealRefusalStopsSharing() {
        XCTAssertFalse(PulseRules.refusalStopsSharing(status: 409, text: "an older position arrived after a newer one"))
        XCTAssertTrue(PulseRules.refusalStopsSharing(status: 409, text: "you are not sharing your location in this circle"))
        XCTAssertTrue(PulseRules.refusalStopsSharing(status: 409, text: ""))
        XCTAssertTrue(PulseRules.refusalStopsSharing(status: 404, text: "not found"))
        XCTAssertTrue(PulseRules.refusalStopsSharing(status: 410, text: "this circle has ended"))
        for s in [0, 400, 422, 429, 500, 502] { XCTAssertFalse(PulseRules.refusalStopsSharing(status: s, text: ""), "\(s)") }
    }

    func testACachedReadingIsNotSent() {
        XCTAssertTrue(PulseRules.recentEnough(1_000_000, now: 1_000_000 + 59_000))
        XCTAssertFalse(PulseRules.recentEnough(1_000_000, now: 1_000_000 + 61_000))
    }

    func testQuietUpdatesAreRestarted() {
        XCTAssertFalse(PulseRules.updatesWentQuiet(lastDeliveryAgoS: 10))
        XCTAssertTrue(PulseRules.updatesWentQuiet(lastDeliveryAgoS: 16))
    }

    /// A still sharer sends every 25 s, inside "live" (40 s), so the line and "Live" stay while nobody moves.
    func testStillCadenceStaysLive() {
        let a = PulseRules.Fix(lat: 33.27, lon: 35.2, accuracy: 10, speed: 0, at: 1_000_000)
        let b = PulseRules.Fix(lat: 33.27, lon: 35.2, accuracy: 10, speed: 0, at: 1_000_000 + 25_000)
        XCTAssertTrue(PulseRules.shouldSend(b, lastSent: a, destDistance: 8000))
        XCTAssertLessThan(PulseRules.cadence(.still).everyMs + 5_000, PulseRules.liveMs, "a reading every second + the 25 s cadence")
    }

    func testTheOpenMeetupAsksAgainAfter15sOfSilence() {
        XCTAssertFalse(PulseRules.needsSafetyReload(lastNewsMs: 1_000_000, now: 1_014_000))
        XCTAssertTrue(PulseRules.needsSafetyReload(lastNewsMs: 1_000_000, now: 1_015_000))
        XCTAssertTrue(PulseRules.needsSafetyReload(lastNewsMs: 0, now: 1_000_000))
    }

    func testSharerNeverAsksAOneShotWhileSharing() throws {
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertFalse(s.contains("> 20 { manager.requestLocation() }"), "the old heartbeat could end the running updates")
        XCTAssertTrue(s.contains("if shares.isEmpty {\n                manager.desiredAccuracy = kCLLocationAccuracyBest\n                manager.requestLocation()"))
        XCTAssertTrue(s.contains("PulseRules.refusalStopsSharing("))
        XCTAssertFalse(s.contains("case 404, 409, 410: stopLocally"))
    }

    func testChatLiveLocationHasNoDistanceFilter() throws {
        let s = try source("Tradeflor/Features/Chat/LocationAndNotes.swift")
        XCTAssertTrue(s.contains("manager.distanceFilter = kCLDistanceFilterNone"))
        XCTAssertFalse(s.contains("manager.distanceFilter = 10"))
    }

    func testMeetupReloadsOnSilenceAndInFront() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(m.contains("safetyReload()"))
        XCTAssertTrue(m.contains("UIApplication.didBecomeActiveNotification"))
    }
}
