import Foundation
import XCTest
@testable import YiyeKit

/// 225：谁配的和几星（v3.21 / v3.22）、大管家译好的意思（v3.23）
final class Voice225Tests: XCTestCase {
    private func json<T: Decodable>(_ type: T.Type, _ s: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(s.utf8)) }

    // ---------------------------------------------------------------- 寄出去的请求
    func testRequestFields() throws {
        let r = ButlerRequest.voiceStars(id: "V-1", engine: "gemini", voice: "Achird", stars: 4, note: "N", at: "2026-11-27T20:00:00+08:00", app: "0.7.39")
        XCTAssertEqual(r.ask, "voice")
        XCTAssertEqual(r.kind, .text)
        XCTAssertEqual(r.text, "gemini:Achird 4星")
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        XCTAssertEqual(o["ask"] as? String, "voice")
        XCTAssertEqual(o["engine"] as? String, "gemini")
        XCTAssertEqual(o["voice"] as? String, "Achird")
        XCTAssertEqual(o["stars"] as? Int, 4)
        XCTAssertEqual(o["note"] as? String, "N")
        XCTAssertNil(o["mark"])                                                   // 带 stars 就不带 mark
        let zero = ButlerRequest.voiceStars(id: "V-2", engine: "edge", voice: "en-GB-RyanNeural", stars: 0, note: "N", at: "x", app: "0.7.39")
        XCTAssertEqual(zero.stars, 0)                                             // 0 = 清掉分
        XCTAssertEqual(zero.text, "edge:en-GB-RyanNeural 0星")
    }

    // ---------------------------------------------------------------- 排队
    func testQueueKeepsLastPerVoice() {
        var q = VoteQueue()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        q.add(engine: "gemini", voice: "Achird", stars: 5, note: "N", at: "a")
        q.add(engine: "edge", voice: "en-GB-RyanNeural", stars: 2, note: "N", at: "b")
        q.add(engine: "Gemini", voice: "achird", stars: 1, note: "M", at: "c")      // 同一个嗓子：只留最后一下
        XCTAssertEqual(q.items.map(\.stars), [2, 1])
        XCTAssertEqual(q.due(now: t0).count, 2)

        let key = VoiceRatings.key("gemini", "Achird")
        q.sending(key, id: "R1")
        q.sent("R1", at: t0)
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(60)).count, 1)             // 寄到了：等回信
        XCTAssertTrue(q.answered("R1", ok: false, at: t0))                          // 老大管家不认
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(60)).count, 1)
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(WordQueue.retryAfter)).count, 2)

        q.sending(key, id: "R2")
        q.add(engine: "gemini", voice: "Achird", stars: 3, note: "N", at: "d")      // 还在路上又点了一下
        XCTAssertFalse(q.answered("R2", ok: true))                                  // 旧那下的回信不认了
        q.sending(key, id: "R3")
        XCTAssertTrue(q.answered("R3", ok: true))
        XCTAssertEqual(q.items.map(\.stars), [2])
        XCTAssertEqual(VoteQueue.decode(q.encoded()), q)
        XCTAssertEqual(VoteQueue.decode(nil), VoteQueue())
    }

    func testVoteReplyRouting() {
        let r = ButlerResult(id: "R9", note: "N", ok: true, text: nil, changes: "Achird 4 星", error: nil)
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:], votes: ["R9"]), .vote(r))
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:]), .drop("没人在等 R9"))
    }

    // ---------------------------------------------------------------- 分：谁新用谁、撤回
    func testRatingsMergeNewerWins() {
        let key = VoiceRatings.key("gemini", "Achird")
        let phone = ISOTime.date("2026-11-27T20:00:00+08:00")!
        var r = VoiceRatings()
        r.delivered(ListenVoice(engine: "gemini", name: "Achird", label: "Achird"))             // 没打过分：不记
        XCTAssertNil(r.byKey[key])
        r.rate(key, 4, at: phone)
        r.delivered(ListenVoice(engine: "gemini", name: "Achird", label: "Achird", stars: 2, starsAt: "2026-11-27T19:00:00+08:00"))
        XCTAssertEqual(r.stars(key), 4)                                                          // 送来的旧：手机的算数
        r.delivered(ListenVoice(engine: "gemini", name: "Achird", label: "Achird", stars: 5, starsAt: "2026-11-27T21:00:00+08:00"))
        XCTAssertEqual(r.stars(key), 5)                                                          // 送来的新：用它
        r.delivered(ListenVoice(engine: "gemini", name: "Achird", label: "Achird", stars: 1))
        XCTAssertEqual(r.stars(key), 5)                                                          // 没写时间、手机记过：不动
        r.delivered(ListenVoice(engine: "gemini", name: "Achird", label: "Achird"))
        XCTAssertEqual(r.stars(key), 5)                                                          // 没带分：不动
        r.delivered(ListenVoice(engine: "edge", name: "x", label: "X", stars: 3))
        XCTAssertEqual(r.stars(VoiceRatings.key("edge", "x")), 3)                                // 手机没记过：用它
    }

    func testUndo() {
        var r = VoiceRatings()
        r.rate("k", 1)
        XCTAssertEqual(r.undo("k"), 0)              // 原来没打过：寄 0
        r.rate("k", 0)
        XCTAssertEqual(r.stars("k"), 0)
        r.rate("k", 4)
        r.rate("k", 1)
        XCTAssertEqual(r.undo("k"), 4)
        r.rate("k", 2)                               // 1 又改 2：撤回还是回到 4
        XCTAssertEqual(r.undo("k"), 4)
        r.rate("k", r.undo("k"))
        XCTAssertEqual(r.stars("k"), 4)
        XCTAssertTrue(VoiceRatings.banned(1) && VoiceRatings.banned(2))
        XCTAssertFalse(VoiceRatings.banned(0) || VoiceRatings.banned(3))
        r.rate("k", 9)
        XCTAssertEqual(r.stars("k"), 5)
    }

    // ---------------------------------------------------------------- 送来的信
    private let article = """
    {"v":1,"id":"6B2E1A2C-5D3F-4E8A-9B10-77C2D4E5F601","kind":"listen","title":"T (Achird)","text":"# T (Achird)\\nHello there.",
     "audio":"附件/6B2E1A2C-听-1.mp3","marks":[{"t":0,"s":"T (Achird)"}],"at":"2026-11-28T06:46:00+08:00"}
    """

    func testOldDeliveryHasNoVoice() throws {
        let d = try json(ButlerDelivery.self, article)
        XCTAssertNil(d.voice)
        XCTAssertNil(d.trans)
        XCTAssertFalse(d.isTransLetter)
        var e = ListenExtras()
        e.delivered(audio: "附件/a.mp3", voice: d.voice, trans: d.trans)
        XCTAssertNil(e.voice(for: "附件/a.mp3"))                       // 老稿没有 voice：那一行不显示
        XCTAssertTrue(e.isEmpty)
    }

    func testVoiceAndExtras() throws {
        let d = try json(ButlerDelivery.self, """
        {"v":1,"id":"X","kind":"listen","text":"hi","audio":"附件/x.mp3","voice":{"engine":"gemini","name":"Achird","label":"Achird","stars":4,"stars_at":"2026-11-27T12:30:00+08:00"}}
        """)
        XCTAssertEqual(d.voice?.stars, 4)
        XCTAssertEqual(d.voice?.starsAt, "2026-11-27T12:30:00+08:00")
        var e = ListenExtras()
        e.delivered(audio: "附件/x.mp3", voice: d.voice, trans: nil)
        XCTAssertEqual(e.voice(for: "附件/x.mp3")?.shown, "Achird")
        XCTAssertNil(e.voice(for: "附件/x-念-1.m4a"))                   // 手机自己重念的不算它配的
        e.delivered(audio: "附件/x2.mp3", voice: nil, trans: nil)       // 重配、没带嗓子：清掉
        XCTAssertNil(e.voice(for: "附件/x2.mp3"))
        // voice 缺字段、类型不对：稿子照收，只是不显示
        let bad = try json(ButlerDelivery.self, #"{"v":1,"id":"Y","kind":"listen","text":"hi","audio":null,"voice":{"label":3},"trans":"??"}"#)
        XCTAssertEqual(bad.text, "hi")
        XCTAssertFalse(bad.voice?.usable ?? false)
        XCTAssertTrue(bad.trans?.isEmpty ?? true)
    }

    // ---------------------------------------------------------------- 补译的信
    func testTransLetter() throws {
        let raw = """
        {"v":2,"kind":"delivery","id":"L-1","at":"2026-11-28T06:50:00+08:00","data":{"v":1,"id":"L-1","kind":"listen","note":"6B2E1A2C-5D3F-4E8A-9B10-77C2D4E5F601",
         "trans":{"v":1,"lines":[{"s":"Hello there.","zh":"你好。","w":{"hello":"你好"},"p":[]}]},"at":"2026-11-28T06:50:00+08:00"}}
        """
        let env = try MailEnvelope.decode(Data(raw.utf8))                // 不带 text：不能当坏信丢掉
        let d = try XCTUnwrap(env.delivery)
        XCTAssertTrue(d.isTransLetter)
        XCTAssertEqual(d.text, "")
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .deliver(d, audio: nil))
        // 只挂 trans，录音和嗓子不动
        let v = ListenVoice(engine: "gemini", name: "Achird", label: "Achird")
        var e = ListenExtras(audio: "附件/a.mp3", voice: v)
        e.delivered(audio: nil, voice: nil, trans: d.trans)
        XCTAssertEqual(e.audio, "附件/a.mp3")
        XCTAssertEqual(e.voice, v)
        XCTAssertEqual(e.trans?.line(for: "Hello there.")?.zh, "你好。")
        // 补译先到、稿子后到（稿子不带 trans）：译文留着
        var early = ListenExtras()
        early.delivered(audio: nil, voice: nil, trans: d.trans)
        early.delivered(audio: "附件/a.mp3", voice: v, trans: nil)
        XCTAssertEqual(early.trans, d.trans)
        XCTAssertEqual(early.voice(for: "附件/a.mp3"), v)
        let back = try JSONDecoder().decode(ListenExtras.self, from: JSONEncoder().encode(early))
        XCTAssertEqual(back, early)
    }

    // ---------------------------------------------------------------- 点词、点句查大管家的
    private let line = ListenTrans.Line(
        s: "The Prime Minister's talks pull out boxes in Iran’s capital, U.S. aides say.",
        zh: "首相的谈判……",
        w: ["the": "这个", "minister": "部长", "talk": "谈判", "box": "盒子", "iran": "伊朗", "u.s": "美国", "aide": "助手", "capital": "首都"],
        p: [.init(t: "Prime Minister", zh: "首相"), .init(t: "pull out", zh: "撤出"), .init(t: "ide", zh: "不该中")])

    private func range(_ word: String) -> NSRange { (line.s as NSString).range(of: word) }
    private func look(_ word: String) -> TransLookup.Hit? { TransLookup.word(range(word), in: line.s, line: line) }

    func testLineMatchesBySentence() {
        let t = ListenTrans(lines: [line, .init(s: "Second one.", zh: "第二句。")])
        XCTAssertEqual(t.line(for: "Second one.")?.zh, "第二句。")
        XCTAssertEqual(t.line(for: " Second  one. ")?.zh, "第二句。")
        XCTAssertNil(t.line(for: "Third."))
    }

    func testBadLineIsSkipped() throws {
        let t = try json(ListenTrans.self, #"{"v":1,"lines":[{"zh":"没有原句"},{"s":"A.","zh":"甲","w":{"a":"一个"}},7]}"#)
        XCTAssertEqual(t.lines.map(\.s), ["A."])
        XCTAssertEqual(t.lines.first?.p, [])
    }

    func testWordDirectAndSuffixes() {
        XCTAssertEqual(look("The")?.zh, "这个")                 // 小写原样
        XCTAssertEqual(look("capital")?.zh, "首都")
        XCTAssertEqual(look("talks")?.zh, "谈判")               // 复数 s
        XCTAssertEqual(look("boxes")?.zh, "盒子")               // es
        XCTAssertEqual(look("Iran’s")?.zh, "伊朗")              // 's
        XCTAssertEqual(look("U.S.")?.zh, "美国")                // 末尾的点去掉
        XCTAssertEqual(look("aides")?.zh, "助手")               // 「ide」是半个词，不算词组
        XCTAssertNil(look("say"))                               // 没有：苹果翻译兜底
    }

    func testPhraseWinsAndCoversWholePhrase() {
        for w in ["Prime", "Minister"] {
            let hit = look(w)
            XCTAssertEqual(hit?.zh, "首相")
            XCTAssertEqual(hit?.text, "Prime Minister")
            XCTAssertEqual(hit?.range, range("Prime Minister"))
        }
        XCTAssertEqual(look("Minister's")?.text, "Prime Minister")        // 带 's 的那个词也算在词组里
        XCTAssertEqual(look("out")?.text, "pull out")
        XCTAssertEqual(look("out")?.zh, "撤出")
        XCTAssertNil(TransLookup.word(NSRange(location: 999, length: 3), in: line.s, line: line))
    }
}
