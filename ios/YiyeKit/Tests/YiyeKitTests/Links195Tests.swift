import XCTest
@testable import YiyeKit

/// 195 认网址
final class Links195Tests: XCTestCase {
    private func urls(_ text: String) -> [String] { Links.find(text).map { $0.url.absoluteString } }

    private func pieces(_ text: String) -> [String] {
        Links.find(text).map { (text as NSString).substring(with: $0.range) }
    }

    func testLongSignInURLIsOneWholeLink() {
        let long = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code"
            + "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile"
            + "&code_challenge=AbCdEfGh1234567890AbCdEfGh1234567890abcde&code_challenge_method=S256&state=XyZ_123-456"
        let text = "第二个网址：一年的令牌（大管家平时一问一答用它），也是点开登、把那串码整串发我：\n" + long
        XCTAssertEqual(pieces(text), [long])
        XCTAssertEqual(urls(text), [long])
        XCTAssertEqual(Links.signIns(text).map(\.absoluteString), [long])
    }

    func testChinesePunctuationAndWordsAreNotPartOfTheLink() {
        XCTAssertEqual(pieces("看这个 https://example.com/a，然后回我"), ["https://example.com/a"])
        XCTAssertEqual(pieces("网址（https://example.com/b）点开。"), ["https://example.com/b"])
        XCTAssertEqual(pieces("打开https://example.com然后登"), ["https://example.com"])
        XCTAssertEqual(urls("打开https://example.com然后登"), ["https://example.com"])
        XCTAssertEqual(pieces("在 https://example.com/c。"), ["https://example.com/c"])
    }

    func testBareDomainsAndWWW() {
        XCTAssertEqual(pieces("去 claude.ai/settings 看"), ["claude.ai/settings"])
        XCTAssertEqual(pieces("www.example.org 也行"), ["www.example.org"])
    }

    func testFileNamesAndMailAreNotLinks() {
        XCTAssertEqual(urls("改了 butler.py 和 config.local.toml，装 Yiye.app，见 规矩.md"), [])
        XCTAssertEqual(urls("写信到 someone@example.com"), [])
        XCTAssertEqual(urls("版本 0.7.34，没有网址"), [])
        XCTAssertEqual(urls(""), [])
    }

    func testRangesAreUTF16WithEmojiBefore() {
        let text = "🐟 好了 https://example.com/x 完"
        XCTAssertEqual(pieces(text), ["https://example.com/x"])
    }

    func testSignInOnlyForOAuthAuthorize() {
        XCTAssertTrue(Links.isSignIn(URL(string: "https://claude.ai/oauth/authorize?x=1")!))
        XCTAssertFalse(Links.isSignIn(URL(string: "https://claude.ai/settings")!))
        let u = "https://example.com/oauth/authorize?a=1"
        XCTAssertEqual(Links.signIns("\(u) 和 \(u)").count, 1)
        XCTAssertEqual(Links.signIns("https://example.com/"), [])
    }
}
