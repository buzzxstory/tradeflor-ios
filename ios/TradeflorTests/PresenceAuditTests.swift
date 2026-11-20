import XCTest
@testable import Tradeflor

/// The presence and lifecycle audit of 2026-11-20 (IOS-PRES-2/3/6/7, IOS-NET-3, IOS-LC-1, IOS-APL-3/4/5).
final class PresenceAuditTests: XCTestCase {
    private func frame(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    // MARK: IOS-PRES-3: an HTTP answer never overwrites a newer live event

    func testClockStampsChangeWithEventsAndSnapshots() {
        var c = PresenceClock()
        let a = c.stamp("u1")
        XCTAssertTrue(c.isCurrent(a, for: "u1"))
        c.bump("u2")
        XCTAssertTrue(c.isCurrent(a, for: "u1"), "another person's event leaves u1's answer valid")
        c.bump("u1")
        XCTAssertFalse(c.isCurrent(a, for: "u1"))
        let b = c.stamp("u1")
        c.bumpAll()
        XCTAssertFalse(c.isCurrent(b, for: "u1"), "a snapshot is newer than every answer in flight")
        let d = c.stamp("u1")
        c.reset()
        XCTAssertFalse(c.isCurrent(d, for: "u1"), "a sign-out makes every stamp stale, even with the counters back at 0")
    }

    @MainActor
    func testOfflineAnswerAfterLiveOnlineIsDropped() {
        let live = LiveConnection()
        let stamp = live.presenceStamp("u1")
        // the live event arrives while the GET is on its way
        live.handle(frame(["type": "presence", "data": ["user_id": "u1", "online": true]]))
        live.applyPresence(PresenceInfo(user_id: "u1", online: false, last_seen: 100, hidden: false), userID: "u1", stamp: stamp)
        XCTAssertTrue(live.online.contains("u1"), "the older offline answer must not win")
    }

    @MainActor
    func testAnswerWithNothingNewerIsApplied() {
        let live = LiveConnection()
        let stamp = live.presenceStamp("u1")
        live.handle(frame(["type": "presence", "data": ["user_id": "u2", "online": true]]))
        live.applyPresence(PresenceInfo(user_id: "u1", online: true, last_seen: nil, hidden: false), userID: "u1", stamp: stamp)
        XCTAssertTrue(live.online.contains("u1"))
    }

    @MainActor
    func testSnapshotMakesAnswerStale() {
        let live = LiveConnection()
        let stamp = live.presenceStamp("u1")
        live.handle(frame(["type": "presence_snapshot", "data": ["online": [String](), "last_seen": [String: Any](), "hidden": [String]()]]))
        live.applyPresence(PresenceInfo(user_id: "u1", online: true, last_seen: nil, hidden: false), userID: "u1", stamp: stamp)
        XCTAssertFalse(live.online.contains("u1"))
    }

    // MARK: IOS-PRES-7: nothing of one account's presence view survives sign-out

    @MainActor
    func testForgetPresenceEmptiesEverything() {
        let live = LiveConnection()
        live.handle(frame(["type": "presence_snapshot", "data": ["online": ["u1"], "last_seen": ["u2": 1_700_000_000], "hidden": ["u3"]]]))
        XCTAssertFalse(live.online.isEmpty)
        let stamp = live.presenceStamp("u1")
        live.forgetPresence()
        XCTAssertTrue(live.online.isEmpty)
        XCTAssertTrue(live.lastSeen.isEmpty)
        XCTAssertTrue(live.hiddenPresence.isEmpty)
        live.applyPresence(PresenceInfo(user_id: "u1", online: true, last_seen: nil, hidden: false), userID: "u1", stamp: stamp)
        XCTAssertTrue(live.online.isEmpty, "an answer asked for by the last account is dropped")
    }

    // MARK: IOS-NET-3: the same interfaces in another order keep the socket

    func testNetworkChangeOnlyForARealSwitch() {
        XCTAssertFalse(NetworkChange.needsNewSocket(before: ["wifi", "cell"], after: ["cell", "wifi"]), "reordered, same set")
        XCTAssertFalse(NetworkChange.needsNewSocket(before: ["wifi"], after: ["wifi", "cell"]), "mobile data joined, Wi-Fi still leads")
        XCTAssertFalse(NetworkChange.needsNewSocket(before: [String](), after: ["wifi"]), "first answer")
        XCTAssertTrue(NetworkChange.needsNewSocket(before: ["wifi", "cell"], after: ["cell"]), "Wi-Fi gone")
        XCTAssertTrue(NetworkChange.needsNewSocket(before: ["cell"], after: ["wifi", "cell"]), "Wi-Fi joined and leads")
        XCTAssertTrue(NetworkChange.needsNewSocket(before: ["wifi"], after: ["cell"]))
    }

    // MARK: IOS-LC-1: an outbox that cannot be read is never saved over

    func testUnreadableOutboxIsNilNotEmpty() throws {
        let account = "acct-lc1-\(UUID().uuidString.prefix(8))"
        let conv = "dm_lc1"
        XCTAssertEqual(OutboxStore.loadIfReadable(account: account, conversation: conv)?.count, 0, "no file: an empty outbox")
        let dir = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("outbox/\(account)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(conv).json")
        try Data("not json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(OutboxStore.loadIfReadable(account: account, conversation: conv), "a file that cannot be read is not an empty outbox")
        XCTAssertEqual(OutboxStore.load(account: account, conversation: conv).count, 0)
    }

    // MARK: source guards (the build Mac has the sources next to the tests; skipped elsewhere)

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("sources not reachable") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// IOS-PRES-2: the first scene phase never reaches onChange, so syncLive sets "in front" itself before the socket starts.
    func testSyncLiveSetsActiveBeforeStarting() throws {
        let s = try source("Tradeflor/App/TradeflorApp.swift")
        let body = try XCTUnwrap(s.range(of: "private func syncLive()").map { String(s[$0.upperBound...]) })
        let active = try XCTUnwrap(body.range(of: "live.setActive(UIApplication.shared.applicationState != .background)"))
        let start = try XCTUnwrap(body.range(of: "live.start(token:"))
        XCTAssertLessThan(active.lowerBound, start.lowerBound)
    }

    /// IOS-LC-1: the outbox stays readable while the phone is locked.
    func testOutboxNotCompleteProtection() throws {
        let s = try source("Tradeflor/Features/Chat/Outbox.swift")
        XCTAssertFalse(s.contains(".completeFileProtection]"))
        XCTAssertTrue(s.contains(".completeFileProtectionUntilFirstUserAuthentication"))
    }

    /// IOS-APL-3/4: a privacy manifest is shipped, and no background mode is declared that nothing uses.
    func testPrivacyManifestAndBackgroundModes() throws {
        let yml = try source("project.yml")
        XCTAssertTrue(yml.contains("UIBackgroundModes: [audio, location, voip]"))
        let manifest = try source("Tradeflor/PrivacyInfo.xcprivacy")
        XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        // the manifest is in the app bundle (copied as a resource)
        XCTAssertNotNil(Bundle(for: LiveConnection.self).url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }

    /// IOS-APL-5: the PushKit registry is never dropped at sign-out, and a push with no session is reported and ended.
    func testVoIPRegistryLivesInEveryState() throws {
        let s = try source("Tradeflor/Core/PushManager.swift")
        XCTAssertFalse(s.contains("registry = nil"))
        XCTAssertTrue(s.contains("CallManager.shared.reportEndedPushCall(callID: callID)"))
    }
}
