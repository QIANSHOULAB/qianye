import Foundation
import XCTest
@testable import YiyeKit

/// 172 遥控：手机图上的一点怎么换成比例、两指滑几格、密码开关、密码那一封怎么装（机密件：只在 secret 里）、回信怎么认
final class Remote172Tests: XCTestCase {
    func testFitAndNormalize() {
        // 390 x 300 的框里放一张 1280 x 800 的图：宽度贴满，上下各留 28.125
        let r = RemoteMap.fitRect(view: (390, 300), image: (1280, 800))
        XCTAssertEqual(r.w, 390, accuracy: 1e-9)
        XCTAssertEqual(r.h, 243.75, accuracy: 1e-9)
        XCTAssertEqual(r.y, 28.125, accuracy: 1e-9)
        let c = RemoteMap.normalized((195, 150), view: (390, 300), image: (1280, 800))!
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
        let tl = RemoteMap.normalized((0, 28.125), view: (390, 300), image: (1280, 800))!
        XCTAssertEqual(tl.x, 0, accuracy: 1e-9)
        XCTAssertEqual(tl.y, 0, accuracy: 1e-9)
        XCTAssertNil(RemoteMap.normalized((10, 10), view: (390, 300), image: (1280, 800)))     // 图外面的空白：不算
        // 这层跟图一样大（app 里的样子）：比例就是位置除以大小
        let same = RemoteMap.normalized((97.5, 60.9375), view: (390, 243.75), image: (1280, 800))!
        XCTAssertEqual(same.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(same.y, 0.25, accuracy: 1e-9)
        XCTAssertNil(RemoteMap.normalized((1, 1), view: (0, 0), image: (1280, 800)))
    }

    func testScrollNotches() {
        XCTAssertEqual(RemoteMap.notches(dragY: -120), -3)      // 两指往上滑：看下面 → 滚轮往下（负的，大管家那头正 = 往上）
        XCTAssertEqual(RemoteMap.notches(dragY: 120), 3)
        XCTAssertEqual(RemoteMap.notches(dragY: 10), 0)
        XCTAssertEqual(RemoteMap.notches(dragY: -1000), -10)
        XCTAssertEqual(RemoteMap.notches(dragY: 1000), 10)
    }

    func testPasswordShownAsDots() {
        XCTAssertEqual(RemotePass.shown("abc密", password: true), "••••")
        XCTAssertEqual(RemotePass.shown("abc密", password: false), "abc密")
        XCTAssertEqual(RemotePass.shown("", password: true), "")
    }

    func testOnlineMachines() {
        XCTAssertEqual(RemoteTarget.online(["desk", "handheld"]), [.desk, .handheld])
        XCTAssertEqual(RemoteTarget.online(["handheld", "pc"]), [.handheld])
        XCTAssertEqual(RemoteTarget.online([]), [])
    }

    func testMoveOrNot() {
        XCTAssertTrue(RemoteOp(op: "tap").isMove)
        XCTAssertTrue(RemoteOp(op: "pass").isMove)
        XCTAssertFalse(RemoteOp(op: "shot").isMove)
        XCTAssertFalse(RemoteOp(op: "close").isMove)
    }

    /// 一个动作的请求：ask=remote、for、remote 一块；没有 secret
    func testTapRequest() throws {
        let r = ButlerRequest.remote(id: "R1", op: RemoteOp(op: "tap", session: "S", shot: 3, x: 0.25, y: 0.75), target: .handheld,
                                     at: "2026-11-26T09:00:00+08:00", app: "0.7.30")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(obj["ask"] as? String, "remote")
        XCTAssertEqual(obj["for"] as? String, "handheld")
        XCTAssertNil(obj["secret"])
        let op = obj["remote"] as! [String: Any]
        XCTAssertEqual(op["op"] as? String, "tap")
        XCTAssertEqual(op["shot"] as? Int, 3)
        XCTAssertEqual(op["x"] as? Double, 0.25)
        XCTAssertEqual(op["session"] as? String, "S")
    }

    /// 密码：只在顶层 secret 里；remote 里只有 op=pass 和这一场的号，text 一定是空的
    func testPasswordGoesOnlyInSecret() throws {
        let fake = "Fake-Pw-172"
        let r = ButlerRequest.remotePass(id: "R2", secret: fake, session: "S", target: .desk, at: "t", app: "0.7.30")
        XCTAssertEqual(r.secret, fake)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.remote?.op, "pass")
        XCTAssertNil(r.remote?.text)
        let data = try JSONEncoder().encode(r)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["secret"] as? String, fake)
        let op = try JSONSerialization.data(withJSONObject: obj["remote"]!)
        XCTAssertFalse(String(decoding: op, as: UTF8.self).contains(fake))
        // 有人往 pass 里塞了 text：照样拿掉
        let sneaky = ButlerRequest.remote(id: "R3", op: RemoteOp(op: "pass", text: fake), target: .desk, at: "t", app: "a")
        XCTAssertNil(sneaky.remote?.text)
        XCTAssertNil(sneaky.secret)
    }

    /// 回信：stage=remote 不管 id 记没记都认；截图从 files 里按 remote.image 拿
    func testRemoteAnswerIsRouted() throws {
        let json = """
        {"v":1,"id":"R1","note":"","ok":true,"text":"","error":null,"stage":"remote","file":"遥控/S-4.jpg",
         "remote":{"on":true,"session":"S","screen":0,"shot":4,"w":2560,"h":1600,"screens":2,"image":"遥控/S-4.jpg","black":false}}
        """
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.remote?.shot, 4)
        XCTAssertEqual(r.remote?.w, 2560)
        XCTAssertEqual(r.remote?.screens, 2)
        let img = Data([0xFF, 0xD8, 0x01])
        let env = MailEnvelope(kind: .result, id: "R1", at: "t", result: r, files: ["遥控/S-4.jpg": img])
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .remote(r, image: img))
        // 结束了的（5 分钟没动）：id 是 remote-end-<session>，没人记着也认
        let end = ButlerResult(id: "remote-end-S", note: "", ok: true, text: "5 分钟没动，遥控自己结束了", changes: nil, error: nil, stage: "remote")
        XCTAssertEqual(MailAction.decide(.result(end), waiting: [:], dubbing: [:]), .remote(end, image: nil))
        // 坏的 remote 一块：整封信照样读
        let bad = try JSONDecoder().decode(ButlerResult.self, from: Data(#"{"v":1,"id":"x","note":"","ok":false,"stage":"remote","remote":"?"}"#.utf8))
        XCTAssertNil(bad.remote)
    }
}
