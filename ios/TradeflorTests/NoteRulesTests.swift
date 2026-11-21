import XCTest
@testable import Tradeflor

/// Shared Notes (2026-11-21): the same cases as the web's tests/noteRules.test.ts (and so the server's
/// sharednotes_text_test.go): the client and the server agree where a change lands, and typing is never lost.
final class NoteRulesTests: XCTestCase {
    typealias R = NoteRules

    func testConcurrentEditCasesMatchTheServer() {
        let cases: [(String, (Int, Int, String), (Int, Int, String), String)] = [
            ("hello world", (5, 5, ","), (11, 11, "!"), "hello, world!"),
            ("ab", (1, 1, "X"), (1, 1, "Y"), "aXYb"),
            ("the quick brown fox", (4, 9, "slow"), (6, 8, "Z"), "the slowZ brown fox"),
            ("draft", (0, 5, ""), (5, 5, " more"), " more"),
            ("مرحبا 👋 عالم", (6, 7, "🙂"), (12, 12, "!"), "مرحبا 🙂 عالم!"),
            ("abcdef", (1, 4, ""), (2, 5, ""), "af"),
        ]
        for (base, a, b, want) in cases {
            let afterA = R.applySplice(base, a.0, a.1, a.2)
            let tb = R.transformSplice(.init(from: b.0, to: b.1, ins: R.cpLen(b.2)), [.init(from: a.0, to: a.1, ins: R.cpLen(a.2))])
            XCTAssertTrue(R.same(R.applySplice(afterA, tb.from, tb.to, b.2), want), base)
        }
    }

    func testPositionsCountCodePoints() {
        XCTAssertEqual(R.cpLen("👋"), 1)
        XCTAssertEqual(R.applySplice("a👋b", 1, 2, "x"), "axb")
        XCTAssertEqual(R.diffSplice("a👋b", "a👋🙂b"), NoteRules.TextSplice(from: 2, to: 2, insert: "🙂"))
        // an Arabic letter with a mark is two code points (one grapheme): the server counts two
        XCTAssertEqual(R.cpLen("بُ"), 2)
    }

    func testMyTypingIsKeptOnTheirText() {
        XCTAssertEqual(R.rebaseLocal("Buy coffee", "Buy coffee today", [.init(from: 4, to: 4, insert: "fresh ")], "Buy fresh coffee"),
                       "Buy fresh coffee today")
        XCTAssertEqual(R.rebaseLocal("one two three", "one two and three", [.init(from: 0, to: 4, insert: "")], "two three"), "two and three")
        XCTAssertEqual(R.rebaseLocal("same", "same", [.init(from: 0, to: 0, insert: "x")], "xsame"), "xsame")
    }

    func testCarryTyping() {
        XCTAssertEqual(R.carryTyping("Plan A", "Plan A and B", "Plan A"), "Plan A and B")
        XCTAssertEqual(R.carryTyping("Plan A", "Plan A and B", "Bob: Plan A"), "Bob: Plan A and B")
        XCTAssertEqual(R.carryTyping("Plan A", "Plan A", "Bob: Plan A"), "Bob: Plan A")
    }

    func testCaretStaysWhereIWasTyping() {
        XCTAssertEqual(R.moveCaret("Hello world", "Hey, Hello world", 5), 10)
        XCTAssertEqual(R.moveCaret("Hello", "Hello!", 2), 2)
        // UTF-16 caret after an emoji (2 units) stays after it when text arrives at the start
        XCTAssertEqual(R.moveCaret("👋a", "x👋a", 2), 3)
    }

    func testPositionsBetweenAndOrder() {
        let p1 = R.posBetween("", "")
        let p2 = R.posBetween(p1, "")
        let mid = R.posBetween(p1, p2)
        XCTAssertTrue(R.bytesLess(p1, mid) && R.bytesLess(mid, p2), "\(p1) < \(mid) < \(p2)")
        XCTAssertTrue(R.bytesLess(R.posBetween("", "1"), "1"))
        struct I { let id: String; let pos: String; let section: String }
        let sorted = R.sortByPos([I(id: "b", pos: "V", section: "decisions"), I(id: "a", pos: "k", section: "notes"),
                                  I(id: "c", pos: "V", section: "notes")], pos: \.pos, id: \.id, section: \.section)
        XCTAssertEqual(sorted.map(\.id), ["c", "a", "b"])
    }

    func testInlineFormatting() {
        typealias S = R.InlineSeg
        XCTAssertEqual(R.inlineSegments("a **b** *c* __d__ [e](https://x.test/y) **f"), [
            S(text: "a "), S(text: "b", b: true), S(text: " "), S(text: "c", i: true), S(text: " "), S(text: "d", u: true), S(text: " "),
            S(text: "e", href: "https://x.test/y"), S(text: " **f"),
        ])
        XCTAssertEqual(R.inlineSegments("[x](javascript:alert(1))"), [S(text: "[x](javascript:alert(1))")], "only http(s) links")
        let w = R.toggleWrap("make this bold", 5, 9, "**")
        XCTAssertEqual(w.text, "make **this** bold"); XCTAssertEqual(w.start, 7); XCTAssertEqual(w.end, 11)
        let u = R.toggleWrap("make **this** bold", 7, 11, "**")
        XCTAssertEqual(u.text, "make this bold"); XCTAssertEqual(u.start, 5); XCTAssertEqual(u.end, 9)
    }

    func testMeetingLength() {
        XCTAssertEqual(R.meetingDuration(45_000), "45 sec")
        XCTAssertEqual(R.meetingDuration(32 * 60_000), "32 min")
        XCTAssertEqual(R.meetingDuration(65 * 60_000), "1 h 05 min")
    }

    func testUnknownTypeAndSectionReadAsParagraphInNotes() throws {
        let b = try JSONDecoder().decode(NoteBlock.self, from: Data(#"{"id":"b1","section":"later","type":"table","pos":"V","text":"x","rev":1}"#.utf8))
        XCTAssertEqual(b.type, "p")
        XCTAssertEqual(b.section, "notes")
    }

    func testMeetingCardIsRead() {
        let c = MeetingNotesCard.parse(#"{"note_id":"mt_c1","call_id":"c1","duration_ms":120000,"video":true,"items":3,"tasks":2,"tasks_done":1,"decisions":1,"edited_at":5,"contributors":2,"extra":1}"#)
        XCTAssertEqual(c?.note_id, "mt_c1")
        XCTAssertEqual(c?.tasks_done, 1)
        XCTAssertNil(MeetingNotesCard.parse("not json"))
        XCTAssertNil(MeetingNotesCard.parse(nil))
    }

    func testOpsLeaveOutEmptyFields() throws {
        var o = NoteOp(op_id: "op12345678", op: "block.text", id: "b1")
        o.base_rev = 1; o.from = 0; o.to = 0; o.insert = "x"
        let j = String(data: try JSONEncoder().encode(o), encoding: .utf8)!
        XCTAssertFalse(j.contains("title"))
        XCTAssertTrue(j.contains("\"base_rev\":1"))
    }
}
