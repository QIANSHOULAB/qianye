import XCTest

/// 136 书童：真点一遍。用的是 Demo 那套假便签和假大脑（只在内存里，大脑 0.6 秒回一串写好的动作）。
/// 1. 主页顶栏点书童 → 打字发一句 → 回执出来 → 列表里标题真改了 → 再开书童点「撤销这一批」→ 改的标题没了
/// 2. 新录的语音便签（等着收拾的）→ 自己被收拾、起了标题 → 写字页顶栏「原话」在 → 点开看得到原样 → 一键换回原话
final class ShutongTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", "en", "-YiyeAppearance", "light",
                             "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        a.launch()
        app = a
    }

    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["YIYE_UITEST_SHOTS"], !dir.isEmpty {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func check(_ ok: Bool, _ name: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        if !ok { shot(name) }
        XCTAssertTrue(ok, "\(name)：\(why)", file: file, line: line)
    }

    private func containing(_ q: XCUIElementQuery, _ text: String) -> XCUIElement {
        q.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // ---------------------------------------------------------------- 1. 聊天窗：发一句、回执、撤销
    func testChatReceiptThenUndo() {
        launch("list")
        let open = app.buttons["Scribe"].firstMatch
        check(open.waitForExistence(timeout: 8), "S1-没有书童按钮", "主页顶栏找不到「Scribe」")
        open.tap()

        let field = app.descendants(matching: .any)["shutong.input"].firstMatch
        check(field.waitForExistence(timeout: 5), "S1-没有输入框", "书童聊天窗没升起来")
        field.tap()
        field.typeText("Put the machine stuff together")
        app.buttons["Send"].firstMatch.tap()

        let undo = app.buttons["Undo this batch"].firstMatch
        check(undo.waitForExistence(timeout: 8), "S1-没有回执", "发了一句，假大脑回了动作，聊天窗里没出「Undo this batch」")
        check(containing(app.staticTexts, "into “Machines”").exists, "S1-回执不对", "回执里没写挪进了「Machines」")
        check(containing(app.staticTexts, "Skipped 1").exists, "S1-受保护的动了", "置顶又换过纸色的那条该没动（Skipped 1）")
        shot("S1-回执")

        app.buttons["Done"].firstMatch.tap()
        // 改过的便签「改的时间」是真的现在，Demo 的便签是今天 9:41 往前排：CI 的钟早于 9:41 时它排到屏幕外。搜出来再看
        let search = app.textFields["Search"]
        check(search.waitForExistence(timeout: 5), "S1-搜索框", "找不到搜索框")
        search.tap()
        search.typeText("Lunch with")
        let renamed = containing(app.buttons, "Lunch with the team")
        check(renamed.waitForExistence(timeout: 5), "S1-标题没改", "搜「Lunch with」搜不到书童起的标题「Lunch with the team」")

        open.tap()
        check(undo.waitForExistence(timeout: 5), "S1-再开没有撤销", "再开书童，回执上的「Undo this batch」不见了")
        undo.tap()
        check(containing(app.staticTexts, "Undone").waitForExistence(timeout: 4), "S1-撤销没反应", "点了撤销，回执上没写「Undone」")
        app.buttons["Done"].firstMatch.tap()
        check(renamed.waitForNonExistence(timeout: 5), "S1-撤销没回去", "撤销以后列表里还有「Lunch with the team」")
    }

    // ---------------------------------------------------------------- 2. 新语音便签自己收拾，原话在
    func testNewVoiceNoteTidiedWithOriginalWords() {
        launch("shutong-auto")
        let search = app.textFields["Search"]
        check(search.waitForExistence(timeout: 8), "S2-搜索框", "找不到搜索框")
        let row = containing(app.buttons, "Coolant and the new blade")
        var found = false
        for _ in 0..<4 where !found {                       // 书童 5 秒看一次：搜不到就清了再搜
            search.tap()
            if let v = search.value as? String, !v.isEmpty, v != "Search" {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count))
            }
            search.typeText("Coolant and the new")
            found = row.waitForExistence(timeout: 5)
        }
        check(found, "S2-没收拾", "新录的语音便签没被收拾成「Coolant and the new blade」")
        row.tap()

        let text = app.textViews.firstMatch
        check(text.waitForExistence(timeout: 6), "S2-没进写字页", "点了没进写字页")
        let v = text.value as? String ?? ""
        check(v.contains("Line B is low on coolant") && !v.contains("Um so"), "S2-正文不对", "正文该是收拾好的，实际开头「\(v.prefix(60))」")

        let orig = app.buttons["Original words"].firstMatch
        check(orig.waitForExistence(timeout: 5), "S2-没有原话按钮", "顶栏没有「Original words」")
        orig.tap()
        check(containing(app.staticTexts, "Um so, line B").waitForExistence(timeout: 4), "S2-原话不对", "原话那块里没有原样的话")
        shot("S2-原话")

        let back = app.buttons["Use original words"].firstMatch
        check(back.waitForExistence(timeout: 3), "S2-没有换回", "原话那块没有「Use original words」")
        back.tap()
        let v2 = text.value as? String ?? ""
        check(v2.contains("Um so, line B"), "S2-没换回", "点了换回原话，正文开头是「\(v2.prefix(60))」")
    }
}
