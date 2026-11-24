import XCTest
@testable import YiyeKit

/// 深聊（pc-butler 施工单 107）里不碰系统框架的几块
final class DeepTests: XCTestCase {
    /// 30 分钟内接着问是同一个话题；隔了 30 分钟换新号；没真问过的不算
    func testTopicThirtyMinutes() {
        var n = 0
        let make = { () -> String in n += 1; return "T\(n)" }
        var t = DeepTopic(id: "T0")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(t.current(t0, make: make), "T0")
        t.asked(t0)
        XCTAssertEqual(t.current(t0.addingTimeInterval(29 * 60), make: make), "T0")
        t.asked(t0.addingTimeInterval(29 * 60))
        XCTAssertEqual(t.current(t0.addingTimeInterval(58 * 60), make: make), "T0", "从上一次真问算")
        XCTAssertEqual(t.current(t0.addingTimeInterval(29 * 60 + 30 * 60 + 1), make: make), "T1", "隔了 30 分钟换新号")
        XCTAssertNil(t.last)
        XCTAssertEqual(t.current(t0.addingTimeInterval(5 * 3600), make: make), "T1", "新号没真问过：一直用它")
        t.asked(t0.addingTimeInterval(5 * 3600))
        t.renew(make: make)
        XCTAssertEqual(t.id, "T2", "换个话题")
        XCTAssertNil(t.last)
    }

    func testTroubleSaidOncePerTenMinutes() {
        var l = TroubleLimiter()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(l.allow("away", now: t0))
        XCTAssertFalse(l.allow("away", now: t0.addingTimeInterval(9 * 60)))
        XCTAssertTrue(l.allow("noMail", now: t0.addingTimeInterval(60)), "别的一类照念")
        XCTAssertTrue(l.allow("away", now: t0.addingTimeInterval(10 * 60 + 1)))
    }

    func testDeepWords() {
        XCTAssertEqual(CompanionTrouble.deepNoAnswer.words, "大管家没想出来，再问一次？")
        XCTAssertEqual(CompanionTrouble.deepCut.words, "深聊被电话打断了，点一下重开")
        XCTAssertFalse(CompanionTrouble.deepNoAnswer.keepsGoing)
        XCTAssertEqual(Deep.endSilenceMs, 1500)
        XCTAssertEqual(Deep.saysGot, "收到，想好了叫你")
    }

    /// 深聊停 1.5 秒才算一句：停 1 秒还没完；一直说 70 秒截在 60 秒
    func testCutterWaitsLongerInDeep() {
        let quiet = [Float](repeating: Float(pow(10, -70.0 / 20)), count: 320)
        let loud = [Float](repeating: Float(pow(10, -30.0 / 20)), count: 320)
        var c = ClipCutter()
        c.gate.endSilenceMs = Deep.endSilenceMs
        c.gate.maxMs = Deep.maxSeconds * 1000
        c.maxSeconds = Deep.maxSeconds
        for _ in 0..<50 { _ = c.feed(quiet) }
        var ev: [ClipCutter.Out] = []
        for _ in 0..<50 { if let e = c.feed(loud) { ev.append(e) } }
        for _ in 0..<50 { if let e = c.feed(quiet) { ev.append(e) } }          // 停 1 秒
        XCTAssertEqual(ev, [.start])
        for _ in 0..<25 { if let e = c.feed(quiet) { ev.append(e) } }          // 停够 1.5 秒
        if case .clip? = ev.last {} else { XCTFail("\(ev)") }

        var d = ClipCutter()
        d.gate.endSilenceMs = Deep.endSilenceMs
        d.gate.maxMs = Deep.maxSeconds * 1000
        d.maxSeconds = Deep.maxSeconds
        for _ in 0..<50 { _ = d.feed(quiet) }
        var got: Double?
        for _ in 0..<(70 * 50) {
            if case .clip(_, let s, _)? = d.feed(loud) { got = s; break }
        }
        XCTAssertEqual(got ?? 0, 60, accuracy: 0.001)
    }

    func testDeepRequestAndResults() throws {
        let id = "DEEP0001-0000"
        let ap = ButlerRequest.deepAudioPath(id)
        XCTAssertEqual(ap, "深聊/DEEP0001-问.wav")
        let r = ButlerRequest.deep(id: id, audio: ap, topic: "TOPIC-1", at: "x", app: "0.7.5", prev: ["deep": 1, "rec": 3.2])
        XCTAssertEqual(r.ask, "deep")
        XCTAssertEqual(r.text, "")
        XCTAssertNil(r.images)
        let env = MailEnvelope.request(r, files: [ap: Wav.encode([0, 0.2])])
        let back = try MailEnvelope.decode(env.encoded())
        XCTAssertEqual(back.request?.topic, "TOPIC-1")
        XCTAssertEqual(back.request?.audio, ap)
        XCTAssertEqual(back.request?.timing?["deep"], 1)
        XCTAssertEqual(ButlerRequest.deepWarm(id: "W", at: "", app: "").ask, "deep-warm")
        // 陪玩的请求不带 topic
        XCTAssertFalse(String(decoding: try Butler.encoder().encode(ButlerRequest.lookWarm(id: "W", at: "", app: "")), as: UTF8.self).contains("topic"))

        // 大管家（Python）回的两封：先 ack，后 answer（同一个 id）
        let ack = #"{"v":2,"kind":"result","id":"DEEP0001-0000","at":"x","data":{"v":1,"id":"DEEP0001-0000","note":"","ok":true,"text":"收到，想好了叫你","changes":"","error":null,"stage":"ack","heard":"大管家，为什么新加坡能长期一党执政？","timing":{"asr":0.4}}}"#
        let a = try MailEnvelope.decode(Data(ack.utf8))
        XCTAssertEqual(a.result?.stage, "ack")
        XCTAssertEqual(MailAction.decide(a, waiting: [:], dubbing: [:], looks: [id]), .look(a.result!, audio: nil))
        let ans = #"{"v":2,"kind":"result","id":"DEEP0001-0000","at":"x","data":{"v":1,"id":"DEEP0001-0000","note":"","ok":true,"text":"完整版……","changes":"","error":null,"stage":"answer","title":"新加坡为什么一党长期执政","audio":"深聊/DEEP0001-答.mp3","timing":{"brain":180.2,"voice":30.1,"audioS":150}},"files":{"深聊/DEEP0001-答.mp3":"SUQz"}}"#
        let b = try MailEnvelope.decode(Data(ans.utf8))
        XCTAssertEqual(b.result?.title, "新加坡为什么一党长期执政")
        XCTAssertEqual(MailAction.decide(b, waiting: [:], dubbing: [:], looks: [id]), .look(b.result!, audio: Data("ID3".utf8)))
    }
}
