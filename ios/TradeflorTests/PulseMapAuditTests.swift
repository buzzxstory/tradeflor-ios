import XCTest
import CoreLocation
@testable import Tradeflor

/// The full map / places / live-sharing check of 2026-11-21 (the owner: "test every single thing"), compared with the web
/// (desktop/src/features/pulse) and the server (backend/internal/pulse).
final class PulseMapAuditTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func person(ring: PulseMapPerson.Ring, toPlace: Double?) -> PulseMapPerson {
        PulseMapPerson(id: "u", name: "A", avatarID: nil, coordinate: CLLocationCoordinate2D(latitude: 33.27, longitude: 35.2),
                       accuracy: 10, approximate: false, ring: ring, line: "", status: nil, statusAt: nil, isMe: false,
                       toPlaceM: toPlace, measuredAt: 0, glide: 0)
    }

    // MARK: the dashed line to the place

    /// web PulseMap: everyone not arrived and more than 60 m away; stale ones too (drawn faint), whatever the speed.
    func testTheLineFollowsTheWebRule() {
        XCTAssertTrue(person(ring: .live, toPlace: 8300).drawsLine, "standing still 8 km away (stuck in traffic)")
        XCTAssertTrue(person(ring: .stale, toPlace: 8300).drawsLine, "stale: faint, not hidden")
        XCTAssertTrue(person(ring: .lagging, toPlace: 120).drawsLine)
        XCTAssertFalse(person(ring: .live, toPlace: 50).drawsLine, "at the place")
        XCTAssertFalse(person(ring: .arrived, toPlace: 900).drawsLine)
        XCTAssertFalse(person(ring: .live, toPlace: nil).drawsLine, "no place")
    }

    func testStaleLinesHaveTheirOwnFaintLayer() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMap.swift")
        XCTAssertTrue(m.contains("\"pulse-direction-stale\""))
        XCTAssertTrue(m.contains("min(p.accuracy, 3000)"), "accuracy circles at most 3 km (web)")
        XCTAssertFalse(m.contains("p.moving"))
    }

    // MARK: camera and zoom

    func testCameraFollowsLikeTheWeb() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMap.swift")
        XCTAssertTrue(m.contains("max(map.zoomLevel, 15.5)"), "place / me / friend never zoom out a closer view")
        XCTAssertTrue(m.contains("if z > 16.5"), "a fit never zooms past 16.5")
        XCTAssertTrue(m.contains("$0.accuracy <= 1000"), "stale and rough positions stay out of the frame")
        XCTAssertTrue(m.contains(".gestureOneFingerZoom"), "a one-finger zoom frees the camera too")
        XCTAssertTrue(m.contains("guard map.bounds.width > 1, map.bounds.height > 1"), "no fit on a map with no size yet")
        XCTAssertFalse(m.contains("private var fitted"), "the fit is not done once only")
        let meetup = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(meetup.contains("onUserMoved: { if camera.mode != .none { camera.mode = .none } }"))
    }

    func testPinsSitOnTheirCoordinates() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMap.swift")
        XCTAssertTrue(m.contains("centerOffset = CGVector(dx: 0, dy: 52 - 48)"), "the avatar photo on the position")
        XCTAssertTrue(m.contains("centerOffset = CGVector(dx: 0, dy: 37 - 22)"), "the gold dot on the place")
        XCTAssertFalse(m.contains("dy: -6)"))
    }

    func testSOSAnimationsSurviveTheBackground() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMap.swift")
        XCTAssertGreaterThanOrEqual(m.components(separatedBy: "isRemovedOnCompletion = false").count - 1, 3)
        XCTAssertTrue(m.contains("override func didMoveToWindow()"))
        XCTAssertTrue(m.contains("override func prepareForReuse()"))
    }

    // MARK: places

    @MainActor
    func testPlaceNameSkipsEmptyNames() {
        XCTAssertEqual(PulseMapView.Coordinator.placeName(["name:latin": " ", "name_en": "", "name": "مقهى البحر"]), "مقهى البحر")
        XCTAssertEqual(PulseMapView.Coordinator.placeName(["name:latin": "Cafe Najjar", "name": "مقهى نجار"]), "Cafe Najjar")
        XCTAssertEqual(PulseMapView.Coordinator.placeName([:]), "")
    }

    /// The server sends proposer_id / accept / reject / my_vote (pulse/social.go): the proposer was always unknown before.
    func testProposalDecodesTheServerFields() throws {
        let json = #"{"id":"p1","proposer_id":"u2","name":"Abdallah","lat":33.27,"lon":35.2,"state":"open","created_at":1,"accept":2,"reject":1,"my_vote":"accept"}"#
        let p = try JSONDecoder().decode(PulseProposal.self, from: Data(json.utf8))
        XCTAssertEqual(p.proposer_id, "u2")
        XCTAssertEqual(p.accept, 2)
        XCTAssertEqual(p.reject, 1)
        XCTAssertEqual(p.my_vote, "accept")
    }

    /// One card (web CircleScreen): open, not voted by me, not mine.
    func testOneProposalCardLikeTheWeb() {
        let mine = PulseProposal(id: "a", proposer_id: "me", name: "A", state: "open")
        let voted = PulseProposal(id: "b", proposer_id: "u2", name: "B", state: "open", my_vote: "accept")
        let closed = PulseProposal(id: "c", proposer_id: "u2", name: "C", state: "accepted")
        let open = PulseProposal(id: "d", proposer_id: "u3", name: "D", state: "open")
        XCTAssertEqual(PulseProposal.cardFor([mine, voted, closed, open], me: "me")?.id, "d")
        XCTAssertNil(PulseProposal.cardFor([mine, voted, closed], me: "me"))
    }

    func testProposalFailuresAreShownNotSwallowed() throws {
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertFalse(m.contains("_ = try? await APIClient.shared.pulsePost(token: token, circle: circleID, \"proposals\""))
        XCTAssertTrue(m.contains("\"destination_changed\""))
        XCTAssertTrue(m.contains("pick: proposalAt.map"), "the spot being picked is drawn on the map")
        XCTAssertTrue(m.contains("proposals: mapProposals"), "open proposals are drawn on the map")
    }

    /// Create: "Near me" moves the map only (web); nobody invited is allowed (web); the button is only the button.
    func testCreateNearMeMovesTheMapOnly() throws {
        let h = try source("Tradeflor/Features/Pulse/PulseHome.swift")
        XCTAssertFalse(h.contains("pin = l.coordinate"))
        XCTAssertTrue(h.contains("mode: .center(l.coordinate.latitude, l.coordinate.longitude)"))
        XCTAssertFalse(h.contains("(!instant && chosen.isEmpty)"))
        XCTAssertTrue(h.contains(".buttonStyle(.borderless) // only the button"))
    }

    // MARK: text the server accepts

    /// The server counts runes and refuses longer text (400) instead of cutting it.
    func testRunesCutWhatTheServerCounts() {
        XCTAssertEqual(PulseRules.runes("abc", 5), "abc")
        XCTAssertEqual(PulseRules.runes("abcdef", 3), "abc")
        let marked = String(repeating: "سَ", count: 50) // 100 runes, 50 characters
        XCTAssertEqual(PulseRules.runes(marked, 80).unicodeScalars.count, 80)
        XCTAssertLessThanOrEqual(PulseRules.runes(String(repeating: "👍🏽", count: 50), 60).unicodeScalars.count, 60)
    }

    func testEveryPulseTextUsesTheServerLimit() throws {
        let h = try source("Tradeflor/Features/Pulse/PulseHome.swift")
        XCTAssertTrue(h.contains("PulseRules.runes(title.trimmingCharacters(in: .whitespaces), 60)"), "title: 60 (it was 80: refused)")
        let x = try source("Tradeflor/Features/Pulse/PulseExtras.swift")
        XCTAssertTrue(x.contains("PulseRules.runes(text, 200)"), "a safety alert: 200 (it was 280: refused)")
        XCTAssertFalse(x.contains("prefix(280)"))
    }

    // MARK: live sharing

    func testFailedSendsWaitInsteadOfRetryingEverySecond() {
        XCTAssertEqual(PulseRules.retryHoldMs(status: 0, retryAfter: nil), 3000)
        XCTAssertEqual(PulseRules.retryHoldMs(status: 422, retryAfter: nil), 3000)
        XCTAssertEqual(PulseRules.retryHoldMs(status: 429, retryAfter: nil), 5000)
        XCTAssertEqual(PulseRules.retryHoldMs(status: 429, retryAfter: 2), 2000)
        XCTAssertLessThan(PulseRules.locationPostTimeoutS, 20)
    }

    func testSharingResumesAfterTheAppWasClosed() throws {
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertTrue(s.contains("func resume(circle: String, until: Int64?, dest: CLLocationCoordinate2D?, ask: Bool = false)"))
        XCTAssertTrue(s.contains("let s = ask ? await permission() : manager.authorizationStatus"), "never a prompt by itself")
        let m = try source("Tradeflor/Features/Pulse/PulseMeetup.swift")
        XCTAssertTrue(m.contains("await resumeIfNeeded(v)"))
        XCTAssertTrue(m.contains("guard gen == loadGen else { return }"), "an older load answer is dropped")
    }

    func testBackgroundWatchdogNeverEndsTheSession() throws {
        let s = try source("Tradeflor/Core/PulseSharer.swift")
        XCTAssertTrue(s.contains("if UIApplication.shared.applicationState == .active { manager.stopUpdatingLocation() }"))
        XCTAssertFalse(s.contains("kCLLocationAccuracyHundredMeters"), "Low Power Mode too: readings close together")
        XCTAssertTrue(s.contains("ServerClock.now"), "positions carry the server's time")
    }
}
