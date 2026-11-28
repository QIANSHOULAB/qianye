import XCTest
@testable import YiyeKit

/// 256 新建机器人、新建群的规矩
final class Bots256Tests: XCTestCase {
    func testCleanName() {
        XCTAssertEqual(BotNew.cleanName(" 254 测@试＠机二 "), "254测试机二")
        XCTAssertEqual(BotNew.cleanName("老　厨子：#1,<a>、"), "老厨子1a")
        XCTAssertEqual(BotNew.cleanName("@ @"), "")
    }

    func testNameProblem() {
        let taken = ["小书童", "Chef"]
        XCTAssertNil(BotNew.nameProblem("", taken: taken))
        XCTAssertNil(BotNew.nameProblem("  ", taken: taken))
        XCTAssertEqual(BotNew.nameProblem("@ @", taken: taken), .nameEmpty)
        XCTAssertEqual(BotNew.nameProblem("ch ef", taken: taken), .nameTaken("chef"))
        XCTAssertEqual(BotNew.nameProblem("小书童", taken: taken), .nameTaken("小书童"))
        XCTAssertNil(BotNew.nameProblem(String(repeating: "字", count: 20), taken: taken))
        XCTAssertNil(BotNew.nameProblem(String(repeating: "字 ", count: 20), taken: taken))
        XCTAssertEqual(BotNew.nameProblem(String(repeating: "字", count: 22), taken: taken), .nameTooLong(22))
    }

    func testFirstSentence() {
        XCTAssertEqual(BotNew.firstSentence("嘴碎，热心。以前开过饭馆。"), "嘴碎，热心")
        XCTAssertEqual(BotNew.firstSentence("  Cheerful. Makes tea."), "Cheerful")
        XCTAssertEqual(BotNew.firstSentence("脾气好\n规矩：不说废话"), "脾气好")
        XCTAssertEqual(BotNew.firstSentence("Version 3.5 fan! Loud."), "Version 3.5 fan")
        XCTAssertEqual(BotNew.firstSentence("。。管账的？"), "管账的")
        XCTAssertEqual(BotNew.firstSentence("管账.不管饭"), "管账")
        XCTAssertEqual(BotNew.firstSentence("没有标点"), "没有标点")
        XCTAssertEqual(BotNew.firstSentence("！！"), "！！")
        XCTAssertEqual(BotNew.firstSentence(String(repeating: "长", count: 300)).count, 200)
    }

    func testBotDraft() {
        var d = BotDraft()
        XCTAssertFalse(d.dirty)
        XCTAssertEqual(d.missing, [.name, .persona])
        XCTAssertFalse(d.ready(taken: []))
        d.name = "Pip"
        XCTAssertTrue(d.dirty)
        XCTAssertEqual(d.missing, [.persona])
        d.persona = " Cheerful. Makes tea. "
        XCTAssertEqual(d.missing, [])
        XCTAssertTrue(d.ready(taken: []))
        XCTAssertFalse(d.ready(taken: ["pip"]))
        XCTAssertEqual(d.sentDesc, "Cheerful")
        XCTAssertEqual(d.sentPersona, "Cheerful. Makes tea.")
        d.desc = " 管做饭 "
        XCTAssertEqual(d.sentDesc, "管做饭")
    }

    func testGroupDraft() {
        var g = BotGroupDraft()
        XCTAssertFalse(g.dirty)
        XCTAssertEqual(g.short, 2)
        g.members = ["a"]
        XCTAssertTrue(g.dirty)
        XCTAssertEqual(g.short, 1)
        g.members = ["a", "b"]
        XCTAssertFalse(g.ready)
        g.name = "  晚饭   群 "
        XCTAssertEqual(g.sentName, "晚饭 群")
        XCTAssertTrue(g.ready)
        g.name = String(repeating: "群", count: 21)
        XCTAssertEqual(g.nameTooLong, 21)
        XCTAssertFalse(g.ready)
    }
}
