import XCTest

/// 204 Bark：从提醒点进来滚到那条来话 / 翻到项目待办；「提醒里显示内容」开关。
/// Demo：-YiyeScreen link-shutong / link-todo 装作点了提醒（走的就是 onOpenURL 那个入口 openLink），settings-bark 假大管家回话
final class BarkTests: XCTestCase {
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

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    func testLinkScrollsToTheMessage() {
        launch("link-shutong")
        let want = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "第 3 条来话")).firstMatch   // 气泡是只读的 UITextView
        check(want.waitForExistence(timeout: 20), "204-L1-没滚到", "30 条来话，链接指第 3 条，屏幕上没有它")
        check(want.isHittable, "204-L2-看不见", "第 3 条在，可是不在屏幕里")
        shot("204-链接进小书童")
    }

    func testLinkOpensTodos() {
        launch("link-todo")
        check(row("真机试新版").waitForExistence(timeout: 15), "204-T1-没有待办", "寄来的待办不在列表里")
        check(row("周末采购").waitForNonExistence(timeout: 15), "204-T2-没翻到项目待办", "点了 yiye://todo，别的文件夹的便签还在列表里")
        check(row("真机试新版").exists, "204-T3-待办没了", "翻过去以后看不到那条待办")
        shot("204-链接进项目待办")
    }

    func testSwitch() {
        launch("settings-bark")
        let toggle = app.switches["bark.toggle"].firstMatch
        check(toggle.waitForExistence(timeout: 15), "204-S1-没有开关", "设置里找不到「提醒里显示内容」")
        let steps = app.staticTexts["bark.steps"].firstMatch
        check(steps.waitForExistence(timeout: 5), "204-S2-没写步骤", "开着的时候要写在 Bark 里粘到哪")
        shot("204-开着")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        check(steps.waitForNonExistence(timeout: 8), "204-S3-关不掉", "关了开关，步骤还在")
        let off = app.staticTexts.matching(NSPredicate(format: "label == %@", "鸽子到了：提醒里不带内容了")).firstMatch
        check(off.waitForExistence(timeout: 8), "204-S4-没回话", "关了以后没看到大管家那句")
        shot("204-关了")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        check(steps.waitForExistence(timeout: 8), "204-S5-开不回来", "再开一次，步骤没回来")
    }
}
