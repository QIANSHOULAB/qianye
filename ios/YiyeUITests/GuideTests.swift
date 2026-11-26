import XCTest

/// 197 遥控带路：模拟器里假大管家（Demo）寄一张带路卡 → 点「去点」是遥控画面、上面有圈 → 圈里点一下寄的是双击（带号）→
/// 假大管家回「点上了」，圈没了。遥控连点两下 = 双击
final class GuideTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", "zh-Hans", "-YiyeAppearance", "light",
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

    private var sent: XCUIElement { app.staticTexts["remote.sent"].firstMatch }

    private func sentStarts(_ prefix: String, _ timeout: TimeInterval = 10) -> String? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if sent.exists, sent.label.hasPrefix(prefix) { return sent.label }
            usleep(300_000)
        } while Date() < end
        return nil
    }

    func testGuideCardOpensCircleTapAndDone() {
        launch("guide")
        let go = app.buttons["shutong.guideGo"].firstMatch
        check(go.waitForExistence(timeout: 15), "197-01-没有带路卡", "小书童里没有「去点」")
        shot("197-带路卡")
        go.tap()
        let screen = app.descendants(matching: .any)["remote.screen"].firstMatch
        check(screen.waitForExistence(timeout: 10), "197-02-没开遥控", "点了「去点」没出那台的截图")
        let ring = app.descendants(matching: .any)["remote.circle"].firstMatch
        check(ring.waitForExistence(timeout: 5), "197-03-没有圈", "截图上没画圈")
        check(app.staticTexts["remote.guideText"].firstMatch.exists, "197-04-没有那句话", "截图上面没有大管家那句话")
        shot("197-遥控带圈")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 1135.0 / 1280, dy: 95.0 / 800)).tap()
        let s = sentStarts("double ")
        check(s != nil && s!.hasSuffix(" g"), "197-05-圈里点一下没按双击寄", "寄出去的是 \(sent.exists ? sent.label : "（没有）")")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: ring)
        check(XCTWaiter().wait(for: [gone], timeout: 10) == .completed, "197-06-点上了圈还在", "大管家回「点上了」以后圈没收")
        shot("197-点上了")
        app.buttons["remote.done"].firstMatch.tap()
        check(app.staticTexts["shutong.guideState"].firstMatch.waitForExistence(timeout: 8), "197-07-卡没变", "回小书童卡片还是「去点」")
        shot("197-卡片点上了")
    }

    func testRemoteDoubleTap() {
        launch("remote")
        let desk = app.buttons["remote.pick.desk"].firstMatch
        check(desk.waitForExistence(timeout: 10), "197-11-没有选电脑", "遥控页没有「电脑」那一格")
        desk.tap()
        let screen = app.descendants(matching: .any)["remote.screen"].firstMatch
        check(screen.waitForExistence(timeout: 8), "197-12-没有截图", "选了电脑以后没出截图")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let s = sentStarts("double ")
        check(s != nil && !s!.hasSuffix(" g"), "197-13-连点两下不是双击", "寄出去的是 \(sent.exists ? sent.label : "（没有）")")
    }
}
