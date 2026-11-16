import XCTest
@testable import Tradeflor

final class ModelsTests: XCTestCase {
    func testDecodesConversationSummaryFromServerShape() throws {
        let json = """
        [{"conversation_id":"c1","peer_id":"u2","peer_username":"sara","peer_display_name":"Sara",
          "last_message":"hi","last_message_at":1763251200000,"last_message_mine":true,"unread_count":2,
          "last_message_kind":"text","restricted":false,"disappear_secs":0,"last_message_status":"read"}]
        """
        let out = try JSONDecoder().decode([ConversationSummary].self, from: Data(json.utf8))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "Sara")
        XCTAssertEqual(out[0].unread_count, 2)
        XCTAssertEqual(out[0].lastDate, Date(timeIntervalSince1970: 1_763_251_200))
    }

    func testTitleFallsBackToUsername() throws {
        let json = """
        {"conversation_id":"c1","peer_id":"u2","peer_username":"sara","last_message":"",
         "last_message_at":1763251200,"last_message_mine":false,"unread_count":0}
        """
        let c = try JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
        XCTAssertEqual(c.title, "sara")
        XCTAssertEqual(c.lastDate, Date(timeIntervalSince1970: 1_763_251_200))
    }

    func testAPIBaseIsProduction() {
        XCTAssertEqual(AppConfig.apiBase.absoluteString, "https://app.tradeflor.com/api")
    }

    func testDecodesMessageAndLiveEvent() throws {
        let json = """
        {"type":"message","seq":9,"conversation_id":"c1","at":1763251200000,
         "data":{"id":"m1","conversation_id":"c1","sender_id":"u2","kind":"text","body":"مرحبا","seq":41,
                 "created_at":1763251200,"client_key":"k1","reactions":"{}","forwarded":false,"read_at":1763251300}}
        """
        let env = try JSONDecoder().decode(LiveEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.type, "message")
        let ev = try JSONDecoder().decode(LiveMessageEvent.self, from: Data(json.utf8))
        XCTAssertEqual(ev.data.body, "مرحبا")
        XCTAssertEqual(ev.data.seq, 41)
        XCTAssertEqual(ev.data.client_key, "k1")
        XCTAssertFalse(ev.data.isDeleted)
        XCTAssertEqual(ev.data.date, Date(timeIntervalSince1970: 1_763_251_200))
    }

    func testPongIsAnEnvelopeWithoutConversation() throws {
        let env = try JSONDecoder().decode(LiveEnvelope.self, from: Data(#"{"type":"pong","data":{"t":1},"at":2}"#.utf8))
        XCTAssertEqual(env.type, "pong")
        XCTAssertNil(env.conversation_id)
    }

    func testWaveformDownsampleKeepsPeaksAndLength() {
        let v = (0..<480).map { i in i == 100 ? 1.0 : 0.2 }
        let out = VoiceRecorder.downsample(v, to: 48)
        XCTAssertEqual(out.count, 48)
        XCTAssertEqual(out.max(), 1.0)
        XCTAssertEqual(VoiceRecorder.downsample([0.123, 0.5], to: 48), [0.12, 0.5])
    }

    func testVoiceLengthLabel() {
        XCTAssertEqual(VoiceBubble.length(65_400), "1:05")
        XCTAssertEqual(VoiceBubble.length(0), "0:00")
    }

    func testReactionsParseAndSort() throws {
        let json = """
        {"id":"m1","conversation_id":"c1","sender_id":"u2","kind":"text","body":"x","seq":1,"created_at":1,
         "reactions":"{\\"❤️\\":[\\"u1\\",\\"u2\\"],\\"👍\\":[\\"u3\\"],\\"😂\\":[]}"}
        """
        let m = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        let r = m.reactionList(me: "u1")
        XCTAssertEqual(r.map(\.emoji), ["❤️", "👍"])
        XCTAssertEqual(r.first?.count, 2)
        XCTAssertEqual(r.first?.mine, true)
    }
}
