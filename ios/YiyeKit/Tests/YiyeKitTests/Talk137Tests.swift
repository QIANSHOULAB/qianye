import XCTest
@testable import YiyeKit

/// 137 书童开口说：请求怎么拼、回信怎么认、回执对得上才念大管家配的那段、秒表、假大管家认的几句、固定的话都配了晓晓
final class Talk137Tests: XCTestCase {
    private let card = ShutongCard(id: "a", title: "交接", folder: "", head: "h", created: "c", modified: "m", chars: 3, kind: "voice", locked: false)

    func testTalkRequestWire() throws {
        let ask = ShutongAsk(mode: "talk", notes: [card], folders: [], autoFolders: 0, confirming: true)
        let r = ButlerRequest.shutongTalk(id: "T1", audio: ButlerRequest.talkAudioPath("T1"), text: "", ask: ask,
                                          at: "2026-11-25T10:00:00+08:00", app: "0.7.20", prev: ["talk": 1, "talkSound": 4.2])
        let j = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(j["ask"] as? String, "shutong-talk")
        XCTAssertEqual(j["kind"] as? String, "voice")
        XCTAssertEqual(j["audio"] as? String, "书童/T1-说.wav")
        XCTAssertEqual((j["timing"] as? [String: Double])?["talkSound"], 4.2)
        let s = j["shutong"] as! [String: Any]
        XCTAssertEqual(s["mode"] as? String, "talk")
        XCTAssertEqual(s["confirming"] as? Bool, true)

        let typed = ButlerRequest.shutongTalk(id: "T2", audio: nil, text: "把机床的放一起", ask: ShutongAsk(mode: "talk", notes: [], folders: [], autoFolders: 0),
                                              at: "x", app: "0.7.20")
        let j2 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as! [String: Any]
        XCTAssertEqual(j2["kind"] as? String, "text", "改过字重发的那句没有录音")
        XCTAssertNil(j2["audio"])
        XCTAssertNil(j2["timing"], "没有上一句的秒数就不寄")
        XCTAssertNil((j2["shutong"] as! [String: Any])["confirming"], "不在等点头就不寄这个字段")

        let w = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ButlerRequest.shutongTalkWarm(id: "W", ask: ask, at: "x", app: "y"))) as! [String: Any]
        XCTAssertEqual(w["ask"] as? String, "shutong-talk-warm")
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ButlerRequest.shutongTalkOff(id: "O", at: "x", app: "y"))) as! [String: Any]
        XCTAssertEqual(o["ask"] as? String, "shutong-talk-off")
    }

    func testReplyRoutesToTalkWithAudio() throws {
        let reply = #"{"v":1,"id":"T1","note":"","ok":true,"text":"好了，挪了 2 条进『机床』","stage":"talk","host":"电脑","heard":"把机床的放一起","audio":"书童/T1.mp3","cmd":"","shutong":{"say":"放好了","acts":[{"op":"move","note":"a","folder":"机床"}],"need":[],"cmd":"","spoken":"好了，挪了 1 条进『机床』"}}"#
        let res = try JSONDecoder().decode(ButlerResult.self, from: Data(reply.utf8))
        XCTAssertEqual(res.shutong?.spoken, "好了，挪了 1 条进『机床』")
        XCTAssertEqual(TalkCmd.of(res.shutong?.cmd), .act)
        var env = MailEnvelope.result(res)
        env.files = ["书童/T1.mp3": Data([1, 2, 3])]
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .talk(res, audio: Data([1, 2, 3])), "stage=talk 认得是开口说的，配音跟着走")
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:], shutongs: ["T1"]), .talk(res, audio: Data([1, 2, 3])), "开口说在书童前面认")

        let who = ButlerResult(id: "W1", note: "", ok: true, text: "", changes: nil, error: nil, timing: ["him": 0], stage: "who")
        XCTAssertEqual(MailAction.decide(.result(who), waiting: [:], dubbing: [:], looks: [], talks: ["W1"]), .talk(who, audio: nil),
                       "开口说寄的对声纹，回信回到开口说（不是陪玩）")
        XCTAssertEqual(TalkCmd.of("not-him"), .notHim)
        XCTAssertEqual(TalkCmd.of("undo"), .undo)
        XCTAssertEqual(TalkCmd.of("什么"), .act, "不认识的 cmd 当大脑回的")
        XCTAssertEqual(TalkCmd.of(nil), .act)
    }

    func testReceiptMatchesOnlyWhenSame() {
        var c = ShutongCounts()
        c.folders = ["机床"]
        c.moved = ["机床": 2]
        XCTAssertTrue(TalkReceipt.matches(spoken: "好了，建了文件夹『机床』，挪了 2 条进『机床』", counts: c))
        XCTAssertFalse(TalkReceipt.matches(spoken: "好了，建了文件夹『机床』，挪了 3 条进『机床』", counts: c), "大管家算的跟手机做的不一样：不念它那段")
        XCTAssertFalse(TalkReceipt.matches(spoken: nil, counts: c))
        XCTAssertFalse(TalkReceipt.matches(spoken: "好了，", counts: ShutongCounts()), "什么都没做：没有回执")
    }

    func testClockSummary() {
        var k = TalkClock(spokeEnd: 100, rec: 1.234)
        k.sent = 100.95
        k.back = 104.2
        k.acted = 104.25
        k.sound = 104.4
        let s = k.summary()
        XCTAssertEqual(s["talk"], 1)
        XCTAssertEqual(s["rec"], 1.23)
        XCTAssertEqual(s["talkSent"], 0.95)
        XCTAssertEqual(s["talkActed"], 4.25)
        XCTAssertEqual(s["talkSound"], 4.4)
        XCTAssertNil(TalkClock(spokeEnd: 1, rec: 1).summary()["talkSound"], "没出声就不记")
    }

    func testDemoCommands() {
        XCTAssertEqual(TalkDemo.command("撤销", confirming: false), .undo)
        XCTAssertEqual(TalkDemo.command("Undo", confirming: false), .undo)
        XCTAssertEqual(TalkDemo.command("对", confirming: true), .yes)
        XCTAssertNil(TalkDemo.command("对", confirming: false), "不在等点头，「对」交给大脑")
        XCTAssertEqual(TalkDemo.command("No.", confirming: true), .no)
        XCTAssertEqual(TalkDemo.command("好了", confirming: true), .bye)
        XCTAssertNil(TalkDemo.command("Put the machine stuff together", confirming: false))
        XCTAssertGreaterThan(TalkDemo.clip().count, 44, "假录音是一段能读的 WAV")
    }

    func testFixedLinesVoiced() {
        for s in TalkSays.all {
            XCTAssertTrue(VoiceLines.all.contains(s), "「\(s)」没进 VoiceLines.all")
            XCTAssertNotNil(VoiceLines.file(for: s))
        }
    }
}
