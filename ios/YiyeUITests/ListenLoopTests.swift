import XCTest

/// 144：听力 🔁 挑哪几天。开 🔁 → 点亮前天、点灭今天 → 放完前天最后一篇回前天第一篇，不进别的天。
/// Demo：今天两篇（有声）、昨天一篇、前天两篇短的（London、Tokyo，各 9 秒的静音）。
final class ListenLoopTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "listen", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    /// 那天的「yyyy-MM-dd」（手机时区），daysAgo 天前
    private func key(_ daysAgo: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 等某个控件的 value 变成 v
    private func waitValue(_ e: XCUIElement, _ v: String, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", v), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    /// 列表滑到看得见这个控件（up：往上翻）
    private func reveal(_ e: XCUIElement, up: Bool) {
        let list = app.scrollViews.firstMatch
        for _ in 0..<5 {
            if e.exists && e.isHittable { return }
            if up { list.swipeDown() } else { list.swipeUp() }
        }
    }

    func testLoopOnlyPickedDay() {
        launch()
        let loop = app.buttons["Loop the whole list"]
        check(loop.waitForExistence(timeout: 8), "144-01-没有🔁", "听力底下找不到 🔁")
        let d0 = app.buttons["listen.loop.\(key(0))"]
        let d2 = app.buttons["listen.loop.\(key(2))"]
        check(!d0.exists, "144-02-关着有小圈", "🔁 关着时标题上不该多东西")

        loop.tap()
        check(d0.waitForExistence(timeout: 3), "144-03-开了没小圈", "开 🔁 以后「Today」旁边没小圈")
        check(app.buttons["listen.loopEvery"].exists, "144-04-没有全部", "第一个标题旁边没有「All」")
        check(d0.value as? String == "on", "144-05-默认没亮今天", "默认应该只亮今天：\(String(describing: d0.value))")

        reveal(d2, up: false)
        check(d2.exists && d2.value as? String == "off", "144-06-前天不对", "前天应该是灭的")
        d2.tap()
        check(waitValue(d2, "on", 3), "144-07-前天点不亮", "点了前天的小圈没亮")
        reveal(d0, up: true)
        d0.tap()
        check(waitValue(d0, "off", 3), "144-08-今天点不灭", "点了今天的小圈没灭")

        // 每篇 1 遍、1.25 倍
        app.buttons.matching(NSPredicate(format: "label == %@", "1×")).element(boundBy: 0).tap()
        app.buttons["1.25×"].tap()

        let london = app.buttons["listen.row.Rain all week in London"]
        let tokyo = app.buttons["listen.row.Trains run late in Tokyo"]
        reveal(tokyo, up: false)
        check(tokyo.exists, "144-09-没有前天的稿子", "前天那两篇不在列表里")
        tokyo.tap()
        check(waitValue(tokyo, "playing", 3), "144-10-点了没放", "点前天最后一篇没放")

        // 下一篇：前天最后一篇 → 回前天第一篇（不进今天、昨天）
        app.buttons["Next"].tap()
        check(waitValue(london, "playing", 3), "144-11-下一篇跑出去了", "前天最后一篇按下一篇应该回前天第一篇")
        app.buttons["Next"].tap()
        check(waitValue(tokyo, "playing", 3), "144-12-下一篇不对", "London 下一篇应该是 Tokyo")

        // 自己放完（9 秒 ÷ 1.25）：回前天第一篇
        check(waitValue(london, "playing", 25), "144-13-放完没回那天第一篇", "Tokyo 放完应该回 London，不进别的天")
        shot("144-循环只在前天")
    }
}
