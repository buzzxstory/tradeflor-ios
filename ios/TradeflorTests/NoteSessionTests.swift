import XCTest
@testable import Tradeflor

/// Shared Notes (2026-11-21): the open-note sync on a fake server, the same cases as the web's tests/noteSession.test.ts.
/// Typing goes out in small batches, a batch whose answer was lost is sent again unchanged (same operation ids), someone else's
/// change is merged into what I am typing, and changes not accepted yet survive closing the note.
@MainActor
final class NoteSessionTests: XCTestCase {
    final class MemStore: NotePendingStore {
        var m: [String: Data] = [:]
        func get(_ key: String) -> Data? { m[key] }
        func set(_ key: String, _ data: Data) { m[key] = data }
        func remove(_ key: String) { m[key] = nil }
        func removeAll(prefix: String) { m = m.filter { !$0.key.hasPrefix(prefix) } }
    }

    final class Shared {
        var text = "Buy coffee"
        var brev = 1
        var rev = 1
        var applied = Set<String>()
    }

    final class Timer { let ms: Int; let f: @MainActor () async -> Void; init(_ ms: Int, _ f: @escaping @MainActor () async -> Void) { self.ms = ms; self.f = f } }

    static func note(_ rev: Int) -> SharedNote { SharedNote(id: "nt_1", conversation_id: "dm_a_b", title: "Plan", rev: rev) }
    static func block(_ text: String, _ rev: Int, by: String = "me") -> NoteBlock {
        NoteBlock(id: "blk1", section: "notes", type: "p", pos: "V", text: text, rev: rev, note_rev: rev, updated_by: by, updated_at: 1)
    }

    /// A fake server holding one block; applies text splices exactly like the real one for the cases used here.
    final class Harness {
        let sh: Shared
        var sent: [[NoteOp]] = []
        var timers: [Timer] = []
        var s: NoteSession!
        var fail: () -> Bool = { false }
        var loseAnswer: () -> Bool = { false }
        var hold: (() async -> Void)?

        @MainActor
        init(storage: NotePendingStore = MemStore(), shared: Shared = Shared(), fail: @escaping () -> Bool = { false },
             loseAnswer: @escaping () -> Bool = { false }, hold: (() async -> Void)? = nil) {
            sh = shared
            self.fail = fail
            self.loseAnswer = loseAnswer
            self.hold = hold
            var deps = NoteSession.Deps(
                getNote: { [unowned self] _ in NoteState(note: NoteSessionTests.note(self.sh.rev), blocks: [NoteSessionTests.block(self.sh.text, self.sh.brev)], tasks: []) },
                sendOps: { [unowned self] ops, _ in try await self.apply(ops) },
                watch: {},
                storage: storage)
            deps.setTimer = { [unowned self] ms, f in
                let t = Timer(ms, f)
                self.timers.append(t)
                return t
            }
            deps.clearTimer = { [unowned self] t in self.timers.removeAll { $0 === t } }
            s = NoteSession(myId: "me", noteId: "nt_1", deps: deps)
        }

        @MainActor
        func apply(_ ops: [NoteOp]) async throws -> NoteOpsAnswer {
            sent.append(ops)
            if fail() { throw NoteHTTPError(status: 0) }
            var results: [NoteOpResult] = []
            for o in ops {
                if sh.applied.contains(o.op_id) { results.append(NoteOpResult(op_id: o.op_id, status: "duplicate")); continue }
                sh.applied.insert(o.op_id)
                sh.rev += 1
                if o.op == "block.text" {
                    sh.text = NoteRules.applySplice(sh.text, o.from ?? 0, o.to ?? 0, o.insert ?? "")
                    sh.brev += 1
                }
                results.append(NoteOpResult(op_id: o.op_id, status: "applied", rev: sh.rev, block: NoteSessionTests.block(sh.text, sh.brev)))
            }
            if let hold { await hold() }
            if loseAnswer() { throw NoteHTTPError(status: 0) }
            return NoteOpsAnswer(note: NoteSessionTests.note(sh.rev), results: results)
        }

        @MainActor
        func runTimers() async {
            var i = 0
            while i < 20, let t = timers.first(where: { $0.ms < 20_000 }) {
                timers.removeAll { $0 === t }
                await t.f()
                i += 1
            }
        }

        var server: String { sh.text }

        @MainActor
        func remote(_ from: Int, _ to: Int, _ insert: String) {
            sh.text = NoteRules.applySplice(sh.text, from, to, insert)
            sh.brev += 1
            sh.rev += 1
            let ev: [String: Any] = ["type": "note.change", "data": [
                "note": ["id": "nt_1", "conversation_id": "dm_a_b", "title": "Plan", "rev": sh.rev, "can_edit": true, "can_manage": true],
                "by": "bob",
                "blocks": [["id": "blk1", "section": "notes", "type": "p", "pos": "V", "text": sh.text, "rev": sh.brev, "note_rev": sh.brev, "updated_by": "bob"]],
                "splices": [["block_id": "blk1", "block_rev": sh.brev, "from": from, "to": to, "insert": insert]],
            ]]
            s.onLive(try! JSONSerialization.data(withJSONObject: ev))
        }
    }

    func testTypingIsSentAsOneSmallSpliceThenSaved() async {
        let h = Harness()
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee")
        h.s.setBlockText("blk1", "Buy coffee and")
        h.s.setBlockText("blk1", "Buy coffee and milk")
        XCTAssertEqual(h.s.view().status, .saving)
        await h.runTimers()
        XCTAssertEqual(h.sent.count, 1, "one request for the whole burst of typing")
        XCTAssertEqual(h.sent[0].map { "\($0.op) \($0.from ?? -1) \($0.to ?? -1) \($0.insert ?? "")" }, ["block.text 10 10  and milk"])
        XCTAssertEqual(h.server, "Buy coffee and milk")
        XCTAssertEqual(h.s.view().status, .saved)
        h.s.dispose()
    }

    func testLostAnswerIsResentUnchangedAndAppliedOnce() async {
        var failures = 1
        let h = Harness(fail: { defer { failures -= 1 }; return failures > 0 })
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee!")
        await h.runTimers()
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent[1], h.sent[0], "the same operations, the same ids")
        XCTAssertEqual(h.server, "Buy coffee!", "applied once")
        h.s.dispose()
    }

    func testSomeoneElsesChangeWhileITypeBothKept() async {
        let h = Harness()
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee today")
        h.remote(4, 4, "fresh ")
        XCTAssertEqual(h.s.view().blocks[0].text, "Buy fresh coffee today", "my typing placed on Bob's text")
        await h.runTimers()
        XCTAssertEqual(h.server, "Buy fresh coffee today")
        h.s.dispose()
    }

    func testUnsentChangesSurviveClosingAndGoWithTheSameIds() async {
        let storage = MemStore()
        var offline = true
        let h1 = Harness(storage: storage, fail: { offline })
        await h1.s.start()
        h1.s.setBlockText("blk1", "Buy coffee beans")
        await h1.runTimers()
        XCTAssertEqual(h1.s.view().status, .offline)
        XCTAssertEqual(storage.m.count, 1, "kept on the device")
        let firstIds = h1.sent[0].map(\.op_id)
        h1.s.dispose()
        offline = false
        let h2 = Harness(storage: storage)
        await h2.s.start()
        await h2.runTimers()
        XCTAssertEqual(h2.sent[0].map(\.op_id), firstIds, "the unanswered batch goes again as it was")
        XCTAssertEqual(h2.server, "Buy coffee beans")
        XCTAssertEqual(storage.m.count, 0, "nothing left once accepted")
        h2.s.dispose()
    }

    func testSignOutRemovesEveryKeptNote() {
        let st = MemStore()
        st.set("tf.notes.pending.me.nt_1", Data("{}".utf8))
        st.set("tf.notes.pending.me.nt_2", Data("{}".utf8))
        st.set("other", Data("x".utf8))
        st.removeAll(prefix: NoteSession.storagePrefix)
        XCTAssertEqual(Array(st.m.keys), ["other"])
    }

    func testAppliedButAnswerLostThenReopenedTextAppearsOnce() async {
        let storage = MemStore()
        let shared = Shared()
        var lose = true
        let h1 = Harness(storage: storage, shared: shared, loseAnswer: { lose })
        await h1.s.start()
        h1.s.setBlockText("blk1", "Buy coffee beans")
        await h1.runTimers()
        XCTAssertEqual(shared.text, "Buy coffee beans", "the server did apply it")
        h1.s.dispose()
        lose = false
        let h2 = Harness(storage: storage, shared: shared)
        await h2.s.start()
        await h2.runTimers()
        XCTAssertEqual(shared.text, "Buy coffee beans", "not applied a second time")
        XCTAssertEqual(h2.s.view().blocks[0].text, "Buy coffee beans")
        XCTAssertEqual(h2.s.view().pending, 0)
        h2.s.dispose()
    }

    func testChangeArrivingWhileMineIsUnansweredIsNotDoubled() async {
        var release: CheckedContinuation<Void, Never>?
        var holding = true
        let h = Harness(hold: {
            if holding { await withCheckedContinuation { release = $0 } }
        })
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee AMAL")
        let flushing = Task { await h.runTimers() } // my change reaches the server, its answer is held back
        for _ in 0..<50 where release == nil { await Task.yield() }
        XCTAssertEqual(h.server, "Buy coffee AMAL", "the server has my change")
        h.remote(15, 15, " BADR") // Badr's change arrives (live) before my answer
        holding = false
        release?.resume()
        await flushing.value
        await h.runTimers()
        XCTAssertEqual(h.server, "Buy coffee AMAL BADR", "the server text has each change once")
        XCTAssertEqual(h.s.view().blocks[0].text, "Buy coffee AMAL BADR", "and so does my screen")
        XCTAssertEqual(h.s.view().pending, 0, "nothing left to send (no doubled text going back)")
        h.s.dispose()
    }

    func testMyOwnEchoIsIgnored() async {
        let h = Harness()
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee now")
        let ev: [String: Any] = ["type": "note.change", "data": [
            "note": ["id": "nt_1", "rev": 9, "can_edit": true], "client": h.s.client,
            "blocks": [["id": "blk1", "text": "something else", "rev": 5]]]]
        h.s.onLive(try! JSONSerialization.data(withJSONObject: ev))
        XCTAssertEqual(h.s.view().blocks[0].text, "Buy coffee now")
        h.s.dispose()
    }

    func testNeverSavedWhileSomethingIsUnsent() async {
        let h = Harness()
        await h.s.start()
        XCTAssertEqual(h.s.view().status, .saved)
        h.s.setBlockText("blk1", "Buy coffee now")
        XCTAssertEqual(h.s.view().status, .saving, "typed but not sent: never Saved")
        await h.runTimers()
        XCTAssertEqual(h.s.view().status, .saved)
        h.s.dispose()
    }

    func testNetworkLossSaysOfflineAndComingBackResendsAtOnceUnchanged() async {
        var offline = true
        let h = Harness(fail: { offline })
        await h.s.start()
        h.s.setBlockText("blk1", "Buy coffee beans")
        // the flush timer runs, the send fails; the retry timer waits (not run here)
        let flush = h.timers.first { $0.ms == NoteSession.flushMS }!
        h.timers.removeAll { $0 === flush }
        await flush.f()
        XCTAssertEqual(h.s.view().status, .offline)
        h.s.connectivity(false)
        XCTAssertEqual(h.s.view().status, .offline)
        offline = false
        h.s.connectivity(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.sent.count, 2, "sent again at once, not after the retry timer")
        XCTAssertEqual(h.sent[1], h.sent[0], "the same batch")
        XCTAssertEqual(h.server, "Buy coffee beans")
        XCTAssertEqual(h.s.view().status, .saved)
        h.s.dispose()
    }

    func testMeetingCardCountsFollowTheNotebook() {
        var t1 = NoteTask(id: "t1", pos: "a", title: "one"); t1.done = true
        var t2 = NoteTask(id: "t2", pos: "b", title: "two"); t2.done = true
        var gone = NoteTask(id: "t3", pos: "c", title: "x"); gone.deleted = true
        let st = NoteState(note: SharedNote(id: "mt_c1", title: "Weekly"), blocks: [
            NoteBlock(id: "b1", section: "notes", text: "hello"),
            NoteBlock(id: "b2", section: "decisions", text: "ship it"),
            NoteBlock(id: "b3", section: "notes", text: "  "),
        ], tasks: [t1, t2, gone])
        let c = MeetingNotesCard.Counts(st)
        XCTAssertEqual(c.title, "Weekly")
        XCTAssertEqual(c.tasks, 2)
        XCTAssertEqual(c.tasksDone, 2, "every task ticked shows as done")
        XCTAssertEqual(c.decisions, 1)
        XCTAssertEqual(c.items, 2)
    }
}
