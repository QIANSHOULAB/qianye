import XCTest

/// 222：听力原文页。点一下一个词出卡片、点两下整句、点卡片外收起、「跟着放」开关、翻不了说为什么。
/// Demo 里翻译是假的（模拟器里系统翻译不能用）：Bitcoin → 比特币。
final class ListenTextTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "listen-text", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private func waitValue(_ e: XCUIElement, _ v: String, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", v), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    private func waitGone(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    /// 第二句「Bitcoin fell below 62,000 dollars on Monday.」开头那个词上的一点
    private func firstWord() -> XCUICoordinate {
        let line = app.textViews["listen.line.1"]
        check(line.waitForExistence(timeout: 10), "222-00-没有原文", "原文页里找不到第二句")
        return line.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 17))
    }

    private var word: XCUIElement { app.staticTexts["listen.card.word"] }
    private var meaning: XCUIElement { app.staticTexts["listen.card.meaning"] }
    private var play: XCUIElement { app.buttons["listen.card.play"] }

    func testTapWordThenClose() {
        launch()
        firstWord().tap()
        check(word.waitForExistence(timeout: 5), "222-01-点词没卡片", "点一下词应该弹卡片")
        check(word.label == "Bitcoin", "222-02-词不对", "点开头应该选中 Bitcoin：\(word.label)")
        check(meaning.waitForExistence(timeout: 5) && meaning.label == "比特币", "222-03-没意思", "卡片上应该有中文意思")
        let hard = app.buttons["listen.card.hard"], known = app.buttons["listen.card.known"]
        check(hard.exists && known.exists && play.exists, "222-04-按钮不齐", "卡片上要有难词、已掌握、从这句放")
        check(!app.buttons["listen.card.loop"].exists, "222-05-词卡多了循环", "单句循环只在整句的卡片上")
        shot("222-词卡")
        known.tap()
        check(waitValue(known, "on", 5), "222-06-点了没记", "点「已掌握」应该打勾")
        // 点卡片外面（标题）：收起
        app.staticTexts["listen.sheetTitle"].tap()
        check(waitGone(word, 5), "222-07-收不起", "点卡片外面应该收起")
        // 点词不跳句，「从这句放」才跳；点了卡片收起
        firstWord().tap()
        check(play.waitForExistence(timeout: 5), "222-08-再点没卡片", "再点词应该又弹卡片")
        play.tap()
        check(waitGone(word, 5), "222-09-放了没收", "点「从这句放」卡片应该收起")
    }

    func testDoubleTapSentence() {
        launch()
        firstWord().doubleTap()
        let loop = app.buttons["listen.card.loop"]
        check(loop.waitForExistence(timeout: 5), "222-11-点两下没句卡", "点两下应该弹整句的卡片")
        check(!word.exists, "222-12-还是词卡", "整句的卡片上不该只有一个词")
        check(meaning.waitForExistence(timeout: 5) && meaning.label.hasPrefix("周一"), "222-13-没整句意思", "应该给整句的中文意思：\(meaning.exists ? meaning.label : "-")")
        check(play.exists, "222-14-没有从这句放", "整句的卡片要有「从这句放」")
        check(!app.menuItems["Hard word"].exists, "222-15-系统菜单冒出来", "点两下不该弹系统选词菜单")
        shot("222-句卡")
        loop.tap()
        check(waitValue(loop, "on", 5), "222-16-循环没开", "点「单句循环」应该亮着")
        loop.tap()
        check(waitValue(loop, "off", 5), "222-17-循环关不掉", "再点一下应该解开")
        play.tap()
        check(waitGone(loop, 5), "222-18-放了没收", "点「从这句放」卡片应该收起")
    }

    func testFollowSwitch() {
        launch()
        let follow = app.buttons["listen.follow"]
        check(follow.waitForExistence(timeout: 10), "222-21-没有开关", "底下那排没有「跟着放」")
        check(follow.value as? String == "on", "222-22-默认没开", "「跟着放」默认开着")
        follow.tap()
        check(waitValue(follow, "off", 5), "222-23-关不掉", "点一下应该关掉")
        shot("222-跟着放关了")
        follow.tap()
        check(waitValue(follow, "on", 5), "222-24-开不回来", "再点一下应该开回来")
    }

    func testNoLanguagePack() {
        launch(["-YiyeNoTranslate", "YES"])
        firstWord().tap()
        let note = app.staticTexts["listen.card.note"]
        check(note.waitForExistence(timeout: 5), "222-31-没说为什么", "翻不了应该在卡片里说为什么")
        check(note.label.contains("language pack"), "222-32-原因不对", "应该说语言包没下：\(note.label)")
        check(app.buttons["listen.card.retry"].exists, "222-33-没有再翻一次", "应该给「再翻一次」")
        check(app.buttons["listen.card.known"].exists, "222-34-按钮没了", "翻不了也能标词")
        shot("222-翻不了")
    }
}
