import UIKit
import XCTest

/// 172 遥控：模拟器里假大管家（Demo）回一张画出来的屏。真点一下、长按一下，看得到寄出去的坐标；
/// 密码开关开着：框里只显示点点，寄出去的只写「pass」，不带密码；关着：打的字照寄
final class RemoteTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        let a = XCUIApplication()
        a.launchArguments = ["-YiyeDemo", "YES", "-YiyeScreen", "remote", "-YiyeLang", "en", "-YiyeAppearance", "light",
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

    private var sent: XCUIElement { app.staticTexts["remote.sent"].firstMatch }

    /// 等「寄出去的」那一行变成以 prefix 打头的字（轮询：CI 模拟器慢）
    private func sentStarts(_ prefix: String, _ timeout: TimeInterval = 8) -> String? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if sent.exists, sent.label.hasPrefix(prefix) { return sent.label }
            usleep(300_000)
        } while Date() < end
        return nil
    }

    // ---------------------------------------------------------------- 181 放大

    /// 「remote.zoom」那一行：倍数、挪了多少（框的几分之几）
    private func zoomNow() -> (scale: Double, x: Double, y: Double)? {
        let e = app.staticTexts["remote.zoom"].firstMatch
        guard e.exists else { return nil }
        let n = e.label.split(separator: " ").compactMap { Double($0) }
        return n.count == 3 ? (n[0], n[1], n[2]) : nil
    }

    private func waitZoom(_ timeout: TimeInterval = 8, _ ok: ((scale: Double, x: Double, y: Double)) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let z = zoomNow(), ok(z) { return true }
            usleep(300_000)
        } while Date() < end
        return false
    }

    /// 手机屏幕上那块红（假大管家画在右上角 x 1020…1250、y 70…120 of 1280×800）的中心，按截图这层的几分之几
    private func redCenter(_ element: XCUIElement) -> CGVector? {
        guard let img = element.screenshot().image.cgImage else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard px[i] > 150, px[i + 1] < 80, px[i + 2] < 80 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return CGVector(dx: Double(minX + maxX + 1) / 2 / Double(w), dy: Double(minY + maxY + 1) / 2 / Double(h))
    }

    /// 放大约 3 倍，把右上角拖进来，点那块红的正中：寄出去的比例对得上（1% 以内）；张合、挪图什么都不寄；
    /// 新截图来了倍数不变；点「1×」回整屏
    func testPinchZoomTapAndReset() {
        launch()
        let desk = app.buttons["remote.pick.desk"].firstMatch
        check(desk.waitForExistence(timeout: 10), "181-01-没有选电脑", "遥控页没有「电脑」那一格")
        desk.tap()
        let screen = app.descendants(matching: .any)["remote.screen"].firstMatch
        check(screen.waitForExistence(timeout: 8), "181-02-没有截图", "选了电脑以后没出截图")
        check(waitZoom { abs($0.scale - 1) < 0.01 }, "181-03-开头不是整屏", "刚连上就放大着")
        check(!app.buttons["remote.zoomReset"].exists, "181-04-没放大就有1×", "整屏时不该有「1×」")
        let before = sent.exists ? sent.label : ""

        screen.pinch(withScale: 3, velocity: 2)
        check(waitZoom { $0.scale > 1.8 }, "181-05-张开没放大", "两指张开以后是 \(String(describing: zoomNow()))")
        check((sent.exists ? sent.label : "") == before, "181-06-张开顺带寄了东西", "张开以后寄出去的是 \(sent.label)")
        check(app.buttons["remote.zoomReset"].waitForExistence(timeout: 3), "181-07-没有1×", "放大了没出「1×」")

        // 一指往左下拖到头：右上角进画面、边贴住
        for _ in 0..<3 {
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        check(waitZoom { abs($0.x - (1 - $0.scale)) < 0.01 && abs($0.y) < 0.01 }, "181-08-没贴住边",
              "往左下拖到头以后是 \(String(describing: zoomNow()))")
        check((sent.exists ? sent.label : "") == before, "181-09-挪图寄出去了", "一指拖以后寄出去的是 \(sent.label)")

        // 点哪儿就是哪儿
        let red = redCenter(screen)
        check(red != nil, "181-10-找不到红块", "放大挪过以后画面里没有右上角那块红")
        if let red {
            screen.coordinate(withNormalizedOffset: red).tap()
            let tap = sentStarts("tap ")
            let n = (tap ?? "").split(separator: " ").compactMap { Double($0) }
            let want = (x: (1020.0 + 1250) / 2 / 1280, y: (70.0 + 120) / 2 / 800)
            check(n.count == 2 && abs(n[0] - want.x) < 0.01 && abs(n[1] - want.y) < 0.01, "181-11-点偏了",
                  "点红块正中寄出去的是 \(tap ?? "（没寄）")，应该是 \(want.x) \(want.y)；缩放 \(String(describing: zoomNow()))")
        }

        // 一两秒换一张新截图：倍数、位置不动
        let held = zoomNow()
        sleep(5)
        let later = zoomNow()
        check(held != nil && later != nil && held! == later!, "181-12-换图跳回去了", "5 秒前 \(String(describing: held))，现在 \(String(describing: later))")

        app.buttons["remote.zoomReset"].firstMatch.tap()
        check(waitZoom { abs($0.scale - 1) < 0.001 && $0.x == 0 && $0.y == 0 }, "181-13-1×没回整屏", "点了「1×」还是 \(String(describing: zoomNow()))")
        check(!app.buttons["remote.zoomReset"].exists, "181-14-1×没收", "回整屏了「1×」还在")
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        check(sentStarts("tap 0.50") != nil || sentStarts("tap 0.49") != nil, "181-15-回整屏点不准", "点正中寄出去的是 \(sent.label)")
        shot("181-放大回整屏")
    }

    func testTapPressAndPassword() {
        launch()
        let desk = app.buttons["remote.pick.desk"].firstMatch
        check(desk.waitForExistence(timeout: 10), "172-01-没有选电脑", "遥控页没有「电脑」那一格")
        desk.tap()

        let screen = app.descendants(matching: .any)["remote.screen"].firstMatch
        check(screen.waitForExistence(timeout: 8), "172-02-没有截图", "选了电脑以后没出截图")

        // 点正中间：寄出去 tap 0.50 0.50（允许差一点）
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let tap = sentStarts("tap ")
        check(tap != nil, "172-03-点了没寄", "点了截图，寄出去的不是 tap：\(sent.exists ? sent.label : "（没有那一行）")")
        if let tap {
            let n = tap.split(separator: " ").compactMap { Double($0) }
            check(n.count == 2 && abs(n[0] - 0.5) < 0.03 && abs(n[1] - 0.5) < 0.03, "172-04-坐标不对", "点正中间寄出去的是 \(tap)")
        }

        // 点左上四分之一处
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).tap()
        let q = sentStarts("tap 0.2")
        check(q != nil, "172-05-第二下坐标不对", "点四分之一处寄出去的是 \(sent.label)")

        // 长按 = 右键
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        check(sentStarts("right ") != nil, "172-06-长按不是右键", "长按寄出去的是 \(sent.label)")

        // 打字（密码开关关着）
        let input = app.textFields["remote.input"].firstMatch
        check(input.waitForExistence(timeout: 5), "172-07-没有输入框", "底下没有打字的框")
        input.tap()
        input.typeText("hello")
        app.buttons["remote.send"].firstMatch.tap()
        check(sentStarts("type hello") != nil, "172-08-打字没寄", "寄出去的是 \(sent.label)")

        // 密码：开关开着框里只显示点点；寄出去只写 pass，不带密码
        app.buttons["remote.passToggle"].firstMatch.tap()
        let secure = app.secureTextFields["remote.input.secure"].firstMatch
        check(secure.waitForExistence(timeout: 5), "172-09-密码框没换上", "开了密码开关，框没变成点点的")
        secure.tap()
        secure.typeText("FakePw172")
        let shown = (secure.value as? String) ?? ""
        check(!shown.contains("FakePw"), "172-10-密码露出来了", "密码框里显示的是 \(shown)")
        app.buttons["remote.send"].firstMatch.tap()
        let p = sentStarts("pass")
        check(p == "pass", "172-11-密码没寄或带出来了", "寄出去的是 \(sent.label)")
        check(app.textFields["remote.input"].waitForExistence(timeout: 3), "172-12-发完没回到普通框", "发完密码，开关该自己关上")
        shot("172-遥控")

        // 结束：回到选机器
        app.buttons["remote.end"].firstMatch.tap()
        check(desk.waitForExistence(timeout: 5), "172-13-结束没回到选机器", "点了结束没回到选电脑 / 掌机")
    }
}
