import XCTest

/// 250 机器人：真点一遍。Demo 里是假大管家（0.5 秒回写好的话；群里一句分两封、故意倒着到）。
/// 1. 只有小书童时点开直接进它 → 右上小人图标进名单 → 建一个 → 聊一句 → 资料页左滑删一条记忆 → 删掉它 → 再点主页按钮又直接进小书童
/// 2. 名单里拉群 → 打 @ 点成员名 → 发一句 → 两条回话按序摆
/// 3. 提醒链接 yiye://group 直接进那个群
/// 4. 252：yiye://bot?id=&msg= 进掌眼的窗、滚到今天第一条（信故意倒着到）→ 图点开全屏、左滑下一张、长按存相册；深色看一眼
/// 5. 258：只剩 👎，设计图点了出「不留了 · 撤回」、几秒淡掉、灵感库里没了 → 资料页定时活开关、左滑删
/// 6. 256：新建页不往上推就点得到「建好」；缺名字、缺人设、重名、太长当场说；回信带 error 字还在；返回先问
/// 7. 258：名单最上面的灵感库卡 → 照片墙、种类、搜索 → 全屏（卡片字、左右滑、长按存、原网址）→ 不留、撤回 → 深色
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
        type("bots.persona", "Cheerful. Makes tea.", "B1-人设框")      // 256：说明不填
        tap("bots.create", "B1-建好按钮")
        check(any("bots.input").waitForExistence(timeout: 8), "B1-没进聊天窗", "建好该直接进它的聊天窗")
        type("bots.input", "hello", "B1-输入框")
        tap("bots.send", "B1-发送")
        check(containing("Aye: hello").waitForExistence(timeout: 8), "B1-没回话", "假大管家该回「Aye: hello」")
        shot("B1-聊天")

        tap("bots.title", "B1-点名字")
        let desc = any("bots.desc")
        check(desc.waitForExistence(timeout: 6) && desc.value as? String == "Cheerful", "256-说明没拿第一句",
              "实际 \(String(describing: desc.value))")
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
        check(!containing("Cheerful").exists, "B1-还在名单里", "删掉的机器人还在名单里")
        app.buttons["Done"].firstMatch.tap()
        check(open.waitForExistence(timeout: 6), "B1-回主页", "关掉名单该回主页")
        open.tap()
        check(any("shutong.input").waitForExistence(timeout: 6), "B1-又是名单", "只剩小书童时点开该直接进它")
    }

    // ---------------------------------------------------------------- 2. 拉群、@、陆续到的发言按序
    func testGroupMentionAndOrder() {
        launch("bots")
        tap("bots.newGroup", "B2-名单没出来")
        let make = app.buttons["bots.create"].firstMatch
        check(make.waitForExistence(timeout: 6) && hittable(make) && !make.isEnabled, "256-群-建好", "进页就该看得到、还不能点")
        check(containing("a group name, members (2 more)").waitForExistence(timeout: 4), "256-群-没说缺什么", "")
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

    // ---------------------------------------------------------------- 6. 256 新建页
    func testNewBotPage() {
        launch("bots")
        tap("bots.new", "256-名单没出来")
        let make = app.buttons["bots.create"].firstMatch
        check(make.waitForExistence(timeout: 6) && hittable(make), "256-建好不在屏上", "不用往上推就该点得到「建好」")
        check(!make.isEnabled, "256-空着就亮了", "什么都没填，「建好」该是灰的")
        check(app.buttons["bots.done"].waitForNonExistence(timeout: 4), "256-还有好了", "新建页不放「好了」")
        check(containing("a name, a persona").waitForExistence(timeout: 4), "256-没说缺什么", "")

        type("bots.name", "Chef", "256-名字框")
        check(containing("already a bot called").waitForExistence(timeout: 4), "256-没说重名", "")
        let delete = XCUIKeyboardKey.delete.rawValue
        any("bots.name").typeText(String(repeating: delete, count: 4) + "Abcdefghijklmnopqrstu")
        check(containing("Name too long: 21").waitForExistence(timeout: 4), "256-没说太长", "")
        any("bots.name").typeText(String(repeating: delete, count: 21) + "Nope")
        check(containing("Still needed: a persona").waitForExistence(timeout: 4), "256-没说缺人设", "")
        check(!make.isEnabled, "256-缺人设就亮了", "")
        type("bots.persona", "Grumpy.", "256-人设框")
        check(make.isEnabled && make.isHittable, "256-填齐了没亮", "")
        shot("256-新建页")

        make.tap()                                                   // 假大管家对「Nope」回 error
        check(containing("12 bots already").waitForExistence(timeout: 8), "256-没亮出错那句", "回信带 error 该原样写在页上")
        check(any("bots.name").value as? String == "Nope", "256-字丢了", "实际 \(String(describing: any("bots.name").value))")
        check(make.waitForExistence(timeout: 4) && make.isEnabled, "256-不能再点", "")
        shot("256-回信带错")

        tap("bots.back", "256-返回")
        let keep = app.buttons["Keep editing"].firstMatch
        check(keep.waitForExistence(timeout: 4), "256-返回没问", "填了字点返回该问一句")
        keep.tap()
        check(any("bots.name").value as? String == "Nope", "256-接着填字没了", "")
        tap("bots.back", "256-返回")
        let drop = app.buttons["Drop it"].firstMatch
        check(drop.waitForExistence(timeout: 4), "256-返回没问", "")
        drop.tap()
        tap("bots.new", "256-没回名单")
        check(containing("a name, a persona").waitForExistence(timeout: 4), "256-不建了还留着字", "")
        tap("bots.back", "256-空着返回")
        check(any("bots.new").waitForExistence(timeout: 6), "256-空着返回也问", "没填字直接走")
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

    // ---------------------------------------------------------------- 5. 258 👎、252 定时活
    func testReactAndJobs() {
        launch("link-eye", lang: "zh-Hans")
        check(any("bots.pic.zdemo1.0").waitForExistence(timeout: 12), "252-没进掌眼的窗", "")
        let down = any("bots.down.zdemo1")
        check(reach(down), "252-没有踩", "能评的话底下该有 👎")
        check(!any("bots.up.zdemo1").exists, "258-还有赞", "👍 没有了")
        for _ in 0..<3 where !down.isHittable { app.swipeUp() }
        down.tap()
        check(selected(down, true), "252-踩不动", "点 👎 该变实")
        let undo = any("bots.undo.zdemo1")
        check(undo.waitForExistence(timeout: 4), "258-没有撤回", "设计图点了 👎，底下该有「不留了 · 撤回」")
        shot("258-不留了")
        undo.tap()
        check(selected(down, false), "258-撤回没撤", "点撤回 👎 该变回空心")
        check(undo.waitForNonExistence(timeout: 6), "258-撤回完还挂着", "")
        down.tap()
        check(selected(down, true), "258-又踩不动", "")
        check(undo.waitForNonExistence(timeout: 15), "258-小字不淡掉", "几秒后该淡掉")
        check(selected(down, true), "258-淡掉就撤了", "小字淡掉，👎 还是实的")
        tap("bots.header.library", "258-窗右上没有灵感库")
        check(any("lib.tile.zdemo2").waitForExistence(timeout: 8), "258-墙没出来", "")
        check(any("lib.tile.zdemo1").waitForNonExistence(timeout: 4), "258-不留的还在墙上", "")
        tap("bots.back", "258-回聊天窗")

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

    // ---------------------------------------------------------------- 7. 258 灵感库
    func testLibrary() {
        launch("bots", lang: "zh-Hans")
        let card = any("bots.library")
        check(card.waitForExistence(timeout: 10), "258-没有卡", "机器人名单最上面该有一张「灵感库」")
        check(card.frame.minY < any("bots.row.shutong").frame.minY, "258-卡不在最上面", "")
        sleep(1)
        shot("258-名单")
        card.tap()
        let wire = any("lib.tile.zdemo1")
        let type4 = any("lib.tile.zlib4")
        check(wire.waitForExistence(timeout: 8) && type4.waitForExistence(timeout: 4), "258-墙没出来", "")
        sleep(1)
        shot("258-灵感库")

        tap("lib.kind.字体", "258-没有种类")
        check(wire.waitForNonExistence(timeout: 6) && type4.exists, "258-种类没筛", "选「字体」只该剩字体")
        tap("lib.kind.all", "258-没有全部")
        check(wire.waitForExistence(timeout: 6), "258-回不到全部", "")
        type("lib.search", "铁丝", "258-搜索框")
        check(type4.waitForNonExistence(timeout: 6) && wire.exists, "258-没搜对", "搜「铁丝」只该剩那一张")
        tap("lib.clear", "258-清不掉")
        tap("lib.kind.all", "258-收键盘")
        check(type4.waitForExistence(timeout: 6), "258-清了没回来", "")

        wire.tap()
        let full0 = any("lib.viewer.image.0")
        check(full0.waitForExistence(timeout: 8), "258-原图没取来", "点一张该全屏、取原图")
        check(containing("同类堆卡片").waitForExistence(timeout: 4), "258-没有差别", "")
        check(containing("一个主角，别的全退后").exists, "258-没有招", "")
        sleep(1)
        shot("258-全屏")
        full0.swipeLeft()
        let full1 = any("lib.viewer.image.1")
        check(full1.waitForExistence(timeout: 4) && hittable(full1), "258-滑不到整屏", "")
        full1.press(forDuration: 1.2)
        check(containing("存进相册了").waitForExistence(timeout: 6), "258-长按没存", "")
        tap("lib.url", "258-没有原网址")
        check(containing("打开 ritual.engineer").waitForExistence(timeout: 4), "258-网址点了没开", "")

        tap("lib.viewer.drop", "258-没有 👎")
        check(wire.waitForNonExistence(timeout: 8), "258-不留了还在墙上", "")
        let undo = app.buttons["撤回"].firstMatch
        check(undo.waitForExistence(timeout: 4), "258-墙下没有撤回", "")
        undo.tap()
        check(wire.waitForExistence(timeout: 8), "258-撤回没挂回去", "")
        wire.tap()
        tap("lib.viewer.drop", "258-再点 👎")
        check(wire.waitForNonExistence(timeout: 8), "258-第二回没拿掉", "")
        tap("bots.back", "258-回名单")
        check(card.waitForExistence(timeout: 6) && card.label.contains("4"), "258-卡上数不对", "实际 \(card.label)")

        app.terminate()
        launch("bots", lang: "zh-Hans", appearance: "dark")
        tap("bots.library", "258-深色没有卡")
        check(any("lib.tile.zdemo1").waitForExistence(timeout: 12), "258-深色墙没出来", "")
        sleep(1)
        shot("258-灵感库-深色")
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
