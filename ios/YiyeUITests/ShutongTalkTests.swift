import XCTest

/// 137 书童开口说：真点一遍。Demo 里没有话筒：开口说的条上多一个「假装说一句」，填的字跟一小段静音录音一起交给假大管家，
/// 假大管家照大管家的规矩「认字」（撤销 / 对 / 不对 / 好了本地认，别的回 136 那套假动作），念的那句照手机这头干一遍不落地算。
/// 1. 开口说 → 说「把机床的放一起」→ 直接做了、回执出来、字幕在 → 说「撤销」→ 撤回去了 → 说「好了」→ 回到打字
/// 2–4. 说「扔掉旧的」→ 列出来等点头 → 说「对」扔了 / 说「不对」没扔 / 不吭声没扔
final class ShutongTalkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "list", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private func containing(_ q: XCUIElementQuery, _ text: String) -> XCUIElement {
        q.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 打开书童、按「开口说」
    private func startTalking(_ tag: String) {
        launch()
        let open = app.buttons["Scribe"].firstMatch
        check(open.waitForExistence(timeout: 8), "\(tag)-没有书童按钮", "主页顶栏找不到「Scribe」")
        open.tap()
        let talk = app.buttons["shutong.talk"].firstMatch
        check(talk.waitForExistence(timeout: 5), "\(tag)-没有开口说", "聊天窗顶上没有「Talk」")
        talk.tap()
        check(app.textFields["talk.fake"].waitForExistence(timeout: 5), "\(tag)-没进开口说", "点了「Talk」，没换成在听的那条")
    }

    /// 假装说一句
    private func say(_ text: String) {
        let field = app.textFields["talk.fake"]
        field.tap()
        field.typeText(text)
        app.buttons["talk.say"].firstMatch.tap()
    }

    // ---------------------------------------------------------------- 1. 说了就做、撤销、好了
    func testTalkDoUndoThenBye() {
        startTalking("T1")
        say("Put the machine stuff together")
        let undo = app.buttons["Undo this batch"].firstMatch
        check(undo.waitForExistence(timeout: 8), "T1-没做", "说了一句，聊天窗里没出回执（Undo this batch）")
        check(containing(app.staticTexts, "into “Machines”").exists, "T1-回执不对", "回执里没写挪进了「Machines」")
        check(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Put the machine stuff together")).firstMatch.exists,
              "T1-没字幕", "他说的那句没出在聊天窗里")                       // 195：气泡里的字是能选的文字框了
        check(app.buttons["shutong.talkFix"].firstMatch.exists, "T1-不能改字", "字幕旁边没有「Fix」")
        shot("T1-开口说回执")

        say("undo")
        check(containing(app.staticTexts, "Undone").waitForExistence(timeout: 6), "T1-撤销没回去", "说了「撤销」，回执上没写「Undone」")
        shot("T1-说撤销")

        say("done")
        check(app.descendants(matching: .any)["shutong.input"].firstMatch.waitForExistence(timeout: 6), "T1-没退出",
              "说了「好了」，没回到打字")
    }

    // ---------------------------------------------------------------- 2–4. 扔东西要他点头
    private func askToTrash(_ tag: String) {
        startTalking(tag)
        say("Trash the old ones")
        check(containing(app.staticTexts, "These need your nod first").waitForExistence(timeout: 8), "\(tag)-没先问", "说了要扔，没列出来等点头")
        check(app.buttons["Toss them"].firstMatch.exists, "\(tag)-清单不对", "等点头的清单上没有「Toss them」")
        check(!containing(app.staticTexts, "Trashed").exists, "\(tag)-没问就扔了", "还没点头就扔了")
    }

    func testTrashSayYes() {
        askToTrash("T2")
        shot("T2-要扔先问")
        say("yes")                                                // 172：CI 模拟器慢的那轮（29 条 700 秒）6 秒等不到「Trashed」，放到 12 秒
        check(containing(app.staticTexts, "Trashed").waitForExistence(timeout: 12), "T2-说对没扔", "说了「对」，没扔（回执里没有「Trashed」）")
    }

    func testTrashSayNo() {
        askToTrash("T3")
        say("no")
        check(containing(app.staticTexts, "Skipped").waitForExistence(timeout: 6), "T3-说不对还在等", "说了「不对」，清单没写「Skipped」")
        check(!containing(app.staticTexts, "Trashed").exists, "T3-说不对也扔了", "说了「不对」还是扔了")
    }

    func testTrashSilenceKeeps() {
        askToTrash("T4")
        check(containing(app.staticTexts, "Skipped").waitForExistence(timeout: 30), "T4-不吭声还在等", "不吭声，清单一直等着没收")
        check(!containing(app.staticTexts, "Trashed").exists, "T4-不吭声也扔了", "不吭声还是扔了")
        shot("T4-不吭声不动")
    }
}
