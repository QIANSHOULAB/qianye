import XCTest
@testable import YiyeKit

/// 250 机器人：信里装什么、回信怎么认、陆续到的发言怎么排、@、链接
final class Bots250Tests: XCTestCase {
    private func json(_ r: ButlerRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    }

    private func result(_ s: String) throws -> ButlerResult {
        try JSONDecoder().decode(ButlerResult.self, from: Data(s.utf8))
    }

    // ---------------------------------------------------------------- 请求
    func testBotRequestFields() throws {
        let ask = BotAsk("chat", id: "b0000abcd", text: "吃啥", history: [BotTalk(who: "he", text: "在吗"), BotTalk(who: "bot", text: "在")])
        let j = try json(.bot(id: "R1", ask: ask, at: "2026-11-28T17:00:00+08:00", app: "0.7.45"))
        XCTAssertEqual(j["ask"] as? String, "bot")
        XCTAssertEqual(j["text"] as? String, "")
        let b = try XCTUnwrap(j["bot"] as? [String: Any])
        XCTAssertEqual(b["do"] as? String, "chat")
        XCTAssertEqual(b["id"] as? String, "b0000abcd")
        XCTAssertEqual((b["history"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(b["name"])
    }

    func testGroupRequestCarriesScribeBlockOnlyWhenGiven() throws {
        let j = try json(.group(id: "R2", ask: BotAsk("say", id: "g1", text: "@小书童 起标题", to: "shutong"),
                                shutong: ShutongAsk(mode: "chat", notes: [], folders: [], autoFolders: 0), at: "t", app: "0.7.45"))
        XCTAssertEqual(j["ask"] as? String, "group")
        XCTAssertEqual((j["group"] as? [String: Any])?["to"] as? String, "shutong")
        XCTAssertEqual((j["shutong"] as? [String: Any])?["mode"] as? String, "chat")
        let k = try json(.group(id: "R3", ask: BotAsk("new", name: "晚饭群", members: ["b1", "b2"], chief: "shutong"), at: "t", app: "0.7.45"))
        XCTAssertNil(k["shutong"])
        XCTAssertEqual((k["group"] as? [String: Any])?["members"] as? [String], ["b1", "b2"])
    }

    // ---------------------------------------------------------------- 回信（照接口文档的样子）
    func testBotMemoryReply() throws {
        let r = try result("""
        {"v":1,"id":"R","note":"","ok":true,"text":"","error":null,"host":"电脑","stage":"bot","re":"R","model":"",
         "bot":{"do":"memory","id":"b1a2b3c4d","bot":{"id":"b1a2b3c4d","name":"厨子","desc":"d","persona":"p","gear":"Sonnet 中","builtin":false},
                "memory":[{"date":"2026-11-28","text":"他不吃香菜"}]}}
        """)
        XCTAssertEqual(r.bot?.action, "memory")
        XCTAssertEqual(r.bot?.bot?.persona, "p")
        XCTAssertEqual(r.bot?.memory, [BotMemo(date: "2026-11-28", text: "他不吃香菜")])
    }

    func testListReply() throws {
        let r = try result("""
        {"v":1,"id":"R","note":"","ok":true,"stage":"bot","bot":{"do":"list","bots":[{"id":"shutong","name":"小书童","desc":"x","gear":"Sonnet 高","builtin":true}],
         "groups":[{"id":"gfe2ece40","name":"晚饭群","members":["b1","shutong"],"chief":"shutong","memory":[]}]}}
        """)
        XCTAssertEqual(r.bot?.bots?.first?.builtin, true)
        XCTAssertEqual(r.bot?.groups?.first?.members, ["b1", "shutong"])
    }

    func testGroupSayReplyWithScribeActs() throws {
        let r = try result("""
        {"v":1,"id":"R","note":"","ok":true,"text":"","stage":"group","re":"R","bark":true,"group":{"do":"say","id":"g1","seq":2,"done":true,
         "messages":[{"bot":"shutong","text":"起好了","acts":[{"op":"title","note":"N1","title":"冷却液"}],"need":[]},{"bot":"","text":"今天的额度用完了，明天再聊"}]}}
        """)
        XCTAssertEqual(r.bark, true)
        XCTAssertEqual(r.group?.seq, 2)
        XCTAssertEqual(r.group?.done, true)
        XCTAssertEqual(r.group?.messages?.first?.acts?.first?.op, "title")
        XCTAssertEqual(r.group?.messages?.last?.bot, "")
    }

    func testMailActionRoutesByStageOrWaiting() throws {
        let g = try result("{\"v\":1,\"id\":\"R\",\"note\":\"\",\"ok\":true,\"stage\":\"group\",\"group\":{\"do\":\"say\",\"id\":\"g1\",\"seq\":1}}")
        XCTAssertEqual(MailAction.decide(.result(g), waiting: [:], dubbing: [:]), .bots(g))
        let old = try result("{\"v\":1,\"id\":\"R9\",\"note\":\"\",\"ok\":false,\"error\":\"大管家不认识这个 ask：bot\"}")
        XCTAssertEqual(MailAction.decide(.result(old), waiting: [:], dubbing: [:], bots: ["R9"]), .bots(old))
        let hear = try result("{\"v\":1,\"id\":\"H\",\"note\":\"\",\"ok\":true,\"stage\":\"shutong-hear\",\"heard\":\"字\"}")
        XCTAssertEqual(MailAction.decide(.result(hear), waiting: [:], dubbing: [:], bots: ["R9"]), .shutong(hear))
    }

    // ---------------------------------------------------------------- 陆续到的发言怎么排
    func testLateLetterGoesWhereItBelongs() {
        var lines = [BotLine(who: "he", text: "问一", rid: "A")]
        func put(_ rid: String, _ seq: Int, _ text: String) {
            if let i = BotLog.slot(rid: rid, seq: seq, in: lines) { lines.insert(BotLine(who: "b1", text: text, rid: rid, seq: seq), at: i) }
        }
        put("A", 2, "a2")
        put("A", 1, "a1")
        XCTAssertEqual(lines.map(\.text), ["问一", "a1", "a2"])
        lines.append(BotLine(who: "he", text: "问二", rid: "B"))
        put("A", 3, "a3")                                       // 第一句晚到的发言插在第二句前面
        put("B", 1, "b1")
        XCTAssertEqual(lines.map(\.text), ["问一", "a1", "a2", "a3", "问二", "b1"])
        XCTAssertNil(BotLog.slot(rid: "A", seq: 2, in: lines))  // 同一封来两回不重复
        XCTAssertEqual(BotLog.slot(rid: "C", seq: 1, in: lines), lines.count)
    }

    func testHistory() {
        var lines = (0..<40).map { BotLine(who: $0 % 2 == 0 ? "he" : "b1", text: "t\($0)") }
        lines.insert(BotLine(who: "", text: "系统"), at: 39)
        let h = BotLog.history(lines, before: lines.last?.id, group: false)
        XCTAssertEqual(h.count, 30)
        XCTAssertEqual(h.last?.text, "t38")
        XCTAssertFalse(h.contains { $0.text == "系统" || $0.text == "t39" })
        XCTAssertTrue(h.allSatisfy { $0.who == "he" || $0.who == "bot" })
        XCTAssertTrue(BotLog.history(lines, before: nil, group: true).contains { $0.who == "b1" })
    }

    // ---------------------------------------------------------------- @
    func testMentionTypingAndInsert() {
        XCTAssertEqual(BotMention.typing("问问@"), "")
        XCTAssertEqual(BotMention.typing("＠老厨"), "老厨")
        XCTAssertNil(BotMention.typing("@老厨子 在吗"))
        XCTAssertNil(BotMention.typing("没有"))
        let cards = [BotCard(id: "b1", name: "老厨子", desc: ""), BotCard(id: "b2", name: "账房", desc: "")]
        XCTAssertEqual(BotMention.candidates("hi @", members: cards).map(\.id), ["b1", "b2"])
        XCTAssertEqual(BotMention.candidates("hi @账", members: cards).map(\.id), ["b2"])
        XCTAssertTrue(BotMention.candidates("hi", members: cards).isEmpty)
        XCTAssertEqual(BotMention.insert("账房", into: "hi @账"), "hi @账房 ")
        XCTAssertEqual(BotMention.insert("账房", into: "hi"), "hi@账房 ")
        XCTAssertTrue(BotMention.atScribe("@小书童 收拾一下"))
        XCTAssertFalse(BotMention.atScribe("小书童收拾一下"))
    }

    // ---------------------------------------------------------------- 链接、头像
    func testLinksAndFace() {
        XCTAssertEqual(YiyeLink.parse(URL(string: "yiye://bot?id=b1a2b3c4d")!), .bot(id: "b1a2b3c4d"))
        XCTAssertEqual(YiyeLink.parse(URL(string: "yiye://group?id=gfe2ece40")!), .group(id: "gfe2ece40"))
        XCTAssertNil(YiyeLink.parse(URL(string: "yiye://group")!))
        XCTAssertEqual(BotFace.letter("老厨子"), "老")
        XCTAssertEqual(BotFace.color("b1", count: 6), BotFace.color("b1", count: 6))
        XCTAssertTrue((0..<6).contains(BotFace.color("gfe2ece40", count: 6)))
        XCTAssertTrue(BotID.isGroup("g1"))
        XCTAssertFalse(BotID.isGroup("shutong"))
    }
}
