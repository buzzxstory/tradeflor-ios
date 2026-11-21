import XCTest
@testable import Tradeflor

/// The People rows and Find My Friend card (web 2e26b511, 208efd39): accuracy as people read it, a distance only when the
/// positions are precise enough for it, and no straight-line times of many hours.
final class PulseRowsTests: XCTestCase {
    typealias R = PulseRules

    func testAccuracyReadsLikePeopleSayIt() {
        XCTAssertEqual(R.accuracyText(8), "8 m")
        XCTAssertEqual(R.accuracyText(350), "350 m")
        XCTAssertEqual(R.accuracyText(1200), "1.2 km")
        XCTAssertEqual(R.accuracyText(5000), "5 km", "never 5.0 km")
        XCTAssertEqual(R.accuracyText(0), "?")
    }

    func testADistanceIsShownOnlyWhenItMeansSomething() {
        XCTAssertTrue(R.distanceKnown(530, accuracy: 10))
        XCTAssertFalse(R.distanceKnown(530, accuracy: 5000), "a 5 km circle says nothing about 530 m")
        XCTAssertFalse(R.distanceKnown(800, accuracy: 900))
        XCTAssertTrue(R.distanceKnown(60, accuracy: 80), "close to the place: the arrival rules take over")
        XCTAssertFalse(R.distanceKnown(nil, accuracy: 5))
    }

    func testLongStraightLineTimesAreOverThreeHours() {
        // 120 km on foot is far beyond 3 h: the row shows the distance instead of "~17 h 53 min"
        XCTAssertGreaterThan(R.etaMinutes(distance: 120_000, speed: 0) ?? 0, 180)
        XCTAssertLessThan(R.etaMinutes(distance: 770, speed: 0) ?? 999, 180)
        XCTAssertNil(R.etaMinutes(distance: nil, speed: 0))
    }

    func testAgeWithoutAgo() {
        XCTAssertEqual(R.ageShort(0, now: 26_000), "26 s")
        XCTAssertEqual(R.ageShort(0, now: 300_000), "5 min")
        XCTAssertEqual(R.ageShort(0, now: 3_840_000), "1 h 4 min")
    }
}
