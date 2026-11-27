import Foundation
import XCTest
@testable import YiyeKit

/// 222：怎么切词、手指落在哪个词、点一下还是点两下、什么时候能自己滚
final class WordPick222Tests: XCTestCase {
    private func split(_ s: String) -> [String] {
        WordPick.words(in: s).map { (s as NSString).substring(with: $0) }
    }

    func testWords() {
        XCTAssertEqual(split("Bitcoin falls below $62,000"), ["Bitcoin", "falls", "below"])
        XCTAssertEqual(split("It costs 1.5 or 100% more."), ["It", "costs", "or", "more"])
        XCTAssertEqual(split("I don't know; it’s well-known."), ["I", "don't", "know", "it’s", "well-known"])
        XCTAssertEqual(split("‘Hello’ said the dogs' owner—twice."), ["Hello", "said", "the", "dogs", "owner", "twice"])
        XCTAssertEqual(split("COVID-19 and 5G in the mid-1990s, an e-mail at 3 o'clock"),
                       ["COVID-19", "and", "5G", "in", "the", "mid-1990s", "an", "e-mail", "at", "o'clock"])
        XCTAssertEqual(split("The U.S. said e.g. this. A bus."), ["The", "U.S.", "said", "e.g.", "this", "A", "bus"])
        XCTAssertEqual(split("A café, a naïve plan"), ["A", "café", "a", "naïve", "plan"])
        XCTAssertEqual(split("他说 hello，然后 iPhone发布"), ["hello", "iPhone"])
        XCTAssertEqual(split("通胀又涨了 3%。"), [])
        XCTAssertEqual(split(""), [])
        XCTAssertEqual(split(" -- ... "), [])
    }

    /// 范围是 UTF-16 的：前面有表情、组合字符也对得上
    func testUTF16Ranges() {
        let s = "🎉 Party time"
        XCTAssertEqual(split(s), ["Party", "time"])
        XCTAssertEqual(WordPick.words(in: s).first, NSRange(location: 3, length: 5))
        XCTAssertEqual(split("Cafe\u{301} open"), ["Cafe\u{301}", "open"])
    }

    func testHit() {
        // 两个词在第一行、一个词折在两行上
        let rects: [[CGRect]] = [
            [CGRect(x: 10, y: 6, width: 60, height: 22)],
            [CGRect(x: 75, y: 6, width: 40, height: 22)],
            [CGRect(x: 120, y: 6, width: 30, height: 22), CGRect(x: 10, y: 33, width: 20, height: 22)],
        ]
        XCTAssertEqual(WordPick.hit(x: 30, y: 17, rects: rects), 0)
        XCTAssertEqual(WordPick.hit(x: 72, y: 17, rects: rects), 0)      // 两个词的缝：归近的（离 0 是 2、离 1 是 3）
        XCTAssertEqual(WordPick.hit(x: 74, y: 17, rects: rects), 1)
        XCTAssertEqual(WordPick.hit(x: 15, y: 45, rects: rects), 2)      // 折下去的那半个
        XCTAssertEqual(WordPick.hit(x: 5, y: 2, rects: rects), 0)        // 边上一点点
        XCTAssertNil(WordPick.hit(x: 200, y: 17, rects: rects))          // 离得远：谁也不算
        XCTAssertNil(WordPick.hit(x: 100, y: 90, rects: rects))
        XCTAssertNil(WordPick.hit(x: 30, y: 17, rects: []))
    }

    func testTapCount() {
        var t = TapCount()
        XCTAssertEqual(t.tap(x: 10, y: 10, at: 100.0), 1)
        XCTAssertEqual(t.tap(x: 14, y: 12, at: 100.2), 2)       // 快、近：两下
        XCTAssertEqual(t.tap(x: 14, y: 12, at: 100.3), 1)       // 第三下重新数
        XCTAssertEqual(t.tap(x: 14, y: 12, at: 101.0), 1)       // 隔久了
        XCTAssertEqual(t.tap(x: 200, y: 12, at: 101.1), 1)      // 隔远了
        XCTAssertEqual(t.tap(x: 201, y: 13, at: 101.2), 2)
    }

    func testFollowHold() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var h = FollowHold()
        XCTAssertTrue(h.mayScroll(on: true, card: false, selecting: false, now: t0))
        XCTAssertFalse(h.mayScroll(on: false, card: false, selecting: false, now: t0))   // 开关关着
        XCTAssertFalse(h.mayScroll(on: true, card: true, selecting: false, now: t0))     // 开着卡片
        XCTAssertFalse(h.mayScroll(on: true, card: false, selecting: true, now: t0))     // 选着字
        h.touched(at: t0)
        XCTAssertFalse(h.mayScroll(on: true, card: false, selecting: false, now: t0.addingTimeInterval(4.9)))
        XCTAssertEqual(h.left(now: t0.addingTimeInterval(2)), 3, accuracy: 0.001)
        XCTAssertTrue(h.mayScroll(on: true, card: false, selecting: false, now: t0.addingTimeInterval(5)))
        h.touched(at: t0)
        h.clear()                                                                       // 点了「从这句放」：马上跟上
        XCTAssertTrue(h.mayScroll(on: true, card: false, selecting: false, now: t0))
    }
}
