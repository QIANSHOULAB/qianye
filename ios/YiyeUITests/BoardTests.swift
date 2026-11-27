import XCTest

/// 234 看板：真点一遍（Demo：-YiyeScreen board-flow，列表停在「游戏」夹子）。
/// 1. 第 1 版建出「Game log」，8 秒后第 2 版原地换，还是一条
/// 2. 右滑扔掉：不寄 todo-done；下一版来了另建一条，回执 board-ok 寄出去了
/// 3. 点开：写字页底下有「大管家代笔」那行小字
final class BoardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "board-flow", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private func rows(_ part: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", part))
    }

    private var sent: String {
        let t = app.staticTexts["board.sent"]
        return t.exists ? t.label : ""
    }

    private func swipeAway(_ e: XCUIElement) {
        let from = e.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))        // 右滑八成松手 = 扔（160）
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: e.frame.width * 0.8, dy: 0)), withVelocity: .slow,
                   thenHoldForDuration: 0.2)
    }

    func testBoardUpdatesInPlaceRebuildsAfterTrashAndSaysSo() {
        launch()
        check(rows("Game log").firstMatch.waitForExistence(timeout: 15), "234-01-看板没出现", "寄来的「Game log」不在列表里")
        let v2 = rows("12 h 30 min").firstMatch
        check(v2.waitForExistence(timeout: 25), "234-02-没有原地更新", "第 2 版没换进那条")
        check(rows("Game log").count == 1, "234-03-多建了一条", "同一个看板应当只有一条（\(rows("Game log").count)）")
        shot("234-游戏记录-原地更新后")

        swipeAway(v2)
        if !v2.waitForNonExistence(timeout: 4), v2.exists { swipeAway(v2) }            // 慢模拟器上第一下偶尔滑不上
        check(v2.waitForNonExistence(timeout: 5), "234-04-右滑没扔掉", "右滑八成以后那条还在")
        let v3 = rows("13 h 30 min").firstMatch
        check(v3.waitForExistence(timeout: 12), "234-05-没重建", "扔了以后下一版没另建一条")
        check(rows("Game log").count == 1, "234-06-重建出了两条", "重建以后应当只有一条")
        check(!app.staticTexts["todo.sent"].exists, "234-07-当成待办了", "扔看板便签不该寄 todo-done")
        check(sent.contains("board-ok|board-game-log~3"), "234-08-没回执", "第 3 版没寄回执（\(sent)）")

        v3.tap()
        check(app.staticTexts["board.note"].firstMatch.waitForExistence(timeout: 8), "234-09-没有那行小字", "写字页底下没说这条是大管家写的")
        shot("234-游戏记录-写字页")
    }
}
