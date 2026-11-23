import Foundation
import XCTest
@testable import YiyeKit

/// 088：听力按日期分组。跨午夜、新加坡时区、同一天 6 条 1→6、空的
final class ListenDaysTests: XCTestCase {
    let sh = TimeZone(identifier: "Asia/Shanghai")!
    let sg = TimeZone(identifier: "Asia/Singapore")!
    let ny = TimeZone(identifier: "America/New_York")!

    func at(_ s: String) -> Date { ISOTime.date(s)! }

    func testEmpty() {
        let none: [(id: String, at: Date)] = []
        XCTAssertEqual(ListenDays.group(none, timeZone: sh), [])
        XCTAssertEqual(ListenDays.flat([ListenDay<String>]()), [])
    }

    /// 每日简讯：第 n 篇是 08:00（+08:00）减 n 秒，送来的顺序随便，排出来 1→6
    func testSameDaySixInOrder() {
        let items: [(id: Int, at: Date)] = [4, 1, 6, 3, 5, 2].map { n in
            (id: n, at: at("2026-11-23T08:00:00+08:00").addingTimeInterval(-Double(n)))
        }
        let g = ListenDays.group(items, timeZone: sg)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].ids, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(g[0].start, at("2026-11-23T00:00:00+08:00"))
    }

    /// 23:59 和 00:01 是两天；新的一天在上面；拼回来就是原来「新的在前」
    func testAcrossMidnight() {
        let items: [(id: String, at: Date)] = [
            (id: "a", at: at("2026-11-22T23:59:00+08:00")),
            (id: "b", at: at("2026-11-23T00:01:00+08:00")),
            (id: "c", at: at("2026-11-22T07:59:59+08:00")),
            (id: "d", at: at("2026-11-23T07:59:58+08:00")),
        ]
        let g = ListenDays.group(items, timeZone: sh)
        XCTAssertEqual(g.map(\.ids), [["d", "b"], ["a", "c"]])
        XCTAssertEqual(g.map(\.start), [at("2026-11-23T00:00:00+08:00"), at("2026-11-22T00:00:00+08:00")])
        XCTAssertEqual(ListenDays.flat(g), items.sorted { $0.at > $1.at }.map(\.id))   // 播放顺序没变
    }

    /// 新加坡和上海一样是 +8；同样的时间在纽约落到前一天、跨午夜分组也跟着变
    func testSingaporeAndOtherZones() {
        let items: [(id: String, at: Date)] = [
            (id: "x", at: at("2026-11-23T07:59:59+08:00")),   // 新加坡 11-23 早上；纽约 11-22 晚上
            (id: "y", at: at("2026-11-23T13:30:00+08:00")),   // 新加坡 11-23 下午；纽约 11-23 00:30
        ]
        XCTAssertEqual(ListenDays.group(items, timeZone: sg).map(\.ids), [["y", "x"]])
        XCTAssertEqual(ListenDays.group(items, timeZone: ny).map(\.ids), [["y"], ["x"]])
    }

    func testSameTimeKeepsGivenOrder() {
        let t = at("2026-11-23T08:00:00+08:00")
        XCTAssertEqual(ListenDays.group([(id: "p", at: t), (id: "q", at: t)], timeZone: sh)[0].ids, ["p", "q"])
    }

    func testLabels() {
        let now = at("2026-11-23T00:30:00+08:00")
        XCTAssertEqual(ListenDays.label(at("2026-11-23T00:00:00+08:00"), now: now, timeZone: sg), .today)
        XCTAssertEqual(ListenDays.label(at("2026-11-22T23:59:00+08:00"), now: now, timeZone: sg), .yesterday)
        XCTAssertEqual(ListenDays.label(at("2026-11-21T08:00:00+08:00"), now: now, timeZone: sg),
                       .date(at("2026-11-21T00:00:00+08:00"), withYear: false))
        XCTAssertEqual(ListenDays.label(at("2025-12-31T08:00:00+08:00"), now: now, timeZone: sg),
                       .date(at("2025-12-31T00:00:00+08:00"), withYear: true))
        // 纽约这时候还是 11-22 上午：11-22 的组是今天
        XCTAssertEqual(ListenDays.label(at("2026-11-22T12:00:00-05:00"), now: now, timeZone: ny), .today)
    }
}
