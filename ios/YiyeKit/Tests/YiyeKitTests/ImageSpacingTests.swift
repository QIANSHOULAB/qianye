import Foundation
import XCTest
@testable import YiyeKit

/// 插图上下的空行：默认空一格，「靠拢」不空（Song 11-22）
final class ImageSpacingTests: XCTestCase {
    let X = String(DisplayMap.attachmentChar)

    /// 照计划插一张图，回插完的字和光标位置（UTF-16）
    func insert(_ before: String, _ after: String, gap: Bool) -> (String, Int) {
        let p = ImageSpacing.insertion(before: before, after: after, gap: gap)
        let text = before + String(repeating: "\n", count: p.prefix) + X + String(repeating: "\n", count: p.suffix) + after
        return (text, before.utf16.count + p.caret)
    }

    func testInsertIntoEmptyNote() {
        // 空一格：上面空一行（好写标题），图下面空一行，光标在空行下面
        let (t, c) = insert("", "", gap: true)
        XCTAssertEqual(t, "\n\(X)\n\n")
        XCTAssertEqual(c, t.utf16.count)
        // 靠拢：顶到头（以前的样子）
        let (s, d) = insert("", "", gap: false)
        XCTAssertEqual(s, "\(X)\n")
        XCTAssertEqual(d, s.utf16.count)
    }

    func testImagesInARowAreOneLineApart() {
        var (t, c) = insert("", "", gap: true)
        for _ in 0..<2 {
            let ns = t as NSString
            (t, c) = insert(ns.substring(to: c), ns.substring(from: c), gap: true)
        }
        XCTAssertEqual(t, "\n\(X)\n\n\(X)\n\n\(X)\n\n")
        // 靠拢：一张挨一张
        var (s, d) = insert("", "", gap: false)
        let ns = s as NSString
        (s, d) = insert(ns.substring(to: d), ns.substring(from: d), gap: false)
        XCTAssertEqual(s, "\(X)\n\(X)\n")
    }

    func testAfterTextInTheMiddleAndAtLineStart() {
        XCTAssertEqual(insert("早班 1280件", "", gap: true).0, "早班 1280件\n\n\(X)\n\n")
        XCTAssertEqual(insert("早班 1280件", "", gap: false).0, "早班 1280件\n\(X)\n")
        // 一行字中间插：前后都隔一行，光标落在后半截字的前面
        let (t, c) = insert("早班", "1280件", gap: true)
        XCTAssertEqual(t, "早班\n\n\(X)\n\n1280件")
        XCTAssertEqual((t as NSString).substring(from: c), "1280件")
        // 已经空过行的不再多空
        XCTAssertEqual(insert("早班\n\n", "", gap: true).0, "早班\n\n\(X)\n\n")
        XCTAssertEqual(insert("早班\n", "\n晚班", gap: true).0, "早班\n\n\(X)\n\n晚班")
        // 光标后面全是空行：不多加，光标照样落在图下面隔一行的地方
        let (u, e) = insert("早班", "\n\n\n", gap: true)
        XCTAssertEqual(u, "早班\n\n\(X)\n\n\n")
        XCTAssertEqual((u as NSString).substring(to: e), "早班\n\n\(X)\n\n")
        // 上面原本就有空行（标题还没写）：不再加
        XCTAssertEqual(insert("\n", "", gap: true).0, "\n\(X)\n\n")
    }

    func testRespaceWholeNote() {
        let snug = "\(X)\n\(X)\n早班 1280件\n\(X)"
        let spaced = "\n\(X)\n\n\(X)\n\n早班 1280件\n\n\(X)"
        XCTAssertEqual(ImageSpacing.respace(snug, gap: true), spaced)
        XCTAssertEqual(ImageSpacing.respace(spaced, gap: false), snug)
        XCTAssertEqual(ImageSpacing.respace(spaced, gap: true), spaced)          // 已经是这样：不动
        // 好几行空行也收成一行
        XCTAssertEqual(ImageSpacing.respace("标题\n\n\n\n\(X)", gap: true), "标题\n\n\(X)")
        // 字跟字之间、最后面的空行不动；没有图的笔记原样
        XCTAssertEqual(ImageSpacing.respace("早班\n\n\n晚班\n\(X)\n\n\n", gap: true), "早班\n\n\n晚班\n\n\(X)\n\n\n")
        XCTAssertEqual(ImageSpacing.respace("早班\n\n\n晚班", gap: false), "早班\n\n\n晚班")
        XCTAssertEqual(ImageSpacing.respace("", gap: true), "")
        XCTAssertEqual(ImageSpacing.respace("\n\n", gap: false), "\n\n")
        // 图跟字挤在一行的不算图行，不动
        XCTAssertEqual(ImageSpacing.respace("\(X)早班\n晚班", gap: true), "\(X)早班\n晚班")
    }

    func testOnlyBlankLinesChangeAndCaretFollows() {
        let snug = "\(X)\n早班\n\(X)"
        let spaced = ImageSpacing.respace(snug, gap: true)
        XCTAssertTrue(ImageSpacing.onlyBlanksDiffer(snug, spaced))
        XCTAssertFalse(ImageSpacing.onlyBlanksDiffer(snug, "\(X)\n晚班\n\(X)"))
        XCTAssertFalse(ImageSpacing.onlyBlanksDiffer(snug, "早班\n\(X)"))                // 图没了不行
        // 光标在「早班」前面：重排以后还在「早班」前面
        let at = (snug as NSString).range(of: "早班").location
        let moved = ImageSpacing.caret(at, from: snug, to: spaced)
        XCTAssertTrue((spaced as NSString).substring(from: moved).hasPrefix("早班"))
        // 光标在「早班」后面
        let end = at + "早班".utf16.count
        XCTAssertEqual((spaced as NSString).substring(to: ImageSpacing.caret(end, from: snug, to: spaced)), "\n\(X)\n\n早班")
        // 靠拢回去也跟着走
        let back = ImageSpacing.caret((spaced as NSString).range(of: "早班").location, from: spaced, to: snug)
        XCTAssertTrue((snug as NSString).substring(from: back).hasPrefix("早班"))
        XCTAssertEqual(ImageSpacing.caret(snug.utf16.count, from: snug, to: spaced), spaced.utf16.count)
    }
}
