import XCTest
@testable import YiyeKit

/// 258 灵感库（接口 v3.29，大管家那头 257 的 handheld/library.py）：请求回信怎么认、手机上那份目录怎么改、怎么找、照片墙怎么分列
final class Library258Tests: XCTestCase {
    private func result(_ s: String) throws -> ButlerResult {
        try JSONDecoder().decode(ButlerResult.self, from: Data(s.utf8))
    }

    /// 大管家回的一封 list，照它实际发的样子
    private func listLetter() throws -> ButlerResult {
        try result(#"""
        {"v":1,"id":"R","note":"","ok":true,"text":"","error":null,"host":"电脑","stage":"library","re":"R",
         "library":{"do":"list","cursor":13,"more":false,"reset":false,"kinds":["网页","字体"],
           "items":[{"id":"z1","bot":"b1","kind":"网页","date":"2026-11-28","label":"少数派","punctum":"表单控件拼成图腾","move":"让控件叛变",
                     "site":"ritual.engineer","url":"https://ritual.engineer/","tags":["图腾","原生控件"],"colors":["#101010"],"thumb":"附件/z1-t.jpg"}],
           "gone":["z0"]}}
        """#)
    }

    private func card(_ id: String, kind: String = "网页", date: String = "2026-11-28", punctum: String = "", move: String = "",
                      site: String = "a.com", tags: [String] = []) -> LibraryCard {
        LibraryCard(id: id, bot: "b1", kind: kind, date: date, punctum: punctum, move: move, site: site, tags: tags)
    }

    private func list(_ cards: [LibraryCard], gone: [String] = [], cursor: Int, reset: Bool = false) -> LibraryReply {
        LibraryReply("list", cursor: cursor, more: false, reset: reset, kinds: ["网页", "字体", "海报"], items: cards, gone: gone)
    }

    func testListReplyReads() throws {
        let r = try listLetter()
        let l = try XCTUnwrap(r.library)
        XCTAssertEqual(l.action, "list")
        XCTAssertEqual(l.cursor, 13)
        XCTAssertEqual(l.gone, ["z0"])
        XCTAssertEqual(l.items?.first?.punctum, "表单控件拼成图腾")
        XCTAssertEqual(l.items?.first?.thumb, "附件/z1-t.jpg")
        XCTAssertEqual(l.items?.first?.tags, ["图腾", "原生控件"])
        XCTAssertEqual(l.items?.first?.difference, "")
        XCTAssertEqual(l.paths, ["附件/z1-t.jpg"])
    }

    func testGetReplyReads() throws {
        let r = try result(#"""
        {"v":1,"id":"G","note":"","ok":true,"stage":"library",
         "library":{"do":"get","id":"z1","item":{"id":"z1","bot":"b1","kind":"网页","date":"2026-11-28","label":"","punctum":"刺","move":"招",
                     "site":"a.com","url":"https://a.com/","tags":[],"colors":[],"difference":"差","idea":"主意","gates":["眯眼","遮字"],"steps":3,
                     "deliberate":"","good":"判","minority_note":"少","stretch_note":""},
                    "images":[{"role":"crop","path":"附件/z1-crop.jpg"},{"role":"mobile","path":"附件/z1-mobile.jpg"}]}}
        """#)
        let l = try XCTUnwrap(r.library)
        XCTAssertEqual(l.item?.difference, "差")
        XCTAssertEqual(l.item?.gates, ["眯眼", "遮字"])
        XCTAssertEqual(l.item?.minorityNote, "少")
        XCTAssertNil(l.item?.thumb)
        XCTAssertEqual(l.images?.map { $0.role }, ["crop", "mobile"])
        XCTAssertEqual(l.paths, ["附件/z1-crop.jpg", "附件/z1-mobile.jpg"])
    }

    /// 按 stage 认；老大管家不认识这个 ask 时回的信没有 stage，按在等的请求认
    func testRoutesWithFiles() throws {
        let r = try listLetter()
        var env = MailEnvelope.result(r)
        let jpg = Data([0xFF, 0xD8])
        env.files = ["附件/z1-t.jpg": jpg, "附件/other.jpg": jpg]
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .library(r, files: ["附件/z1-t.jpg": jpg]))
        let old = try result(#"{"v":1,"id":"O","note":"","ok":false,"error":"?"}"#)
        XCTAssertEqual(MailAction.decide(.result(old), waiting: [:], dubbing: [:], libraries: ["O"]), .library(old))
    }

    func testRequestJSON() throws {
        func json(_ r: ButlerRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        }
        let a = try json(.library(id: "R", ask: LibraryAsk("list", since: 13, limit: 40), at: "t", app: "0.7.48"))
        XCTAssertEqual(a["ask"] as? String, "library")
        let q = try XCTUnwrap(a["library"] as? [String: Any])
        XCTAssertEqual(q["do"] as? String, "list")
        XCTAssertEqual(q["since"] as? Int, 13)
        XCTAssertNil(q["id"])
        let b = try json(.library(id: "R", ask: LibraryAsk("drop", id: "z1"), at: "t", app: "0.7.48"))
        XCTAssertEqual((b["library"] as? [String: Any])?["do"] as? String, "drop")
        XCTAssertEqual((b["library"] as? [String: Any])?["id"] as? String, "z1")
    }

    /// 寄来的设计图带 item；老记录没有照样读
    func testDeliveryItemGoesIntoTheLine() throws {
        let d = try JSONDecoder().decode(ButlerDelivery.self, from: Data(#"""
        {"v":1,"id":"bm-1","kind":"bot","bot":"b1","msg":"m1","text":"刺点","react":true,"item":"z1"}
        """#.utf8))
        XCTAssertEqual(d.item, "z1")
        let line = try XCTUnwrap(BotPost.line(d, images: []))
        XCTAssertEqual(line.item, "z1")
        let back = try JSONDecoder().decode(BotLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(back.item, "z1")
    }

    func testApplyUpsertGoneAndThumbs() {
        var b = LibraryBook()
        b.apply(list([card("a"), card("b", kind: "字体")], cursor: 2), saved: ["a": LibraryThumb(name: "a-t.jpg", ratio: 1.5)])
        XCTAssertEqual(b.cursor, 2)
        XCTAssertEqual(b.shown.map { $0.id }, ["b", "a"])                       // 同一天：后到的排前
        XCTAssertEqual(b.entry("a")?.thumb?.name, "a-t.jpg")
        XCTAssertEqual(b.owners, ["b1"])
        XCTAssertEqual(b.kindsShown, ["网页", "字体"])                              // 照大管家的顺序，只放有东西的
        // 取过的整张卡和原图：下回 list 的卡盖上来，后一半和图还在
        var full = card("a")
        full.difference = "差"
        b.fill("a", card: full, shots: [LibraryShot(role: "crop", name: "a-crop.jpg")])
        b.apply(list([card("a", punctum: "改过")], cursor: 3), saved: [:])
        XCTAssertEqual(b.entry("a")?.card.punctum, "改过")
        XCTAssertEqual(b.entry("a")?.card.difference, "差")
        XCTAssertEqual(b.entry("a")?.shots?.count, 1)
        XCTAssertEqual(b.entry("a")?.thumb?.name, "a-t.jpg")
        // 不留了的：看不见，图还存着
        b.apply(list([], gone: ["a"], cursor: 4), saved: [:])
        XCTAssertEqual(b.shown.map { $0.id }, ["b"])
        XCTAssertTrue(b.files.contains("a-crop.jpg"))
        XCTAssertEqual(b.kindsShown, ["字体"])
        // 撤回以后大管家又送回来
        b.apply(list([card("a")], cursor: 5), saved: [:])
        XCTAssertEqual(Set(b.shown.map { $0.id }), ["a", "b"])
        XCTAssertTrue(b.bin.isEmpty)
    }

    func testResetStartsOver() {
        var b = LibraryBook()
        b.apply(list([card("a"), card("b")], cursor: 9), saved: ["a": LibraryThumb(name: "a-t.jpg", ratio: 1), "b": LibraryThumb(name: "b-t.jpg", ratio: 1)])
        let before = b.files
        b.apply(list([card("b")], cursor: 1, reset: true), saved: [:])
        XCTAssertEqual(b.shown.map { $0.id }, ["b"])
        XCTAssertEqual(b.cursor, 1)
        XCTAssertEqual(before.subtracting(b.files), ["a-t.jpg"])                    // 掉出去的图该删
    }

    /// 他点了 👎：当场看不见；大管家还没回话时拉回来的旧样子盖不掉；撤回当场回来
    func testDropAndUndoShowAtOnce() {
        var b = LibraryBook()
        b.apply(list([card("a"), card("b")], cursor: 2), saved: [:])
        b.intend("a", kept: false)
        XCTAssertEqual(b.shown.map { $0.id }, ["b"])
        XCTAssertFalse(b.visible("a"))
        b.apply(list([card("a")], cursor: 3), saved: [:])
        XCTAssertEqual(b.shown.map { $0.id }, ["b"])
        b.settle("a", kept: false)
        XCTAssertNil(b.pending["a"])
        XCTAssertEqual(b.shown.map { $0.id }, ["b"])
        b.intend("a", kept: true)                                                // 撤回：回话没到就先放回来
        XCTAssertEqual(Set(b.shown.map { $0.id }), ["a", "b"])
        b.settle("a", kept: true)
        XCTAssertEqual(Set(b.shown.map { $0.id }), ["a", "b"])
        XCTAssertTrue(b.bin.isEmpty)
    }

    func testFailedDropComesBack() {
        var b = LibraryBook()
        b.apply(list([card("a")], cursor: 1), saved: [:])
        b.intend("a", kept: false)
        b.giveUp("a")
        XCTAssertEqual(b.shown.map { $0.id }, ["a"])
    }

    /// 大管家拉回来的跟他点的一样了：不用再记着
    func testServerAgreeingClearsPending() {
        var b = LibraryBook()
        b.apply(list([card("a")], cursor: 1), saved: [:])
        b.intend("a", kept: false)
        b.apply(list([], gone: ["a"], cursor: 2), saved: [:])
        XCTAssertNil(b.pending["a"])
        XCTAssertFalse(b.visible("a"))
    }

    func testSearchAndKinds() {
        var b = LibraryBook()
        b.apply(list([card("a", punctum: "一根烧红的铁丝", move: "一个主角", site: "ritual.engineer", tags: ["线"]),
                      card("b", kind: "字体", date: "2026-11-29", punctum: "黑三角啃字", move: "用形状切字", site: "TypeWolf.com")], cursor: 2), saved: [:])
        XCTAssertEqual(b.search("").map { $0.id }, ["b", "a"])                      // 新的在前
        XCTAssertEqual(b.search("铁丝").map { $0.id }, ["a"])
        XCTAssertEqual(b.search("切字").map { $0.id }, ["b"])                       // 招式
        XCTAssertEqual(b.search("typewolf").map { $0.id }, ["b"])                   // 站名，不分大小写
        XCTAssertEqual(b.search("线").map { $0.id }, ["a"])                         // 标签
        XCTAssertEqual(b.search("铁丝 主角").map { $0.id }, ["a"])
        XCTAssertEqual(b.search("铁丝 切字").map { $0.id }, [])
        XCTAssertEqual(b.search("", kind: "字体").map { $0.id }, ["b"])
        XCTAssertEqual(b.search("铁丝", kind: "字体").map { $0.id }, [])
    }

    func testBookSurvivesSaving() throws {
        var b = LibraryBook()
        b.apply(list([card("a")], cursor: 7), saved: ["a": LibraryThumb(name: "a-t.jpg", ratio: 0.6)])
        b.intend("a", kept: false)
        let back = try JSONDecoder().decode(LibraryBook.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
    }

    func testColumns() {
        XCTAssertEqual(LibraryBook.columns([], count: 2), [[], []])
        XCTAssertEqual(LibraryBook.columns([1, 1, 1, 1], count: 2), [[0, 2], [1, 3]])
        // 第一张很高：后面两张都排到另一列
        XCTAssertEqual(LibraryBook.columns([0.62, 1.8, 1.8, 1], count: 2), [[0], [1, 2, 3]])
        XCTAssertEqual(LibraryBook.tileRatio(0.1), 0.62)
        XCTAssertEqual(LibraryBook.tileRatio(9), 1.8)
        XCTAssertEqual(LibraryBook.tileRatio(0), 1)
    }
}
