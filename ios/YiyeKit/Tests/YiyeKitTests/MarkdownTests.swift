import Foundation
import XCTest
@testable import YiyeKit

final class MarkdownTests: XCTestCase {
    func testParseFiveTricks() {
        let t = "# 标题\n## 二级\n### 三级\n- 列表\n> 引用\n<center>居中</center>\n有**粗体**的字\n![](附件/a.jpg)\n\n#不是标题"
        let ls = Markdown5.parse(t)
        XCTAssertEqual(ls.count, 10)
        XCTAssertEqual(ls[0].block, .heading(1))
        XCTAssertEqual(t.sub16(ls[0].markers[0]), "# ")
        XCTAssertEqual(t.sub16(ls[0].content), "标题")
        XCTAssertEqual(ls[1].block, .heading(2))
        XCTAssertEqual(ls[2].block, .heading(3))
        XCTAssertEqual(ls[3].block, .bullet)
        XCTAssertEqual(t.sub16(ls[3].content), "列表")
        XCTAssertEqual(ls[4].block, .quote)
        XCTAssertTrue(ls[5].centered)
        XCTAssertEqual(ls[5].markers.map { t.sub16($0) }, ["<center>", "</center>"])
        XCTAssertEqual(t.sub16(ls[5].content), "居中")
        XCTAssertEqual(ls[6].bold.map { t.sub16($0) }, ["粗体"])
        XCTAssertEqual(ls[6].markers.map { t.sub16($0) }, ["**", "**"])
        XCTAssertEqual(ls[7].block, .image("附件/a.jpg"))
        XCTAssertEqual(ls[8].block, .blank)
        XCTAssertEqual(ls[9].block, .plain)
    }

    func testCenterWithHeadingInside() {
        let l = Markdown5.parseLine("<center>## 通知</center>", at: 0)
        XCTAssertTrue(l.centered)
        XCTAssertEqual(l.block, .heading(2))
        XCTAssertEqual("<center>## 通知</center>".sub16(l.content), "通知")
    }

    func testBoldAtLineStartIsNotBullet() {
        let l = Markdown5.parseLine("**重要** 明天开会", at: 0)
        XCTAssertEqual(l.block, .plain)
        XCTAssertEqual(l.bold.count, 1)
    }

    func testHeadingCycles() {
        var text = "开会"
        var sel = NSRange(location: 1, length: 0)
        var seen: [String] = []
        for _ in 0..<4 {
            let e = Markdown5.apply(.heading, to: text, selection: sel)
            text = e.applied(to: text); sel = e.selection
            seen.append(text)
        }
        XCTAssertEqual(seen, ["# 开会", "## 开会", "### 开会", "开会"])
        XCTAssertEqual(sel.location, 1)   // 光标跟着字走
    }

    func testBulletToggleMultiline() {
        let text = "螺丝\n垫片\n胶带"
        let e = Markdown5.apply(.bullet, to: text, selection: NSRange(location: 0, length: text.u16))
        let t2 = e.applied(to: text)
        XCTAssertEqual(t2, "- 螺丝\n- 垫片\n- 胶带")
        let e2 = Markdown5.apply(.bullet, to: t2, selection: NSRange(location: 0, length: t2.u16))
        XCTAssertEqual(e2.applied(to: t2), text)
    }

    func testQuoteReplacesBullet() {
        let text = "- 一句话"
        let e = Markdown5.apply(.quote, to: text, selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(e.applied(to: text), "> 一句话")
    }

    func testCenterToggle() {
        let text = "第一行\n落款"
        let e = Markdown5.apply(.center, to: text, selection: NSRange(location: 5, length: 0))
        let t2 = e.applied(to: text)
        XCTAssertEqual(t2, "第一行\n<center>落款</center>")
        XCTAssertEqual(e.selection.location, "第一行\n<center>落".u16)
        let e2 = Markdown5.apply(.center, to: t2, selection: e.selection)
        XCTAssertEqual(e2.applied(to: t2), text)
    }

    func testBold() {
        let text = "今天很重要"
        let e = Markdown5.apply(.bold, to: text, selection: NSRange(location: 3, length: 2))
        let t2 = e.applied(to: text)
        XCTAssertEqual(t2, "今天很**重要**")
        XCTAssertEqual(t2.sub16(e.selection), "重要")
        let e2 = Markdown5.apply(.bold, to: t2, selection: e.selection)
        XCTAssertEqual(e2.applied(to: t2), text)
        let e3 = Markdown5.apply(.bold, to: text, selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(e3.applied(to: text), "今天很重要****")
        XCTAssertEqual(e3.selection.location, 7)
    }

    func testTitleSummary() {
        let t = "\n# 11月3日交接\n\nA线早班 **1280件**\n- 3号机换了刀\n![](附件/x.jpg)\n冷却液快没了"
        XCTAssertEqual(Markdown5.title(t), "11月3日交接")
        XCTAssertEqual(Markdown5.summary(t), "A线早班 1280件 3号机换了刀 冷却液快没了")
        XCTAssertEqual(Markdown5.imagePaths(t), ["附件/x.jpg"])
    }

    func testDisplayMapRoundTrip() {
        let md = "前面\n![](附件/a.jpg)\n后面**粗**\n![](附件/b.jpg)"
        let m = DisplayMap(markdown: md)
        XCTAssertEqual(m.display, "前面\n\u{FFFC}\n后面**粗**\n\u{FFFC}")
        XCTAssertEqual(m.images.map(\.path), ["附件/a.jpg", "附件/b.jpg"])
        let paths = Dictionary(uniqueKeysWithValues: m.images.map { ($0.display.location, $0.path) })
        XCTAssertEqual(markdownFromDisplay(m.display, paths: paths), md)
        // 「后面」在两边的位置
        let mdR = NSRange(location: md.u16 - "后面**粗**\n![](附件/b.jpg)".u16, length: 2)
        let dR = m.toDisplay(mdR)
        XCTAssertEqual(m.display.sub16(dR), "后面")
        XCTAssertEqual(m.toMarkdown(dR), mdR)
    }

    func testAttachmentGetsOwnLine() {
        let display = "字\u{FFFC}字"
        XCTAssertEqual(markdownFromDisplay(display, paths: [1: "附件/c.jpg"]), "字\n![](附件/c.jpg)\n字")
    }
}
