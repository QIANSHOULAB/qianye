import Foundation
import XCTest
@testable import YiyeKit

final class DraftTests: XCTestCase {
    func line(_ t: String, _ top: Double, conf: Float = 1, alt: [String] = [], wraps: Bool? = false, title: Bool = false) -> OCRLine {
        OCRLine(text: t, confidence: conf, alternatives: alt, wraps: wraps, isTitle: title, top: top, left: 0.1, height: 0.03)
    }

    func testTitlePairsAndUnsure() {
        let page = OCRPage(blocks: [
            OCRBlock(kind: .paragraph, lines: [line("11月3日交接", 0.05)]),
            OCRBlock(kind: .paragraph, lines: [
                line("A线早班 128O件", 0.15, alt: ["A线早班 1280件"]),
                line("B线早班 960件", 0.20),
                line("□班 1105件", 0.25, conf: 0.3),
            ]),
            OCRBlock(kind: .listItem(marker: "•"), lines: [line("3号机换了刀", 0.32)]),
            OCRBlock(kind: .listItem(marker: "2."), lines: [line("冷却液快没了", 0.37)]),
        ])
        let d = DraftBuilder.build(page)
        XCTAssertEqual(d.markdown, "# 11月3日交接\nA线早班 128O件\nB线早班 960件\n□班 1105件\n- 3号机换了刀\n2. 冷却液快没了")
        XCTAssertEqual(d.unsureTexts, ["128O", "□班 1105件"])
    }

    func testWrappedProseJoins() {
        let page = OCRPage(blocks: [
            OCRBlock(kind: .title, lines: [line("通知", 0.02)]),
            OCRBlock(kind: .paragraph, lines: [
                line("明天上午八点在二楼会议室开安全生产", 0.1, wraps: true),
                line("会议，请各车间主任准时参加。", 0.14, wraps: false),
            ]),
            OCRBlock(kind: .paragraph, lines: [line("行政部", 0.3)], centered: true),
        ])
        let d = DraftBuilder.build(page)
        XCTAssertEqual(d.markdown, "# 通知\n明天上午八点在二楼会议室开安全生产会议，请各车间主任准时参加。\n<center>行政部</center>")
        XCTAssertEqual(d.unsure, [])
    }

    func testListLinesNotDuplicated() {
        let item = line("螺丝 200个", 0.2)
        let page = OCRPage(blocks: [
            OCRBlock(kind: .paragraph, lines: [line("采购清单", 0.05), item]),
            OCRBlock(kind: .listItem(marker: "1."), lines: [item]),
        ])
        XCTAssertEqual(DraftBuilder.build(page).markdown, "# 采购清单\n1. 螺丝 200个")
    }

    func testEnglishWordsGetSpaces() {
        let page = OCRPage(blocks: [OCRBlock(kind: .paragraph, lines: [
            line("Meeting moved to Friday because the", 0.1, wraps: true),
            line("room is booked.", 0.14, wraps: false),
        ])])
        XCTAssertEqual(DraftBuilder.build(page).markdown, "Meeting moved to Friday because the room is booked.")
    }

    func testTidyShiftsUnsure() {
        let md = "\n\n# 标题  \n\n\n\nA线 128O件"
        let at = md.u16 - "128O件".u16
        let x = IntakeFormatter.tidy(Intake(kind: .photo, markdown: md, unsure: [NSRange(location: at, length: 4)]))
        XCTAssertEqual(x.markdown, "# 标题\n\nA线 128O件")
        XCTAssertEqual(x.unsure.map { x.markdown.sub16($0) }, ["128O"])
        XCTAssertEqual(RangeCodec.decode(RangeCodec.encode(x.unsure)), x.unsure)
    }

    func testMarkerAlreadyInText() {
        let page = OCRPage(blocks: [
            OCRBlock(kind: .paragraph, lines: [line("11月18日产量", 0.02)]),
            OCRBlock(kind: .listItem(marker: "A"), lines: [line("A线早班1,280件", 0.1)]),
            OCRBlock(kind: .listItem(marker: "B"), lines: [line("B线早班960件", 0.15)]),
            OCRBlock(kind: .listItem(marker: "1."), lines: [line("1.螺丝200个", 0.2)]),
            OCRBlock(kind: .listItem(marker: "•"), lines: [line("• 牛奶", 0.25)]),
        ])
        XCTAssertEqual(DraftBuilder.build(page).markdown, "# 11月18日产量\nA线早班1,280件\nB线早班960件\n1.螺丝200个\n- 牛奶")
    }

    func testCheckboxesBecomeList() {
        let page = OCRPage(blocks: [
            OCRBlock(kind: .paragraph, lines: [line("周末采购", 0.02)]),
            OCRBlock(kind: .paragraph, lines: [
                line("口牛奶2盒", 0.1, alt: ["口牛奶3盒"]),
                line("口鸡蛋1盒", 0.15),
                line("口洗衣液 1瓶", 0.2),
            ]),
        ])
        let d = DraftBuilder.build(page)
        XCTAssertEqual(d.markdown, "# 周末采购\n- 牛奶2盒\n- 鸡蛋1盒\n- 洗衣液 1瓶")
        XCTAssertEqual(d.unsureTexts, ["2"])
    }

    func testIdsAndDatesAreNotNumbers() {
        XCTAssertNil(Structure.asPair("Morning shift done, new blade on #3"))
        XCTAssertNil(Structure.asPair("Shift report, Nov 18"))
        XCTAssertNil(Structure.asPair("换刀 第3"))
        XCTAssertNotNil(Structure.asPair("A线 1280件"))
        XCTAssertNotNil(Structure.asPair("Line A 1,280 pcs"))
        XCTAssertEqual(Structure.parse("Shift report, Nov 18\nLine A 1,280 pcs\nLine B 960 pcs").titleText, "Shift report, Nov 18")
    }
}

