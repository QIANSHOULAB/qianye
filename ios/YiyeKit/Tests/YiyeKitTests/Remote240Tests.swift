import XCTest
@testable import YiyeKit

/// 240 遥控聪明截图：新字段读得对、块的回信分得出来、拼不拼、反馈栏那一句
final class Remote240Tests: XCTestCase {
    func testTilesAnswerIsReadAndRouted() throws {
        let json = """
        {"v":1,"id":"R9","note":"","ok":true,"text":"","error":null,"stage":"remote",
         "remote":{"on":true,"session":"S","screen":0,"shot":9,"base":8,"w":1920,"h":1080,"screens":1,"live":true,"iw":1280,"ih":720,
                   "tiles":[["遥控/S-9-0.jpg",960,256,128,64],["遥控/S-9-1.jpg",0,640,64,80]],"after":"moved","ms":{"grab":20,"enc":3}}}
        """
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(json.utf8))
        let st = try XCTUnwrap(r.remote)
        XCTAssertEqual(st.tiles?.count, 2)
        XCTAssertEqual(st.tiles?.first, RemoteTile(path: "遥控/S-9-0.jpg", x: 960, y: 256, w: 128, h: 64))
        XCTAssertEqual(st.base, 8)
        XCTAssertEqual(st.live, true)
        XCTAssertEqual(st.after, "moved")
        XCTAssertEqual(st.iw, 1280)
        let a = Data([0xFF, 0xD8, 0x0A]), b = Data([0xFF, 0xD8, 0x0B])
        let env = MailEnvelope(kind: .result, id: "R9", at: "t", result: r, files: ["遥控/S-9-0.jpg": a, "遥控/S-9-1.jpg": b])
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .remoteTiles(r, tiles: ["遥控/S-9-0.jpg": a, "遥控/S-9-1.jpg": b]))
        // 块写回 JSON 还是 [路径, x, y, w, h]
        let back = String(decoding: try JSONEncoder().encode(st.tiles![1]), as: UTF8.self)
        XCTAssertEqual(back, #"["遥控\/S-9-1.jpg",0,640,64,80]"#)
    }

    func testSameAnswerHasNoImage() throws {
        let json = #"{"v":1,"id":"R2","note":"","ok":true,"stage":"remote","remote":{"on":true,"session":"S","shot":7,"same":true,"live":true}}"#
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(json.utf8))
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:]), .remote(r, image: nil))
        XCTAssertEqual(RemoteFeed.step(shown: 7, state: r.remote!, hasImage: false), .same)
    }

    func testWhatToDoWithAnAnswer() {
        var st = RemoteState(shot: 5)
        XCTAssertEqual(RemoteFeed.step(shown: nil, state: st, hasImage: true), .full)
        XCTAssertEqual(RemoteFeed.step(shown: 4, state: st, hasImage: true), .full)
        XCTAssertEqual(RemoteFeed.step(shown: 6, state: st, hasImage: true), .skip)          // 晚到的旧图
        st.tiles = [RemoteTile(path: "p", x: 0, y: 0, w: 64, h: 64)]
        st.base = 4
        XCTAssertEqual(RemoteFeed.step(shown: 4, state: st, hasImage: false), .tiles)
        XCTAssertEqual(RemoteFeed.step(shown: 3, state: st, hasImage: false), .skip)         // 拼的底不是手上那张
        XCTAssertEqual(RemoteFeed.step(shown: nil, state: st, hasImage: false), .skip)
        st.shot = 4
        XCTAssertEqual(RemoteFeed.step(shown: 4, state: st, hasImage: false), .skip)         // 拼完不比底新：不对
        XCTAssertEqual(RemoteFeed.step(shown: 4, state: RemoteState(shot: 4), hasImage: false), .same)
    }

    func testOpsCarryWhatThePhoneShows() throws {
        let r = ButlerRequest.remote(id: "R1", op: RemoteOp(op: "shot", session: "S", have: 12, wait: true), target: .handheld, at: "t", app: "0.7.44")
        let s = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(s.contains(#""have":12"#), s)
        XCTAssertTrue(s.contains(#""wait":true"#), s)
        // 没带的不写进去（老大管家看见 have 才走新路）
        let old = String(decoding: try JSONEncoder().encode(RemoteOp(op: "close", session: "S")), as: UTF8.self)
        XCTAssertFalse(old.contains("have"), old)
        XCTAssertFalse(old.contains("wait"), old)
        // 问大管家：op=ask，字在 text
        let ask = ButlerRequest.remote(id: "R2", op: RemoteOp(op: "ask", session: "S", text: "点上没"), target: .desk, at: "t", app: "a")
        XCTAssertEqual(ask.remote?.text, "点上没")
    }

    func testFeedbackLine() {
        XCTAssertEqual(RemoteFeed.line(op: "tap", sent: true, after: nil), "remote.fb.tapped")
        XCTAssertEqual(RemoteFeed.line(op: "tap", after: "wait"), "remote.fb.waiting")
        XCTAssertEqual(RemoteFeed.line(op: "double", after: "moved"), "remote.fb.done")
        XCTAssertEqual(RemoteFeed.line(op: "right", after: "none"), "remote.fb.none")
        XCTAssertEqual(RemoteFeed.line(op: "scroll", after: "moved"), "remote.fb.changed")
        XCTAssertEqual(RemoteFeed.line(op: "type", after: "none"), "remote.fb.unchanged")
        XCTAssertEqual(RemoteFeed.line(op: "type", sent: true, after: nil), "remote.fb.typed")
        XCTAssertNil(RemoteFeed.line(op: "tap", after: nil))
        XCTAssertEqual(RemoteFeed.nextDelay(live: true), 0)
        XCTAssertEqual(RemoteFeed.nextDelay(live: false), 1.5)
    }
}
