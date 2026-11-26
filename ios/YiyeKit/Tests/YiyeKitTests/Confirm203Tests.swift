import XCTest
@testable import YiyeKit

/// 203 要他点头的卡：大管家寄来的读得对、认得出；过点就是过期；定了的不回头；点的那一下寄得对
final class Confirm203Tests: XCTestCase {
    private let raw = #"{"v":2,"kind":"delivery","kind2":"confirm","id":"confirm-a1b2-ask","at":"2026-11-27T09:00:00+08:00","data":{"v":1,"id":"confirm-a1b2-ask","kind":"confirm","kind2":"confirm","confirm":"a1b2","status":"ask","order":"207","title":"大管家","text":"掌机 207 单要做一步，等你点头：放一个文件","detail":"Bash：echo hi > C:/x.txt","host":"handheld","at":"2026-11-27T09:00:00+08:00","expires":"2026-11-27T09:20:00+08:00","urgent":true,"bark":true}}"#

    func testLetterIsACard() throws {
        let env = try MailEnvelope.decode(Data(raw.utf8))
        guard case .confirm(let d) = MailAction.decide(env, waiting: [:], dubbing: [:]) else { return XCTFail("没认成要点头的卡") }
        XCTAssertEqual(d.bark, true)
        let c = try XCTUnwrap(ConfirmCard(d))
        XCTAssertEqual(c.id, "a1b2")
        XCTAssertEqual(c.order, "207")
        XCTAssertEqual(c.host, "handheld")
        XCTAssertEqual(c.detail, "Bash：echo hi > C:/x.txt")
        XCTAssertEqual(c.expires, ISOTime.date("2026-11-27T09:20:00+08:00"))
    }

    func testOtherDeliveriesAreNotCards() {
        let d = ButlerDelivery(id: "x", text: "听力", audio: nil, marks: nil)
        XCTAssertNil(ConfirmCard(d))
        if case .confirm = MailAction.decide(.delivery(d), waiting: [:], dubbing: [:]) { XCTFail("听力稿被当成卡") }
    }

    func testRunsOutByItself() {
        let end = Date(timeIntervalSince1970: 1_000_000)
        var c = ConfirmCard(id: "c", text: "t", expires: end)
        XCTAssertTrue(c.open(at: end.addingTimeInterval(-1)))
        XCTAssertEqual(c.shown(at: end.addingTimeInterval(1)), "expired")
        XCTAssertFalse(c.open(at: end.addingTimeInterval(1)))
        c.sent = "yes"
        XCTAssertEqual(c.shown(at: end.addingTimeInterval(1)), "ask", "点过寄出去了的等大管家说")
        XCTAssertFalse(c.open(at: end.addingTimeInterval(-1)), "点过了不能再点")
    }

    func testFinalStaysFinal() {
        var c = ConfirmCard(id: "c", text: "t")
        c = c.updated(by: ConfirmCard(id: "c", status: "yes", text: "t"))
        XCTAssertEqual(c.status, "yes")
        c = c.updated(by: ConfirmCard(id: "c", status: "ask", text: "t"))
        XCTAssertEqual(c.status, "yes")
        XCTAssertEqual(ConfirmCard(id: "d", text: "t").updated(by: ConfirmCard(id: "d", status: "expired", text: "t")).status, "expired")
    }

    func testTapRequestAndReply() throws {
        let c = ConfirmCard(id: "a1b2", text: "t", host: "handheld", order: "207")
        let r = ButlerRequest.confirm(id: "R", card: c, yes: false, at: "t", app: "0.7.36")
        let j = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertTrue(j.contains("\"ask\":\"ok\""), j)
        XCTAssertTrue(j.contains("\"confirm\":\"a1b2\""), j)
        XCTAssertTrue(j.contains("\"yes\":false"), j)
        XCTAssertTrue(j.contains("\"for\":\"handheld\""), j)
        let back = #"{"v":2,"kind":"result","id":"R","at":"t","data":{"v":1,"id":"R","note":"","ok":true,"text":"好","stage":"confirm","re":"R","confirm":{"id":"a1b2","taken":true}}}"#
        let env = try MailEnvelope.decode(Data(back.utf8))
        guard case .confirmReply(let res) = MailAction.decide(env, waiting: [:], dubbing: [:]) else { return XCTFail("没认成点头的回信") }
        XCTAssertEqual(res.confirm, ConfirmReply(id: "a1b2", taken: true))
    }
}
