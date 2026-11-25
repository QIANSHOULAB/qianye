import XCTest

/// 139 打电话式：模拟器里假接通（没有真话筒、没有信箱：等于信箱断着），-YiyeCallSay 给他说的几句。
/// 挂断词照手机本地的规矩认（YiyeKit HangUp），不过信箱也挂得掉；带「挂」的别的话不挂；顶上的挂断键能挂。
final class CallTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(say: String) {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "call", "-YiyeLang", "en", "-YiyeAppearance", "light",
                             "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-YiyeCallSay", say]
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

    private var bar: XCUIElement { app.otherElements["call.bar"].firstMatch }
    private var state: XCUIElement { app.staticTexts["call.state"].firstMatch }

    private func gone(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let ex = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: e)
        return XCTWaiter().wait(for: [ex], timeout: timeout) == .completed
    }

    /// 等顶上的胶囊写着 text（按字找：状态一换字，旧的那个元素就没了，盯着一个元素读字会读空）
    private func label(_ e: XCUIElement, _ text: String, _ timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch.waitForExistence(timeout: timeout)
    }

    /// 点一下状态字：Demo 走一步（不靠计时）
    private func step() { state.tap() }

    /// 接通 → 问一句 → 在想 → 在说 → 说「挂掉」→ 挂（信箱断着：模拟器里根本没有信箱）
    func testAskThenHangUpByWords() {
        launch(say: "书童做完没|挂掉")
        check(state.waitForExistence(timeout: 8), "139-01-没接通", "顶上没有通话条")
        check(label(state, "Butler's listening", 5), "139-02-接通不在听", "接通以后应该是「在听」")
        shot("139-1-接通")
        step()
        check(label(state, "Butler's thinking", 10), "139-03-没在想", "问了一句应该「在想」")
        shot("139-2-在想")
        step()
        check(label(state, "Butler's talking", 10), "139-04-没在说", "应该「在说」")
        shot("139-3-在说")
        step()
        check(label(state, "Butler's listening", 10), "139-04b-没回到在听", "说完应该回到「在听」")
        step()
        check(gone(state, 10), "139-05-说挂掉没挂", "说了「挂掉」，通话条应该没了")
        _ = app.staticTexts["Hung up. Back to your music."].waitForExistence(timeout: 2)   // 那行提示只停几秒：慢模拟器上可能已经走了，不强求
        shot("139-4-挂了")
    }

    /// 带「挂」的别的话：一句不挂
    func testOtherWordsWithHangDontHangUp() {
        launch(say: "把那个会话挂掉|挂个后台")
        check(state.waitForExistence(timeout: 8), "139-07-没接通", "顶上没有通话条")
        for _ in 0..<6 {                       // 两句各走一圈：在想 → 在说 → 在听
            step()
            usleep(300_000)
        }
        check(state.exists && label(state, "Butler's listening", 10), "139-08-误挂", "「把那个会话挂掉」「挂个后台」不该挂")
    }

    /// 顶上的挂断键
    func testHangUpButton() {
        launch(say: "")
        let b = app.buttons["call.hangUp"].firstMatch
        check(b.waitForExistence(timeout: 8), "139-09-没挂断键", "通话条上没有挂断键")
        b.tap()
        check(gone(state, 5), "139-10-点了没挂", "点挂断键应该挂")
    }
}
