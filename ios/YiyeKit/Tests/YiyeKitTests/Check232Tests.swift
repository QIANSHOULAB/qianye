import Foundation
import XCTest
@testable import YiyeKit

/// 232：手机点出来的词，跟大管家写进 trans 的「w」键对得上。
/// 下面每句的键是拿大管家那头切词的原函数（pc-butler handheld/trans.py 的 keys，11-27）算出来抄在这儿的。
final class Check232Tests: XCTestCase {
    private let cases: [(s: String, keys: [String])] = [
        ("The U.S. aides say e.g. Iran’s well-known mid-1990s plan didn’t work.",
         ["the", "u.s", "aides", "say", "e.g", "iran’s", "well-known", "mid-1990s", "plan", "didn’t", "work"]),
        ("Prime Minister's COVID-19 talks pull out in 2026, don't they?",
         ["prime", "minister's", "covid-19", "talks", "pull", "out", "in", "don't", "they"]),
        ("A 5G e-mail at 3 o'clock—the U.S.-led ‘quotes’ and the dogs' bones, i.e. 100% real.",
         ["a", "5g", "e-mail", "at", "o'clock", "the", "u.s", "led", "quotes", "and", "dogs", "bones", "i.e", "real"]),
    ]

    func testTappedWordsGiveTheButlersKeys() {
        for c in cases {
            var seen: [String] = []
            for r in WordPick.words(in: c.s) {
                let k = TransLookup.key((c.s as NSString).substring(with: r))
                if !seen.contains(k) { seen.append(k) }
            }
            XCTAssertEqual(seen, c.keys, c.s)
        }
    }

    func testEveryTappedWordFindsItsMeaning() {
        for c in cases {
            let line = ListenTrans.Line(s: c.s, zh: "整句", w: Dictionary(uniqueKeysWithValues: c.keys.map { ($0, "意思·\($0)") }))
            for r in WordPick.words(in: c.s) {
                let token = (c.s as NSString).substring(with: r)
                XCTAssertEqual(TransLookup.word(r, in: c.s, line: line)?.zh, "意思·\(TransLookup.key(token))", "\(token) 在「\(c.s)」里查不到")
            }
        }
    }

    func testPhraseAsTheButlerSendsIt() {
        // p 里的 t 是原句里原样的一段（弯撇号、连字符都照原文）
        let s = "Aides to Iran’s Supreme Leader pull out of the U.S.-led talks."
        let line = ListenTrans.Line(s: s, zh: "整句", w: ["leader": "领袖"],
                                    p: [.init(t: "Iran’s Supreme Leader", zh: "伊朗最高领袖"), .init(t: "pull out", zh: "退出"), .init(t: "U.S.-led", zh: "美国牵头的")])
        func tap(_ word: String) -> TransLookup.Hit? { TransLookup.word((s as NSString).range(of: word), in: s, line: line) }
        for w in ["Iran’s", "Supreme", "Leader"] { XCTAssertEqual(tap(w)?.zh, "伊朗最高领袖", w) }
        XCTAssertEqual(tap("out")?.text, "pull out")
        XCTAssertEqual(tap("U.S.")?.zh, "美国牵头的")
        XCTAssertEqual(tap("led")?.zh, "美国牵头的")
        XCTAssertNil(tap("talks"))
    }
}
