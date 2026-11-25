import Foundation
import XCTest
@testable import YiyeKit

/// 144：听力循环挑哪几天
final class Listen144Tests: XCTestCase {
    let today = "2026-11-25", d24 = "2026-11-24", d23 = "2026-11-23", d22 = "2026-11-22"
    /// 队：今天 3 篇、24 号 2 篇、23 号 2 篇、22 号 1 篇（列表从上到下的顺序）
    lazy var q = [today, today, today, d24, d24, d23, d23, d22]
    var days: [String] { ListenLoop.ordered(q) }

    func loop(_ lit: Set<String>) -> ListenLoop { ListenLoop(on: true, lit: lit, litDay: today) }

    func testKey() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ListenLoop.key(Date(timeIntervalSince1970: 1_800_000_000), timeZone: utc), "2027-01-15")
        XCTAssertEqual(ListenLoop.ordered(q), [today, d24, d23, d22])
    }

    // ---------------------------------------------------------------- 下一篇是谁

    func testOneDay() {
        let l = loop([d24])
        XCTAssertEqual(l.next(after: 3, dayOf: q), 4)
        XCTAssertEqual(l.next(after: 4, dayOf: q), 3)          // 那天最后一篇放完回那天第一篇，不进别的天
    }

    func testTwoDaysNotNextToEachOther() {
        let l = loop([today, d23])
        XCTAssertEqual(l.next(after: 1, dayOf: q), 2)
        XCTAssertEqual(l.next(after: 2, dayOf: q), 5)          // 跳过 24 号
        XCTAssertEqual(l.next(after: 5, dayOf: q), 6)
        XCTAssertEqual(l.next(after: 6, dayOf: q), 0)          // 回亮着的第一篇
    }

    func testAllLit() {
        var l = loop([d24])
        l.lightAll(today: today)
        XCTAssertTrue(l.allLit(days))
        XCTAssertEqual(l.next(after: 6, dayOf: q), 7)
        XCTAssertEqual(l.next(after: 7, dayOf: q), 0)
    }

    func testStartOutsideLit() {
        let l = loop([d23])
        XCTAssertEqual(l.next(after: 0, dayOf: q), 5)          // 起点在今天（没亮）：接后面第一篇亮着的
        XCTAssertEqual(l.next(after: 7, dayOf: q), 5)          // 起点在最后（没亮）：回亮着的第一篇
    }

    func testOnlyOneTrackLit() {
        let l = loop([d22])
        XCTAssertEqual(l.next(after: 7, dayOf: q), 7)          // 亮着的只有一篇：自己再来
        XCTAssertEqual(l.next(after: 2, dayOf: q), 7)
    }

    func testLoopOffIsOldBehaviour() {
        var l = loop([d24])
        l.on = false
        XCTAssertEqual(l.next(after: 4, dayOf: q), 5)          // 关着：照整张单子往下
        XCTAssertNil(l.next(after: 7, dayOf: q))               // 到最后停
        XCTAssertNil(l.next(after: 0, dayOf: []))
    }

    // ---------------------------------------------------------------- 点小圈、点一篇

    func testToggle() {
        var l = loop([today])
        l.toggle(d23, days: days, today: today)
        XCTAssertEqual(l.lit, [today, d23])
        l.toggle(today, days: days, today: today)
        XCTAssertEqual(l.lit, [d23])
        XCTAssertTrue(l.on)
    }

    func testToggleOffFromAll() {
        var l = loop([ListenLoop.every])
        l.toggle(d24, days: days, today: today)
        XCTAssertEqual(l.lit, [today, d23, d22])
        XCTAssertFalse(l.isLit(d24))
    }

    func testLastDayOffTurnsLoopOff() {
        var l = loop([d23])
        l.toggle(d23, days: days, today: today)
        XCTAssertFalse(l.on)                                   // 最后一天点灭 = 关 🔁
        XCTAssertEqual(l.lit, [today])                         // 再开 🔁 就是只亮今天
        XCTAssertNil(l.next(after: 7, dayOf: q))
    }

    func testPlayUnlitDayNarrowsToThatDay() {
        var l = loop([today, d24])
        l.played(day: d23, days: days, today: today)
        XCTAssertEqual(l.lit, [d23])
        l.played(day: d23, days: days, today: today)           // 亮着的照常
        XCTAssertEqual(l.lit, [d23])
        var off = ListenLoop(on: false, lit: [today], litDay: today)
        off.played(day: d23, days: days, today: today)         // 🔁 关着：什么都不动
        XCTAssertEqual(off.lit, [today])
    }

    // ---------------------------------------------------------------- 过了一天、新稿子、老设置

    func testNewDayBackToToday() {
        var l = ListenLoop(on: true, lit: [d23, d24], litDay: d24)
        l.open(today: today)
        XCTAssertEqual(l.lit, [today])
        XCTAssertEqual(l.litDay, today)
        XCTAssertTrue(l.on)                                    // 🔁 照旧开着
        var same = ListenLoop(on: true, lit: [d23, d24], litDay: today)
        same.open(today: today)
        XCTAssertEqual(same.lit, [d23, d24])                   // 同一天里他挑的记住
    }

    func testNewArrivalJoinsWhenTodayLit() {
        let l = loop([today, d23])
        // 放到 23 号最后一篇时，今天来了第 4 篇（排在今天最前）
        let q2 = [today] + q
        XCTAssertEqual(l.next(after: 7, dayOf: q2), 0)         // 回第一篇：就是新来的
        XCTAssertEqual(l.next(after: 0, dayOf: q2), 1)
        let notToday = loop([d23])
        XCTAssertEqual(notToday.next(after: 7, dayOf: q2), 6)  // 今天没亮：新来的不排
    }

    func testEmptyLitDayFallsBackToTopDay() {
        // 今天亮着，但今天还没稿子：亮最上面那天，免得循环空转
        let l = loop([today])
        let q3 = [d24, d24, d23]
        XCTAssertEqual(l.shown(ListenLoop.ordered(q3)), [d24])
        XCTAssertEqual(l.next(after: 1, dayOf: q3), 0)
    }

    func testMigrateOldSetting() {
        let old = ListenLoop.load(loopAll: true, lit: nil, litDay: nil, today: today)
        XCTAssertTrue(old.on)
        XCTAssertTrue(old.allLit(days))
        var o = old
        o.open(today: today)
        XCTAssertTrue(o.allLit(days))                          // 迁过来那天不被翻回只亮今天
        let off = ListenLoop.load(loopAll: false, lit: nil, litDay: nil, today: today)
        XCTAssertFalse(off.on)
        XCTAssertEqual(off.lit, [today])
        let saved = ListenLoop.load(loopAll: true, lit: [d23], litDay: d24, today: today)
        XCTAssertEqual(saved.lit, [d23])
        XCTAssertEqual(saved.litDay, d24)
    }
}
