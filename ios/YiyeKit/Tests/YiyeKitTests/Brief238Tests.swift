import Foundation
import XCTest
@testable import YiyeKit

/// 238：称呼行不当小标题；结尾的日期和它上面的名字靠右
final class Brief238Tests: XCTestCase {
    private func salutes(_ m: SModel) -> [String] {
        m.blocks.compactMap { b -> String? in
            if case .para(let r, _, _, true) = b { return r.map(\.text).joined() }
            return nil
        }
    }

    private func subs(_ m: SModel) -> [String] {
        m.blocks.compactMap { b -> String? in if case .sub(let s) = b { return s }; return nil }
    }

    private func signs(_ m: SModel) -> [String] {
        m.blocks.flatMap { b -> [String] in if case .sign(let l, _) = b { return l }; return [] }
    }

    /// ios/tools/brief-samples/（这个测试文件往上四层是 ios/）
    private func sample(_ name: String) throws -> String {
        let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: ios.appendingPathComponent("tools/brief-samples/\(name).md"), encoding: .utf8)
    }

    // ---------------------------------------------------------------- 称呼
    func testSaluteWithBlankLineBelowStaysAParagraph() {
        let m = Structure.parse("# 停电通知\n\n各位同事：\n\n因配电房检修，一号车间停电。")
        XCTAssertEqual(salutes(m), ["各位同事："], "\(m.blocks)")      // 普通段落、冒号还在
        XCTAssertEqual(subs(m), [])
    }

    func testSaluteAsVeryFirstLineIsNotTheTitle() {
        let m = Structure.parse("各位同事：\n\n因配电房检修，一号车间停电。")
        XCTAssertEqual(m.titleText, "")
        XCTAssertEqual(salutes(m), ["各位同事："], "\(m.blocks)")
    }

    func testSaluteWords() {
        for yes in ["各位住宿员工：", "尊敬的各位家长:", "亲爱的小李：", "致全体员工：", "Dear all:", "Hi team:", "hello everyone：", "To all staff:"] {
            XCTAssertTrue(Structure.isSalute(yes), yes)
        }
        for no in ["致谢：", "注意事项：", "带好：", "To do:", "To-do:", "To buy:", "History:", "Today:", "各位同事", "各位同事，请看下面这几条要求：不要迟到",
                   "各位参加这次年度总结大会的同事和外来嘉宾朋友们：", "大家好，各位："] {
            XCTAssertFalse(Structure.isSalute(no), no)
        }
    }

    func testHeadingInTheMiddleStaysAHeading() {
        let m = Structure.parse("# 通知\n\n因配电房检修，一号车间停电。\n\n注意事项：\n\n关好电源。\n\n各位同事：\n\n互相转告。")
        XCTAssertEqual(subs(m), ["注意事项", "各位同事"], "\(m.blocks)")   // 正文中间的照旧是小标题
        XCTAssertEqual(salutes(m), [])
    }

    func testThanksOnTheFirstLineIsNotASalute() {
        let m = Structure.parse("# 论文\n\n致谢：\n\n感谢导师的指导。")
        XCTAssertEqual(salutes(m), [], "\(m.blocks)")
        XCTAssertEqual(subs(m), ["致谢"])
    }

    // ---------------------------------------------------------------- 落款
    func testNameAndDateAtTheEndGoRight() {
        let m = Structure.parse("# 通知\n\n如有疑问，找设备课陈工。\n\n设备课\n2026年11月27日")
        XCTAssertEqual(m.blocks.last, .sign(["设备课", "2026年11月27日"], dash: false), "\(m.blocks)")
    }

    func testDateFormats() {
        for d in ["2026年11月26日", "2026-11-26", "2026.11.26", "11月26日", "2026年11月26日（星期四）"] {
            let m = Structure.parse("# 通知\n明天照常上班。\n\(d)\n")
            XCTAssertEqual(signs(m).last, d, "\(m.blocks)")
        }
        for no in ["1.5", "26.11", "版本 2026.11.26"] {
            XCTAssertFalse(Structure.signDateRe.test(no), no)
        }
    }

    func testOnlyAShortNameJoinsTheDate() {
        // 上一行带句号、超过 15 个字、是清单或键值：只有日期靠右
        for above in ["明天照常上班。", "这一行写得很长已经超过十五个字了不算名字", "- 带上房卡", "地点：宿舍楼下", "带好：", "**请准时**"] {
            let m = Structure.parse("# 通知\n大家看一下\n\(above)\n11月26日")
            XCTAssertEqual(signs(m), ["11月26日"], "\(above) \(m.blocks)")
        }
        // 日期前面隔了空行：名字不跟着走
        XCTAssertEqual(signs(Structure.parse("# 通知\n大家看一下。\n\n设备课\n\n2026年11月27日")), ["2026年11月27日"])
        // 整张只有一个日期：不当落款
        XCTAssertEqual(signs(Structure.parse("11月26日")), [])
    }

    func testDateInTheMiddleStaysLeft() {
        let m = Structure.parse("# 记录\n上午开会。\n\n设备课\n2026年11月27日\n\n下午接着干，没干完的明天再说。")
        XCTAssertEqual(signs(m), [], "\(m.blocks)")
        let long = "这个月订单比上个月多了不少，各位辛苦了，月底前要把积压的单子清掉。"
        XCTAssertEqual(signs(Structure.parse("# 记录\n\(long)\n11月26日\n然后再说两句")), [])
    }

    func testSignOffWithoutADateStillWorks() {
        let long = "本周六正常上班，下周一补休，请大家互相转告，有问题找组长。"
        XCTAssertEqual(signs(Structure.parse("通知\n\(long)\n——人事部")), ["人事部"])
        XCTAssertEqual(signs(Structure.parse("通知\n\(long)\n\n办公室")), ["办公室"])
    }

    // ---------------------------------------------------------------- 228 的两张样稿、三张纸
    func testTheTwoSamplesOnAllThreePapers() throws {
        for (name, salute, dept, date) in [("02通知", "各位同事：", "设备课", "2026年11月27日"),
                                           ("12打印通知照片", "各位住宿员工：", "行政部", "2026年11月26日")] {
            let m = Structure.parse(try sample(name))
            XCTAssertEqual(salutes(m), [salute], "\(name) \(m.blocks)")
            XCTAssertEqual(m.blocks.last, .sign([dept, date], dash: false), "\(name) \(m.blocks)")
            for theme in ShareTheme.all {
                let r = ShareLayout.layout(m, theme: theme, measurer: FakeMeasurer(), mark: "ONE")
                for word in [dept, date] {
                    XCTAssertTrue(r.ops.contains { op in
                        if case .text(let s, let x, _, _, _, let a, _) = op { return s == word && a == .right && x == ShareLayout.width - theme.pad.r }
                        return false
                    }, "\(name) \(theme.id) \(word) 没靠右")
                }
                XCTAssertTrue(r.ops.contains { op in
                    if case .text(let s, let x, _, _, _, let a, _) = op { return s == salute && a == .left && x == theme.pad.l }
                    return false
                }, "\(name) \(theme.id) 称呼没按正文排")
                XCTAssertFalse(r.ops.contains { if case .rect(_, _, let w, _, let fill, _, _) = $0 { return w == 3 && fill == theme.headingBar && theme.headingBar != nil }; return false },
                               "\(name) \(theme.id) 不该有小标题竖条")
            }
        }
    }
}
