import XCTest

/// 162 项目待办：真点一遍（Demo：-YiyeScreen todo 寄来两条待办，第二条 6 秒后「那边办完了」）。
/// 1. 两条都出现在列表里；第二条收到 todo-done 以后进了废纸篓（列表里没了）
/// 2. 右滑扔掉第一条：发出了 todo-done；点 Undo 放回：发出了 todo-undo（App 在 -YiyeDemo 下把寄的请求写在 todo.sent 那行）
final class TodoTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "todo", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    private var sent: String {
        let t = app.staticTexts["todo.sent"]
        return t.exists ? t.label : ""
    }

    private func waitSent(_ part: String, timeout: TimeInterval = 6) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if sent.contains(part) { return true }
            usleep(200_000)
        }
        return sent.contains(part)
    }

    func testTodoArrivesDoneTrashesSwipeTellsButler() {
        launch()
        let a = row("Try the new build")
        check(a.waitForExistence(timeout: 10), "T1-待办没出现", "寄来的「Try the new build」不在列表里")
        let b = row("Reply A or B")
        check(b.waitForExistence(timeout: 4), "T2-第二条没出现", "寄来的「Reply A or B」不在列表里")
        shot("T-两条待办")
        check(b.waitForNonExistence(timeout: 12), "T3-办完没进废纸篓", "收到 todo-done 以后「Reply A or B」还在列表里")
        check(!sent.contains("demo-2"), "T4-回声", "那边办完扔的，不该再回 todo-done（\(sent)）")

        // 右滑八成松手 = 扔（160）
        let from = a.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: a.frame.width * 0.8, dy: 0)), withVelocity: .slow,
                   thenHoldForDuration: 0.2)
        check(a.waitForNonExistence(timeout: 4), "T5-右滑没扔掉", "右滑八成以后「Try the new build」还在")
        check(waitSent("todo-done|demo-1"), "T6-没发 todo-done", "扔了待办，没看到发出 todo-done（\(sent)）")
        let undo = app.buttons["Undo"]
        check(undo.waitForExistence(timeout: 3), "T7-没有撤销", "扔了以后底下没出「Undo」")
        undo.tap()
        check(row("Try the new build").waitForExistence(timeout: 4), "T8-撤销没拿回来", "点了 Undo 这条没回来")
        check(waitSent("todo-undo|demo-1"), "T9-没发 todo-undo", "放回去了，没看到发出 todo-undo（\(sent)）")
    }
}
