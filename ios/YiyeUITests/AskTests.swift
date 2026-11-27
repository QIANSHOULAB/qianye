import XCTest

/// 203 在外面点确认：模拟器里假大管家寄一张要他点头的卡 → 小书童里两个按钮 → 点「同意」（另一回点「不同意」）→
/// 卡写成同意了 / 没同意，按钮收了
final class AskTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "askok", "-YiyeLang", "zh-Hans", "-YiyeAppearance", "light",
                             "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
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

    private func tapAndSee(_ button: String, _ words: String, _ tag: String) {
        launch()
        let yes = app.buttons["shutong.askYes"].firstMatch
        check(yes.waitForExistence(timeout: 15), "203-\(tag)1-没有卡", "小书童里没有「同意」")
        check(app.buttons["shutong.askNo"].firstMatch.exists, "203-\(tag)2-没有不同意", "少了「不同意」")
        check(app.descendants(matching: .any)["shutong.askDetail"].firstMatch.exists, "203-\(tag)3-没写做什么", "卡上没有那件事")
        shot("203-\(tag)卡")
        app.buttons[button].firstMatch.tap()
        let state = app.staticTexts["shutong.askState"].firstMatch
        func said(_ timeout: TimeInterval) -> Bool {
            let e = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", words), object: state)
            return XCTWaiter().wait(for: [e], timeout: timeout) == .completed
        }
        // 222：CI 模拟器慢的时候 10 秒读不到（11-27 cd27893）；整套第一条（模拟器刚开机）那一下还会点丢（62c4b90，卡原样没动）：
        // 按钮还在才补点一下，再等 30 秒
        var done = said(15)
        if !done {
            if yes.exists { app.buttons[button].firstMatch.tap() }
            done = said(30)
        }
        check(done, "203-\(tag)4-卡没变", "点完应该写「\(words)」，现在是 \(state.exists ? state.label : "（没有）")")
        check(!yes.exists, "203-\(tag)5-按钮还在", "点过了按钮要收")
        shot("203-\(tag)点完")
    }

    func testAllow() {
        tapAndSee("shutong.askYes", "同意了，只放行这一回", "同意")
    }

    func testRefuse() {
        tapAndSee("shutong.askNo", "没同意", "不同意")
    }
}
