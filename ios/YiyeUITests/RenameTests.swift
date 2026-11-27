import XCTest

/// 229：改名叫 one。看三处：手机桌面上的名字、设置页里自己叫自己、分享出来的图的落款（图上的字量不到，截图给人看）
final class RenameTests: XCTestCase {
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

    func testHomeScreenName() {
        launch("list")
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = board.icons["one"].firstMatch
        _ = icon.waitForExistence(timeout: 10)
        // 新装的图标不一定在第一页：往左翻几页找
        for _ in 0..<4 where !(icon.exists && icon.isHittable) { board.swipeLeft() }
        check(icon.exists && icon.isHittable, "229-1-桌面没找到", "桌面上应该有个叫 one 的图标")
        sleep(1)
        shot("229-桌面")
    }

    func testSettingsAndShareImage() {
        launch("settings")
        let mention = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "› one ›")).firstMatch
        check(app.staticTexts["设置"].firstMatch.waitForExistence(timeout: 15), "229-2-没进设置", "设置页没开")
        for _ in 0..<8 where !(mention.exists && mention.isHittable) { app.swipeUp() }
        check(mention.exists, "229-3-设置里没写 one", "设置里讲侧键那段应该叫它 one")
        let old = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "选一叶笺")).firstMatch
        check(!old.exists, "229-4-还有旧名字", "设置里还写着旧名字")
        shot("229-设置")
        app.terminate()

        launch("share-note")
        check(app.buttons["分享"].firstMatch.waitForExistence(timeout: 15), "229-5-没开分享", "分享成图那页没开")
        sleep(4)                                    // 三张图画完
        shot("229-分享图")
    }
}
