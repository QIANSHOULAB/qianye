import Foundation
import XCTest
@testable import YiyeKit

/// 170：耳朵「配置变了」以后怎么办（陪玩、深聊、电话、小书童通话共用）。真话筒在单测里没有，用一只假耳朵把几种情形走一遍：
/// start 以后马上来一次「配置变了」；重开第一次失败、第二次成；回声消除开不了走退路；一直「配置变了」也不转圈。
@MainActor
final class Ear170Tests: XCTestCase {
    final class FakeEar {
        let n: Int
        let echo: Bool
        var running = true
        var startedAt: Double
        var released: [Bool] = []
        init(n: Int, echo: Bool, at: Double) { self.n = n; self.echo = echo; self.startedAt = at }
    }

    struct Boom: Error, Equatable { var n: Int }

    /// 假的一场：clock 自己走（sleep 就是把钟往前拨），make 按脚本成 / 败
    final class Rig {
        var clock: Double = 100
        var slept: [Double] = []
        var made: [FakeEar] = []
        var tries: [Bool] = []                   // 每次 make 要的 echo
        /// 第几次 make（0 起）失败；echoFails：开了回声消除就失败
        var failAt: Set<Int> = []
        var echoFails = false
        var releasedKeep: [Bool] = []

        @MainActor
        func keeper() -> EarKeeper<FakeEar> {
            EarKeeper(.init(make: { [unowned self] echo in
                let i = self.tries.count
                self.tries.append(echo)
                if self.failAt.contains(i) || (self.echoFails && echo) { throw Boom(n: i) }
                let e = FakeEar(n: i, echo: echo, at: self.clock)
                self.made.append(e)
                return e
            }, release: { [unowned self] e, keep in
                e.running = false
                e.released.append(keep)
                self.releasedKeep.append(keep)
            }, running: { $0.running }, startedAt: { $0.startedAt },
               sleep: { [unowned self] s in self.slept.append(s); self.clock += s },
               now: { [unowned self] in self.clock }))
        }
    }

    /// 等 configChanged 里那个 Task 跑完
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    func testDelayRules() {
        XCTAssertEqual(EarRestart.checkDelay(sinceStart: 0), 1.5, accuracy: 1e-9)       // 刚开：等满 1.5 秒
        XCTAssertEqual(EarRestart.checkDelay(sinceStart: 1.0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EarRestart.checkDelay(sinceStart: 30), 0.4, accuracy: 1e-9)      // 开了好久：等几百毫秒
        XCTAssertEqual(EarRestart.retryDelay(after: 0), 0.5)
        XCTAssertEqual(EarRestart.retryDelay(after: 1), 1.0)
        XCTAssertNil(EarRestart.retryDelay(after: 2))                                      // 最多 3 次
    }

    /// start 以后马上来一次「配置变了」：等满 1.5 秒看一眼，引擎还在跑：不动它
    func testConfigChangeRightAfterStartIsNotALoss() async throws {
        let rig = Rig()
        let k = rig.keeper()
        var rebuilt = 0, ignored = 0
        k.onRebuilt = { _, _, _ in rebuilt += 1 }
        k.onIgnored = { _ in ignored += 1 }
        let e = try await k.open()
        k.configChanged(e, why: "话筒的配置变了")
        k.configChanged(e, why: "话筒的配置变了")                                         // 一串来的只看一回
        await settle()
        XCTAssertEqual(rig.slept, [1.5])
        XCTAssertEqual(rebuilt, 0)
        XCTAssertEqual(ignored, 1)
        XCTAssertTrue(k.ear === e)
        XCTAssertEqual(rig.made.count, 1)
    }

    /// 「配置变了」、引擎真停了：换一只新的（不复用老的），会话不放掉；新的开了回声消除
    func testConfigChangeWithEngineStoppedRebuildsWithANewEar() async throws {
        let rig = Rig()
        let k = rig.keeper()
        var whys: [String] = []
        k.onRebuilt = { _, why, _ in whys.append(why) }
        let e = try await k.open()
        rig.clock += 10
        e.running = false
        k.configChanged(e, why: "话筒的配置变了")
        await settle()
        XCTAssertEqual(rig.slept, [0.4])
        XCTAssertEqual(whys, ["话筒的配置变了"])
        XCTAssertFalse(k.ear === e)
        XCTAssertEqual(k.ear?.n, 1)
        XCTAssertEqual(k.ear?.echo, true)
        XCTAssertEqual(e.released, [true])                                                // 重开：会话留着
        XCTAssertEqual(k.rules.rebuilds, 1)
    }

    /// 重开第一次失败、第二次成：隔 0.5 秒再试；失败的那次开了回声消除，第二次不开（退路）
    func testRebuildFirstTryFailsSecondWorks() async throws {
        let rig = Rig()
        let k = rig.keeper()
        var gaveUp = 0
        k.onGaveUp = { _, _ in gaveUp += 1 }
        _ = try await k.open()
        rig.failAt = [1]
        await k.rebuild("话筒没声音了")
        XCTAssertEqual(rig.tries, [true, true, false])
        XCTAssertEqual(rig.slept, [0.5])
        XCTAssertEqual(gaveUp, 0)
        XCTAssertEqual(k.ear?.echo, false)
        XCTAssertTrue(k.rules.echoOff)
    }

    /// 回声消除一开就失败：第一只就退到不开回声消除，照样开得起来
    func testEchoFailsFallsBackWithoutEcho() async throws {
        let rig = Rig()
        rig.echoFails = true
        let k = rig.keeper()
        let e = try await k.open()
        XCTAssertEqual(rig.tries, [true, false])
        XCTAssertFalse(e.echo)
        await k.rebuild("被打断了")
        XCTAssertEqual(rig.tries, [true, false, false])                                   // 以后都不开了
    }

    /// 3 次都开不起来：放弃，报最后那个错
    func testThreeFailuresGiveUpWithTheLastError() async throws {
        let rig = Rig()
        let k = rig.keeper()
        var got: [Error?] = []
        k.onGaveUp = { _, err in got.append(err) }
        _ = try await k.open()
        rig.failAt = [1, 2, 3]
        await k.rebuild("话筒的配置变了")
        XCTAssertEqual(rig.tries.count, 4)
        XCTAssertEqual(rig.slept, [0.5, 1.0])
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual((got.first ?? nil) as? Boom, Boom(n: 3))
    }

    /// 第一次开也一样：3 次不成才抛
    func testOpenRetriesThenThrows() async {
        let rig = Rig()
        rig.failAt = [0, 1, 2]
        let k = rig.keeper()
        do {
            _ = try await k.open()
            XCTFail("该抛")
        } catch {
            XCTAssertEqual(error as? Boom, Boom(n: 2))
        }
        XCTAssertEqual(rig.tries.count, 3)
        XCTAssertFalse(k.busy)
        XCTAssertNil(k.ear)
    }

    /// 一直「配置变了」、每回引擎都停（这回 Song 遇到的转圈）：第 3 回起不开回声消除，第 6 回停下报错，不再转
    func testConfigChangeStormStopsInsteadOfSpinning() async throws {
        let rig = Rig()
        let k = rig.keeper()
        var gaveUp: [Error?] = []
        k.onGaveUp = { _, err in gaveUp.append(err); k.close() }          // app 那头：报错、停听（这一场结束）
        _ = try await k.open()
        for _ in 0..<20 {
            guard let cur = k.ear else { break }
            cur.running = false
            k.configChanged(cur, why: "话筒的配置变了")
            await settle()
        }
        XCTAssertEqual(rig.made.count, 6)                                                  // 1 只 + 重开 5 回
        XCTAssertEqual(rig.made.map(\.echo), [true, true, true, false, false, false])
        XCTAssertEqual(gaveUp.count, 1)
        XCTAssertNil(gaveUp[0])                                                            // 不是开不起来，是太频繁
        XCTAssertNil(k.ear)
        XCTAssertEqual(k.rules.rebuilds, 6)
    }

    /// 一分钟以前的重开不算（隔得开的掉线照样重开）
    func testOldRebuildsAgeOut() {
        var r = EarRestart()
        for i in 0..<10 {
            XCTAssertEqual(r.willRebuild(now: Double(i) * 61), .rebuild(echo: true))
        }
        XCTAssertFalse(r.echoOff)
    }

    /// 关了以后：「配置变了」不理，重开不做；开到一半关了：新开的那只撒手
    func testClosedKeeperDoesNothing() async throws {
        let rig = Rig()
        let k = rig.keeper()
        let e = try await k.open()
        XCTAssertTrue(k.close() === e)
        e.running = false
        k.configChanged(e, why: "话筒的配置变了")
        await k.rebuild("话筒没声音了")
        await settle()
        XCTAssertEqual(rig.made.count, 1)
        XCTAssertTrue(rig.slept.isEmpty)
    }

    // ---------------------------------------------------------------- 报错写全
    func testErrorLineCarriesTheCode() {
        let s = AudioErrorLine.of(domain: "com.apple.coreaudio.avfaudio", code: 561_017_449,
                                  text: "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 561017449.)")
        XCTAssertTrue(s.hasPrefix("错误码 561017449 '!pri'（avfaudio）："), s)
        XCTAssertEqual(AudioErrorLine.of(domain: "NSOSStatusErrorDomain", code: -10868, text: "x"), "错误码 -10868（OSStatus）：x")
        XCTAssertEqual(AudioErrorLine.fourCC(Int(Int32(bitPattern: 0x77686174))), "what")
        XCTAssertNil(AudioErrorLine.fourCC(-50))
    }

    // ---------------------------------------------------------------- 诊断
    func testDiagLetterIsSmallAndHasNoContent() throws {
        let d = EarDiag(kind: .failed, entry: .companion, line: "话筒的配置变了\n错误码 561017449", code: 561_017_449, rebuilds: 2, ignored: 1, echo: true)
        let r = ButlerRequest.yiyeDiag(id: "x", diag: d, at: "2026-11-26T08:00:00+08:00", app: "0.7.28")
        XCTAssertEqual(r.ask, "look-check")                                                // 老大管家也认：只记数
        XCTAssertEqual(r.timing?["diag"], 1)
        XCTAssertEqual(r.timing?["code"], 561_017_449)
        XCTAssertEqual(r.timing?["entry"], 1)
        XCTAssertEqual(r.timing?["failed"], 1)
        XCTAssertEqual(r.timing?["rebuilds"], 2)
        XCTAssertNil(r.audio)
        XCTAssertNil(r.images)
        XCTAssertFalse(r.text.contains("\n"))
        // 108 那头只收 [A-Za-z]{1,16} 的键
        for k in r.timing!.keys { XCTAssertNotNil(k.range(of: "^[A-Za-z]{1,16}$", options: .regularExpression), k) }
        let long = EarDiag(kind: .stall, entry: .none, line: String(repeating: "卡", count: 500), stall: 1.234)
        XCTAssertEqual(long.line.count, 300)
        XCTAssertEqual(long.numbers["stallSec"], 1.23)
    }

    func testDiagGate() {
        var g = DiagGate()
        XCTAssertTrue(g.allow(.stall, now: 0, dayNumber: 1))
        XCTAssertFalse(g.allow(.stall, now: 30, dayNumber: 1))                             // 一分钟一封
        XCTAssertTrue(g.allow(.failed, now: 30, dayNumber: 1))                             // 别的种照寄
        XCTAssertTrue(g.allow(.stall, now: 61, dayNumber: 1))
        var n = 0
        for i in 0..<100 where g.allow(.stall, now: 200 + Double(i) * 61, dayNumber: 1) { n += 1 }
        XCTAssertEqual(n, DiagGate.perDay - 3)                                             // 一天 30 封
        XCTAssertTrue(g.allow(.stall, now: 99_999, dayNumber: 2))                          // 换天清零
    }

    func testStallRule() {
        XCTAssertNil(StallRule.isStall(posted: 10, ran: 10.9))
        XCTAssertEqual(StallRule.isStall(posted: 10, ran: 11.5)!, 1.5, accuracy: 1e-9)
    }
}
