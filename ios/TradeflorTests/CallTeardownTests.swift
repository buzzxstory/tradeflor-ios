import XCTest
@testable import Tradeflor

/// Ending a call closes the call screen at once; the slow part (closing the peer connection, resetting the audio session)
/// runs in the background (owner: the red button took seconds to close the screen).
final class CallTeardownTests: XCTestCase {
    /// Where the injected close ran (it is called on the teardown queue).
    private final class ThreadRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: Bool?
        func set(_ v: Bool) { lock.lock(); onMain = v; lock.unlock() }
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    @MainActor
    func testHangUpClosesTheScreenAtOnceAndTearsDownOffTheMainThread() {
        let calls = CallManager.shared
        let saved = CallManager.closePeerConnection
        defer { CallManager.closePeerConnection = saved }
        let closed = expectation(description: "the peer connection close ran")
        let record = ThreadRecord()
        CallManager.closePeerConnection = { _ in
            record.set(Thread.isMainThread)
            closed.fulfill()
        }

        calls.testOnlyPretendCallOnScreen()
        XCTAssertTrue(calls.showScreen)
        XCTAssertTrue(calls.lineInUse)

        calls.hangUp()

        // synchronously, before any run-loop turn: the screen is gone and the call is over
        XCTAssertFalse(calls.showScreen)
        XCTAssertEqual(calls.phase, .ended)
        XCTAssertFalse(calls.lineInUse)
        XCTAssertTrue(calls.endedByMe) // ended here: no end-of-call notice

        wait(for: [closed], timeout: 2)
        XCTAssertEqual(record.get(), false, "the peer connection must be closed off the main thread")
    }
}
