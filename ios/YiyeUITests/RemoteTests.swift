import XCTest

/// 172 遥控：模拟器里假大管家（Demo）回一张画出来的屏。真点一下、长按一下，看得到寄出去的坐标；
/// 密码开关开着：框里只显示点点，寄出去的只写「pass」，不带密码；关着：打的字照寄
final class RemoteTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "remote", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private var sent: XCUIElement { app.staticTexts["remote.sent"].firstMatch }

    /// 等「寄出去的」那一行变成以 prefix 打头的字（轮询：CI 模拟器慢）
    private func sentStarts(_ prefix: String, _ timeout: TimeInterval = 8) -> String? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if sent.exists, sent.label.hasPrefix(prefix) { return sent.label }
            usleep(300_000)
        } while Date() < end
        return nil
    }

    func testTapPressAndPassword() {
        launch()
        let desk = app.buttons["remote.pick.desk"].firstMatch
        check(desk.waitForExistence(timeout: 10), "172-01-没有选电脑", "遥控页没有「电脑」那一格")
        desk.tap()

        let screen = app.descendants(matching: .any)["remote.screen"].firstMatch
        check(screen.waitForExistence(timeout: 8), "172-02-没有截图", "选了电脑以后没出截图")

        // 点正中间：寄出去 tap 0.50 0.50（允许差一点）
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let tap = sentStarts("tap ")
        check(tap != nil, "172-03-点了没寄", "点了截图，寄出去的不是 tap：\(sent.exists ? sent.label : "（没有那一行）")")
        if let tap {
            let n = tap.split(separator: " ").compactMap { Double($0) }
            check(n.count == 2 && abs(n[0] - 0.5) < 0.03 && abs(n[1] - 0.5) < 0.03, "172-04-坐标不对", "点正中间寄出去的是 \(tap)")
        }

        // 点左上四分之一处
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
        let q = sentStarts("tap 0.2")
        check(q != nil, "172-05-第二下坐标不对", "点四分之一处寄出去的是 \(sent.label)")

        // 长按 = 右键
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        check(sentStarts("right ") != nil, "172-06-长按不是右键", "长按寄出去的是 \(sent.label)")

        // 打字（密码开关关着）
        let input = app.textFields["remote.input"].firstMatch
        check(input.waitForExistence(timeout: 5), "172-07-没有输入框", "底下没有打字的框")
        input.tap()
        input.typeText("hello")
        app.buttons["remote.send"].firstMatch.tap()
        check(sentStarts("type hello") != nil, "172-08-打字没寄", "寄出去的是 \(sent.label)")

        // 密码：开关开着框里只显示点点；寄出去只写 pass，不带密码
        app.buttons["remote.passToggle"].firstMatch.tap()
        let secure = app.secureTextFields["remote.input.secure"].firstMatch
        check(secure.waitForExistence(timeout: 5), "172-09-密码框没换上", "开了密码开关，框没变成点点的")
        secure.tap()
        secure.typeText("FakePw172")
        let shown = (secure.value as? String) ?? ""
        check(!shown.contains("FakePw"), "172-10-密码露出来了", "密码框里显示的是 \(shown)")
        app.buttons["remote.send"].firstMatch.tap()
        let p = sentStarts("pass")
        check(p == "pass", "172-11-密码没寄或带出来了", "寄出去的是 \(sent.label)")
        check(app.textFields["remote.input"].waitForExistence(timeout: 3), "172-12-发完没回到普通框", "发完密码，开关该自己关上")
        shot("172-遥控")

        // 结束：回到选机器
        app.buttons["remote.end"].firstMatch.tap()
        check(desk.waitForExistence(timeout: 5), "172-13-结束没回到选机器", "点了结束没回到选电脑 / 掌机")
    }
}
