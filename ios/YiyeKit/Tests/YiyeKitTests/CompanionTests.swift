import XCTest
@testable import YiyeKit

/// 陪玩模式（100）里不碰系统框架的几块
final class CompanionTests: XCTestCase {
    /// 跟 pc-butler handheld/luru.py 的 resized_size 一个结果（数是 Python 那头算出来的）
    func testResizedSizeMatchesButler() {
        let cases: [((Int, Int), (Int, Int))] = [
            ((1179, 2556), (1179, 2556)), ((1290, 2796), (1188, 2576)), ((2556, 1179), (2556, 1179)),
            ((1320, 2868), (1186, 2576)), ((3000, 4000), (1659, 2212)), ((4000, 3000), (2212, 1659)),
            ((800, 600), (800, 600)), ((2048, 2732), (1658, 2212)), ((5000, 100), (2576, 52)),
        ]
        for ((w, h), (ew, eh)) in cases {
            let (rw, rh) = BrainImage.resizedSize(w, h)
            XCTAssertEqual(rw, ew, "\(w)x\(h)")
            XCTAssertEqual(rh, eh, "\(w)x\(h)")
            XCTAssertLessThanOrEqual(BrainImage.tokens(rw, rh), BrainImage.maxTokens)
        }
    }

    func testLiveWireRoundTrip() {
        let req = LiveWire.request(token: "0123456789abcdef0123", id: "A1B2-C3")
        let p = LiveWire.parseRequest(req)
        XCTAssertEqual(p?.token, "0123456789abcdef0123")
        XCTAssertEqual(p?.id, "A1B2-C3")
        XCTAssertNil(LiveWire.parseRequest(Data("GET / HTTP/1.1\r\n".utf8)))
        XCTAssertNil(LiveWire.parseRequest(Data("YIYE1 short id\n".utf8)))
        XCTAssertNil(LiveWire.parseRequest(Data("YIYE1 0123456789abcdef0123 a/b\n".utf8)))

        let jpeg = Data((0..<300).map { UInt8($0 % 256) })
        let r = LiveWire.reply(.frame, jpeg: jpeg)
        let head = LiveWire.parseHead(r)
        XCTAssertEqual(head?.0, .frame)
        XCTAssertEqual(head?.1, 300)
        XCTAssertEqual(r.dropFirst(5), jpeg)
        XCTAssertEqual(LiveWire.parseHead(LiveWire.reply(.none))?.1, 0)
        XCTAssertEqual(LiveWire.parseHead(LiveWire.reply(.refused))?.0, .refused)
        XCTAssertNil(LiveWire.parseHead(Data([0, 0xff, 0xff, 0xff, 0xff])))   // 太大的不认
    }

    func testGateKeepsTheFirstToken() {
        var g = LiveWire.Gate()
        XCTAssertTrue(g.allow("app-token-0000000001"))
        XCTAssertTrue(g.allow("app-token-0000000001"))
        XCTAssertFalse(g.allow("someone-else-000000"))
    }

    /// 底噪 -60 分贝；说话 -30；说一秒停 0.8 秒算一句
    func testVoiceGateOneSentence() {
        var g = VoiceGate()
        var events: [VoiceGate.Event] = []
        for _ in 0..<50 { if let e = g.feed(db: -60, ms: 20) { events.append(e) } }
        XCTAssertTrue(events.isEmpty)
        for _ in 0..<50 { if let e = g.feed(db: -30, ms: 20) { events.append(e) } }     // 1 秒话
        XCTAssertEqual(events, [.start])
        for _ in 0..<30 { if let e = g.feed(db: -60, ms: 20) { events.append(e) } }     // 停 0.6 秒：还没完
        XCTAssertEqual(events.count, 1)
        for _ in 0..<10 { if let e = g.feed(db: -60, ms: 20) { events.append(e) } }     // 停够 0.8 秒
        guard case .end(let s)? = events.last else { return XCTFail("没说完：\(events)") }
        XCTAssertEqual(s, 1.0, accuracy: 0.05)
    }

    func testVoiceGateIgnoresClicksAndItself() {
        var g = VoiceGate()
        for _ in 0..<50 { _ = g.feed(db: -60, ms: 20) }
        XCTAssertNil(g.feed(db: -20, ms: 20))                                         // 一下咔哒
        XCTAssertNil(g.feed(db: -60, ms: 20))
        for _ in 0..<100 { XCTAssertNil(g.feed(db: -20, ms: 20, mute: true)) }        // 自己在放声音
        XCTAssertFalse(g.speaking)
        var ev: [VoiceGate.Event] = []
        for _ in 0..<8 { if let e = g.feed(db: -25, ms: 20) { ev.append(e) } }        // 0.16 秒：算开口
        for _ in 0..<45 { if let e = g.feed(db: -60, ms: 20) { ev.append(e) } }
        XCTAssertEqual(ev, [.start, .tooShort])                                          // 太短，不算一句
    }

    /// 底噪跟着游戏声往上走，人声比它高 12 分贝照样认得出
    func testVoiceGateNoisyRoom() {
        var g = VoiceGate()
        for _ in 0..<400 { _ = g.feed(db: -38 + Double.random(in: -2...2), ms: 20) }
        XCTAssertGreaterThan(g.noise, -42)
        var ev: [VoiceGate.Event] = []
        for _ in 0..<60 { if let e = g.feed(db: -18, ms: 20) { ev.append(e) } }
        for _ in 0..<45 { if let e = g.feed(db: -38, ms: 20) { ev.append(e) } }
        XCTAssertEqual(ev.first, .start)
        if case .end = ev.last {} else { XCTFail("\(ev)") }
    }

    func testLookRequestAndAnswer() throws {
        let req = ButlerRequest.look(id: "LOOK-0001", question: "export curbs 是什么意思", image: "陪玩/LOOK-000-屏.jpg",
                                     at: "2026-11-24T10:00:00+08:00", app: "0.7.0", prev: ["asr": 0.6, "total": 5.2])
        let env = MailEnvelope.request(req, files: ["陪玩/LOOK-000-屏.jpg": Data([0xff, 0xd8])])
        let back = try MailEnvelope.decode(env.encoded())
        XCTAssertEqual(back.request?.ask, "look")
        XCTAssertEqual(back.request?.images ?? [], ["陪玩/LOOK-000-屏.jpg"])
        XCTAssertEqual(back.request?.timing?["total"], 5.2)
        XCTAssertNil(ButlerRequest.look(id: "LOOK-0002", question: "q", image: nil, at: "", app: "").timing)
        XCTAssertEqual(ButlerRequest.lookWarm(id: "WARM-0001", at: "", app: "").ask, "look-warm")

        // 大管家（Python）回的样子：timing 里混了个 true 也不能把整封信弄坏
        let json = #"{"v":2,"kind":"result","id":"LOOK-0001","at":"x","data":{"v":1,"id":"LOOK-0001","note":"","ok":true,"text":"出口限制","changes":"","error":null,"model":"claude-opus-5-5","at":"x","host":"电脑","audio":"陪玩/LOOK-000-答.mp3","timing":{"brain":2.2,"warm":true}},"files":{"陪玩/LOOK-000-答.mp3":"SUQz"}}"#
        let res = try MailEnvelope.decode(Data(json.utf8))
        XCTAssertEqual(res.result?.audio, "陪玩/LOOK-000-答.mp3")
        XCTAssertEqual(res.result?.host, "电脑")
        XCTAssertEqual(res.result?.text, "出口限制")
        let a = MailAction.decide(res, waiting: [:], dubbing: [:], looks: ["LOOK-0001"])
        XCTAssertEqual(a, .look(res.result!, audio: Data("ID3".utf8)))
        XCTAssertEqual(MailAction.decide(res, waiting: [:], dubbing: [:]), .drop("没人在等 LOOK-0001"))   // 关了陪玩以后来的
    }

    func testClockSummary() {
        var c = LookClock(spokeEnd: 100)
        c.heard = 100.6; c.frame = 100.7; c.sent = 101.2; c.back = 105.0; c.playing = 105.1
        let s = c.summary(butler: ["brain": 2.2, "voice": 1.3, "fetch": 0.4, "warm": 1])
        XCTAssertEqual(s["asr"], 0.6)
        XCTAssertEqual(s["total"], 5.1)
        XCTAssertEqual(s["wait"], 3.8)
        XCTAssertEqual(s["bBrain"], 2.2)
        XCTAssertNil(s["warm"])
    }
}
