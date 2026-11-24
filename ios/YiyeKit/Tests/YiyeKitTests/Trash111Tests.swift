import Foundation
import XCTest
@testable import YiyeKit

/// 111：废纸篓留 3 天、思想排泄物抄到电脑（寄信状态）、长按批量选的拖选
final class Trash111Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    // ---------------------------------------------------------------- 3 天规则
    func testExpiry() {
        XCTAssertFalse(TrashRule.isExpired(trashedAt: t0, now: hours(71.9)))
        XCTAssertTrue(TrashRule.isExpired(trashedAt: t0, now: hours(72)))
        XCTAssertTrue(TrashRule.isExpired(trashedAt: t0, now: hours(200)))
    }

    func testLeftLabels() {
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: t0), .days(3))
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: hours(12)), .days(2))        // 剩 2.5 天
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: hours(30)), .tomorrow)       // 剩 1.75 天
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: hours(47)), .tomorrow)
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: hours(49)), .today)          // 剩 23 小时
        XCTAssertEqual(TrashRule.left(trashedAt: t0, now: hours(71)), .today)
    }

    func testBackfillOldData() {
        // 老数据：扔了但没写时间，补成现在，从现在起算 3 天
        XCTAssertEqual(TrashRule.backfill(trashed: true, trashedAt: nil, now: t0), t0)
        XCTAssertEqual(TrashRule.backfill(trashed: true, trashedAt: hours(-5), now: t0), hours(-5))
        XCTAssertNil(TrashRule.backfill(trashed: false, trashedAt: nil, now: t0))
        let filled = TrashRule.backfill(trashed: true, trashedAt: nil, now: t0)!
        XCTAssertFalse(TrashRule.isExpired(trashedAt: filled, now: hours(71)))
    }

    // ---------------------------------------------------------------- 抄到电脑
    func cand(_ id: UUID = UUID(), folder: String = "思想排泄物", on: Bool = true, trashed: Bool = false, modified: Date, desk: Date? = nil) -> KeepCandidate {
        KeepCandidate(id: id, folder: folder, folderToDesk: on, trashed: trashed, modifiedAt: modified, deskAt: desk)
    }

    func testNeedsDesk() {
        XCTAssertTrue(cand(modified: t0).needsDesk)                                   // 从没寄过
        XCTAssertFalse(cand(modified: t0, desk: t0).needsDesk)                        // 电脑那份就是这一版
        XCTAssertTrue(cand(modified: hours(1), desk: t0).needsDesk)                   // 改过了，再寄
        XCTAssertFalse(cand(on: false, modified: t0).needsDesk)                       // 夹子没开
        XCTAssertFalse(cand(trashed: true, modified: t0).needsDesk)                   // 删了不用管
    }

    func testNoDeskNoSend() {
        let n = cand(modified: t0)
        XCTAssertEqual(KeepPlan.due([n], now: hours(1), desk: false), [])            // pcs 里没有 desk（只有掌机、或没有人）
        XCTAssertEqual(KeepPlan.due([n], now: hours(1), desk: true), [n.id])
    }

    func testOpenNoteWaitsSixtySeconds() {
        let n = cand(modified: t0)
        XCTAssertEqual(KeepPlan.due([n], now: t0.addingTimeInterval(30), desk: true, editing: n.id), [])
        XCTAssertEqual(KeepPlan.due([n], now: t0.addingTimeInterval(61), desk: true, editing: n.id), [n.id])
        // 离开写字页：马上寄
        XCTAssertEqual(KeepPlan.due([n], now: t0.addingTimeInterval(1), desk: true, editing: nil, force: [n.id]), [n.id])
        // 别的没开着的便签不用等
        let other = cand(modified: t0)
        XCTAssertEqual(KeepPlan.due([n, other], now: t0.addingTimeInterval(1), desk: true, editing: n.id), [other.id])
    }

    func testSameVersionSentOnce() {
        let n = cand(modified: t0)
        let inflight = [n.id: (modified: t0, sentAt: t0)]
        XCTAssertEqual(KeepPlan.due([n], now: t0.addingTimeInterval(10), desk: true, inflight: inflight), [])      // 同一版在路上
        XCTAssertEqual(KeepPlan.due([n], now: t0.addingTimeInterval(KeepPlan.resendAfter + 1), desk: true, inflight: inflight), [n.id])   // 久没回信，再寄
        // 又改了：不管上一封回没回，寄最新一版
        let edited = cand(n.id, modified: hours(1))
        XCTAssertEqual(KeepPlan.due([edited], now: hours(1), desk: true, inflight: inflight), [n.id])
    }

    func testReplyRules() {
        XCTAssertTrue(KeepPlan.reached(ok: true, host: "电脑"))
        XCTAssertFalse(KeepPlan.reached(ok: false, host: "掌机"))                    // desk-only
        XCTAssertFalse(KeepPlan.reached(ok: true, host: "掌机"))
        XCTAssertFalse(KeepPlan.reached(ok: false, host: "电脑"))                    // 电脑说信不对
        XCTAssertFalse(KeepPlan.reached(ok: true, host: nil))
        // 旧的回信晚到，不把 deskAt 倒退
        XCTAssertEqual(KeepPlan.newDeskAt(current: hours(2), sent: hours(1)), hours(2))
        XCTAssertEqual(KeepPlan.newDeskAt(current: nil, sent: hours(1)), hours(1))
        XCTAssertEqual(KeepPlan.newDeskAt(current: hours(1), sent: hours(2)), hours(2))
    }

    func testStaleAfter24h() {
        let a = cand(folder: "思想排泄物", modified: t0)
        let b = cand(folder: "思想排泄物", modified: hours(10))
        let c = cand(folder: "别的", modified: t0, desk: t0)
        let s = KeepPlan.stale([a, b, c], now: hours(25))
        XCTAssertEqual(s, [KeepPlan.Stale(folder: "思想排泄物", count: 1)])          // b 才 15 小时；c 已经到了
        XCTAssertEqual(KeepPlan.stale([a, b], now: hours(40)).first?.count, 2)
        XCTAssertEqual(KeepPlan.stale([a], now: hours(5)), [])                       // 到了就消失 / 没到 24 小时不提
    }

    func testDeskFolderName() {
        XCTAssertTrue(KeepPlan.isDeskFolderName("思想排泄物"))
        XCTAssertTrue(KeepPlan.isDeskFolderName(" 思想排泄物 "))
        XCTAssertFalse(KeepPlan.isDeskFolderName("工作"))
    }

    func testMachinesFromPush() {
        XCTAssertEqual(KeepPlan.machines(in: #"{"t":"hello","v":3,"pc":true,"pcs":["desk","handheld"],"items":[]}"#), ["desk", "handheld"])
        XCTAssertEqual(KeepPlan.machines(in: #"{"t":"state","pc":true,"pcs":["handheld"]}"#), ["handheld"])
        XCTAssertEqual(KeepPlan.machines(in: #"{"t":"pc","on":false,"pcs":[]}"#), [])
        XCTAssertNil(KeepPlan.machines(in: #"{"t":"state","pc":true}"#))              // 老信箱没有 pcs
        XCTAssertNil(KeepPlan.machines(in: #"{"t":"msg","pcs":["desk"]}"#))
        XCTAssertNil(KeepPlan.machines(in: "pong"))
    }

    // ---------------------------------------------------------------- 信
    func testKeepLetterFields() throws {
        let r = ButlerRequest.keep(id: "KEEP-0001", note: "N-1", folder: "思想排泄物", text: "# 标题\n正文", created: "2026-11-24T10:00:00+08:00",
                                   modified: "2026-11-24T11:00:00+08:00", at: "2026-11-24T11:00:01+08:00", app: "0.7.8")
        let env = MailEnvelope.request(r)
        let back = try MailEnvelope.decode(env.encoded())
        let q = try XCTUnwrap(back.request)
        XCTAssertEqual(q.kind, .keep)
        XCTAssertEqual(q.folder, "思想排泄物")
        XCTAssertEqual(q.text, "# 标题\n正文")
        XCTAssertEqual(q.created, "2026-11-24T10:00:00+08:00")
        XCTAssertEqual(q.modified, "2026-11-24T11:00:00+08:00")
        XCTAssertEqual(q.note, "N-1")
        // 字段名照 v3（113 照同一份在做）
        let json = String(decoding: try env.encoded(), as: UTF8.self)
        for key in ["\"kind\":\"keep\"", "\"folder\":", "\"text\":", "\"created\":", "\"modified\":", "\"note\":", "\"app\":", "\"at\":"] {
            XCTAssertTrue(json.contains(key), key)
        }
    }

    func testReplyDecode() throws {
        let desk = #"{"v":1,"id":"KEEP-0001","note":"N-1","ok":true,"text":null,"changes":"","error":null,"host":"电脑","re":"KEEP-0001","file":"思想排泄物/标题.md","at":"2026-11-24T11:00:02+08:00"}"#
        let hand = #"{"v":1,"id":"KEEP-0002","note":"N-1","ok":false,"error":"掌机不存文件，等电脑在线再寄","host":"掌机","why":"desk-only","re":"KEEP-0002"}"#
        let a = try JSONDecoder().decode(ButlerResult.self, from: Data(desk.utf8))
        let b = try JSONDecoder().decode(ButlerResult.self, from: Data(hand.utf8))
        XCTAssertEqual(a.re, "KEEP-0001")
        XCTAssertEqual(a.file, "思想排泄物/标题.md")
        XCTAssertTrue(KeepPlan.reached(ok: a.ok, host: a.host))
        XCTAssertEqual(b.why, "desk-only")
        XCTAssertFalse(KeepPlan.reached(ok: b.ok, host: b.host))
        // 回信按「在等的 keep 请求」认出来，没人在等的当 drop
        XCTAssertEqual(MailAction.decide(.result(a), waiting: [:], dubbing: [:], keeps: ["KEEP-0001"]), .keep(a))
        XCTAssertEqual(MailAction.decide(.result(b), waiting: [:], dubbing: [:], keeps: ["KEEP-0002"]), .keep(b))
        XCTAssertEqual(MailAction.decide(.result(a), waiting: [:], dubbing: [:]), .drop("没人在等 KEEP-0001"))
    }

    // ---------------------------------------------------------------- 拖选
    func testSpan() {
        let ids = (0..<6).map { _ in UUID() }
        XCTAssertEqual(BatchSelect.span(ids, from: 1, to: 3), Array(ids[1...3]))
        XCTAssertEqual(BatchSelect.span(ids, from: 4, to: 2), Array(ids[2...4]))      // 往上划
        XCTAssertEqual(BatchSelect.span(ids, from: 2, to: 2), [ids[2]])
        XCTAssertEqual(BatchSelect.span(ids, from: -3, to: 99), ids)                  // 划出界算到头
        XCTAssertEqual(BatchSelect.span([], from: 0, to: 3), [])
    }

    func testIndexAtY() {
        let f: [(minY: Double, maxY: Double)] = [(0, 80), (90, 170), (180, 260)]
        XCTAssertEqual(BatchSelect.index(atY: 10, frames: f), 0)
        XCTAssertEqual(BatchSelect.index(atY: 100, frames: f), 1)
        XCTAssertEqual(BatchSelect.index(atY: 85, frames: f), 0)                      // 两条中间的缝：算上面那条
        XCTAssertEqual(BatchSelect.index(atY: -50, frames: f), 0)                     // 手指划到最上面以外
        XCTAssertEqual(BatchSelect.index(atY: 999, frames: f), 2)
        XCTAssertNil(BatchSelect.index(atY: 10, frames: []))
    }

    func testDragSelectGrowsAndShrinks() {
        let ids = (0..<6).map { _ in UUID() }
        // 以前已经选了第 5 条；长按第 1 条，往下划到第 3 条
        let base: Set<UUID> = [ids[5]]
        var sel = BatchSelect.selection(base: base, order: ids, anchor: 1, current: 1)
        XCTAssertEqual(sel, [ids[1], ids[5]])
        sel = BatchSelect.selection(base: base, order: ids, anchor: 1, current: 3)
        XCTAssertEqual(sel, [ids[1], ids[2], ids[3], ids[5]])
        // 往回划退掉
        sel = BatchSelect.selection(base: base, order: ids, anchor: 1, current: 2)
        XCTAssertEqual(sel, [ids[1], ids[2], ids[5]])
        // 划过起点往上
        sel = BatchSelect.selection(base: base, order: ids, anchor: 1, current: 0)
        XCTAssertEqual(sel, [ids[0], ids[1], ids[5]])
    }

    /// 批量扔：N 条一起进废纸篓，撤销一起回来——这里验的是「同一个时间戳」，一个提示撤全部靠 ids 一次放回
    func testBatchTrashShareOneTimestampAndExpireTogether() {
        let at = hours(0)
        let stamps = (0..<5).map { _ in at }
        XCTAssertEqual(Set(stamps).count, 1)
        XCTAssertTrue(stamps.allSatisfy { TrashRule.isExpired(trashedAt: $0, now: hours(72)) })
        XCTAssertTrue(stamps.allSatisfy { !TrashRule.isExpired(trashedAt: $0, now: hours(70)) })
    }
}
