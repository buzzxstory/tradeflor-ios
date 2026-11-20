import XCTest
@testable import Tradeflor

/// The rules of App Lock (PIN and pattern): no screen, no Keychain.
final class AppLockTests: XCTestCase {
    func testPINMustBeSixDigits() {
        XCTAssertTrue(AppLockRules.validPIN("123456"))
        XCTAssertTrue(AppLockRules.validPIN("000000"))
        XCTAssertFalse(AppLockRules.validPIN("12345"))
        XCTAssertFalse(AppLockRules.validPIN("1234567"))
        XCTAssertFalse(AppLockRules.validPIN("12a456"))
        XCTAssertFalse(AppLockRules.validPIN(""))
        XCTAssertFalse(AppLockRules.validPIN("١٢٣٤٥٦")) // Arabic-Indic digits are not accepted: one way to type each PIN
    }

    func testPatternNeedsFourDifferentDotsOneToNine() {
        XCTAssertTrue(AppLockRules.validPattern([1, 2, 3, 6]))
        XCTAssertTrue(AppLockRules.validPattern([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        XCTAssertFalse(AppLockRules.validPattern([1, 2, 3]))
        XCTAssertFalse(AppLockRules.validPattern([1, 2, 2, 3]))
        XCTAssertFalse(AppLockRules.validPattern([1, 2, 3, 10]))
        XCTAssertFalse(AppLockRules.validPattern([0, 1, 2, 3]))
        XCTAssertFalse(AppLockRules.validPattern([]))
    }

    func testPatternSecretKeepsTheOrder() {
        XCTAssertEqual(AppLockRules.patternSecret([1, 2, 5, 9]), "1-2-5-9")
        XCTAssertNotEqual(AppLockRules.patternSecret([1, 2, 5, 9]), AppLockRules.patternSecret([9, 5, 2, 1]))
    }

    func testAStrokeTakesTheDotItPassesOver() {
        XCTAssertEqual(AppLockRules.between(1, 3), 2)
        XCTAssertEqual(AppLockRules.between(3, 1), 2)
        XCTAssertEqual(AppLockRules.between(1, 7), 4)
        XCTAssertEqual(AppLockRules.between(1, 9), 5)
        XCTAssertEqual(AppLockRules.between(3, 7), 5)
        XCTAssertEqual(AppLockRules.between(2, 8), 5)
        XCTAssertEqual(AppLockRules.between(4, 6), 5)
        XCTAssertEqual(AppLockRules.between(7, 9), 8)
        // neighbours and knight moves pass no dot
        XCTAssertNil(AppLockRules.between(1, 2))
        XCTAssertNil(AppLockRules.between(1, 5))
        XCTAssertNil(AppLockRules.between(1, 8))
        XCTAssertNil(AppLockRules.between(2, 9))
        XCTAssertNil(AppLockRules.between(5, 5))
        XCTAssertNil(AppLockRules.between(0, 3))
    }

    func testTheWaitGrowsAfterFiveWrongTries() {
        XCTAssertEqual(AppLockRules.lockout(failures: 0), 0)
        XCTAssertEqual(AppLockRules.lockout(failures: 4), 0)
        XCTAssertEqual(AppLockRules.lockout(failures: 5), 30)
        XCTAssertEqual(AppLockRules.lockout(failures: 6), 60)
        XCTAssertEqual(AppLockRules.lockout(failures: 7), 120)
        XCTAssertEqual(AppLockRules.lockout(failures: 8), 300)
        XCTAssertEqual(AppLockRules.lockout(failures: 9), 900)
        XCTAssertEqual(AppLockRules.lockout(failures: 40), 900)
    }

    func testTheHashIsSaltedAndRepeatable() {
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        let other = Data([16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        let a = AppLockRules.derive("123456", salt: salt)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(a, AppLockRules.derive("123456", salt: salt))
        XCTAssertNotEqual(a, AppLockRules.derive("123457", salt: salt))
        XCTAssertNotEqual(a, AppLockRules.derive("123456", salt: other))
        XCTAssertNotEqual(AppLockRules.derive("1-2-5-9", salt: salt), AppLockRules.derive("9-5-2-1", salt: salt))
    }
}
