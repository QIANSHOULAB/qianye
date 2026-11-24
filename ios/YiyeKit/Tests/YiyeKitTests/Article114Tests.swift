import Foundation
import XCTest
@testable import YiyeKit

/// 114：分享进来的网址 / 文字、页面标题、便签正文怎么拼、文章便签的状态、两种新信
final class Article114Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // ---------------------------------------------------------------- 捷径收网址、收文字
    func testShareURLOnly() {
        XCTAssertEqual(ArticleShare.parse(url: "https://example.com/a?b=1", text: nil), .url("https://example.com/a?b=1"))
        XCTAssertEqual(ArticleShare.parse(url: "  https://example.com/a \n", text: nil), .url("https://example.com/a"))
    }

    func testShareTextThatIsAURL() {
        // 捷径把网页的输入转成文字给来：整段就是个网址
        XCTAssertEqual(ArticleShare.parse(url: nil, text: "https://example.com/story"), .url("https://example.com/story"))
        XCTAssertEqual(ArticleShare.parse(url: "", text: "http://example.com"), .url("http://example.com"))
    }

    func testShareTitleAndURLTogether() {
        XCTAssertEqual(ArticleShare.parse(url: nil, text: "A good read\nhttps://example.com/story"), .url("https://example.com/story"))
        XCTAssertEqual(ArticleShare.parse(url: nil, text: "看这篇「好文章」 https://example.com/x，转给你"), .url("https://example.com/x"))
    }

    func testSharePlainText() {
        XCTAssertEqual(ArticleShare.parse(url: nil, text: "明天开会带报表"), .text("明天开会带报表"))
        let long = String(repeating: "很长的一段文字。", count: 80) + " https://example.com/in-the-middle"
        XCTAssertEqual(ArticleShare.parse(url: nil, text: long), .text(long))                        // 长文里夹一个网址：当文字存
    }

    func testShareNothing() {
        XCTAssertEqual(ArticleShare.parse(url: nil, text: nil), .nothing)
        XCTAssertEqual(ArticleShare.parse(url: "", text: "   \n"), .nothing)
        XCTAssertEqual(ArticleShare.parse(url: "ftp://example.com/x", text: nil), .nothing)           // 不是 http(s) 的当没有
    }

    // ---------------------------------------------------------------- 页面标题
    func testPageTitle() {
        XCTAssertEqual(PageTitle.extract("<html><head><title>Hello &amp; welcome</title></head>"), "Hello & welcome")
        XCTAssertEqual(PageTitle.extract("<HEAD><TITLE lang=\"en\">\n  A   long\n title \n</TITLE>"), "A long title")
        XCTAssertNil(PageTitle.extract("<html><body>no title</body></html>"))
        XCTAssertNil(PageTitle.extract("<title>   </title>"))
        XCTAssertEqual(PageTitle.extract("<title>\(String(repeating: "x", count: 300))</title>")?.count, 120)
    }

    // ---------------------------------------------------------------- 便签正文
    func testInitialText() {
        XCTAssertEqual(ArticleText.initial(title: "What is WSL", url: "https://e.com/a"), "# What is WSL\n\nhttps://e.com/a")
        XCTAssertEqual(ArticleText.initial(title: nil, url: "https://e.com/a"), "# https://e.com/a\n\nhttps://e.com/a")   // 拿不到标题放网址
        XCTAssertTrue(ArticleText.initial(title: "  ", url: "https://e.com/a").hasPrefix("# https://e.com/a"))
    }

    func testComposeKeepsURLLast() {
        let t = ArticleText.compose(title: "Big title", body: "Para one.\n\nPara two.\n", url: "https://e.com/a", keepingHeadOf: "# old\n\nhttps://e.com/a")
        XCTAssertEqual(t, "# Big title\n\nPara one.\n\nPara two.\n\nhttps://e.com/a")
        XCTAssertEqual(Markdown5.title(t), "Big title")
        XCTAssertEqual(t.split(separator: "\n").last, "https://e.com/a")                              // 网址留在最后一行
        // 大管家没给标题：留便签原来的第一行
        let k = ArticleText.compose(title: nil, body: "Body.", url: "https://e.com/a", keepingHeadOf: "# Old head\n\nhttps://e.com/a")
        XCTAssertTrue(k.hasPrefix("# Old head\n\nBody."))
    }

    // ---------------------------------------------------------------- 信
    func testRequestFields() throws {
        let a = ButlerRequest.article(id: "ART-0001", note: "N-1", url: "https://e.com/a", at: "2026-11-24T18:00:00+08:00", app: "0.7.10")
        let s = ButlerRequest.simplify(id: "SIM-0001", note: "N-1", text: "# T\n\nBody text here.", at: "2026-11-24T18:00:00+08:00", app: "0.7.10")
        let ea = try MailEnvelope.request(a).encoded()
        let es = try MailEnvelope.request(s).encoded()
        let ja = String(decoding: ea, as: UTF8.self)
        let js = String(decoding: es, as: UTF8.self)
        XCTAssertTrue(ja.contains("\"ask\":\"article\"") && ja.contains("\"url\":\"https://e.com/a\""))
        XCTAssertTrue(js.contains("\"ask\":\"simplify\"") && js.contains("\"text\":\"# T\\n\\nBody text here.\""))
        XCTAssertEqual(try MailEnvelope.decode(ea).request?.url, "https://e.com/a")
        XCTAssertNil(try MailEnvelope.decode(es).request?.url)
    }

    func testArticleReplyRouting() throws {
        let ok = #"{"v":1,"id":"ART-0001","note":"N-1","ok":true,"text":"Clean body.","title":"A title","host":"电脑"}"#
        let r = try JSONDecoder().decode(ButlerResult.self, from: Data(ok.utf8))
        XCTAssertEqual(r.title, "A title")
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:], articles: ["ART-0001"]), .article(r))
        XCTAssertEqual(MailAction.decide(.result(r), waiting: [:], dubbing: [:]), .drop("没人在等 ART-0001"))
    }

    // ---------------------------------------------------------------- 文章便签的状态
    func testFetchFlow() {
        var st = ArticleState()
        st.url = "https://e.com/a"
        st.startFetch(id: "F1", now: t0)
        XCTAssertTrue(st.fetching(now: t0.addingTimeInterval(30)))
        XCTAssertFalse(st.canPress(now: t0.addingTimeInterval(30)))                                 // 正文还在扒：按钮灰着
        XCTAssertEqual(st.line(now: t0.addingTimeInterval(30)), .fetching)
        XCTAssertFalse(st.fetchReply(id: "OLD", ok: true, error: nil))                              // 不是这次的回信，不理
        XCTAssertTrue(st.fetchReply(id: "F1", ok: true, error: nil))
        XCTAssertEqual(st.fetch, .ready)
        XCTAssertTrue(st.canPress(now: t0.addingTimeInterval(31)))
        XCTAssertEqual(st.line(now: t0), .none)
    }

    func testFetchFailedStillPressable() {
        var st = ArticleState()
        st.startFetch(id: "F1", now: t0)
        XCTAssertFalse(st.fetchReply(id: "F1", ok: false, error: "这页大管家进不去"))
        XCTAssertEqual(st.line(now: t0), .fetchFailed("这页大管家进不去"))
        XCTAssertTrue(st.canPress(now: t0))                                                         // 扒失败：按钮照样能用
    }

    func testFetchSilentAfterTenMinutes() {
        var st = ArticleState()
        st.startFetch(id: "F1", now: t0)
        XCTAssertTrue(st.fetching(now: t0.addingTimeInterval(599)))
        XCTAssertFalse(st.fetching(now: t0.addingTimeInterval(601)))
        XCTAssertTrue(st.canPress(now: t0.addingTimeInterval(601)))
        XCTAssertEqual(st.line(now: t0.addingTimeInterval(601)), .fetchSilent)
    }

    func testSimplifyFlow() {
        var st = ArticleState()
        st.fetch = .ready
        st.startSimplify(id: "S1", now: t0)
        XCTAssertEqual(st.line(now: t0.addingTimeInterval(60)), .simplifying)
        XCTAssertFalse(st.canPress(now: t0.addingTimeInterval(60)))
        st.pieceArrived(request: "OTHER", note: "X")                                                // 别的请求的听力，不理
        XCTAssertNil(st.simplifiedNote)
        st.pieceArrived(request: "S1", note: "LISTEN-1")
        st.pieceArrived(request: "S1", note: "LISTEN-2")                                            // 多篇：只记第一篇
        XCTAssertEqual(st.simplifiedNote, "LISTEN-1")
        XCTAssertEqual(st.line(now: t0.addingTimeInterval(61)), .simplified(note: "LISTEN-1"))
        st.simplifyReply(id: "S1", ok: true, error: nil)                                            // 后到的结果，不改
        XCTAssertEqual(st.simplify, .done)
        XCTAssertTrue(st.canPress(now: t0.addingTimeInterval(62)))
    }

    func testSimplifyFailedAndAgain() {
        var st = ArticleState()
        st.startSimplify(id: "S1", now: t0)
        st.simplifyReply(id: "S1", ok: false, error: "大脑没写成：超时")
        XCTAssertEqual(st.line(now: t0), .simplifyFailed("大脑没写成：超时"))
        st.startSimplify(id: "S2", now: t0.addingTimeInterval(10))                                  // 再点一次：从头来
        XCTAssertEqual(st.simplify, .working)
        XCTAssertNil(st.simplifyError)
        st.simplifyReply(id: "S1", ok: true, error: nil)                                            // 旧请求的回信不理
        XCTAssertEqual(st.simplify, .working)
    }

    func testStateRoundTrip() {
        var st = ArticleState()
        st.url = "https://e.com/a"
        st.startFetch(id: "F1", now: t0)
        XCTAssertEqual(ArticleState.decode(st.encoded()), st)
        XCTAssertEqual(ArticleState.decode(""), ArticleState())
        XCTAssertEqual(ArticleState.decode("not json"), ArticleState())
    }
}
