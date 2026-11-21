import XCTest
@testable import Tradeflor

/// TRADEFLOR Pulse (2026-11-21): the map's rules (the same as the web's pulseRules.ts and its tests/pulse.test.ts), the
/// shapes the server sends, and the notification routing.
@MainActor
final class PulseTests: XCTestCase {
    typealias R = PulseRules

    func testFreshnessNeverCallsAnOldPositionLive() {
        let now: Int64 = 1_000_000
        XCTAssertEqual(R.freshness(now - 10_000, now: now), .live)
        XCTAssertEqual(R.freshness(now - 40_000, now: now), .live)
        XCTAssertEqual(R.freshness(now - 41_000, now: now), .lagging)
        XCTAssertEqual(R.freshness(now - 120_000, now: now), .lagging)
        XCTAssertEqual(R.freshness(now - 121_000, now: now), .stale)
    }

    func testFirstFixIsAlwaysSentAndNeverSoonerThanTwoSeconds() {
        let a = R.Fix(lat: 33.9, lon: 35.5, accuracy: 10, speed: 0, at: 0)
        XCTAssertTrue(R.shouldSend(a, lastSent: nil, destDistance: nil))
        var b = a
        b.at = 1_500
        b.lat += 0.01 // far away, but only 1.5 s later
        XCTAssertFalse(R.shouldSend(b, lastSent: a, destDistance: nil), "the server refuses anything sooner than 2 s")
    }

    func testStillPersonSendsAHeartbeatEvery25Seconds() {
        let a = R.Fix(lat: 33.9, lon: 35.5, accuracy: 10, speed: 0, at: 0)
        var b = a
        b.at = 20_000
        XCTAssertFalse(R.shouldSend(b, lastSent: a, destDistance: nil))
        b.at = 25_000
        XCTAssertTrue(R.shouldSend(b, lastSent: a, destDistance: nil), "the 25 s heartbeat keeps a still person live")
    }

    func testWalkingAndDrivingCadence() {
        let a = R.Fix(lat: 33.9, lon: 35.5, accuracy: 10, speed: 1.4, at: 0)
        var b = a
        b.at = 10_000
        XCTAssertEqual(R.motion(b, last: a, destDistance: nil), .walking)
        XCTAssertTrue(R.shouldSend(b, lastSent: a, destDistance: nil), "walking: every 10 s")
        var c = R.Fix(lat: 33.9, lon: 35.5, accuracy: 10, speed: 12, at: 0)
        let d0 = c
        c.at = 5_000
        XCTAssertEqual(R.motion(c, last: d0, destDistance: nil), .driving)
        XCTAssertTrue(R.shouldSend(c, lastSent: d0, destDistance: nil), "driving: every 5 s")
        XCTAssertEqual(R.motion(a, last: nil, destDistance: 120), .near, "within 300 m of the place")
    }

    func testJitterSmallerThanHalfTheAccuracyIsNotMovement() {
        let a = R.Fix(lat: 33.9, lon: 35.5, accuracy: 80, speed: nil, at: 0)
        var b = a
        b.at = 3_000
        b.lat += 0.0003 // about 33 m, inside half of an 80 m circle... 40 m
        XCTAssertFalse(R.shouldSend(b, lastSent: a, destDistance: nil))
    }

    func testAMuchBetterReadingIsSentAtOnce() {
        let a = R.Fix(lat: 33.9, lon: 35.5, accuracy: 120, speed: 0, at: 0)
        var b = a
        b.at = 3_000
        b.accuracy = 20
        XCTAssertTrue(R.shouldSend(b, lastSent: a, destDistance: nil))
    }

    func testGlideNeverPredictsAndJumpsFarMoves() {
        func loc(_ lat: Double, _ at: Int64) -> PulseLocation {
            PulseLocation(user_id: "u", lat: lat, lon: 35.5, accuracy: 10, speed: nil, heading: nil, source: "gps", measured_at: at,
                          received_at: nil, quality: nil, until: nil, distance_m: nil)
        }
        XCTAssertEqual(R.glideMs(prev: nil, next: loc(33.9, 1000), reduceMotion: false), 0)
        XCTAssertEqual(R.glideMs(prev: loc(33.9, 0), next: loc(33.9001, 10_000), reduceMotion: false), 1500, "at most 1.5 s")
        XCTAssertEqual(R.glideMs(prev: loc(33.9, 0), next: loc(33.9001, 200), reduceMotion: false), 300, "at least 0.3 s")
        XCTAssertEqual(R.glideMs(prev: loc(33.9, 0), next: loc(34.0, 10_000), reduceMotion: false), 0, "a jump over 2 km is a jump")
        XCTAssertEqual(R.glideMs(prev: loc(33.9, 0), next: loc(33.9001, 10_000), reduceMotion: true), 0, "Reduce Motion: no animation")
    }

    func testOverlappingAvatarsGroupAndStatusesAreCapped() {
        let pts = [R.ScreenPoint(id: "me", x: 100, y: 100, priority: 2), R.ScreenPoint(id: "a", x: 110, y: 105, priority: 1),
                   R.ScreenPoint(id: "b", x: 300, y: 300, priority: 1)]
        let c = R.clusterPoints(pts)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].ids, ["me", "a"], "the higher priority stays on top")
        var many: [R.ScreenPoint] = []
        var at: [String: Int64] = [:]
        for i in 0..<10 { many.append(R.ScreenPoint(id: "p\(i)", x: CGFloat(i * 100), y: 0, priority: 1)); at["p\(i)"] = Int64(i) }
        let shown = R.visibleStatuses(R.clusterPoints(many), statusAt: at, selected: "p0")
        XCTAssertEqual(shown.count, 6, "at most six statuses")
        XCTAssertTrue(shown.contains("p0"), "the selected person keeps theirs")
        XCTAssertTrue(shown.contains("p9"), "newest first")
    }

    func testEtaIsAnEstimateFromTheStraightLine() {
        XCTAssertNil(R.eta(distance: nil, speed: nil, arrived: false))
        XCTAssertEqual(R.eta(distance: 30, speed: 0, arrived: false), "< 1 min")
        // 1 km walking: 1000 x 1.3 / 1.35 / 60 = 16 min
        XCTAssertEqual(R.eta(distance: 1000, speed: 1, arrived: false), "~16 min")
        // driving (> 3 m/s): 1000 x 1.3 / 8 / 60 = 2.7 -> 3 min
        XCTAssertEqual(R.eta(distance: 1000, speed: 10, arrived: false), "~3 min")
        XCTAssertEqual(R.progress(first: 1000, now: 250, arrived: false), 75)
        XCTAssertEqual(R.progress(first: 1000, now: 0, arrived: false), 99, "never 100 before arriving")
        XCTAssertEqual(R.progress(first: nil, now: 10, arrived: true), 100)
    }

    func testDistanceCountdownAndCircle() {
        XCTAssertEqual(R.distanceM(33.9, 35.5, 33.9, 35.5), 0, accuracy: 0.001)
        XCTAssertEqual(R.distanceM(0, 0, 0, 1), 111_195, accuracy: 50)
        XCTAssertEqual(R.distanceText(434), "430 m")
        XCTAssertEqual(R.distanceText(2500), "2.5 km")
        XCTAssertEqual(R.distanceText(12_400), "12 km")
        XCTAssertEqual(R.countdown(65_000), "1:05")
        XCTAssertEqual(R.countdown(3_725_000), "1:02:05")
        XCTAssertEqual(R.countdown(-5), "0:00")
        let ring = R.circlePolygon(lat: 33.9, lon: 35.5, radiusM: 100)
        XCTAssertEqual(ring.count, 49)
        XCTAssertEqual(R.distanceM(33.9, 35.5, ring[10].latitude, ring[10].longitude), 100, accuracy: 2)
    }

    func testViewDecodesWithMissingFields() throws {
        let json = #"{"view":{"circle":{"id":"pc_1","title":"Coffee","activity":"coffee","dest_lat":33.9,"dest_lon":35.5,"state":"active","x":1},"me":{"user_id":"a","role":"organizer"},"members":[{"user_id":"a","response":"going","sharing":true},{"user_id":"b","response":"left"}],"locations":[{"user_id":"b","lat":33.89,"lon":35.49,"accuracy":150,"measured_at":5}],"now":9},"people":{"b":{"username":"badr","display_name":"Badr"}}}"#
        let d = try JSONDecoder().decode(PulseCircleDetail.self, from: Data(json.utf8))
        let v = try XCTUnwrap(d.view)
        XCTAssertEqual(v.circle.icon, "☕")
        XCTAssertTrue(v.circle.hasDest)
        XCTAssertTrue(v.circle.isOpen)
        XCTAssertEqual(v.locations?.first?.approximate, true, "over 100 m: approximate")
        XCTAssertEqual(d.people?["b"]?.name, "Badr")
        XCTAssertNil(d.invitation)
    }

    func testConfigOffWithoutPulse() throws {
        XCTAssertFalse(PulseConfig().enabled, "a server without Pulse (404) is off")
        let c = try JSONDecoder().decode(PulseConfig.self, from: Data(#"{"enabled":true,"style_url":""}"#.utf8))
        XCTAssertTrue(c.enabled)
        XCTAssertNil(PulseMapView.style("").flatMap { $0.scheme == "https" ? $0 : nil }, "an empty style_url uses the bundled Pulse Night")
    }

    func testHeaderTimeIsShortAndTheRingEmpties() {
        XCTAssertEqual(R.shortLeft(2 * 3_600_000 + 46 * 60_000 + 30_000), "2h 46m")
        XCTAssertEqual(R.shortLeft(3 * 3_600_000), "3h")
        XCTAssertEqual(R.shortLeft(46 * 60_000), "46m")
        XCTAssertEqual(R.shortLeft(40_000), "40s")
        XCTAssertEqual(R.leftFraction(now: 50, starts: 0, expires: 100), 0.5, accuracy: 0.001)
        XCTAssertEqual(R.leftFraction(now: -5, starts: 0, expires: 100), 1, "before the start: full")
        XCTAssertEqual(R.leftFraction(now: 200, starts: 0, expires: 100), 0, "over: empty")
    }

    func testNotificationRouting() {
        XCTAssertEqual(PulseRouting.circle("pulse-pc_42"), "pc_42")
        XCTAssertNil(PulseRouting.circle("pulse-alert-a1"), "an alert names no meetup")
        XCTAssertNil(PulseRouting.circle("msg-1"))
    }

    func testBundledStylesAreThere() throws {
        let night = try XCTUnwrap(Bundle(for: PulseStore.self).url(forResource: "pulse-night-style", withExtension: "json")
                                  ?? Bundle.main.url(forResource: "pulse-night-style", withExtension: "json"))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: night)) as? [String: Any])
        XCTAssertEqual(o["version"] as? Int, 8)
        XCTAssertNotNil(PulseMapView.offlineStyle)
    }
}
