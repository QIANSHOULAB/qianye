import XCTest
@testable import YiyeKit

/// 252 机器人的话带图、👍👎、定时活（接口 v3.28）：信怎么认、放哪儿、请求里装什么
final class Bots252Tests: XCTestCase {
    private func delivery(_ s: String) throws -> ButlerDelivery {
        try JSONDecoder().decode(ButlerDelivery.self, from: Data(s.utf8))
    }

    private func letter(_ msg: String, seq: Int) throws -> ButlerDelivery {
        try delivery("""
        {"v":1,"id":"bm-\(msg)","kind":"bot","kind2":"bot","bot":"b1a2b3c4d","msg":"\(msg)","text":"刺点","images":["附件/\(msg)-1.jpg","附件/\(msg)-2.jpg"],
         "react":true,"run":"R","seq":\(seq),"last":false,"at":"2026-11-28T20:45:00+08:00","bark":true}
        """)
    }

    func testDeliveryRoutesWithPictures() throws {
        let d = try letter("m1", seq: 1)
        XCTAssertEqual(d.bot, "b1a2b3c4d")
        XCTAssertEqual(d.react, true)
        XCTAssertEqual(d.bark, true)
        let jpg = Data([0xFF, 0xD8])
        let env = MailEnvelope.delivery(d, files: ["附件/m1-1.jpg": jpg, "附件/other.jpg": jpg])
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .botPost(d, images: ["附件/m1-1.jpg": jpg]))
    }

    func testListenDeliveryStillAListenDelivery() throws {
        let d = try delivery(#"{"v":1,"id":"L","kind":"listen","text":"字"}"#)
        XCTAssertEqual(MailAction.decide(.delivery(d), waiting: [:], dubbing: [:]), .deliver(d, audio: nil))
    }

    func testChatReplyCarriesMessageAndPictures() throws {
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(#"""
        {"v":1,"id":"R","note":"","ok":true,"stage":"bot","bot":{"do":"chat","id":"b1","say":"看","msg":"m9","images":["附件/a.jpg"]}}
        """#.utf8))
        XCTAssertEqual(r.bot?.msg, "m9")
        XCTAssertEqual(r.bot?.images, ["附件/a.jpg"])
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:]), .bots(r))
    }

    func testFileNames() {
        XCTAssertEqual(BotPost.fileName("附件/zab12-1.jpg"), "zab12-1.jpg")
        XCTAssertNil(BotPost.fileName("附件/.."))
        XCTAssertNil(BotPost.fileName("附件/.hidden"))
        XCTAssertNil(BotPost.fileName(""))
        XCTAssertNil(BotPost.fileName("附件/名字.jpg"))
    }

    func testLine() throws {
        let l = try XCTUnwrap(BotPost.line(try letter("m1", seq: 1), images: ["m1-1.jpg"]))
        XCTAssertEqual(l.who, "b1a2b3c4d")
        XCTAssertEqual(l.msg, "m1")
        XCTAssertEqual(l.canReact, true)
        XCTAssertEqual(l.images, ["m1-1.jpg"])
        XCTAssertEqual(l.run, "R")
        XCTAssertNil(l.reaction)
        XCTAssertEqual(l.at, ISOTime.date("2026-11-28T20:45:00+08:00"))
    }

    /// 一趟里倒着到也按 seq 摆；同一句只放一回；比它晚的话排在它后面
    func testSlot() throws {
        let t = try XCTUnwrap(ISOTime.date("2026-11-28T20:45:00+08:00"))
        var lines = [BotLine(who: "he", text: "昨天", at: t.addingTimeInterval(-90_000)),
                     BotLine(who: "he", text: "之后", at: t.addingTimeInterval(60))]
        for n in [3, 1, 2] {
            let l = try XCTUnwrap(BotPost.line(try letter("m\(n)", seq: n), images: []))
            let at = try XCTUnwrap(BotPost.slot(l, in: lines))
            lines.insert(l, at: at)
        }
        XCTAssertEqual(lines.map { $0.msg ?? $0.text }, ["昨天", "m1", "m2", "m3", "之后"])
        let again = try XCTUnwrap(BotPost.line(try letter("m2", seq: 2), images: []))
        XCTAssertNil(BotPost.slot(again, in: lines))
    }

    func testOldChatLinesStillRead() throws {
        let old = #"{"id":"6F1C1D0B-3E0A-4C55-9C5C-2A7B2F0E9A11","who":"bot","text":"在","at":0,"state":""}"#
        let l = try JSONDecoder().decode(BotLine.self, from: Data(old.utf8))
        XCTAssertNil(l.msg)
        XCTAssertNil(l.images)
    }

    func testJobsReply() throws {
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(#"""
        {"v":1,"id":"R","note":"","ok":true,"stage":"bot","bot":{"do":"jobs","id":"b1","jobs":[
          {"id":"j1a2b3c4","when":"每天 20:45","kind":"设计日课","what":"设计日课","on":true},
          {"id":"j2","when":"每周一 08:00","kind":"查资料","what":"查天气","on":false}]}}
        """#.utf8))
        XCTAssertEqual(r.bot?.jobs?.count, 2)
        XCTAssertEqual(r.bot?.jobs?.first?.title, "设计日课")
        XCTAssertEqual(r.bot?.jobs?.last?.title, "查天气")
        XCTAssertEqual(r.bot?.jobs?.last?.on, false)
    }

    func testReactAndJobRequests() throws {
        func bot(_ r: ButlerRequest) throws -> [String: Any] {
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
            return try XCTUnwrap(j["bot"] as? [String: Any])
        }
        let a = try bot(.bot(id: "R", ask: BotAsk("react", id: "b1", msg: "m1", react: "none"), at: "t", app: "0.7.46"))
        XCTAssertEqual(a["do"] as? String, "react")
        XCTAssertEqual(a["msg"] as? String, "m1")
        XCTAssertEqual(a["react"] as? String, "none")
        XCTAssertNil(a["job"])
        let b = try bot(.bot(id: "R", ask: BotAsk("job-off", id: "b1", job: "j1"), at: "t", app: "0.7.46"))
        XCTAssertEqual(b["do"] as? String, "job-off")
        XCTAssertEqual(b["job"] as? String, "j1")
        XCTAssertNil(b["msg"])
    }

    func testLinkWithMessage() {
        XCTAssertEqual(YiyeLink.parse(URL(string: "yiye://bot?id=b1&msg=z12")!), .bot(id: "b1", msg: "z12"))
        XCTAssertEqual(YiyeLink.parse(URL(string: "yiye://bot?id=b1")!), .bot(id: "b1"))
        XCTAssertEqual(YiyeLink.parse(URL(string: "yiye://bot?id=b1&msg=")!), .bot(id: "b1"))
    }
}
