import Foundation
import XCTest
@testable import YiyeKit

/// 123：写字页的记号只在光标所在的行露出来。这里测「这一行露不露」的规则，和每一行记号的位置（藏的就是这些位置）
final class Marker123Tests: XCTestCase {
    // 三行：「# 标题\n」0..<5、「- 清单\n」5..<10、「**粗**尾」10..<17（最后一行没有换行）
    let text = "# 标题\n- 清单\n**粗**尾"
    func lines() -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var at = 0
        while at < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: at, length: 0))
            out.append(r)
            at = NSMaxRange(r)
        }
        return out
    }

    func shown(_ sel: NSRange) -> [Bool] {
        lines().map { MarkerVisibility.reveals(line: $0, selection: sel, total: (text as NSString).length) }
    }

    func testCaretInsideALine() {
        XCTAssertEqual(lines().count, 3)
        XCTAssertEqual(shown(NSRange(location: 2, length: 0)), [true, false, false])           // 光标在标题行里
        XCTAssertEqual(shown(NSRange(location: 7, length: 0)), [false, true, false])           // 在清单行里
        XCTAssertEqual(shown(NSRange(location: 12, length: 0)), [false, false, true])
    }

    func testCaretAtLineEdges() {
        XCTAssertEqual(shown(NSRange(location: 0, length: 0)), [true, false, false])           // 行首：露
        XCTAssertEqual(shown(NSRange(location: 4, length: 0)), [true, false, false])           // 标题行末尾（换行前）：还是这一行
        XCTAssertEqual(shown(NSRange(location: 5, length: 0)), [false, true, false])           // 换行后面 = 下一行的行首，上一行藏回去
        let end = (text as NSString).length
        XCTAssertEqual(shown(NSRange(location: end, length: 0)), [false, false, true])         // 文末：最后一行
    }

    func testSelectionTouchesSeveralLines() {
        XCTAssertEqual(shown(NSRange(location: 3, length: 4)), [true, true, false])           // 从标题选到清单里
        XCTAssertEqual(shown(NSRange(location: 0, length: (text as NSString).length)), [true, true, true])   // 全选：全露
        XCTAssertEqual(shown(NSRange(location: 0, length: 5)), [true, false, false])          // 选的正好是第一行（到换行为止）：下一行不算
    }

    func testNoCursorHidesEverything() {
        // 没开着键盘（没有光标）：写字页传 nil，一行都不露——这是调用方的事；规则里选区放到文外也不露任何一行
        XCTAssertEqual(shown(NSRange(location: 999, length: 0)), [false, false, false])
    }

    func testRestyleOnlyWhenTheRevealedLinesChange() {
        let a = NSRange(location: 0, length: 5), b = NSRange(location: 5, length: 5)
        XCTAssertFalse(MarkerVisibility.needsRestyle(oldKey: a, newKey: a))                   // 同一行里挪光标
        XCTAssertTrue(MarkerVisibility.needsRestyle(oldKey: a, newKey: b))                    // 换了一行
        XCTAssertTrue(MarkerVisibility.needsRestyle(oldKey: nil, newKey: a))                  // 刚点进写字页
        XCTAssertTrue(MarkerVisibility.needsRestyle(oldKey: a, newKey: nil))                  // 收起键盘
        XCTAssertFalse(MarkerVisibility.needsRestyle(oldKey: nil, newKey: nil))
    }

    /// 藏的就是 Markdown5 认出来的那些记号：标题的「# 」、清单的「- 」、粗体两头的「**」；字本身不在里面
    func testMarkersAreOnlyTheSyntax() {
        let ns = text as NSString
        let ls = Markdown5.parse(text)
        let hidden = ls.flatMap { $0.markers }.map { ns.substring(with: $0) }
        XCTAssertEqual(hidden, ["# ", "- ", "**", "**"])
        for l in ls { for m in l.markers { XCTAssertTrue(NSLocationInRange(m.location, l.range)) } }
        XCTAssertEqual(ns.substring(with: ls[0].content), "标题")
        XCTAssertEqual(ns.substring(with: ls[2].bold[0]), "粗")
    }

    /// 图上本来有的符号不是记号：日期里的「–」、「/」、编号里的横杠、人名都不会被当成要藏的东西
    func testSymbolsFromThePaperAreNotMarkers() {
        let t = "Departure: 24 Nov 2026 – 14:30\nTicket-No: BTM-889102\nDate: 2026/11/23\nSONG CHENGMIN"
        XCTAssertTrue(Markdown5.parse(t).allSatisfy { $0.markers.isEmpty })
    }
}
