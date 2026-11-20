import Combine
import XCTest
@testable import Tradeflor

/// The messaging, sync and network tasks of the communications audit of 2026-11-20 (IOS-MSG-1..5, IOS-SYNC-1/2, IOS-NET-2):
/// the pure decisions behind them.
final class MessagingAuditTests: XCTestCase {
    // MARK: helpers

    private func msg(id: String, seq: Int64, body: String = "x", kind: String = "text", replyTo: String? = nil,
                     snippet: String? = nil, edited: Int64? = nil, deleted: Int64? = nil,
                     delivered: Int64? = nil, read: Int64? = nil) throws -> Message {
        var o: [String: Any] = ["id": id, "conversation_id": "c1", "sender_id": "u1", "kind": kind, "body": body,
                                "seq": seq, "created_at": 1_763_251_200]
        if let replyTo { o["reply_to_id"] = replyTo; o["reply_sender_id"] = "u2" }
        if let snippet { o["reply_snippet"] = snippet }
        if let edited { o["edited_at"] = edited }
        if let deleted { o["deleted_at"] = deleted }
        if let delivered { o["delivered_at"] = delivered }
        if let read { o["read_at"] = read }
        let data = try JSONSerialization.data(withJSONObject: o)
        return try JSONDecoder().decode(Message.self, from: data)
    }

    private func http(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid/api/messages")!, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }

    // MARK: IOS-MSG-1: retries, Idempotency-Key, 409

    func testConflict409IsAClientBugNeverRetried() {
        XCTAssertEqual(SendPolicy.decide(APIError.server(status: 409)), .conflict)
        // a group text (postJSON) turns every 409 into `refused` with the server's text
        XCTAssertEqual(SendPolicy.decide(APIError.refused("this Idempotency-Key was already used for another conversation")), .conflict)
    }

    func testPassingErrorsWaitWithTheSameKey() {
        XCTAssertEqual(SendPolicy.decide(APIError.network), .wait)
        XCTAssertEqual(SendPolicy.decide(APIError.rateLimited), .wait)
        XCTAssertEqual(SendPolicy.decide(APIError.server(status: 503)), .wait)
        XCTAssertEqual(SendPolicy.decide(URLError(.notConnectedToInternet)), .wait)
        XCTAssertEqual(SendPolicy.decide(APIError.badCredentials), .signOut)
    }

    func test403AfterARetryIsFinalWithTheServersText() {
        XCTAssertEqual(SendPolicy.decide(APIError.refused("slow mode: wait 30s")), .final("slow mode: wait 30s"))
        XCTAssertEqual(SendPolicy.decide(APIError.server(status: 400)), .final(""))
    }

    func test409StatusMapsToServer409() {
        XCTAssertThrowsError(try APIClient.shared.check(http(409), Data("this Idempotency-Key was already used for another conversation".utf8))) { e in
            XCTAssertEqual(e as? APIError, .server(status: 409))
            XCTAssertEqual(SendPolicy.decide(e), .conflict)
        }
    }

    /// The key is created once with the message and survives a restart (the saved outbox); a 409 keeps it as "Not sent" and
    /// the background flusher never sends it again by itself.
    func testOutboxKeepsTheKeyAndAFailedEntryIsNeverFlushed() throws {
        let account = "acct-audit-\(UUID().uuidString.prefix(8))"
        let conv = "c-audit"
        AccountGate.set(Session(token: "tf_test", userID: account, username: "t"))
        defer {
            OutboxStore.clear(account: account, conversation: conv)
            AccountGate.set(Keychain.load())
        }
        let key = UUID().uuidString.lowercased()
        OutboxStore.save(account: account, conversation: conv, [PendingMessage(id: key, body: "hello", date: Date())])
        let loaded = OutboxStore.load(account: account, conversation: conv)
        XCTAssertEqual(loaded.map(\.id), [key], "the same key comes back after a restart")
        XCTAssertEqual(OutboxStore.lines(account: account).map(\.id), [key])

        OutboxStore.markFailed(account: account, conversation: conv, id: key) // what a 409 does
        XCTAssertTrue(OutboxStore.lines(account: account).isEmpty, "a failed entry is not flushed again")
        let again = OutboxStore.load(account: account, conversation: conv)
        XCTAssertEqual(again.first?.refused, true, "shown as Not sent")
        XCTAssertEqual(again.first?.id, key, "still the same key")
    }

    // MARK: IOS-MSG-2: a known id replaces the copy; quotes follow edits and deletes

    func testDeleteForEveryoneClearsTheQuoteOfReplies() throws {
        let original = try msg(id: "m1", seq: 1, body: "", deleted: 1_763_251_300)
        let reply = try msg(id: "m2", seq: 2, body: "ok", replyTo: "m1", snippet: "PIN 4242")
        let other = try msg(id: "m3", seq: 3, body: "unrelated", replyTo: "m9", snippet: "keep me")
        let out = try XCTUnwrap(MessageMerge.requote([original, reply, other], after: [original]))
        XCTAssertNil(out[1].reply_snippet, "the deleted text never stays inside a quote")
        XCTAssertEqual(out[2].reply_snippet, "keep me")
        XCTAssertEqual(out[1].reply_to_id, "m1", "the reply stays a reply")
    }

    func testEditRequotesReplies() throws {
        let edited = try msg(id: "m1", seq: 1, body: "PIN changed", edited: 1_763_251_400)
        let reply = try msg(id: "m2", seq: 2, replyTo: "m1", snippet: "PIN 4242")
        let out = try XCTUnwrap(MessageMerge.requote([edited, reply], after: [edited]))
        XCTAssertEqual(out[1].reply_snippet, "PIN changed")
        // nothing to change the second time
        XCTAssertNil(MessageMerge.requote(out, after: out))
    }

    func testReplyWithoutAQuoteIsLeftAlone() throws {
        let original = try msg(id: "m1", seq: 1, deleted: 1_763_251_300)
        let reply = try msg(id: "m2", seq: 2, replyTo: "m1", snippet: nil)
        XCTAssertNil(MessageMerge.requote([original, reply], after: [original]))
    }

    func testServerUpdateForAKnownIdIsAChangedCopy() throws {
        // the server's update for an existing reply: same id, quote gone. Message is Equatable, so the row redraws.
        let before = try msg(id: "m2", seq: 2, replyTo: "m1", snippet: "PIN 4242")
        let after = try msg(id: "m2", seq: 2, replyTo: "m1", snippet: nil)
        XCTAssertNotEqual(before, after)
        XCTAssertNil(MessageMerge.keepingReceipts(old: before, new: after).reply_snippet)
    }

    func testQuoteIsCutAt140BytesOnACharacterBoundary() {
        XCTAssertEqual(MessageMerge.quote(ofText: "short"), "short")
        let arabic = String(repeating: "م", count: 100) // 2 bytes each
        let q = MessageMerge.quote(ofText: arabic)
        XCTAssertEqual(q.utf8.count, 140)
        let mixed = String(repeating: "a", count: 139) + "\u{00E9}" // 139 + 2 bytes: the last letter does not fit
        XCTAssertEqual(MessageMerge.quote(ofText: mixed), String(repeating: "a", count: 139))
    }

    // MARK: IOS-MSG-3: deadlines and the send line

    func testVoiceDeadlineGrowsWithSizeAndIsCapped() {
        XCTAssertEqual(SendPolicy.voiceDeadline(bytes: 0), 120)
        XCTAssertEqual(SendPolicy.voiceDeadline(bytes: 2048 * 100), 220)
        XCTAssertEqual(SendPolicy.voiceDeadline(bytes: 50_000_000), 900)
    }

    func testATimedOutVoiceNoteStepsOutOfTheLine() {
        let now = Date()
        let queue = ["voice", "text1", "text2"]
        XCTAssertEqual(SendPolicy.decide(SendDeadlineExceeded()), .later)
        XCTAssertEqual(SendPolicy.nextInLine(queue, held: [:], now: now), "voice")
        let held = ["voice": now.addingTimeInterval(30)]
        XCTAssertEqual(SendPolicy.nextInLine(queue, held: held, now: now), "text1", "the texts behind it go")
        XCTAssertNil(SendPolicy.nextInLine(["voice"], held: held, now: now))
        XCTAssertEqual(SendPolicy.nextInLine(queue, held: held, now: now.addingTimeInterval(31)), "voice", "tried again later")
    }

    func testDeadlineGivesUp() async throws {
        let started = Date()
        do {
            _ = try await SendDeadline.run(seconds: 0.2) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
            XCTFail("the deadline should have passed")
        } catch {
            XCTAssertTrue(error is SendDeadlineExceeded)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let fast = try await SendDeadline.run(seconds: 5) { () async throws -> Int in 7 }
        XCTAssertEqual(fast, 7)
    }

    // MARK: IOS-MSG-4: refusals

    func testBlockedRefusalIsShownAndNotRetried() {
        let body = Data("cannot message a blocked contact\n".utf8)
        XCTAssertThrowsError(try APIClient.shared.check(http(403), body)) { e in
            XCTAssertEqual(e as? APIError, .refused("cannot message a blocked contact"))
            XCTAssertEqual(SendPolicy.decide(e), .final("cannot message a blocked contact"))
        }
        XCTAssertThrowsError(try APIClient.shared.check(http(401), Data())) { e in XCTAssertEqual(e as? APIError, .badCredentials) }
        XCTAssertThrowsError(try APIClient.shared.check(http(429, headers: ["Retry-After": "7"]), Data())) { e in
            XCTAssertEqual(e as? APIError, .rateLimited)
        }
        APIClient.shared.lastRetryAfter = 0
        XCTAssertNoThrow(try APIClient.shared.check(http(200), Data()))
    }

    // MARK: IOS-MSG-5: receipts

    func testReadNeverGoesBackToDelivered() throws {
        let read = try msg(id: "m1", seq: 1, delivered: 100, read: 200)
        let lateSendAnswer = try msg(id: "m1", seq: 1) // the send's 200 (or an older page), arriving after the receipt
        let kept = MessageMerge.keepingReceipts(old: read, new: lateSendAnswer)
        XCTAssertEqual(kept.read_at, 200)
        XCTAssertEqual(kept.delivered_at, 100)
        let deliveredLate = try msg(id: "m1", seq: 1, delivered: 100)
        XCTAssertEqual(MessageMerge.keepingReceipts(old: read, new: deliveredLate).read_at, 200, "read beats delivered")
        // forward still moves forward
        let delivered = try msg(id: "m1", seq: 1, delivered: 100)
        XCTAssertEqual(MessageMerge.keepingReceipts(old: delivered, new: read).read_at, 200)
    }

    func testReadMarkIsSentOnceThenOnlyForNewerIncoming() {
        XCTAssertTrue(ReadMark.due(newestIncoming: 0, marked: -1), "the first time")
        XCTAssertTrue(ReadMark.due(newestIncoming: 500, marked: -1))
        XCTAssertFalse(ReadMark.due(newestIncoming: 500, marked: 500), "a reload for a receipt or a reaction sends nothing")
        XCTAssertTrue(ReadMark.due(newestIncoming: 501, marked: 500))
    }

    // MARK: IOS-SYNC-1: nothing written for a signed-out account

    @MainActor
    func testNothingIsWrittenForASignedOutAccount() {
        let account = "acct-gone-\(UUID().uuidString.prefix(8))"
        let conv = "c-gone"
        AccountGate.set(Session(token: "tf_a", userID: account, username: "a"))
        defer { AccountGate.set(Keychain.load()) }
        XCTAssertTrue(AccountGate.isCurrent(account: account))
        XCTAssertTrue(AccountGate.isCurrent(token: "tf_a"))

        AccountGate.set(nil) // the sign-out
        XCTAssertFalse(AccountGate.isCurrent(account: account))
        XCTAssertFalse(AccountGate.isCurrent(token: "tf_a"))
        OutboxStore.save(account: account, conversation: conv, [PendingMessage(id: "k1", body: "late", date: Date())])
        XCTAssertTrue(OutboxStore.load(account: account, conversation: conv).isEmpty, "a late outbox write is dropped")
        ChatMemo.put(account: account, conv, [])
        XCTAssertNil(ChatMemo.get(account: account, conv), "a chat closing after the sign-out remembers nothing")

        // another account sharing the same group never sees the first account's copy
        AccountGate.set(Session(token: "tf_b", userID: "acct-b", username: "b"))
        XCTAssertNil(ChatMemo.get(account: "acct-b", conv))
        ChatMemo.drop(conv)
    }

    // MARK: IOS-NET-2: an expired session closes the socket, the next ticket is 401

    @MainActor
    func testTicket401SignsOutOnceAndAsksNoMoreTickets() async throws {
        let live = LiveConnection()
        var tickets = 0
        var signOuts = 0
        live.ticketURL = { _ in
            tickets += 1
            throw APIError.badCredentials
        }
        let sub = live.sessionInvalid.sink { _ in signOuts += 1 }
        defer { sub.cancel(); live.stop() }
        live.start(token: "tf_expired")
        for _ in 0..<40 where signOuts == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        // what used to start a loop again: a return to the app, a network change, a call
        live.probe()
        live.reconnectNow()
        live.proveForCall()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(signOuts, 1)
        XCTAssertEqual(tickets, 1)
        XCTAssertFalse(live.connected)
    }
}
