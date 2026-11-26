import XCTest
@testable import YiyeKit

/// 197 遥控带路：大管家寄来的卡读得对；圈里圈外怎么发；遥控的双击和带路号寄得出去
final class Guide197Tests: XCTestCase {
    private let raw = #"{"v":2,"kind":"delivery","kind2":"guide","id":"guide-ab12-1-ask","at":"2026-11-26T20:00:00+08:00","data":{"v":1,"id":"guide-ab12-1-ask","kind":"guide","kind2":"guide","guide":"ab12","status":"ask","title":"大管家","text":"双击桌面上的「装Soulframe」","host":"handheld","screen":0,"double":true,"x":0.5,"y":0.25,"r":0.05,"image":"带路/ab12-1.jpg","at":"2026-11-26T20:00:00+08:00"}}"#

    func testGuideLetterIsACard() throws {
        var env = try MailEnvelope.decode(Data(raw.utf8))
        let pic = Data([9, 8, 7])
        env.files = ["带路/ab12-1.jpg": pic]
        guard case .guide(let d, let image) = MailAction.decide(env, waiting: [:], dubbing: [:]) else { return XCTFail("没认成带路卡") }
        XCTAssertEqual(image, pic)
        let c = try XCTUnwrap(GuideCard(d))
        XCTAssertEqual(c.id, "ab12")
        XCTAssertEqual(c.status, "ask")
        XCTAssertEqual(c.target, .handheld)
        XCTAssertTrue(c.twice)
        XCTAssertEqual(c.x, 0.5)
        XCTAssertEqual(c.r, 0.05)
    }

    func testListeningPieceIsNotACard() {
        let d = ButlerDelivery(id: "x", text: "听力", audio: nil, marks: nil)
        XCTAssertNil(GuideCard(d))
        if case .guide = MailAction.decide(.delivery(d), waiting: [:], dubbing: [:]) { XCTFail("听力稿被当成带路卡") }
    }

    func testCircleAndHowToSend() {
        let c = GuideCard(id: "g", text: "t", x: 0.5, y: 0.5, r: 0.05, twice: true)
        let aspect = 0.625
        XCTAssertTrue(c.contains(0.5, 0.5, aspect: aspect))
        XCTAssertTrue(c.contains(0.555, 0.5, aspect: aspect), "放宽两成")
        XCTAssertFalse(c.contains(0.57, 0.5, aspect: aspect))
        XCTAssertTrue(c.contains(0.5, 0.59, aspect: aspect), "竖向按图高换算")
        XCTAssertFalse(c.contains(0.5, 0.61, aspect: aspect))
        let inside = c.tapPlan(0.5, 0.5, aspect: aspect)
        XCTAssertEqual(inside.op, "double")
        XCTAssertEqual(inside.guide, "g")
        let outside = c.tapPlan(0.1, 0.1, aspect: aspect)
        XCTAssertEqual(outside.op, "tap")
        XCTAssertNil(outside.guide)
        var once = c
        once.twice = false
        XCTAssertEqual(once.tapPlan(0.5, 0.5, aspect: aspect).op, "tap")
        once.status = "done"
        XCTAssertNil(once.tapPlan(0.5, 0.5, aspect: aspect).guide, "点上了的卡不再带号")
        XCTAssertFalse(GuideCard(id: "n", text: "没圈").contains(0.5, 0.5, aspect: aspect))
    }

    func testDoubleOpCarriesTheGuide() throws {
        XCTAssertTrue(RemoteOp(op: "double").isMove)
        let r = ButlerRequest.remote(id: "R", op: RemoteOp(op: "double", session: "S", shot: 1, x: 0.5, y: 0.5, guide: "ab12"),
                                     target: .handheld, at: "t", app: "a")
        let j = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(j.contains("\"guide\":\"ab12\""), j)
        XCTAssertTrue(j.contains("\"op\":\"double\""), j)
    }
}
