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

    /// 等标签变成 text（直接轮询：谓词等法在这个胶囊上判不出来）
    private func label(_ e: XCUIElement, _ text: String, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if e.exists && e.label == text { return true }
            usleep(200_000)
        } while Date() < end
        return false
    }

    /// 接通 → 问一句 → 答 → 说「挂掉」→ 挂（信箱断着：模拟器里根本没有信箱）
    func testAskThenHangUpByWords() {
        launch(say: "书童做完没|挂掉")
        check(state.waitForExistence(timeout: 8), "139-01-没接通", "顶上没有通话条")
        check(label(state, "Butler's listening", 3), "139-02-接通不在听", "接通以后应该是「在听」：\(state.label)")
        shot("139-1-接通")
        check(label(state, "Butler's thinking", 6), "139-03-没在想", "问了一句应该「在想」：\(state.label)")
        shot("139-2-在想")
        check(label(state, "Butler's talking", 4), "139-04-没在说", "应该「在说」：\(state.label)")
        shot("139-3-在说")
        check(gone(state, 8), "139-05-说挂掉没挂", "说了「挂掉」，通话条应该没了")
        check(app.staticTexts["Hung up. Back to your music."].waitForExistence(timeout: 2), "139-06-没说挂了", "挂了应该弹「Hung up」")
        shot("139-4-挂了")
    }

    /// 带「挂」的别的话：一句不挂
    func testOtherWordsWithHangDontHangUp() {
        launch(say: "把那个会话挂掉|挂个后台")
        check(state.waitForExistence(timeout: 8), "139-07-没接通", "顶上没有通话条")
        sleep(9)
        check(state.exists, "139-08-误挂", "「把那个会话挂掉」「挂个后台」不该挂")
    }

    /// 顶上的挂断键
    func testHangUpButton() {
        launch(say: "")
        let b = app.buttons["call.hangUp"].firstMatch
        check(b.waitForExistence(timeout: 8), "139-09-没挂断键", "通话条上没有挂断键")
        b.tap()
        check(gone(state, 3), "139-10-点了没挂", "点挂断键应该挂")
    }
}
