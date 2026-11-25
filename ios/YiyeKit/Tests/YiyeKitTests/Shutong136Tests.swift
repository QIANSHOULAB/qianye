import XCTest
@testable import YiyeKit

/// 136 书童：白名单、受保护的不动、撤销一批全回去、原话能换回、回执那句话、接口的字段
final class Shutong136Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func note(_ id: String, _ md: String, folder: String? = nil, pinned: Bool = false, paper: Bool = false, kind: String = "text") -> ShutongNote {
        ShutongNote(id: id, markdown: md, folder: folder, pinned: pinned, trashed: false, trashedAt: nil, modifiedAt: t0,
                    spoken: "", kind: kind, manualPaper: paper, pinnedBy: false)
    }

    var base: [String: ShutongNote] {
        [
            "v": note("v", "嗯那个就是 B 线的 VMC-850 冷却液快没了，然后 1,280 件做完了", kind: "voice"),
            "t": note("t", "明天早上8点开会\n二楼会议室"),
            "pin": note("pin", "# 采购\n牛奶", pinned: true),
            "paper": note("paper", "# 读书\n第三章", paper: true),
            "old": note("old", "# 作废的会议\n改到下周", folder: "工作"),
        ]
    }

    // ---------------------------------------------------------------- 白名单
    func testOnlyWhitelistedOpsPass() {
        let acts = [ShutongAct(op: "delete", note: "t"), ShutongAct(op: "purge", note: "t"), ShutongAct(op: "open_app", note: "t"),
                    ShutongAct(op: "title", note: "t", title: "开会")]
        let c = ShutongPlan.check(acts, notes: base, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertEqual(c.ok.map(\.op), ["title"])
        XCTAssertEqual(c.skipped.count, 3)
        XCTAssertTrue(c.skipped.allSatisfy { $0.why.hasPrefix("不在白名单") })
    }

    func testMissingNoteIsSkipped() {
        let c = ShutongPlan.check([ShutongAct(op: "title", note: "nope", title: "x")], notes: base, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertTrue(c.ok.isEmpty)
        XCTAssertEqual(c.skipped.first?.why, "找不到这条")
    }

    func testMoveToUnknownFolderSkippedUnlessMadeInSameBatch() {
        let acts = [ShutongAct(op: "move", note: "t", folder: "机床"), ShutongAct(op: "folder", name: "机床"), ShutongAct(op: "move", note: "v", folder: "机床")]
        let c = ShutongPlan.check(acts, notes: base, folders: ["工作"], autoFolders: 0, mode: "chat")
        XCTAssertEqual(c.ok.map(\.op), ["folder", "move"])
        XCTAssertEqual(c.ok.last?.note, "v")
    }

    func testFolderCap() {
        let c = ShutongPlan.check([ShutongAct(op: "folder", name: "新的")], notes: base, folders: [], autoFolders: 10, mode: "tidy")
        XCTAssertTrue(c.ok.isEmpty)
        XCTAssertTrue(c.folderCapHit)
        let c2 = ShutongPlan.check([ShutongAct(op: "folder", name: "工作")], notes: base, folders: ["工作"], autoFolders: 10, mode: "tidy")
        XCTAssertFalse(c2.folderCapHit, "已经有的不算新建")
    }

    func testTidyModeOnlyTouchesTargetAndKeepsHisFolders() {
        let acts = [ShutongAct(op: "title", note: "t", title: "开会"), ShutongAct(op: "title", note: "old", title: "改"),
                    ShutongAct(op: "move", note: "old", folder: ""), ShutongAct(op: "trash", note: "t"),
                    ShutongAct(op: "tidy", note: "t", text: "明天 8 点开会")]
        let c = ShutongPlan.check(acts, notes: base, folders: ["工作"], autoFolders: 0, mode: "tidy", target: "t")
        XCTAssertEqual(c.ok.map(\.op), ["title"], "打字的只起标题；别的条不碰；收拾不扔；打字的不改正文")
    }

    func testTitleOnlyWhenNoneInTidy() {
        let n = ["h": note("h", "# 已经有\n字")]
        let c = ShutongPlan.check([ShutongAct(op: "title", note: "h", title: "新的")], notes: n, folders: [], autoFolders: 0, mode: "tidy", target: "h")
        XCTAssertTrue(c.ok.isEmpty)
        let c2 = ShutongPlan.check([ShutongAct(op: "title", note: "h", title: "新的")], notes: n, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertEqual(c2.ok.count, 1, "聊天窗里他让改就改")
    }

    func testTidyMustKeepNumbersAndCodes() {
        let bad = ShutongAct(op: "tidy", note: "v", text: "B 线冷却液快没了，1280 件做完了")
        let c = ShutongPlan.check([bad], notes: base, folders: [], autoFolders: 0, mode: "tidy", target: "v")
        XCTAssertTrue(c.ok.isEmpty)
        XCTAssertTrue(c.skipped.first?.why.contains("VMC-850") == true)
        let good = ShutongAct(op: "tidy", note: "v", text: "B 线 VMC-850 冷却液快没了。\n1280 件做完了。")
        XCTAssertEqual(ShutongPlan.check([good], notes: base, folders: [], autoFolders: 0, mode: "tidy", target: "v").ok.count, 1)
    }

    // ---------------------------------------------------------------- 受保护
    func testProtectedNotesUntouched() {
        let acts = [ShutongAct(op: "move", note: "pin", folder: ""), ShutongAct(op: "trash", note: "paper"),
                    ShutongAct(op: "title", note: "pin", title: "x"), ShutongAct(op: "merge", note: "t", into: "paper")]
        let c = ShutongPlan.check(acts, notes: base, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertTrue(c.ok.isEmpty, "\(c.ok)")
        XCTAssertEqual(c.skipped.count, 4)
    }

    func testNamedProtectedOnlyInChat() {
        let a = ShutongAct(op: "trash", note: "paper", named: true)
        XCTAssertEqual(ShutongPlan.check([a], notes: base, folders: [], autoFolders: 0, mode: "chat").ok.count, 1)
        XCTAssertTrue(ShutongPlan.check([a], notes: base, folders: [], autoFolders: 0, mode: "sweep").ok.isEmpty)
    }

    func testPinnedByShutongIsNotProtected() {
        var n = base
        n["pin"]?.pinnedBy = true
        XCTAssertFalse(n["pin"]!.locked)
        XCTAssertEqual(ShutongPlan.check([ShutongAct(op: "pin", note: "pin", on: false)], notes: n, folders: [], autoFolders: 0, mode: "chat").ok.count, 1)
    }

    func testTrashAndMergeNeedConfirm() {
        let c = ShutongPlan.check([ShutongAct(op: "title", note: "t", title: "x")], notes: base, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertFalse(c.needsConfirm)
        let c2 = ShutongPlan.check([ShutongAct(op: "trash", note: "t")], notes: base, folders: [], autoFolders: 0, mode: "chat")
        XCTAssertTrue(c2.needsConfirm)
    }

    // ---------------------------------------------------------------- 做 + 撤销
    func testUndoPutsEverythingBack() {
        var notes = base
        var folders = ["工作"]
        let start = notes
        let acts = ShutongPlan.check([
            ShutongAct(op: "folder", name: "机床"),
            ShutongAct(op: "tidy", note: "v", text: "B 线 VMC-850 冷却液快没了。1280 件做完了。"),
            ShutongAct(op: "title", note: "v", title: "B 线冷却液"),
            ShutongAct(op: "move", note: "v", folder: "机床"),
            ShutongAct(op: "pin", note: "t"),
            ShutongAct(op: "merge", note: "old", into: "t"),
            ShutongAct(op: "trash", note: "v"),
        ], notes: notes, folders: folders, autoFolders: 0, mode: "chat").ok
        let b = ShutongApply.run(acts, notes: &notes, folders: &folders, now: t0.addingTimeInterval(60), id: "B1")
        XCTAssertEqual(folders, ["工作", "机床"])
        XCTAssertEqual(notes["v"]?.folder, "机床")
        XCTAssertEqual(notes["v"]?.markdown, "# B 线冷却液\nB 线 VMC-850 冷却液快没了。1280 件做完了。")
        XCTAssertEqual(notes["v"]?.spoken, start["v"]?.markdown, "原话是收拾之前那一版")
        XCTAssertTrue(notes["v"]!.trashed)
        XCTAssertTrue(notes["t"]!.pinned && notes["t"]!.pinnedBy)
        XCTAssertTrue(notes["old"]!.trashed)
        XCTAssertTrue(notes["t"]!.markdown.contains("改到下周"))
        XCTAssertEqual(b.counts.tidied, 1)
        XCTAssertEqual(b.counts.titles, 1)
        XCTAssertEqual(b.counts.moved["机床"], 1)
        XCTAssertEqual(b.made, ["机床"])

        let kept = ShutongApply.undo(b, notes: &notes, folders: &folders)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertEqual(notes, start, "撤销以后跟没动过一样")
        XCTAssertEqual(folders, ["工作"], "这一批建的空文件夹拿掉")
    }

    func testUndoKeepsWhatHeEditedAfterwards() {
        var notes = base
        var folders: [String] = []
        let b = ShutongApply.run([ShutongAct(op: "title", note: "t", title: "开会"), ShutongAct(op: "pin", note: "v")],
                                 notes: &notes, folders: &folders, now: t0, id: "B2")
        notes["t"]?.markdown = "# 开会\n明天早上8点开会\n二楼会议室\n他自己加的一行"
        let kept = ShutongApply.undo(b, notes: &notes, folders: &folders)
        XCTAssertEqual(kept, ["t"])
        XCTAssertTrue(notes["t"]!.markdown.contains("他自己加的一行"), "他后来写的字不盖掉")
        XCTAssertFalse(notes["v"]!.pinned, "没改过的照样撤")
    }

    func testSpokenCanBeSwappedBack() {
        var notes = base
        var folders: [String] = []
        let raw = notes["v"]!.markdown
        _ = ShutongApply.run([ShutongAct(op: "tidy", note: "v", text: "收拾好的 VMC-850 1280")], notes: &notes, folders: &folders, now: t0, id: "B3")
        XCTAssertEqual(notes["v"]?.spoken, raw)
        // 再收拾一次：原话还是最早那一版
        _ = ShutongApply.run([ShutongAct(op: "tidy", note: "v", text: "又收拾 VMC-850 1280")], notes: &notes, folders: &folders, now: t0, id: "B4")
        XCTAssertEqual(notes["v"]?.spoken, raw, "原话一个字不丢")
        // 换回原话 = 把 spoken 放回正文
        notes["v"]?.markdown = notes["v"]!.spoken
        XCTAssertEqual(notes["v"]?.markdown, raw)
    }

    // ---------------------------------------------------------------- 字
    func testTitleHelpers() {
        XCTAssertEqual(ShutongText.setTitle("第一行\n第二行", "标题"), "# 标题\n第一行\n第二行")
        XCTAssertEqual(ShutongText.setTitle("# 旧\n正文", "新"), "# 新\n正文")
        XCTAssertEqual(ShutongText.heading("# 标题\n字"), "标题")
        XCTAssertNil(ShutongText.heading("## 小标题\n字"))
        XCTAssertEqual(ShutongText.body("# 标题\n字"), "字")
    }

    func testTokens() {
        XCTAssertEqual(ShutongText.tokens("A线早班 1,280件，3号机 VMC-850，12:30 开会"), ["1280", "3", "VMC-850", "12:30"])
        XCTAssertTrue(ShutongText.lost(from: "CNC 3 号机", to: "3号机").isEmpty, "没数字的词不管")
    }

    // ---------------------------------------------------------------- 回执
    func testReceiptLine() {
        var c = ShutongCounts()
        c.titles = 3
        c.moved = ["机床": 2]
        c.tidied = 1
        XCTAssertEqual(ShutongReceipt.line(c, zh: true), "起了 3 个标题，挪了 2 条进『机床』，收拾了 1 条语音")
        XCTAssertEqual(ShutongReceipt.line(c, zh: false), "Titled 3, moved 2 into “机床”, tidied 1 voice note")
        XCTAssertNil(ShutongReceipt.line(ShutongCounts(), zh: true))
    }

    // ---------------------------------------------------------------- 接口
    func testRequestAndReplyWire() throws {
        let ask = ShutongAsk(mode: "chat", notes: [ShutongCard(id: "a", title: "t", folder: "", head: "h", created: "c", modified: "m", chars: 3, kind: "text", locked: false)],
                             folders: [ShutongFolderInfo(name: "工作", auto: false, count: 2, samples: ["x"])], autoFolders: 1)
        let r = ButlerRequest.shutong(id: "R1", text: "把机床的放一起", ask: ask, at: "2026-11-25T08:00:00+08:00", app: "0.7.19")
        let d = try JSONEncoder().encode(r)
        let j = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(j["ask"] as? String, "shutong")
        XCTAssertEqual(j["note"] as? String, "")
        let s = j["shutong"] as! [String: Any]
        XCTAssertEqual(s["mode"] as? String, "chat")
        XCTAssertEqual(s["folderCap"] as? Int, 10)
        XCTAssertNil(s["full"], "空的不寄")

        let reply = #"{"v":1,"id":"R1","note":"","ok":true,"text":"放好了","stage":"shutong","host":"电脑","shutong":{"say":"放好了","acts":[{"op":"folder","name":"机床"},{"op":"pin","note":"a","on":"true"},{"op":"move","note":"a","folder":"机床","extra":1}],"need":[]}}"#
        let res = try JSONDecoder().decode(ButlerResult.self, from: Data(reply.utf8))
        XCTAssertEqual(res.shutong?.acts?.count, 3)
        XCTAssertEqual(res.shutong?.acts?[1].on, true)
        let env = MailEnvelope.result(res)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .shutong(res), "app 被杀过、不在等也认得是书童的回信")
    }

    func testNoteStateDue() {
        var s = ShutongNoteState()
        XCTAssertFalse(s.due(now: t0))
        s.phase = "queued"
        XCTAssertTrue(s.due(now: t0))
        s.phase = "sent"; s.sentAt = t0; s.tries = 1
        XCTAssertFalse(s.due(now: t0.addingTimeInterval(60)))
        XCTAssertTrue(s.due(now: t0.addingTimeInterval(21 * 60)))
        XCTAssertEqual(ShutongNoteState.decode(s.encoded()), s)
    }
}
