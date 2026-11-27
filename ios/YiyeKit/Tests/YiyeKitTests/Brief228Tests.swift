import Foundation
import XCTest
@testable import YiyeKit

/// 228：出图的新纸「简报」，编号步骤按清单排（折行跟字对齐，不跟编号对齐）
final class Brief228Tests: XCTestCase {
    private typealias Word = (s: String, x: Double, y: Double, color: RGBA)

    private func texts(_ r: ShareLayoutResult) -> [Word] {
        r.ops.compactMap { op in
            if case .text(let s, let x, let y, _, let c, _, _) = op { return (s, x, y, c) }
            return nil
        }
    }

    func testBriefIsThirdPaper() {
        XCTAssertEqual(ShareTheme.all.map(\.id), ["note", "white", "brief"])
        XCTAssertEqual(ShareTheme.byID("brief"), .brief)
        XCTAssertEqual(ShareTheme.byID("nothing"), .note)             // 默认纸不动
        XCTAssertEqual(ShareTheme.brief.bg, RGBA(hex: "#FFFFFF"))
        XCTAssertNil(ShareTheme.note.headingBar)                      // 便签、白纸不长新东西
        XCTAssertNil(ShareTheme.note.quoteFill)
        XCTAssertNil(ShareTheme.white.headingBar)
        XCTAssertNil(ShareTheme.white.quoteFill)
        XCTAssertEqual(ShareTheme.note.sectionGap + ShareTheme.white.sectionGap, 0)
    }

    func testNumberedPrefix() {
        XCTAssertEqual(Markdown5.numberedPrefix("1. 开机")?.prefix, "1. ")
        XCTAssertEqual(Markdown5.numberedPrefix("12.  Check")?.number, "12")
        XCTAssertEqual(Markdown5.numberedPrefix("3、换刀")?.number, "3")
        XCTAssertEqual(Markdown5.numberedPrefix("4）对刀")?.number, "4")
        for no in ["1.5 米", "2026.11.27", "1.开机", "第 1. 步", "- 1. 开机", "A. 开机", "1. "] {
            XCTAssertNil(Markdown5.numberedPrefix(no), no)
        }
    }

    func testNumberedStepsWithBoldBecomeAList() {
        let m = Structure.parse("# 换刀\n1. 先停机。\n2. 换上 **T12** 立铣刀，锁紧扭矩 **35 牛米**。\n> 注意安全\n3. 空跑一遍，倍率 **25%**。")
        let rows = m.blocks.compactMap { b -> [RowItem]? in if case .rows(let r) = b { return r }; return nil }.flatMap { $0 }
        XCTAssertEqual(rows.map(\.marker), ["1.", "2.", "3."], "\(m.blocks)")
        XCTAssertEqual(rows[1].label.first, Run("换上 "))
        XCTAssertTrue(rows[1].label.contains(Run("T12", bold: true)))
        XCTAssertNil(rows[1].num)
        // 引用、标题、居中不当步骤
        let other = Structure.parse("# 笔记\n## 1. 方法 **重点**\n> 2. 引用 **一句**\n<center>3. 居中 **一句**</center>")
        XCTAssertFalse(other.blocks.contains { if case .rows = $0 { return true }; return false }, "\(other.blocks)")
    }

    func testWrappedStepAlignsWithItsText() {
        let long = "1. 把 Z 值输到刀补 **H12** 里，然后到 MDI 里面运行一遍，看实际高度和屏幕上写的对不对，不对就回到上一步重新量。"
        let m = Structure.parse("步骤\n\(long)\n2. 完了。")
        for theme in ShareTheme.all {
            let r = ShareLayout.layout(m, theme: theme, measurer: FakeMeasurer(), mark: "一叶笺")
            let all = texts(r)
            guard let one = all.first(where: { $0.s == "1." }), let two = all.first(where: { $0.s == "2." }) else { return XCTFail("\(theme.id) 没有编号") }
            // 第一步占的那几行：每一行最左边那截字都在同一个 x 上，且在编号右边
            let lines = Dictionary(grouping: all.filter { $0.y >= one.y - 0.5 && $0.y < two.y - 0.5 && $0.s != "1." }, by: { Int($0.y.rounded()) })
            XCTAssertGreaterThanOrEqual(lines.count, 3, "\(theme.id) 应该折行")
            let lefts = Set(lines.values.map { line in line.map(\.x).min()! })
            XCTAssertEqual(lefts.count, 1, "\(theme.id) 折行没对齐：\(lefts)")
            XCTAssertGreaterThan(lefts.first!, theme.pad.l + 8, "\(theme.id) 字顶到编号下面了")
            // 不出纸
            for w in all where !w.s.isEmpty { XCTAssertLessThanOrEqual(w.x, ShareLayout.width - theme.pad.r + 0.5, theme.id) }
        }
    }

    func testBriefBarQuoteAndInk() {
        let m = Structure.parse("# 周会\n## 决定\n正文带 **36 件** 粗体。\n> 别忘了\n## 待办\n- 换刀")
        let r = ShareLayout.layout(m, theme: .brief, measurer: FakeMeasurer(), mark: "一叶笺")
        let t = ShareTheme.brief
        let bars = r.ops.filter { if case .rect(_, _, let w, _, let fill, _, _) = $0 { return w == 3 && fill == t.headingBar }; return false }
        XCTAssertEqual(bars.count, 2)                                             // 两个小标题各一条竖线
        let head = texts(r).first { $0.s == "决定" }
        XCTAssertEqual(head?.x ?? 0, t.pad.l + 12, accuracy: 0.01)
        XCTAssertEqual(head?.color, t.subColor)
        XCTAssertEqual(texts(r).first { $0.s.contains("36") }?.color, t.ink)     // 数字和粗体用最深的墨色
        // 引用：浅灰块先画，字在块里
        guard let box = r.ops.firstIndex(where: { if case .rect(_, _, _, _, let fill, _, _) = $0 { return fill == t.quoteFill }; return false }),
              let word = r.ops.firstIndex(where: { if case .text(let s, _, _, _, _, _, _) = $0 { return s.contains("别忘了") }; return false })
        else { return XCTFail("没有引用块") }
        XCTAssertLessThan(box, word)
        if case .rect(let x, let y, let w, let h, _, _, _) = r.ops[box], case .text(_, let tx, let ty, _, _, _, _) = r.ops[word] {
            XCTAssertTrue(tx > x && tx < x + w && ty > y && ty < y + h)
        }
        // 便签照旧画引用线，没有竖线和色块
        let note = ShareLayout.layout(m, theme: .note, measurer: FakeMeasurer(), mark: "一叶笺")
        XCTAssertTrue(note.ops.contains { if case .rect(_, _, let w, _, let fill, _, _) = $0 { return w == 3 && fill == ShareTheme.note.quoteBar }; return false })
        XCTAssertFalse(note.ops.contains { if case .rect(_, _, _, _, let fill, _, _) = $0 { return fill == t.quoteFill || fill == t.headingBar }; return false })
    }
}
