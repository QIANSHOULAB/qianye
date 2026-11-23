import Foundation
import XCTest
@testable import YiyeKit

/// 088：选中的词怎么算、排队、寄出去的信长什么样、回信怎么认
final class WordMarkTests: XCTestCase {
    func testClean() {
        XCTAssertEqual(WordMark.clean(" inflation, "), "inflation")
        XCTAssertEqual(WordMark.clean("**interest  rate**"), "interest rate")
        XCTAssertEqual(WordMark.clean("“snap election”."), "snap election")
        XCTAssertNil(WordMark.clean("   "))
        XCTAssertNil(WordMark.clean("1,280"))                                     // 没有字母
        XCTAssertNil(WordMark.clean("one two three four five six seven"))         // 一整句
        XCTAssertNil(WordMark.clean("line one\nline two"))
        XCTAssertEqual(WordMark.clean("通胀"), "通胀")
    }

    func testQueue() {
        var q = WordQueue()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        q.add("Inflation", .known, note: "N", at: "2026-11-23T17:00:00+08:00")
        q.add("zzqtest1", .learning, note: "N", at: "2026-11-23T17:00:01+08:00")
        q.add("inflation ", .learning, note: "N", at: "2026-11-23T17:00:02+08:00")   // 同一个词：换成最后一次
        XCTAssertEqual(q.items.map(\.word), ["zzqtest1", "inflation "])
        XCTAssertEqual(q.items.last?.mark, .learning)
        XCTAssertEqual(q.due(now: t0).count, 2)

        q.sending("zzqtest1", id: "R1")
        q.sent("R1", at: t0)
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(60)).map(\.word), ["inflation "])   // 寄到了：等回信
        XCTAssertEqual(q.due(now: t0.addingTimeInterval(WordQueue.resendAfter)).count, 2)   // 一天没回：再寄

        XCTAssertTrue(q.answered("R1", ok: false, at: t0))                    // 老大管家不认 word
        XCTAssertFalse(q.due(now: t0.addingTimeInterval(60)).contains { $0.word == "zzqtest1" })
        XCTAssertTrue(q.due(now: t0.addingTimeInterval(WordQueue.retryAfter)).contains { $0.word == "zzqtest1" })

        q.sending("zzqtest1", id: "R2")
        XCTAssertFalse(q.answered("R1", ok: true))                             // 旧的 id 不认了
        XCTAssertTrue(q.answered("R2", ok: true))
        XCTAssertEqual(q.items.map(\.word), ["inflation "])

        q.sending("inflation", id: "R3")
        q.notSent("R3")
        XCTAssertEqual(q.due(now: t0).count, 1)                                // 寄不出去：下回再寄
        XCTAssertEqual(q.requestIDs, ["R3"])
        XCTAssertEqual(WordQueue.decode(q.encoded()), q)
        XCTAssertEqual(WordQueue.decode(nil), WordQueue())
    }

    func testGivesUp() {
        var q = WordQueue()
        q.add("x", .known, note: "N", at: "a")
        for i in 0..<WordQueue.maxTries { q.sending("x", id: "R\(i)"); q.notSent("R\(i)") }
        XCTAssertTrue(q.due().isEmpty)
    }

    /// 信里的请求：ask=word，word、mark 两个字段；别的请求不带这两个字段
    func testLetter() throws {
        let r = ButlerRequest.wordMark(id: "W-1", word: "zzqtest1", mark: .known, note: "N-1", at: "2026-11-23T17:00:00+08:00", app: "0.6.0")
        let env = MailEnvelope.request(r)
        let json = try JSONSerialization.jsonObject(with: env.encoded()) as! [String: Any]
        let data = json["data"] as! [String: Any]
        XCTAssertEqual(data["ask"] as? String, "word")
        XCTAssertEqual(data["word"] as? String, "zzqtest1")
        XCTAssertEqual(data["mark"] as? String, "known")
        XCTAssertEqual(data["text"] as? String, "zzqtest1")
        XCTAssertEqual(data["v"] as? Int, 1)
        XCTAssertEqual(try MailEnvelope.decode(env.encoded()).request, r)
        let fix = ButlerRequest(id: "F-1", note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: "a", app: "b")
        let fj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fix)) as! [String: Any]
        XCTAssertNil(fj["word"])
        XCTAssertNil(fj["mark"])
    }

    func testReplyGoesToQueue() {
        let ok = ButlerResult(id: "W-1", note: "N", ok: true, text: nil, changes: "zzqtest1 → 已掌握", error: nil)
        let n = UUID()
        XCTAssertEqual(MailAction.decide(.result(ok), waiting: ["W-1": n], dubbing: [:], words: ["W-1"]), .word(ok))
        XCTAssertEqual(MailAction.decide(.result(ok), waiting: [:], dubbing: [:]), .drop("没人在等 W-1"))
    }
}
