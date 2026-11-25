import Foundation
import XCTest
@testable import YiyeKit

/// 139 打电话式：挂断词本地认、挂了放掉会话、60 秒没话自己挂（陪玩里不挂）
final class Call139Tests: XCTestCase {
    /// 20 句全挂（pc-butler handheld/selftest/deep139_test.py 同一张单子）
    let hang = ["挂掉", "挂了", "挂吧", "挂断", "拜拜", "再见", "bye", "Bye bye", "嗯挂了", "好拜拜", "那先挂了", "好，挂了", "行，挂吧",
                "嗯，再见", "先挂了啊", "那就这样，挂了", "好的拜拜", "OK bye", "那我先挂了", "嗯嗯，拜拜"]
    /// 带「挂」的别的话：10 句一句不挂
    let notHang = ["把那个会话挂掉", "挂个后台", "电脑挂了吗", "游戏又挂了", "他挂了我电话", "挂号怎么挂", "把衣服挂起来",
                   "挂掉的那个程序重启一下", "再见到他跟他说一声", "拜拜是什么意思"]

    func testHangWords() {
        for s in hang { XCTAssertTrue(HangUp.isHangUp(s), s) }
    }

    func testNotHangWords() {
        for s in notHang { XCTAssertFalse(HangUp.isHangUp(s), s) }
        for s in notHang { XCTAssertFalse(HangUp.endsCall(s), s) }
    }

    func testEndWordsHangUpInACall() {
        for s in ["不聊了", "结束", "退出", "好，不聊了", "那就这样", "嗯，结束吧"] { XCTAssertTrue(HangUp.endsCall(s), s) }
        for s in ["结束了吗", "怎么退出微信", "这个游戏不聊了吗"] { XCTAssertFalse(HangUp.endsCall(s), s) }
        XCTAssertFalse(HangUp.isHangUp("不聊了"))              // 陪玩深聊里「不聊了」不是挂断词（只退深聊）
    }

    final class Port: CallPort {
        var steps: [String] = []
        func beep(_ times: Int) { steps.append("beep\(times)") }
        func stopMic() { steps.append("mic") }
        func stopPlaying() { steps.append("play") }
        func releaseSession(notifyOthers: Bool) { steps.append(notifyOthers ? "release+notify" : "release") }
    }

    func testHangUpReleasesSession() {
        let port = Port()
        var line = CallLine(idleOn: true)
        let t0 = Date()
        line.connect(now: t0, companion: false)
        line.asked("q1")
        let left = line.hangUp(.words, port: port)
        XCTAssertEqual(port.steps, ["beep2", "mic", "play", "release+notify"])   // 嘟嘟两声、停话筒、停放、放掉会话叫别家接着放
        XCTAssertFalse(line.on)
        XCTAssertEqual(line.hungBy, .words)
        XCTAssertEqual(left, ["q1"])                         // 还在等的回答不扔
        XCTAssertTrue(line.hangUp(.words, port: port).isEmpty)   // 挂过了再挂：什么都不做
        XCTAssertEqual(port.steps.count, 4)
    }

    func testIdleHangsUpAfter60s() {
        var line = CallLine(idleOn: true)
        let t0 = Date()
        line.connect(now: t0, companion: false)
        line.answered(now: t0.addingTimeInterval(10))
        XCTAssertFalse(line.idleDue(now: t0.addingTimeInterval(69), busy: false))
        XCTAssertTrue(line.idleDue(now: t0.addingTimeInterval(70), busy: false))
        XCTAssertFalse(line.idleDue(now: t0.addingTimeInterval(200), busy: true))   // 在说、在放：不挂
        line.heard(now: t0.addingTimeInterval(65))
        XCTAssertFalse(line.idleDue(now: t0.addingTimeInterval(100), busy: false))   // 他又说话了：从头数
        XCTAssertTrue(line.idleDue(now: t0.addingTimeInterval(125), busy: false))
    }

    func testNoIdleInCompanionOrWhenOff() {
        var line = CallLine(idleOn: true)
        let t0 = Date()
        line.connect(now: t0, companion: true)
        XCTAssertFalse(line.idleDue(now: t0.addingTimeInterval(600), busy: false))  // 陪玩（打游戏）里不自动挂
        var off = CallLine(idleOn: false)
        off.connect(now: t0, companion: false)
        XCTAssertFalse(off.idleDue(now: t0.addingTimeInterval(600), busy: false))   // 锁屏喊不回来：自动挂先关着
    }

    func testCarryLine() {
        XCTAssertNil(CallLine.carryLine(titles: [], zh: true))
        XCTAssertEqual(CallLine.carryLine(titles: ["比特币为什么跌"], zh: true), "上回挂了以后答好了：「比特币为什么跌」，存在深聊里")
    }
}

final class Call139WavTests: XCTestCase {
    func testWavRoundTrip() {
        let s: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let back = Wav.decode(Wav.encode(s))
        XCTAssertEqual(back.count, s.count)
        for (a, b) in zip(s, back) { XCTAssertEqual(a, b, accuracy: 0.001) }
        XCTAssertTrue(Wav.decode(Data([1, 2, 3])).isEmpty)
    }
}
