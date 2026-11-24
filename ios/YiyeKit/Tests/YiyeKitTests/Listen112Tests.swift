import Foundation
import XCTest
@testable import YiyeKit

/// 112：听力只住小耳机（便签这边过滤、小耳机收全）、听完满 7 天自己清、整串循环
final class Listen112Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func days(_ d: Double) -> Date { t0.addingTimeInterval(d * 86_400) }

    // ---------------------------------------------------------------- 便签这边 / 小耳机
    func testNotesSideHidesListen() {
        XCTAssertFalse(ListenRule.showsInNotes(kind: "listen", trashed: false))        // 听力一条都不出现：主页、文件夹、搜索、计数
        XCTAssertTrue(ListenRule.showsInNotes(kind: "text", trashed: false))
        XCTAssertTrue(ListenRule.showsInNotes(kind: "photo", trashed: false))
        XCTAssertTrue(ListenRule.showsInNotes(kind: "voice", trashed: false))
        XCTAssertFalse(ListenRule.showsInNotes(kind: "text", trashed: true))
    }

    func testPlaylistTakesEveryListen() {
        // 不管 inListen 是不是 true（镜像导入、老版本送来的），listen 都在
        XCTAssertTrue(ListenRule.inPlaylist(kind: "listen", inListen: false, trashed: false))
        XCTAssertTrue(ListenRule.inPlaylist(kind: "listen", inListen: true, trashed: false))
        // Song 自己点小耳机放进来的普通便签：两边都在
        XCTAssertTrue(ListenRule.inPlaylist(kind: "text", inListen: true, trashed: false))
        XCTAssertTrue(ListenRule.showsInNotes(kind: "text", trashed: false))
        // 没点的普通便签不在；进了废纸篓的都不在
        XCTAssertFalse(ListenRule.inPlaylist(kind: "text", inListen: false, trashed: false))
        XCTAssertFalse(ListenRule.inPlaylist(kind: "listen", inListen: true, trashed: true))
    }

    func testNoNoteIsInNeitherPlace() {
        // 不许有哪条两边都看不到：没进废纸篓的，每一种 kind × inListen 的组合至少有一边收
        for kind in ["text", "photo", "voice", "listen", "deep", ""] {
            for inListen in [false, true] {
                let notes = ListenRule.showsInNotes(kind: kind, trashed: false)
                let play = ListenRule.inPlaylist(kind: kind, inListen: inListen, trashed: false)
                XCTAssertTrue(notes || play, "kind=\(kind) inListen=\(inListen) 两边都看不到")
            }
        }
    }

    func testListenOnlyFolder() {
        XCTAssertTrue(ListenRule.isListenOnlyFolder(kinds: ["listen", "listen"]))      // 英语、试听
        XCTAssertFalse(ListenRule.isListenOnlyFolder(kinds: ["listen", "text"]))       // 里面还有别的便签
        XCTAssertFalse(ListenRule.isListenOnlyFolder(kinds: []))                       // 空夹子照旧显示
        XCTAssertFalse(ListenRule.isListenOnlyFolder(kinds: ["text"]))
    }

    // ---------------------------------------------------------------- 听完自己清
    func testCleanAfterSevenDays() {
        XCTAssertFalse(ListenRule.shouldClean(kind: "listen", heardAt: days(0), now: days(6.9)))
        XCTAssertTrue(ListenRule.shouldClean(kind: "listen", heardAt: days(0), now: days(7)))
        XCTAssertTrue(ListenRule.shouldClean(kind: "listen", heardAt: days(0), now: days(30)))
    }

    func testNeverCleanUnheardOrPlainNotes() {
        XCTAssertFalse(ListenRule.shouldClean(kind: "listen", heardAt: nil, now: days(365)))      // 没听完的一直留着
        XCTAssertFalse(ListenRule.shouldClean(kind: "text", heardAt: days(0), now: days(365)))    // 普通便签一条都不自动清
        XCTAssertFalse(ListenRule.shouldClean(kind: "photo", heardAt: days(0), now: days(365)))
    }

    func testPutBackRestartsTheClock() {
        // 听完过的，从放回这天重新算
        let back = ListenRule.heardAtAfterPutBack(days(0), now: days(10))
        XCTAssertEqual(back, days(10))
        XCTAssertFalse(ListenRule.shouldClean(kind: "listen", heardAt: back, now: days(16.9)))
        XCTAssertTrue(ListenRule.shouldClean(kind: "listen", heardAt: back, now: days(17)))
        // 没听完过的，放回来还是没听完
        XCTAssertNil(ListenRule.heardAtAfterPutBack(nil, now: days(10)))
    }

    func testHeardAtOnlyFirstTime() {
        XCTAssertEqual(ListenRule.firstHeard(current: nil, now: days(1)), days(1))
        XCTAssertEqual(ListenRule.firstHeard(current: days(1), now: days(5)), days(1))            // 以后不改
    }

    /// 自动清走 111 的废纸篓：扔进去以后再留 3 天才真删（总共听完 + 7 天 + 3 天）
    func testCleanThenTrashKeepsThreeMore() {
        let heard = days(0)
        XCTAssertTrue(ListenRule.shouldClean(kind: "listen", heardAt: heard, now: days(7)))
        XCTAssertFalse(TrashRule.isExpired(trashedAt: days(7), now: days(9.9)))
        XCTAssertTrue(TrashRule.isExpired(trashedAt: days(7), now: days(10)))
    }

    // ---------------------------------------------------------------- 整串循环
    func testLoopAll() {
        XCTAssertEqual(ListenRule.nextIndex(after: 0, count: 3, loopAll: false), 1)
        XCTAssertEqual(ListenRule.nextIndex(after: 1, count: 3, loopAll: true), 2)
        XCTAssertNil(ListenRule.nextIndex(after: 2, count: 3, loopAll: false))                    // 关着：最后一条放完就停
        XCTAssertEqual(ListenRule.nextIndex(after: 2, count: 3, loopAll: true), 0)                // 开着：回到第一条
        XCTAssertEqual(ListenRule.nextIndex(after: 0, count: 1, loopAll: true), 0)                // 只有一条：接着放这条
        XCTAssertNil(ListenRule.nextIndex(after: 0, count: 1, loopAll: false))
        XCTAssertNil(ListenRule.nextIndex(after: 0, count: 0, loopAll: true))
    }

    /// 播放列表里放一整串：把 nextIndex 一路走下去，开着永远转，关着走完停
    func testWalkTheList() {
        var i = 0
        var seen: [Int] = [0]
        while let n = ListenRule.nextIndex(after: i, count: 3, loopAll: false) { i = n; seen.append(n) }
        XCTAssertEqual(seen, [0, 1, 2])
        i = 2
        var wrap: [Int] = []
        for _ in 0..<4 { i = ListenRule.nextIndex(after: i, count: 3, loopAll: true)!; wrap.append(i) }
        XCTAssertEqual(wrap, [0, 1, 2, 0])
    }

    // ---------------------------------------------------------------- 选词（写字页和小耳机共用）
    func testWordCleanForListenText() {
        XCTAssertEqual(WordMark.clean("snap election"), "snap election")
        XCTAssertEqual(WordMark.clean("Polymarket,"), "Polymarket")
        XCTAssertNil(WordMark.clean("87"))                                                        // 没有字母不弹菜单
    }
}
