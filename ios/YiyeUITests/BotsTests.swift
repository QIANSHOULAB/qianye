import XCTest

/// 250 机器人：真点一遍。Demo 里是假大管家（0.5 秒回写好的话；群里一句分两封、故意倒着到）。
/// 1. 只有小书童时点开直接进它 → 右上小人图标进名单 → 建一个 → 聊一句 → 资料页左滑删一条记忆 → 删掉它 → 再点主页按钮又直接进小书童
/// 2. 名单里拉群 → 打 @ 点成员名 → 发一句 → 两条回话按序摆
/// 3. 提醒链接 yiye://group 直接进那个群
/// 4. 252：yiye://bot?id=&msg= 进掌眼的窗、滚到今天第一条（信故意倒着到）→ 图点开全屏、左滑下一张、长按存相册；深色看一眼
/// 5. 252：👍 再点取消、👎 → 资料页定时活开关、左滑删
final class BotsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String, lang: String = "en", appearance: String = "light") {
        let a = XCUIApplication()
        let locale = lang == "en" ? "en_US" : "zh_CN"
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", screen, "-YiyeLang", lang, "-YiyeAppearance", appearance,
                             "-AppleLanguages", "(\(lang))", "-AppleLocale", locale]
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

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func containing(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 半屏里排在下面的行，没滚到就不存在：往上推几下（第一下先把半屏拉高）
    private func reach(_ e: XCUIElement) -> Bool {
        if e.waitForExistence(timeout: 6) { return true }
        for _ in 0..<5 {
            app.swipeUp()
            if e.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// 等它出来再点；被键盘挡着就往上推一下
    private func tap(_ id: String, _ name: String) {
        let e = any(id)
        check(reach(e), name, "找不到「\(id)」")
        for _ in 0..<3 where !e.isHittable { app.swipeUp() }
        e.tap()
    }

    private func type(_ id: String, _ text: String, _ name: String) {
        tap(id, name)
        any(id).typeText(text)
    }

    // ---------------------------------------------------------------- 1. 建、聊、记忆、删
    func testCreateChatForgetDelete() {
        launch("list")
        let open = app.buttons["Scribe"].firstMatch
        check(open.waitForExistence(timeout: 8), "B1-没有书童按钮", "主页顶栏找不到「Scribe」")
        open.tap()
        check(any("shutong.input").waitForExistence(timeout: 6), "B1-没直接进小书童", "只有小书童时点开该直接进它的聊天窗")
        tap("shutong.bots", "B1-没有机器人图标")
        tap("bots.new", "B1-名单没出来")
        type("bots.name", "Pip", "B1-名字框")
        type("bots.desc", "Food ideas", "B1-说明框")
        type("bots.persona", "Cheerful.", "B1-人设框")
        tap("bots.create", "B1-建好按钮")
        check(any("bots.input").waitForExistence(timeout: 8), "B1-没进聊天窗", "建好该直接进它的聊天窗")
        type("bots.input", "hello", "B1-输入框")
        tap("bots.send", "B1-发送")
        check(containing("Aye: hello").waitForExistence(timeout: 8), "B1-没回话", "假大管家该回「Aye: hello」")
        shot("B1-聊天")

        tap("bots.title", "B1-点名字")
        let memo = containing("He likes tea")
        check(reach(memo), "B1-没有记忆", "资料页该列出「He likes tea」")
        shot("B1-资料页")
        for _ in 0..<3 where !memo.isHittable { app.swipeUp() }
        memo.swipeLeft()
        let forget = app.buttons["Forget"].firstMatch
        check(forget.waitForExistence(timeout: 4), "B1-左滑没出忘掉", "左滑一条记忆该出「Forget」")
        forget.tap()
        check(memo.waitForNonExistence(timeout: 6), "B1-没删掉", "删掉的记忆还在")

        tap("bots.delete", "B1-删机器人")
        let yes = app.buttons["Delete"].firstMatch
        check(yes.waitForExistence(timeout: 4), "B1-没有确认", "删机器人该问一下")
        yes.tap()
        check(any("bots.new").waitForExistence(timeout: 8), "B1-没回名单", "删完该回名单")
        check(!containing("Food ideas").exists, "B1-还在名单里", "删掉的机器人还在名单里")
        app.buttons["Done"].firstMatch.tap()
        check(open.waitForExistence(timeout: 6), "B1-回主页", "关掉名单该回主页")
        open.tap()
        check(any("shutong.input").waitForExistence(timeout: 6), "B1-又是名单", "只剩小书童时点开该直接进它")
    }

    // ---------------------------------------------------------------- 2. 拉群、@、陆续到的发言按序
    func testGroupMentionAndOrder() {
        launch("bots")
        tap("bots.newGroup", "B2-名单没出来")
        type("bots.groupName", "Lunch", "B2-群名")
        tap("bots.pick.bdemo0001", "B2-勾第一个")
        tap("bots.pick.bdemo0002", "B2-勾第二个")
        tap("bots.create", "B2-建好")
        check(any("bots.input").waitForExistence(timeout: 8), "B2-没进群", "建好该进群聊窗")
        type("bots.input", "go @", "B2-打@")
        tap("bots.mention.bdemo0002", "B2-没弹出成员名")
        let value = any("bots.input").value as? String ?? ""
        check(value.contains("@Ledger "), "B2-没插进去", "输入框里该有「@Ledger 」，实际「\(value)」")
        tap("bots.send", "B2-发送")
        let first = containing("First: dumplings")
        let second = containing("Second: I’ll do the sums")
        check(first.waitForExistence(timeout: 10), "B2-第一句没到", "")
        check(second.waitForExistence(timeout: 6), "B2-第二句没到", "")
        check(first.frame.minY < second.frame.minY, "B2-顺序反了", "第 2 封先到，也该摆在第 1 封下面")
        shot("B2-群聊")
    }

    // ---------------------------------------------------------------- 4. 252 掌眼：图、全屏、👍👎、定时活
    func testPicturesReactAndJobs() {
        launch("link-eye", lang: "zh-Hans")
        let first = containing("第一条 刺点")
        check(first.waitForExistence(timeout: 12), "252-没进掌眼的窗", "点提醒链接该直接进它的聊天窗")
        let pic = any("bots.pic.zdemo1.0")
        check(pic.waitForExistence(timeout: 6) && hittable(pic), "252-没滚到第一条", "提醒指的那一句该在屏幕上")
        check(pic.frame.minY < first.frame.minY, "252-图没在字上面", "")
        check(any("bots.pic.zdemo1.1").exists, "252-没有第二张", "这条有两张图")
        sleep(1)
        shot("252-掌眼窗")

        pic.tap()
        let full0 = any("bots.viewer.image.0")
        check(full0.waitForExistence(timeout: 6), "252-没全屏", "点图该全屏看")
        shot("252-全屏")
        full0.swipeLeft()
        let full1 = any("bots.viewer.image.1")
        check(full1.waitForExistence(timeout: 4) && hittable(full1), "252-没翻到下一张", "左滑看这条里的下一张")
        full1.press(forDuration: 1.2)
        check(containing("存进相册了").waitForExistence(timeout: 6), "252-长按没存", "长按该存进相册")
        tap("bots.viewer.close", "252-没有关")
        check(full1.waitForNonExistence(timeout: 6), "252-关不掉", "")

        // 深色里看一眼图
        app.terminate()
        launch("link-eye", lang: "zh-Hans", appearance: "dark")
        check(any("bots.pic.zdemo1.0").waitForExistence(timeout: 12), "252-深色没进窗", "")
        sleep(1)
        shot("252-掌眼窗-深色")
    }

    // ---------------------------------------------------------------- 5. 252 👍👎、定时活
    func testReactAndJobs() {
        launch("link-eye", lang: "zh-Hans")
        check(any("bots.pic.zdemo1.0").waitForExistence(timeout: 12), "252-没进掌眼的窗", "")
        let up = any("bots.up.zdemo1")
        check(reach(up), "252-没有赞", "能评的话底下该有 👍")
        for _ in 0..<3 where !up.isHittable { app.swipeUp() }
        up.tap()
        check(selected(up, true), "252-点了没变实", "点 👍 该变实")
        up.tap()
        check(selected(up, false), "252-再点没取消", "再点一次取消")
        let down = any("bots.down.zdemo1")
        down.tap()
        check(selected(down, true), "252-踩不动", "点 👎 该变实")
        shot("252-赞踩")

        tap("bots.title", "252-点名字")
        let job = app.switches["bots.job.j0000001"].firstMatch
        check(reach(job), "252-没有定时活", "资料页该列出定时活")
        for _ in 0..<3 where !job.isHittable { app.swipeUp() }
        check(job.value as? String == "1", "252-开关不是开的", "实际 \(String(describing: job.value))")
        shot("252-定时活")
        let wide = app.windows.firstMatch.frame.width
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: wide - 50, dy: job.frame.midY)).tap()
        check(valueBecomes(job, "0"), "252-关不掉定时活", "")
        let second = app.switches["bots.job.j0000002"].firstMatch
        check(reach(second), "252-没有第二条", "")
        for _ in 0..<3 where !second.isHittable { app.swipeUp() }
        second.swipeLeft()
        let delete = app.buttons["删除"].firstMatch
        check(delete.waitForExistence(timeout: 4), "252-左滑没出删除", "")
        delete.tap()
        check(second.waitForNonExistence(timeout: 6), "252-删不掉定时活", "")
    }

    private func hittable(_ e: XCUIElement) -> Bool {
        for _ in 0..<12 { if e.isHittable { return true }; usleep(500_000) }
        return false
    }

    private func selected(_ e: XCUIElement, _ want: Bool) -> Bool {
        for _ in 0..<10 { if e.isSelected == want { return true }; usleep(300_000) }
        return false
    }

    private func valueBecomes(_ e: XCUIElement, _ want: String) -> Bool {
        for _ in 0..<12 { if e.value as? String == want { return true }; usleep(500_000) }
        return false
    }

    // ---------------------------------------------------------------- 3. 从提醒进群
    func testLinkOpensGroup() {
        launch("link-group")
        check(containing("Dumplings.").waitForExistence(timeout: 10), "B3-没进群", "yiye://group 该直接打开那个群的聊天窗")
        check(containing("Dinner club").exists, "B3-群名不对", "顶上该是群名")
    }
}
