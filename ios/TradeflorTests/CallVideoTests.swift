import XCTest
@testable import Tradeflor

/// One-to-one video calls (IOS-VIDEO-001…008): the state rules that do not need a camera.
@MainActor
final class CallVideoTests: XCTestCase {
    private func video() -> CallVideo { CallVideo.forTests() }

    func testSummaryMarksVideoAndPeerCamera() {
        let v = video()
        v.applySummary(["video": true, "caller_camera": true], iAmCaller: false)
        XCTAssertTrue(v.isVideo)
        XCTAssertTrue(v.peerCamera, "the caller's camera, seen by the callee")
        v.applySummary(["video": true], iAmCaller: true)
        XCTAssertFalse(v.peerCamera, "a live summary omits a camera that is off")
    }

    func testPlainVoiceSummaryStaysVoice() {
        let v = video()
        v.applySummary(["call_id": "c1"], iAmCaller: false)
        XCTAssertFalse(v.isVideo)
        XCTAssertFalse(v.peerCamera)
    }

    func testPeerMediaFollowsCameraAndOldServersLeaveItAlone() {
        let v = video()
        v.applyPeerMedia(["muted": false, "camera": true])
        XCTAssertTrue(v.peerCamera)
        XCTAssertTrue(v.isVideo, "a camera turned on makes it a video call (upgrade)")
        v.applyPeerMedia(["muted": true]) // an older server: no camera field
        XCTAssertTrue(v.peerCamera, "the shown state stays")
        v.applyPeerMedia(["muted": true, "camera": false])
        XCTAssertFalse(v.peerCamera)
        XCTAssertTrue(v.isVideo, "the video flag is sticky")
    }

    func testResetClearsTheLastCall() {
        let v = video()
        v.applyPeerMedia(["camera": true])
        v.reset()
        XCTAssertFalse(v.isVideo)
        XCTAssertFalse(v.peerCamera)
        XCTAssertFalse(v.cameraOn)
        XCTAssertFalse(v.hasRemotePicture)
    }

    func testStopBumpsGenerationSoALateCaptureStops() {
        let v = video()
        let g = v.generation
        v.stopCapture()
        XCTAssertEqual(v.generation, g + 1, "a capture that completes after this is stopped at once")
    }

    func testFormatClosestTo720pOr360pWhenHot() {
        let formats: [(width: Int32, height: Int32, maxFps: Double)] = [(640, 480, 30), (1280, 720, 30), (1920, 1080, 30), (640, 360, 30)]
        XCTAssertEqual(CallVideo.pickFormat(formats, hot: false), 1)
        XCTAssertEqual(CallVideo.pickFormat(formats, hot: true), 3)
        XCTAssertNil(CallVideo.pickFormat([], hot: false))
    }

    /// The caller's video offer: one audio and one video line; H.264 (VideoToolbox) and VP8 offered.
    func testVideoOfferHasOneVideoLine() async throws {
        let sdp = try await CallVideo.probeOfferSDP()
        let lines = sdp.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("m=video") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("m=audio") }.count, 1)
        XCTAssertTrue(sdp.contains("H264"))
        XCTAssertTrue(sdp.contains("VP8"))
    }

    /// Audit T4: a flip after the call ended (camera off) does nothing and starts no capture.
    func testFlipAfterEndIsIgnored() async {
        let v = video()
        v.reset()
        let g = v.generation
        await v.flip()
        XCTAssertFalse(v.cameraOn)
        XCTAssertTrue(v.front, "nothing flipped")
        XCTAssertEqual(v.generation, g, "no capture was started or stopped")
    }
}
