import XCTest
@testable import Tradeflor

/// The call engine's pure decisions (CallDecisions), against the server contract of 2026-11-20
/// (docs/audit-2026-11-20/SHARED_PROTOCOL_CONTRACT.md section 6 and IOS_ENGINEERING_TASKS.md IOS-CALL-1..7).
final class CallDecisionsTests: XCTestCase {
    private func local(_ callID: String?, _ phase: CallManager.Phase, role: CallManager.Role = .caller, acknowledged: Bool = true,
                       pc: Bool = true, mediaUp: Bool = false, endedHere: Set<String> = []) -> CallDecisions.Local {
        CallDecisions.Local(callID: callID, phase: phase, role: role, acknowledged: acknowledged, hasPeerConnection: pc,
                            mediaUp: mediaUp, endedHere: endedHere)
    }

    // MARK: IOS-CALL-1: a lost call.active / call.connected does not end a healthy call

    func testSyncActiveWhileConnectingMovesToActive() {
        let s = CallDecisions.Server(id: "c1", state: "active", role: "callee")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .connecting, role: .callee)), [.resume, .markActive])
    }

    func testSyncConnectingWithMediaUpResendsConnected() {
        let s = CallDecisions.Server(id: "c1", state: "connecting", role: "caller")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .connecting, mediaUp: true)), [.resume, .resendConnected])
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .active, mediaUp: true)), [.resume, .resendConnected])
        // media not up yet: nothing to claim, only what the gap lost is resent
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .connecting, mediaUp: false)), [.resume])
    }

    func testSyncActiveWhileActiveOnlyResumes() {
        let s = CallDecisions.Server(id: "c1", state: "active", role: "caller")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .active, mediaUp: true)), [.resume])
    }

    func testSyncWithoutPeerConnectionSetsItUp() {
        let s = CallDecisions.Server(id: "c1", state: "connecting", role: "caller")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("c1", .outgoing, pc: false)), [.acceptedLost])
    }

    // MARK: IOS-CALL-2: name the call; end leftovers after a relaunch

    func testSyncNamesTheHeldCallFirst() {
        XCTAssertEqual(CallDecisions.syncCallID(held: "held", pushRings: ["K1": "push1"], lastPushKey: "K1", rememberedIncoming: "r"), "held")
        XCTAssertEqual(CallDecisions.syncCallID(held: nil, pushRings: ["K1": "push1", "K2": "push2"], lastPushKey: "K2", rememberedIncoming: "r"), "push2")
        XCTAssertEqual(CallDecisions.syncCallID(held: nil, pushRings: ["K1": "push1"], lastPushKey: "gone", rememberedIncoming: "r"), "push1")
        XCTAssertEqual(CallDecisions.syncCallID(held: nil, pushRings: [:], lastPushKey: nil, rememberedIncoming: "r"), "r")
        XCTAssertNil(CallDecisions.syncCallID(held: nil, pushRings: [:], lastPushKey: nil, rememberedIncoming: nil))
    }

    func testLeftoverCallAfterRelaunchIsHungUp() {
        // relaunched: nothing held, no peer connection; the server still has our connecting/active call
        for state in ["connecting", "active"] {
            let s = CallDecisions.Server(id: "old", state: state, role: "caller")
            XCTAssertEqual(CallDecisions.syncActions(server: s, local: local(nil, .idle, pc: false)),
                           [.close(op: "call.hangup", callID: "old")])
        }
    }

    func testLeftoverRingWePlacedIsCancelled() {
        let s = CallDecisions.Server(id: "old", state: "ringing", role: "caller")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local(nil, .idle, pc: false)),
                       [.close(op: "call.cancel", callID: "old")])
    }

    func testRingForUsStillRings() {
        let s = CallDecisions.Server(id: "in", state: "ringing", role: "callee")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local(nil, .idle, pc: false)), [.ring])
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local(nil, .ended, pc: false)), [.ring])
    }

    func testCallEndedHereWhileOfflineIsClosedAgain() {
        let s = CallDecisions.Server(id: "x", state: "ringing", role: "callee")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local(nil, .ended, pc: false, endedHere: ["x"])),
                       [.close(op: "call.decline", callID: "x")])
    }

    func testNoCallOnServer() {
        XCTAssertEqual(CallDecisions.syncActions(server: nil, local: local("c1", .active)), [.endLost])
        XCTAssertEqual(CallDecisions.syncActions(server: nil, local: local("c1", .outgoing, acknowledged: false, pc: false)), [.resendInvite])
        XCTAssertEqual(CallDecisions.syncActions(server: nil, local: local(nil, .ended, pc: false)), [])
        XCTAssertEqual(CallDecisions.syncActions(server: nil, local: local(nil, .idle, pc: false)), [])
    }

    func testOtherSyncCases() {
        let ringing = CallDecisions.Server(id: "c1", state: "ringing", role: "caller")
        XCTAssertEqual(CallDecisions.syncActions(server: ringing, local: local("c1", .outgoing, acknowledged: false, pc: false)), [.acknowledge])
        XCTAssertEqual(CallDecisions.syncActions(server: ringing, local: local("c1", .outgoing, acknowledged: true, pc: false)), [])
        let stillRingingUs = CallDecisions.Server(id: "c1", state: "ringing", role: "callee")
        XCTAssertEqual(CallDecisions.syncActions(server: stillRingingUs, local: local("c1", .connecting, role: .callee, pc: false)), [.resendAccept])
    }

    // MARK: IOS-CALL-3: glare, merged_from

    func testMergedFromAdoptsTheCall() {
        let s = CallDecisions.Server(id: "theirs", state: "connecting", role: "callee", mergedFrom: "mine")
        XCTAssertEqual(CallDecisions.syncActions(server: s, local: local("mine", .outgoing, acknowledged: false, pc: false)),
                       [.adoptMerge(into: "theirs"), .acceptedLost])
        XCTAssertEqual(CallDecisions.mergeTarget(server: s, placed: "mine", phase: .outgoing), "theirs")
        // only while still placing it, and only for our own invite
        XCTAssertNil(CallDecisions.mergeTarget(server: s, placed: "mine", phase: .connecting))
        XCTAssertNil(CallDecisions.mergeTarget(server: s, placed: "other", phase: .outgoing))
        XCTAssertNil(CallDecisions.mergeTarget(server: CallDecisions.Server(id: "theirs"), placed: "mine", phase: .outgoing))
    }

    func testServerSummaryParsing() {
        let s = CallDecisions.Server(["call_id": "a", "state": "active", "role": "callee", "merged_from": "b"])
        XCTAssertEqual(s, CallDecisions.Server(id: "a", state: "active", role: "callee", mergedFrom: "b"))
        XCTAssertNil(CallDecisions.Server(nil))
        XCTAssertNil(CallDecisions.Server(["state": "active"]))
        XCTAssertNil(CallDecisions.Server(["call_id": "a", "merged_from": ""])?.mergedFrom)
    }

    // MARK: IOS-CALL-6: a repeated identical offer is harmless

    func testRepeatedOffer() {
        let offer = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n"
        XCTAssertTrue(CallDecisions.isRepeatedOffer(offer, lastApplied: offer, stable: true))
        XCTAssertFalse(CallDecisions.isRepeatedOffer(offer, lastApplied: offer, stable: false)) // mid-negotiation: normal path
        XCTAssertFalse(CallDecisions.isRepeatedOffer(offer, lastApplied: nil, stable: true))     // the first one
        XCTAssertFalse(CallDecisions.isRepeatedOffer(offer + "a=x\r\n", lastApplied: offer, stable: true)) // a new offer (ICE restart)
        XCTAssertEqual(CallDecisions.offerResendDelays.count, 3)
    }

    // MARK: IOS-CALL-7: a ring while placing a call

    func testRecheckIncomingAfterOurCallFails() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CallDecisions.shouldRecheckIncoming(rememberedAt: t, now: t.addingTimeInterval(20), ourCallConnected: false))
        XCTAssertFalse(CallDecisions.shouldRecheckIncoming(rememberedAt: t, now: t.addingTimeInterval(51), ourCallConnected: false))
        XCTAssertFalse(CallDecisions.shouldRecheckIncoming(rememberedAt: t, now: t.addingTimeInterval(5), ourCallConnected: true))
    }

    // MARK: IOS-CALL-5: TURN refresh and URLs

    func testIceRefreshDelay() {
        XCTAssertEqual(CallDecisions.iceRefreshDelay(ttl: 40), 32)    // 80 % of 40 s
        XCTAssertEqual(CallDecisions.iceRefreshDelay(ttl: 10), 30)    // never sooner than 30 s
        XCTAssertEqual(CallDecisions.iceRefreshDelay(ttl: 600), 480)
        XCTAssertEqual(CallDecisions.iceRefreshDelay(ttl: 43_200), 34_560)
        XCTAssertNil(CallDecisions.iceRefreshDelay(ttl: nil))         // older server: no refresh
        XCTAssertNil(CallDecisions.iceRefreshDelay(ttl: 0))
    }

    func testIceURLs() {
        XCTAssertTrue(CallDecisions.validICEURL("stun:turn.tradeflor.com:3478"))
        XCTAssertTrue(CallDecisions.validICEURL("turn:turn.tradeflor.com:3478?transport=udp"))
        XCTAssertTrue(CallDecisions.validICEURL("turns:turn.tradeflor.com:443?transport=tcp"))
        XCTAssertTrue(CallDecisions.validICEURL("turn:[2001:db8::1]:3478"))
        XCTAssertFalse(CallDecisions.validICEURL("stun:host?transport=udp"))   // transport for turn/turns only
        XCTAssertFalse(CallDecisions.validICEURL("turn:host?transport=sctp"))
        XCTAssertFalse(CallDecisions.validICEURL("https://turn.tradeflor.com"))
        XCTAssertFalse(CallDecisions.validICEURL("turn:"))
        XCTAssertFalse(CallDecisions.validICEURL("turn:bad host"))
    }
}
