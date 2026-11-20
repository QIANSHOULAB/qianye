import Foundation
import XCTest
@testable import YiyeKit

/// 假的量字：汉字一个字号宽，别的 0.55 个字号
final class FakeMeasurer: TextMeasurer {
    func width(_ s: String, _ f: FontSpec) -> Double {
        s.reduce(0) { $0 + (isWide($1) ? f.size : f.size * 0.55) } * (f.weight >= 700 ? 1.04 : 1)
    }
}

final class StructureLayoutTests: XCTestCase {
    func testPairsAndTitle() {
        let m = Structure.parse("11月2日产量\nA线 1280件\nB线 960件\nC线 1105件\n合计 3345件")
        XCTAssertEqual(m.titleText, "11月2日产量")
        guard case .rows(let rows) = m.blocks[1] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].label, [Run("A线")])
        XCTAssertEqual(rows[0].num?.int, "1280")
        XCTAssertEqual(rows[0].unit, "件")
        XCTAssertTrue(rows[3].total)
    }

    func testDecimalAndKV() {
        let m = Structure.parse("质检\n合格率：98.5%\n时间：11月8日下午\n地点：二楼会议室")
        guard case .rows(let r) = m.blocks[1] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(r[0].num?.int, "98")
        XCTAssertEqual(r[0].num?.frac, ".5")
        guard case .kvs(let kv, _) = m.blocks[2] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(kv.map(\.key), ["时间", "地点"])
    }

    func testBlobSplit() {
        XCTAssertEqual(Structure.splitBlob("A线早班12件B线早班9件C线早班15件"), ["A线早班12件", "B线早班9件", "C线早班15件"])
        XCTAssertEqual(Structure.splitBlob("本月出勤：张师傅22天，李师傅20天，王师傅21天"), ["本月出勤", "张师傅22天", "李师傅20天", "王师傅21天"])
    }

    func testListsAndBareKV() {
        let m = Structure.parse("采购清单\n1. 螺丝 200个\n2. 垫片 50个\n\n值班\n周一 张师傅\n周二 李师傅\n周三 王师傅")
        XCTAssertEqual(m.titleText, "采购清单")
        guard case .rows(let r) = m.blocks[1] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(r.map(\.marker), ["1.", "2."])
        XCTAssertEqual(r[0].num?.int, "200")
        XCTAssertTrue(m.blocks.contains { if case .kvs(_, true) = $0 { return true }; return false }, "\(m.blocks)")
    }

    func testMarkdownBlocks() {
        let md = "# 周会\n## 进度\n- A线 1280件\n- 换刀\n> 冷却液快没了\n<center>就这些</center>\n这周**很忙**，大家辛苦了，下周继续，有事随时找我说一声就行。\n![](附件/a.jpg)"
        let m = Structure.parse(md)
        XCTAssertEqual(m.titleText, "周会")
        XCTAssertEqual(m.blocks[0], .title("周会", center: false))
        XCTAssertEqual(m.blocks[1], .heading([Run("进度")], level: 2, center: false))
        guard case .rows(let r) = m.blocks[2] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(r[0].num?.int, "1280")
        XCTAssertEqual(r[1].label, [Run("换刀")])
        XCTAssertEqual(m.blocks[3], .para([Run("冷却液快没了")], quote: true, center: false, salute: false))
        XCTAssertEqual(m.blocks[4], .para([Run("就这些")], quote: false, center: true, salute: false))
        guard case .para(let runs, false, false, false) = m.blocks[5] else { return XCTFail("\(m.blocks)") }
        XCTAssertEqual(runs[1], Run("很忙", bold: true))
        XCTAssertEqual(m.blocks[6], .image("附件/a.jpg"))
    }

    func testSignAndSalute() {
        let t = "通知\n各车间：\n明天上午八点在二楼会议室开安全生产会议，请各车间主任准时参加，不要迟到。\n\n行政部\n11月20日"
        let m = Structure.parse(t)
        XCTAssertTrue(m.blocks.contains { if case .para(_, _, _, true) = $0 { return true }; return false }, "\(m.blocks)")
        XCTAssertEqual(m.blocks.last, .sign(["行政部", "11月20日"], dash: false))
    }

    func testLayoutAlignsNumbers() {
        let m = Structure.parse("产量\nA线 1280件\nB线 96.5件\nC线 1105件")
        for theme in ShareTheme.all {
            let r = ShareLayout.layout(m, theme: theme, measurer: FakeMeasurer(), mark: "一叶笺")
            XCTAssertGreaterThan(r.height, 100)
            // 整数部分右对齐在同一个 x 上
            let ints = r.ops.compactMap { op -> Double? in
                if case .text(let s, let x, _, _, _, let a, _) = op, a == .right, ["1280", "96", "1105"].contains(s) { return x }
                return nil
            }
            XCTAssertEqual(ints.count, 3)
            XCTAssertEqual(Set(ints).count, 1)
            // 落款在
            XCTAssertTrue(r.ops.contains { if case .text("一叶笺", _, _, _, _, _, _) = $0 { return true }; return false })
            // 不印日期：除了正文里的字，没有别的
            let texts = r.ops.compactMap { op -> String? in if case .text(let s, _, _, _, _, _, _) = op { return s }; return nil }
            XCTAssertFalse(texts.contains { $0.contains("2026") })
        }
    }

    func testLongTextMakesLongImage() {
        let short = ShareLayout.layout(Structure.parse("一句话"), theme: .note, measurer: FakeMeasurer(), mark: "Yiye")
        let long = ShareLayout.layout(Structure.parse(String(repeating: "很长很长的一段话，", count: 120)), theme: .note, measurer: FakeMeasurer(), mark: "Yiye")
        XCTAssertGreaterThan(long.height, short.height * 5)
        // 每行都不超出纸
        for op in long.ops {
            if case .text(var s, let x, _, let f, _, .left, _) = op {
                while let c = s.last, ShareLayout.noStart.contains(c) { s.removeLast() }   // 标点可以挂在行尾
                XCTAssertLessThanOrEqual(x + FakeMeasurer().width(s, f), ShareLayout.width - ShareTheme.note.pad.r + 0.01)
            }
        }
    }

    func testWrapKeepsPunctuationOffLineStart() {
        let lay = ShareLayout(t: .note, m: FakeMeasurer(), latin: false)
        let lines = lay.wrap("一二三四五六七八九十，好", FontSpec(10), 100)
        XCTAssertEqual(lines.first, "一二三四五六七八九十，")
    }

    func testNoiseIsDeterministic() {
        let a = PaperNoise.specks(width: 390, height: 300, alpha: 0.05, seed: 11)
        let b = PaperNoise.specks(width: 390, height: 300, alpha: 0.05, seed: 11)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.first, b.first)
        XCTAssertEqual(a.count, 3 * 8986)
    }
}
