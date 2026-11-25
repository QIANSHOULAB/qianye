import XCTest

/// 157：顶栏「听力」一点直接进；有没听过的新稿子时右上角有小点，放过以后没了；工具箱里不再有听力、小书童，剩下 4 格照旧
final class TopBarTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "list", "-YiyeLang", "en", "-YiyeAppearance", "light",
                             "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
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

    private var listen: XCUIElement { app.buttons["bar.listen"].firstMatch }

    /// 等某个控件的 value 变成 v（直接轮询）
    private func value(_ e: XCUIElement, _ v: String, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if e.exists, (e.value as? String ?? "") == v { return true }
            usleep(300_000)
        } while Date() < end
        return false
    }

    func testListenButtonOpensAndDotGoesAfterHearing() {
        launch(["-YiyeOneUnheard", "YES"])
        check(listen.waitForExistence(timeout: 8), "157-1-顶栏没有听力", "主页顶栏找不到「听力」")
        check(value(listen, "New ones to hear", 3), "157-2-没有小点", "有没听过的稿子，「听力」应该带小点：\(listen.value ?? "-")")
        shot("157-1-顶栏有小点")
        listen.tap()
        let show = app.buttons.matching(NSPredicate(format: "label == %@", "Show text")).firstMatch
        check(show.waitForExistence(timeout: 6), "157-3-没进听力", "点顶栏「听力」没进听力页")
        app.buttons.matching(NSPredicate(format: "label == %@", "1×")).element(boundBy: 0).tap()
        app.buttons["1.25×"].tap()
        let first = app.buttons["listen.row.Bitcoin falls below $62,000"].firstMatch
        check(first.waitForExistence(timeout: 4), "157-4-没有那篇", "听力里找不到没听过的那篇")
        first.tap()
        check(value(first, "playing", 4), "157-5-没放", "点了那篇没放")
        check(value(first, "", 40), "157-6-没放完", "那篇 1 遍、1.25 倍，40 秒还没放完")
        app.buttons["Close"].firstMatch.tap()
        check(value(listen, "", 6), "157-7-听完小点没走", "放完了，「听力」的小点应该没了：\(listen.value ?? "-")")
        shot("157-2-听完没小点")
    }

    func testToolboxLostListenAndScribe() {
        launch()
        let box = app.buttons["Toolbox"].firstMatch
        check(box.waitForExistence(timeout: 8), "157-8-没有工具箱", "顶栏找不到工具箱")
        box.tap()
        check(app.buttons["tool.settings"].waitForExistence(timeout: 3), "157-9-工具箱没开", "工具箱没打开")
        check(!app.buttons["tool.listen"].exists && !app.buttons["tool.shutong"].exists, "157-10-箱子里还有", "工具箱里不该再有听力、小书童")
        for t in ["companion", "deep", "dove", "settings"] {
            check(app.buttons["tool.\(t)"].exists, "157-11-少了\(t)", "工具箱里应该还有 \(t)")
        }
        shot("157-3-工具箱")
        app.buttons["tool.settings"].tap()
        check(app.navigationBars.firstMatch.waitForExistence(timeout: 4) || app.staticTexts["Settings"].waitForExistence(timeout: 4),
              "157-12-设置点不开", "工具箱里点设置没打开")
    }
}
