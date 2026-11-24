import XCTest

/// 133：列表上真点、真滑、真长按。以前 CI 只截图、不点，0.7.8 起便签点不开、左右滑没反应，一路绿灯没人发现。
/// 跑法：shots.sh 在截图前 `xcodebuild test -only-testing:YiyeUITests`，用的是 Demo 那套假便签（只在内存里）。
/// 出错那一刻截一张图：挂在结果包里，环境变量 YIYE_UITEST_SHOTS 给了目录就再存一份 png（CI 提交回 ios/shots/uitest/）。
final class ListGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String = "list") {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", "en", "-YiyeAppearance", "light",
                             "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        a.launch()
        app = a
    }

    // ---------------------------------------------------------------- 小工具

    /// 那一刻的模拟器截图
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

    /// 不对就截图、记一笔（continueAfterFailure = false，记完这条测试就停）
    private func check(_ ok: Bool, _ name: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        if !ok { shot(name) }
        XCTAssertTrue(ok, "\(name)：\(why)", file: file, line: line)
    }

    /// 一条纸条：整条是一个按钮，标签里带标题
    private func row(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let b = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        if b.waitForExistence(timeout: 8) { return b }
        let t = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        check(t.waitForExistence(timeout: 2), "00-找不到纸条", "列表里找不到「\(title)」", file: file, line: line)
        return t
    }

    private var editorText: XCUIElement { app.textViews.firstMatch }

    /// 进了写字页：正文那块（UITextView）出来了，里面是这条的字
    private func assertEditor(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = editorText.waitForExistence(timeout: 6)
        check(ok, name, "点了没进写字页", file: file, line: line)
        let v = editorText.value as? String ?? ""
        check(v.contains(text), name, "写字页里不是这条（要有「\(text)」，实际开头「\(v.prefix(40))」）", file: file, line: line)
    }

    private func selectedCount() -> Int? {
        let t = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " selected")).firstMatch
        guard t.waitForExistence(timeout: 3) else { return nil }
        return Int(t.label.split(separator: " ").first ?? "")
    }

    private func waitSelected(_ n: Int, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = app.staticTexts["\(n) selected"].waitForExistence(timeout: 3)
        var now = "没在批量选"
        if !ok, let c = selectedCount() { now = "\(c) selected" }
        check(ok, name, "顶上该是「\(n) selected」，实际：\(now)", file: file, line: line)
    }

    // ---------------------------------------------------------------- 点

    func testTapOpensNote() {
        launch()
        row("Tomorrow").tap()
        assertEditor("room two", "01-点一条没进写字页")
    }

    func testSearchThenTapOpensNote() {
        launch()
        let f = app.textFields["Search"]
        check(f.waitForExistence(timeout: 5), "02-搜索框", "找不到搜索框")
        f.tap()
        f.typeText("Reading")
        row("Reading list").tap()
        assertEditor("Chapter 3", "02-搜完点结果没进写字页")
    }

    // ---------------------------------------------------------------- 滑

    func testSwipeRightTrashesAndUndo() {
        launch()
        let r = row("Tomorrow")
        r.swipeRight()
        // 没整条滑过去：露出「Trash」再点
        let trash = app.buttons["Trash"]
        if r.exists, trash.waitForExistence(timeout: 1.5) { trash.tap() }
        check(r.waitForNonExistence(timeout: 4), "03-右滑没扔掉", "右滑以后这条还在列表里")
        let undo = app.buttons["Undo"]
        check(undo.waitForExistence(timeout: 3), "03-没有撤销", "扔了以后底下没出「Undo」")
        undo.tap()
        check(row("Tomorrow").waitForExistence(timeout: 4), "03-撤销没拿回来", "点了 Undo 这条没回来")
    }

    func testSwipeLeftPins() {
        launch()
        row("Tomorrow").swipeLeft()
        let pin = app.buttons["Pin"]
        check(pin.waitForExistence(timeout: 3), "04-左滑没露出置顶", "左滑以后没有「Pin」")
        check(app.buttons["Add to Listening"].exists, "04-左滑没有小耳机", "左滑以后没有「Add to Listening」")
        pin.tap()
        // 置顶了：再左滑一次，按钮变成「Unpin」
        row("Tomorrow").swipeLeft()
        check(app.buttons["Unpin"].waitForExistence(timeout: 3), "04-置顶没生效", "再左滑没变成「Unpin」")
    }

    // ---------------------------------------------------------------- 长按批量选

    func testLongPressSelectsAndTapToggles() {
        launch()
        row("Tomorrow").press(forDuration: 1.0)
        waitSelected(1, "05-长按没进批量选")
        check(!editorText.exists, "05-长按松手打开了便签", "长按松手不该进写字页")
        row("Weekly sync").tap()
        waitSelected(2, "05-批量选里点一条没选上")
        row("Weekly sync").tap()
        waitSelected(1, "05-批量选里再点没取消")
        row("Tomorrow").tap()
        waitSelected(0, "05-批量选里点按下那条没取消")
        app.buttons["Cancel"].tap()
        // 退出批量选，点一条照样进写字页
        row("Weekly sync").tap()
        assertEditor("Line A 1280", "05-退出批量选以后点不开")
    }

    func testLongPressThenDragSelectsRange() {
        launch()
        let from = row("Weekly sync")
        let to = row("Handover, Nov 3")
        from.press(forDuration: 0.8, thenDragTo: to)
        let n = selectedCount() ?? 0
        check(n >= 3, "06-长按往下划没选上一串", "从 Weekly sync 划到 Handover 该选上 3 条以上，实际 \(n)")
    }

    // ---------------------------------------------------------------- 沿左边那一条划选（135）
    // Demo 主页从上往下（CI 截图里看的）：Weekend groceries（置顶）、Weekly sync、An article being pulled、Tomorrow's sync、Handover, Nov 3……

    /// 一条纸条上的一个点：左边那一条（圆圈 / 小木钉）离纸条按钮左边 x 点；mid = true 就是纸条正中间
    private func spot(_ r: XCUIElement, x: CGFloat = 24, mid: Bool = false) -> XCUICoordinate {
        mid ? r.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            : r.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: x, dy: 0))
    }

    /// 按住（不到长按的 0.4 秒）慢慢划过去，停一下再松手
    private func sweep(_ from: XCUICoordinate, _ to: XCUICoordinate) {
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// 进批量选、一条都没选：长按 Handover 进去，再点它取消
    private func enterSelectingEmpty() {
        row("Handover, Nov 3").press(forDuration: 1.0)
        waitSelected(1, "08-长按没进批量选")
        row("Handover, Nov 3").tap()
        waitSelected(0, "08-点按下那条没取消")
    }

    func testSweepLeftStripSelectsRange() {
        launch()
        enterSelectingEmpty()
        sweep(spot(row("Weekend groceries")), spot(row("Tomorrow")))
        waitSelected(4, "08-左边那一条从第 1 条划到第 4 条没选上 4 条")
        check(!editorText.exists, "08-划完打开了便签", "划选松手不该进写字页")
    }

    func testSweepFromSelectedDeselects() {
        launch()
        enterSelectingEmpty()
        sweep(spot(row("Weekend groceries")), spot(row("Tomorrow")))
        waitSelected(4, "09-先划选 4 条没成")
        // 从已选的第 2 条起手往下划到第 4 条：这三条都取消，只剩第 1 条
        sweep(spot(row("Weekly sync")), spot(row("Tomorrow")))
        waitSelected(1, "09-从已选的那条往下划没取消")
    }

    func testSweepMiddleScrollsNotSelects() {
        launch()
        enterSelectingEmpty()
        sweep(spot(row("Weekend groceries"), mid: true), spot(row("Tomorrow"), mid: true))
        waitSelected(0, "10-纸条中间往下划选上了")
        check(!editorText.exists, "10-纸条中间划完打开了便签", "上下滚不该进写字页")
        // 还能点：点一条照样选上
        row("Weekly sync").tap()
        waitSelected(1, "10-划完以后点一条没选上")
    }

    func testLeftStripWhenNotSelecting() {
        launch()
        // 右滑：从左边那一条起手往右划，照样扔进废纸篓。
        // 撤销 testSwipeRightTrashesAndUndo 测过；这里 CI 模拟器慢，Undo 只亮 5 秒，等查到常常已经没了（11-25 第二轮），在就顺手点掉，不卡它
        let r = row("Handover, Nov 3")
        spot(r).press(forDuration: 0.05, thenDragTo: spot(r, x: 330), withVelocity: .fast, thenHoldForDuration: 0)
        let trash = app.buttons["Trash"]
        if r.exists, trash.waitForExistence(timeout: 1.5) { trash.tap() }
        check(r.waitForNonExistence(timeout: 4), "11-左边那一条右滑没扔掉", "从左边那一条右滑以后这条还在列表里")
        let undo = app.buttons["Undo"]
        if undo.exists { undo.tap() }
        // 左滑：从左边那一条起手往左划，露出置顶
        let w = row("Weekly sync")
        spot(w, x: 70).press(forDuration: 0.05, thenDragTo: spot(w, x: -10), withVelocity: .fast, thenHoldForDuration: 0)
        let pin = app.buttons["Pin"]
        check(pin.waitForExistence(timeout: 3), "11-左边那一条左滑没露出置顶", "从左边那一条左滑以后没有「Pin」")
        pin.tap()
        // 点左边那一条：进写字页
        spot(row("Tomorrow")).tap()
        assertEditor("room two", "11-点左边那一条没进写字页")
    }

    // ---------------------------------------------------------------- 小耳机（112）

    func testListeningOpensText() {
        launch("listen")
        let show = app.buttons.matching(NSPredicate(format: "label == %@", "Show text")).firstMatch
        check(show.waitForExistence(timeout: 8), "07-小耳机没开", "小耳机里找不到「Show text」")
        show.tap()
        check(app.textViews.firstMatch.waitForExistence(timeout: 5), "07-小耳机点了没打开", "点了「Show text」没出原文")
    }
}
