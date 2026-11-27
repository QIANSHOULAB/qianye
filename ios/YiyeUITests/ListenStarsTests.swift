import XCTest

/// 225：听力页「谁配的」和五颗星（打 1、2 星出「以后不用」和「撤回」）；点词、点句用大管家译好的，没有的走系统翻译并写明。
/// Demo：listen-rate 第一篇 Achird 配的、在放；listen-trans 打开第一篇原文，头两句有假的大管家译文。
final class ListenStarsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String, lang: String = "zh-Hans") {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", lang, "-YiyeAppearance", "light",
                             "-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "en" ? "en_US" : "zh_CN"]
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

    private func waitValue(_ e: XCUIElement, _ v: String, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", v), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    private func waitGone(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    private func bar(_ n: Int) -> XCUIElement { app.buttons["star.bar.\(n)"] }

    func testRateBanAndUndo() {
        launch("listen-rate")
        check(bar(1).waitForExistence(timeout: 15), "225-01-没有星", "播放条上没有「谁配的」那一行")
        check(app.staticTexts["star.bar.by"].label.contains("Achird"), "225-02-谁配的不对", "应该写 Achird 配的")
        check(bar(1).value as? String == "off" && bar(5).value as? String == "off", "225-03-没打过就亮着", "没打过分，星应该全空")
        shot("225-没打分")

        bar(4).tap()
        check(waitValue(bar(4), "on", 8), "225-05-点了没亮", "点第 4 颗应该亮 4 颗")
        check(bar(5).value as? String == "off", "225-06-亮多了", "第 5 颗应该空着")
        check(!app.staticTexts["star.bar.banned"].exists, "225-07-4星也拉黑", "4 星不该出「以后不用」")
        shot("225-4星")

        bar(1).tap()
        let banned = app.staticTexts["star.bar.banned"]
        check(banned.waitForExistence(timeout: 8), "225-08-没说以后不用", "打 1 星应该出「以后不用」")
        check(banned.label.contains("Achird"), "225-09-名字不对", "应该写以后不用 Achird：\(banned.label)")
        let undo = app.buttons["star.bar.undo"]
        check(undo.exists, "225-10-没有撤回", "打 1 星应该有「撤回」")
        shot("225-1星")

        undo.tap()
        check(waitGone(banned, 8), "225-11-撤不回", "点撤回以后「以后不用」应该没了")
        check(waitValue(bar(4), "on", 8) && bar(5).value as? String == "off", "225-12-没回到4星", "撤回应该回到原来的 4 星")
        shot("225-撤回")

        // 听完的那一行（昨天那篇）下面有小星星
        let row = app.buttons["star.row.1"]
        for _ in 0..<4 where !(row.exists && row.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        check(row.waitForExistence(timeout: 5), "225-13-听完的那篇没星", "听完的那一行下面应该有小星星")
        shot("225-列表小星星")
    }

    func testButlerMeaningAndSystemFallback() {
        launch("listen-trans")
        let second = app.textViews["listen.line.1"]
        check(second.waitForExistence(timeout: 15), "225-20-没有原文", "原文页里找不到第二句")
        let word = second.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 17))
        word.tap()
        let meaning = app.staticTexts["listen.card.meaning"]
        check(meaning.waitForExistence(timeout: 8) && meaning.label == "比特币（一种加密货币）", "225-21-不是大管家的词义",
              "点词应该出大管家译的：\(meaning.exists ? meaning.label : "-")")
        check(!app.staticTexts["listen.card.system"].exists, "225-22-写成系统翻译", "大管家译的不该写「系统翻译」")
        shot("225-词义")

        app.staticTexts["listen.sheetTitle"].tap()
        check(waitGone(meaning, 5), "225-23-收不起", "点卡片外面应该收起")
        word.doubleTap()
        check(meaning.waitForExistence(timeout: 8) && meaning.label.hasPrefix("大管家译"), "225-24-不是大管家的整句",
              "点两下应该出大管家译的整句：\(meaning.exists ? meaning.label : "-")")
        check(!app.staticTexts["listen.card.system"].exists, "225-25-写成系统翻译", "大管家译的整句不该写「系统翻译」")
        shot("225-整句")

        app.staticTexts["listen.sheetTitle"].tap()
        check(waitGone(meaning, 5), "225-26-收不起", "点卡片外面应该收起")
        // 第三句没有大管家的译文：系统翻译兜底，角上写明
        app.textViews["listen.line.2"].coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: 17)).tap()
        check(app.staticTexts["listen.card.system"].waitForExistence(timeout: 8), "225-27-没写系统翻译", "兜底的卡片角上应该写「系统翻译」")
        check(meaning.waitForExistence(timeout: 5) && meaning.label == "译：That", "225-28-兜底没翻", "应该走系统翻译：\(meaning.exists ? meaning.label : "-")")
        shot("225-系统翻译")
    }
}
