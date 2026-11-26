import Foundation
import XCTest
@testable import YiyeKit

/// 128 飞鸽传书：钥匙怎么遮、看着像谁家的、请求长什么样、回信、机密文件卡。钥匙都是编的
final class Dove128Tests: XCTestCase {
    let fake = "ntn_a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"

    func testMaskShowsOnlyFourAndFour() {
        XCTAssertEqual(Dove.masked(fake), "ntn_…c3d4")
        XCTAssertFalse(Dove.masked(fake).contains("a1b2"))
        XCTAssertEqual(Dove.masked("  " + fake + "\n"), "ntn_…c3d4")              // 粘贴带来的空白不算
        XCTAssertEqual(Dove.masked(""), "")
        XCTAssertEqual(Dove.masked("abcdefghij"), "ab…ij")                        // 短的露 2 位
        XCTAssertEqual(Dove.masked("abcd"), "••••")                               // 太短的一位都不露
    }

    func testCleanRemovesAllWhitespace() {
        XCTAssertEqual(Dove.clean(" ab c\n\td\u{00A0}e "), "abcde")
    }

    func testGuessByPrefix() {
        XCTAssertEqual(Dove.guess(fake), "Notion")
        XCTAssertEqual(Dove.guess("secret_" + String(repeating: "x", count: 30)), "Notion")
        XCTAssertEqual(Dove.guess("AIzaSyB" + String(repeating: "q", count: 30)), "Gemini")
        XCTAssertEqual(Dove.guess("sk-proj-" + String(repeating: "q", count: 30)), "OpenAI")
        XCTAssertEqual(Dove.guess("sk-ant-api03-" + String(repeating: "q", count: 40)), "Claude")          // 162：别被 sk- 抢走
        XCTAssertEqual(Dove.guess("sk-ant-oat01-" + String(repeating: "q", count: 40)), "Claude 令牌")
        XCTAssertEqual(Dove.guess("sk_" + String(repeating: "q", count: 30)), "ElevenLabs")
        XCTAssertEqual(Dove.guess("xai-" + String(repeating: "q", count: 30)), "xAI")
        XCTAssertEqual(Dove.guess("ghp_" + String(repeating: "q", count: 30)), "GitHub")
        XCTAssertEqual(Dove.guess("github_pat_" + String(repeating: "q", count: 30)), "GitHub")
        XCTAssertEqual(Dove.guess("1234567890:" + String(repeating: "Ab", count: 16)), "Telegram")
        XCTAssertNil(Dove.guess("zzz-" + String(repeating: "q", count: 30)))
        XCTAssertNil(Dove.guess(""))
    }

    func testCanSend() {
        XCTAssertTrue(Dove.canSend(key: fake, sending: false))
        XCTAssertFalse(Dove.canSend(key: fake, sending: true))
        XCTAssertFalse(Dove.canSend(key: "  \n", sending: false))
    }

    func testRequestShape() throws {
        let r = ButlerRequest.dove(id: "K-1", key: " " + fake + "\n", name: "  Notion ", at: "2026-11-24T21:00:00+08:00", app: "0.7.15")
        XCTAssertEqual(r.ask, "key")
        XCTAssertEqual(r.kind, .text)
        XCTAssertEqual(r.text, "")                                              // 钥匙不放 text：老大管家只会当成一条空笔记
        XCTAssertEqual(r.key, fake)
        XCTAssertEqual(r.name, "Notion")
        XCTAssertEqual(r.note, "")
        let raw = try MailEnvelope.request(r).encoded()
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let data = obj["data"] as! [String: Any]
        XCTAssertEqual(data["ask"] as? String, "key")
        XCTAssertEqual(data["key"] as? String, fake)
        XCTAssertEqual(data["name"] as? String, "Notion")
        XCTAssertEqual(data["v"] as? Int, 1)
        XCTAssertEqual(try MailEnvelope.decode(raw), MailEnvelope.request(r))
        let none = ButlerRequest.dove(id: "K-2", key: fake, name: "   ", at: "t", app: "0.7.15")
        XCTAssertNil(none.name)                                                 // 不写就是没有这一项
        let noneObj = try JSONSerialization.jsonObject(with: MailEnvelope.request(none).encoded()) as! [String: Any]
        XCTAssertNil((noneObj["data"] as! [String: Any])["name"])
        let longName = ButlerRequest.dove(id: "K-3", key: fake, name: String(repeating: "名", count: 80), at: "t", app: "0.7.15")
        XCTAssertEqual(longName.name?.count, 40)
    }

    func testOtherRequestsDoNotCarryAKey() throws {
        let r = ButlerRequest(id: "X", note: "N", kind: .text, text: "hello", images: nil, unsure: nil, at: "t", app: "0.7.15")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertNil(obj["key"])
        XCTAssertNil(obj["name"])
    }

    /// 大管家（Python dove.body）回的信长这样
    func testReplyFromTheButler() throws {
        let raw = #"{"v":2,"kind":"result","id":"K-1","at":"2026-11-24T21:00:02+08:00","data":{"v":1,"id":"K-1","note":"","ok":true,"text":"鸽子到了：Notion，ntn_ 开头、c3d4 结尾，能用","changes":"","error":null,"model":null,"at":"2026-11-24T21:00:02+08:00","host":"电脑","re":"K-1","stage":"key","key":{"slug":"notion","saved":true,"check":"ok","head":"ntn_","tail":"c3d4","guess":"notion"}}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let res = try XCTUnwrap(env.result)
        XCTAssertEqual(DoveReply.from(res), DoveReply(ok: true, line: "鸽子到了：Notion，ntn_ 开头、c3d4 结尾，能用"))
        // 没登记在等的（app 被杀过又打开）也认得：stage=key
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .dove(res))
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:], doves: ["K-1"]), .dove(res))

        let badRaw = #"{"v":2,"kind":"result","id":"K-2","data":{"v":1,"id":"K-2","note":"","ok":false,"text":null,"changes":"","error":"鸽子到了，但Notion 不认这把钥匙，没存","model":null,"at":"t","host":"电脑","re":"K-2","stage":"key","key":{"slug":"notion","saved":false,"check":"bad","head":"ntn_","tail":"w6x7","guess":null}}}"#
        let bad = try XCTUnwrap(MailEnvelope.decode(Data(badRaw.utf8)).result)
        XCTAssertEqual(DoveReply.from(bad), DoveReply(ok: false, line: "鸽子到了，但Notion 不认这把钥匙，没存"))
    }

    func testOtherResultsAreNotDoves() {
        let r = ButlerResult(id: "R", note: "N", ok: true, text: "x", changes: nil, error: nil)
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:]), .drop("没人在等 R"))
    }

    /// 大管家（Python dgjbox.send_secret）递来的一次性东西
    func testSecretCard() throws {
        let raw = #"{"v":2,"kind":"delivery","kind2":"secret","id":"sec-abc123def456","at":"2026-11-24T21:05:00+08:00","data":{"v":1,"id":"sec-abc123def456","kind":"secret","kind2":"secret","title":"铁屑江湖配对码","text":"tiexie:AbC-_123","hint":"到铁屑江湖设置里点「粘贴配对码」","at":"2026-11-24T21:05:00+08:00"}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .secret(d))
        let card = try XCTUnwrap(SecretCard.from(d))
        XCTAssertEqual(card, SecretCard(id: "sec-abc123def456", title: "铁屑江湖配对码", text: "tiexie:AbC-_123", hint: "到铁屑江湖设置里点「粘贴配对码」"))
        // 空的、不是机密的不弹
        XCTAssertNil(SecretCard.from(ButlerDelivery(id: "D", kind: "secret", text: "  ", audio: nil, marks: nil)))
        XCTAssertNil(SecretCard.from(ButlerDelivery(id: "D", text: "# Hi", audio: nil, marks: nil)))
        // 听力稿照旧
        let listen = ButlerDelivery(id: "DLV-9", text: "# Hi", audio: nil, marks: nil)
        XCTAssertEqual(MailAction.decide(.delivery(listen), waiting: [:], dubbing: [:]), .deliver(listen, audio: nil))
    }
}
