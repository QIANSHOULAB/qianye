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
        var c = LookClock(spokeEnd: 100, rec: 2.34, peak: -31.26)
        c.frame = 100.1; c.frameOK = true; c.sent = 100.6; c.sentOK = true; c.back = 105.0; c.playing = 105.1; c.playOK = true
        let s = c.summary(butler: ["brain": 2.2, "voice": 1.3, "fetch": 0.4, "asr": 0.5, "warm": 1])
        XCTAssertEqual(s["gate"], 1)
        XCTAssertEqual(s["rec"], 2.34)
        XCTAssertEqual(s["peak"], -31.3)
        XCTAssertEqual(s["frame"], 0.1)
        XCTAssertEqual(s["frameOK"], 1)
        XCTAssertEqual(s["sentOK"], 1)
        XCTAssertEqual(s["backOK"], 1)
        XCTAssertEqual(s["playOK"], 1)
        XCTAssertEqual(s["total"], 5.1)
        XCTAssertEqual(s["wait"], 4.4)
        XCTAssertEqual(s["bBrain"], 2.2)
        XCTAssertEqual(s["bAsr"], 0.5)
        XCTAssertNil(s["warm"])

        // 寄出去了、回信没到：backOK = 0，没有 total
        var d = LookClock(spokeEnd: 10, rec: 1)
        d.frame = 10.1; d.frameOK = false; d.sent = 10.5; d.sentOK = true
        let t = d.summary()
        XCTAssertEqual(t["frameOK"], 0)
        XCTAssertEqual(t["backOK"], 0)
        XCTAssertNil(t["total"])
        XCTAssertNil(t["playOK"])
        // 没寄出去：没有 backOK
        var e = LookClock(spokeEnd: 10, rec: 1)
        e.sentOK = false
        XCTAssertNil(e.summary()["backOK"])
        XCTAssertEqual(e.summary()["sentOK"], 0)
    }

    // ---------------------------------------------------------------- 108 切句录音
    /// 20 毫秒一块（16 kHz 是 320 个样本），整块一个值：RMS 就是这个值
    private func chunk(_ db: Double) -> [Float] { [Float](repeating: Float(pow(10, db / 20)), count: 320) }

    private func run(_ c: inout ClipCutter, _ db: Double, _ n: Int, mute: Bool = false, strict: Bool = false) -> [ClipCutter.Out] {
        var out: [ClipCutter.Out] = []
        for _ in 0..<n { if let e = c.feed(chunk(db), mute: mute, strict: strict) { out.append(e) } }
        return out
    }

    /// 底噪 -70，说 1 秒（-30），停 0.8 秒：交出一句，从开口前 0.3 秒开始，带着后面那 0.8 秒
    func testCutterOneSentenceWithPreRoll() {
        var c = ClipCutter()
        XCTAssertTrue(run(&c, -70, 50).isEmpty)
        let talk = run(&c, -30, 50)
        XCTAssertEqual(talk, [.start])
        XCTAssertTrue(c.speaking)
        XCTAssertTrue(run(&c, -70, 39).isEmpty)                    // 停 0.78 秒：还没完
        let end = run(&c, -70, 1)
        guard case .clip(let s, let secs, let peak)? = end.first else { return XCTFail("没交出一句：\(end)") }
        let quiet = Float(pow(10, -70.0 / 20)) * 1.01
        let lead = s.prefix { $0 <= quiet }.count
        XCTAssertEqual(Double(lead) / 16_000, 0.3, accuracy: 0.025, "开口前留 0.3 秒")
        XCTAssertEqual(secs, Double(s.count) / 16_000, accuracy: 0.0001)
        XCTAssertEqual(secs, 0.32 + 1.0 + 0.8, accuracy: 0.03)
        XCTAssertEqual(peak, -30, accuracy: 0.2)
        XCTAssertFalse(c.speaking)
        XCTAssertTrue(c.clip.isEmpty)
    }

    /// 144：插嘴（strict）判开口要 0.5 秒，交出去的一句也是从开口前 0.3 秒起，判开口那 0.5 秒一点不丢
    func testCutterStrictKeepsSamePreRoll() {
        var c = ClipCutter()
        XCTAssertTrue(run(&c, -70, 50).isEmpty)
        XCTAssertEqual(run(&c, -20, 50, strict: true), [.start])
        _ = run(&c, -70, 39)
        guard case .clip(let s, _, _)? = run(&c, -70, 1).first else { return XCTFail("没交出一句") }
        let quiet = Float(pow(10, -70.0 / 20)) * 1.01
        let lead = s.prefix { $0 <= quiet }.count
        XCTAssertEqual(Double(lead) / 16_000, 0.3, accuracy: 0.025, "插嘴也是开口前留 0.3 秒")
    }

    /// 一直说 25 秒：第一句截在 20 秒整
    func testCutterCapsAtTwentySeconds() {
        var c = ClipCutter()
        _ = run(&c, -70, 50)
        let out = run(&c, -30, 25 * 50)
        guard case .clip(let s, let secs, _)? = out.first(where: { if case .clip = $0 { return true }; return false }) else {
            return XCTFail("没截：\(out.count)")
        }
        XCTAssertEqual(s.count, 20 * 16_000)
        XCTAssertEqual(secs, 20, accuracy: 0.0001)
    }

    /// 太短的（咔哒一下）不算一句；说到一半自己开始放声音：这一句不要
    func testCutterDropsShortAndMuted() {
        var c = ClipCutter()
        _ = run(&c, -70, 50)
        var ev = run(&c, -25, 8)
        ev += run(&c, -70, 45)
        XCTAssertEqual(ev, [.start, .tooShort])
        XCTAssertTrue(c.clip.isEmpty)

        XCTAssertEqual(run(&c, -30, 20), [.start])
        XCTAssertTrue(run(&c, -30, 20, mute: true).isEmpty)
        XCTAssertFalse(c.speaking)
        XCTAssertTrue(c.clip.isEmpty)
        XCTAssertTrue(run(&c, -70, 60).allSatisfy { if case .clip = $0 { return false }; return true })
    }

    /// 回声消除开了电平低：底噪 -75、人声 -55 也得认得出（108 把 floorMin 从 -52 降到 -60）
    func testCutterHearsQuietVoiceWithEchoCancel() {
        var c = ClipCutter()
        _ = run(&c, -75, 100)
        let ev = run(&c, -55, 40) + run(&c, -75, 45)
        XCTAssertEqual(ev.first, .start)
        if case .clip? = ev.last {} else { XCTFail("\(ev)") }
    }

    func testWav() {
        let d = Wav.encode([0, 1, -1, 0.5, 2])
        XCTAssertEqual(d.count, 44 + 10)
        let b = [UInt8](d)
        XCTAssertEqual(String(bytes: b[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: b[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(bytes: b[36..<40], encoding: .ascii), "data")
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
        func i16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
        XCTAssertEqual(u32(4), 36 + 10)
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(28), 32_000)
        XCTAssertEqual(b[22], 1)                       // 单声道
        XCTAssertEqual(b[34], 16)                      // 16 位
        XCTAssertEqual(u32(40), 10)
        XCTAssertEqual([i16(44), i16(46), i16(48), i16(50), i16(52)], [0, 32767, -32767, 16383, 32767])
    }

    // ---------------------------------------------------------------- 108 小圆点、出错就说、体检
    func testLight() {
        XCTAssertNil(CompanionLight.of(.off, alert: false))
        XCTAssertEqual(CompanionLight.of(.listening, alert: false), .green)
        XCTAssertEqual(CompanionLight.of(.hearing, alert: false), .greenBlink)
        XCTAssertEqual(CompanionLight.of(.asking, alert: false), .orange)
        XCTAssertEqual(CompanionLight.of(.speaking, alert: false), .orange)
        XCTAssertEqual(CompanionLight.of(.failed("x"), alert: false), .red)
        XCTAssertEqual(CompanionLight.of(.listening, alert: true), .red)
        XCTAssertEqual(CompanionLight.of(.asking, alert: true), .red)
        XCTAssertEqual(CompanionLight.of(.hearing, alert: true), .greenBlink)    // 又开口了：先让他看见在听
        XCTAssertNil(CompanionLight.of(.off, alert: true))
    }

    func testEveryTroubleSaysSomething() {
        let all = CompanionTrouble.allCases
        XCTAssertEqual(Set(all.map(\.words)).count, all.count, "每一种说的不一样")
        for t in all {
            XCTAssertFalse(t.words.isEmpty)
            XCTAssertLessThanOrEqual(t.words.count, 20, "念的要短：\(t.words)")
        }
        XCTAssertEqual(all.filter(\.keepsGoing), [.noFrame, .frameRefused, .liveDown])
        XCTAssertEqual(CompanionTrouble.misheard.words, "没听清，再说一遍")
    }

    func testHealth() {
        let h = CompanionHealth(mic: true, live: true, mail: false, noise: -58.26, echo: true)
        XCTAssertEqual(h.numbers, ["mic": 1, "live": 1, "mail": 0, "echo": 1, "noise": -58.3])
        XCTAssertEqual(h.line, "话筒✓ 直播✓ 信箱✗ 底噪 -58 dB")
        XCTAssertEqual(CompanionHealth(mic: false, live: false, mail: false, noise: nil, echo: false).line, "话筒✗ 直播✗ 信箱✗")
        let r = ButlerRequest.lookCheck(id: "CHK-1", health: h, at: "", app: "0.7.4")
        XCTAssertEqual(r.ask, "look-check")
        XCTAssertEqual(r.timing?["noise"], -58.3)
        XCTAssertEqual(r.text, "")
    }

    func testLookWithAudio() throws {
        let id = "ABCDEF12-0000"
        let ap = ButlerRequest.lookAudioPath(id)
        XCTAssertEqual(ap, "陪玩/ABCDEF12-问.wav")
        let req = ButlerRequest.look(id: id, question: "不该带上", audio: ap, image: "陪玩/ABCDEF12-屏.jpg", at: "x", app: "0.7.4", prev: ["gate": 1])
        XCTAssertEqual(req.text, "")
        XCTAssertEqual(req.kind, .voice)
        XCTAssertEqual(req.audio, ap)
        let wav = Wav.encode([0, 0.1])
        let env = MailEnvelope.request(req, files: [ap: wav, "陪玩/ABCDEF12-屏.jpg": Data([0xff, 0xd8])])
        let back = try MailEnvelope.decode(env.encoded())
        XCTAssertEqual(back.request?.audio, ap)
        XCTAssertEqual(back.files[ap], wav)
        // 打字问（以后）：没有 audio 字段
        let typed = ButlerRequest.look(id: "T", question: "q", image: nil, at: "", app: "")
        XCTAssertNil(typed.audio)
        XCTAssertFalse(String(decoding: try Butler.encoder().encode(typed), as: UTF8.self).contains("\"audio\""))

        // 大管家回的：认出来的字在 heard；没听清是空串、没有 audio
        let json = #"{"v":2,"kind":"result","id":"ABCDEF12-0000","at":"x","data":{"v":1,"id":"ABCDEF12-0000","note":"","ok":true,"text":"没听清，再说一遍","changes":"","error":null,"heard":"","timing":{"asr":0.4}}}"#
        let res = try MailEnvelope.decode(Data(json.utf8))
        XCTAssertEqual(res.result?.heard, "")
        XCTAssertNil(res.result?.audio)
        XCTAssertEqual(MailAction.decide(res, waiting: [:], dubbing: [:], looks: [id]), .look(res.result!, audio: nil))
    }
}
