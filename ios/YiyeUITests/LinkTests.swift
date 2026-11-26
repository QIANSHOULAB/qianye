import XCTest

/// 195 网址能点、能单独拷。用的是假网址（example.com），不真登；Demo 下「打开」不跳出去，打开过什么写在 link.opened 那行
/// （「第几次|网址」），拷到什么写在 link.pasted 那行。
/// 1. 小书童里续登那种长网址：折行不撑破；点它打开的是整条；旁边的「Open」也开它
/// 2. 长按气泡里的链接：弹「Open / Copy Link / Share…」，Copy Link 拷到的是那条网址
/// 3. 气泡里的字能只拷一段
/// 4. 便签正文：没弹键盘时点链接就打开；长按弹菜单拷链接；点别处照旧打字，打字时点链接不跳走
/// 5. 项目待办的便签正文一样
final class LinkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    /// 屏幕角上那行现在写着什么
    private func tag(_ id: String) -> String {
        let t = app.staticTexts[id].firstMatch
        return t.exists ? t.label : ""
    }

    private func wait(_ id: String, _ ok: (String) -> Bool, timeout: TimeInterval = 8) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok(tag(id)) { return true }
            usleep(200_000)
        }
        return ok(tag(id))
    }

    private func bubble(_ part: String) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", part)).firstMatch
    }

    /// 元素左上角往里 (x, y) 那个点
    private func point(_ e: XCUIElement, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        e.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func menuButton(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// 小书童聊天窗拉到最高
    private func openLinksChat() -> XCUIElement {
        launch("shutong-links")
        let login = bubble("oauth/authorize")
        check(login.waitForExistence(timeout: 12), "L1-没有气泡", "小书童里找不到带网址的那条大管家的话")
        let title = app.staticTexts["Scribe"].firstMatch
        if title.exists {
            let from = title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -420)))
            usleep(900_000)
        }
        return login
    }

    // ---------------------------------------------------------------- 1. 长网址：折行、点开整条、「Open」
    func testLongLinkWrapsAndOpens() {
        let login = openLinksChat()
        let screen = app.windows.firstMatch.frame
        let f = login.frame
        shot("L1-长网址")
        check(f.minX >= 0 && f.maxX <= screen.maxX - 16, "L1-撑破", "长网址那条出了屏幕：\(f)，屏幕 \(screen)")
        check(f.height >= 90, "L1-没折行", "长网址那条只有 \(f.height) 高，像是没折行或者被截了")
        point(login, 6, f.height - 8).tap()                          // 最后一行
        check(wait("link.opened") { $0.hasPrefix("1|https://example.com/cai/oauth/authorize?code=true") && $0.hasSuffix("state=END-195") },
              "L1-点不开", "点长网址最后一行，该打开整条，实际「\(tag("link.opened"))」")
        let open = app.buttons["shutong.openLink"].firstMatch
        check(open.waitForExistence(timeout: 4), "L1-没有打开", "续登那条旁边没有「Open」")
        open.tap()
        check(wait("link.opened") { $0.hasPrefix("2|") && $0.hasSuffix("state=END-195") },
              "L1-打开没反应", "点「Open」没打开那条网址，实际「\(tag("link.opened"))」")
    }

    // ---------------------------------------------------------------- 2. 长按链接：菜单拷链接
    func testHoldLinkInBubbleCopiesLink() {
        let login = openLinksChat()
        point(login, 6, login.frame.height - 8).press(forDuration: 1.2)
        let copy = menuButton("Copy Link")
        check(copy.waitForExistence(timeout: 6), "L2-没有菜单", "长按链接没弹出带「Copy Link」的菜单")
        shot("L2-长按链接")
        copy.tap()
        check(wait("link.pasted") { $0.hasPrefix("https://example.com/cai/oauth/authorize") && $0.hasSuffix("state=END-195") },
              "L2-没拷到", "拷到的不是整条网址：「\(tag("link.pasted"))」")
    }

    // ---------------------------------------------------------------- 3. 只拷一段
    func testSelectPartOfBubbleAndCopy() {
        _ = openLinksChat()
        let say = bubble("Partial copy words")
        check(say.waitForExistence(timeout: 5), "L3-没有气泡", "小书童说的那条不在")
        let full = say.value as? String ?? ""
        point(say, 24, 9).doubleTap()                                 // 第一个词
        var copy = menuButton("Copy")
        if !copy.waitForExistence(timeout: 4) {
            point(say, 24, 9).press(forDuration: 1.2)
            copy = menuButton("Copy")
        }
        check(copy.waitForExistence(timeout: 5), "L3-选不中", "双击、长按气泡里的字都没出「Copy」")
        shot("L3-选中一段")
        copy.tap()
        check(wait("link.pasted") { !$0.isEmpty && $0.count < full.count && full.contains($0) }, "L3-拷不出一段",
              "该只拷到选中的那段，实际「\(tag("link.pasted"))」")
    }

    // ---------------------------------------------------------------- 4. 便签正文
    func testNoteLinkTapHoldAndStillTypes() {
        launch("link-note")
        let text = app.textViews.firstMatch
        check(text.waitForExistence(timeout: 10), "L4-没进写字页", "link-note 没打开写字页")
        usleep(800_000)
        let link = point(text, 70, 20)                                // 第一行就是网址
        link.tap()
        check(wait("link.opened") { $0 == "1|https://example.com/note-195" }, "L4-点不开",
              "便签里点网址没打开，实际「\(tag("link.opened"))」")
        let hide = app.buttons["Hide keyboard"].firstMatch
        check(!hide.exists, "L4-弹了键盘", "点链接不该弹键盘")

        link.press(forDuration: 1.0)
        let copy = app.buttons["Copy Link"].firstMatch
        check(copy.waitForExistence(timeout: 5), "L4-没有菜单", "长按便签里的链接没弹出「Copy Link」")
        shot("L4-长按链接")
        check(app.buttons["Open"].firstMatch.exists && app.buttons["Share…"].firstMatch.exists, "L4-菜单缺项", "菜单里该有 Open、Copy Link、Share…")
        copy.tap()
        check(wait("link.pasted") { $0 == "https://example.com/note-195" }, "L4-没拷到", "拷到的是「\(tag("link.pasted"))」")

        usleep(800_000)
        point(text, 70, 84).tap()                                     // 第三行：普通的字
        check(hide.waitForExistence(timeout: 5), "L4-打不了字", "点普通的字没进编辑")
        usleep(800_000)
        link.tap()                                                    // 打字时点链接：放光标，不跳走
        usleep(1_500_000)
        check(tag("link.opened").hasPrefix("1|"), "L4-打字时跳走", "弹着键盘点链接不该打开，实际「\(tag("link.opened"))」")
    }

    // ---------------------------------------------------------------- 5. 项目待办
    func testTodoNoteLinkOpens() {
        launch("todo")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Try the new build")).firstMatch
        check(row.waitForExistence(timeout: 12), "L5-待办没出现", "寄来的待办不在列表里")
        usleep(800_000)
        row.tap()
        let text = app.textViews.firstMatch
        check(text.waitForExistence(timeout: 6), "L5-没进写字页", "点待办没打开写字页")
        usleep(800_000)
        point(text, 70, 84).tap()                                     // 标题、空行、网址
        check(wait("link.opened") { $0 == "1|https://example.com/todo-195" }, "L5-点不开",
              "项目待办正文里点网址没打开，实际「\(tag("link.opened"))」")
    }
}
