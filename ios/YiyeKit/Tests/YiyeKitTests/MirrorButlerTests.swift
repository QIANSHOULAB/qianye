import Foundation
import XCTest
@testable import YiyeKit

/// 假 iCloud：占位文件「.名字.icloud」，ensureDownloaded 时才把真文件放出来
final class FakeICloud: FileAccess {
    let base = PlainFileAccess()
    var stash: [String: Data] = [:]   // 真文件名 → 内容（macOS 的临时目录有 /var → /private/var 的软链，按全路径对不上）
    var downloads = 0
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func move(_ from: URL, to: URL) throws { try base.move(from, to: to) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func list(_ dir: URL) throws -> [URL] { try base.list(dir) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func makeDir(_ url: URL) throws { try base.makeDir(url) }
    func modified(_ url: URL) -> Date? { base.modified(url) }
    func ensureDownloaded(_ url: URL) -> Bool {
        if base.exists(url) { return true }
        guard let d = stash[url.lastPathComponent] else { return false }
        downloads += 1
        try? base.write(d, to: url)
        try? base.remove(url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud"))
        return true
    }
    /// 别的机器写进来、手机上还只是占位
    func plantPlaceholder(_ real: URL, _ data: Data) throws {
        stash[real.lastPathComponent] = data
        try base.write(Data(), to: real.deletingLastPathComponent().appendingPathComponent(".\(real.lastPathComponent).icloud"))
    }
}

final class MirrorButlerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-\(UUID().uuidString)/一叶笺", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testNewEditRenameDeleteImageImport() throws {
        let fs = PlainFileAccess()
        let mirror = MirrorFolder(root: root, fs: fs)
        try mirror.prepare()
        let id = UUID(uuidString: "9F1C2D4E-0B7A-4C61-9E52-2A6F1D3B8C70")!
        let t0 = Date(timeIntervalSince1970: 1_763_596_800)
        var meta = MirrorMeta(id: id, created: t0, modified: t0, folder: "工作", pinned: true, color: "yellow", kind: "photo")

        // 新建
        try mirror.save(meta, body: "# 11月3日交接\nA线早班 1280件")
        XCTAssertEqual(names(mirror.notesDir), ["11月3日交接-9F1C2D4E.md"])
        let file = try String(contentsOf: mirror.notesDir.appendingPathComponent("11月3日交接-9F1C2D4E.md"), encoding: .utf8)
        XCTAssertTrue(file.hasPrefix("---\nid: 9F1C2D4E-0B7A-4C61-9E52-2A6F1D3B8C70\ncreated: "))
        XCTAssertTrue(file.contains("folder: \"工作\"\npinned: true\ncolor: yellow\nkind: photo\n---\n\n# 11月3日交接\nA线早班 1280件\n"))

        // 改（标题不变）
        meta.modified = t0.addingTimeInterval(60)
        try mirror.save(meta, body: "# 11月3日交接\nA线早班 1,280件")
        XCTAssertEqual(names(mirror.notesDir), ["11月3日交接-9F1C2D4E.md"])
        XCTAssertTrue(try String(contentsOf: mirror.notesDir.appendingPathComponent("11月3日交接-9F1C2D4E.md"), encoding: .utf8).contains("1,280件"))

        // 改名（标题改了）
        try mirror.save(meta, body: "# 早班交接 / 11月3日\nA线早班 1,280件")
        XCTAssertEqual(names(mirror.notesDir), ["早班交接 11月3日-9F1C2D4E.md"])

        // 插图
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try mirror.writeAttachment(jpg, relative: "附件/9F1C2D4E-a1b2c3.jpg")
        try mirror.save(meta, body: "# 早班交接 / 11月3日\nA线早班 1,280件\n![](附件/9F1C2D4E-a1b2c3.jpg)")
        XCTAssertEqual(names(mirror.attachDir), ["9F1C2D4E-a1b2c3.jpg"])
        let refs = Markdown5.imagePaths(try String(contentsOf: mirror.notesDir.appendingPathComponent("早班交接 11月3日-9F1C2D4E.md"), encoding: .utf8))
        XCTAssertEqual(refs, ["附件/9F1C2D4E-a1b2c3.jpg"])
        XCTAssertTrue(refs.allSatisfy { mirror.hasAttachment($0) })

        // 删 → 废纸篓；撤销 → 回来
        try mirror.trash(id)
        XCTAssertEqual(names(mirror.notesDir), [])
        XCTAssertEqual(names(mirror.trashDir), ["早班交接 11月3日-9F1C2D4E.md"])
        try mirror.restore(id)
        XCTAssertEqual(names(mirror.notesDir), ["早班交接 11月3日-9F1C2D4E.md"])
        XCTAssertEqual(names(mirror.trashDir), [])

        // 导入：一条不落，字段都对
        let other = UUID()
        try mirror.save(MirrorMeta(id: other, created: t0, modified: t0), body: "")       // 空标题 → 只用短 id
        XCTAssertTrue(names(mirror.notesDir).contains("\(MirrorFormat.shortID(other)).md"))
        try fs.write(Data("别处写的，没有 front matter".utf8), to: mirror.notesDir.appendingPathComponent("手写.md"))
        let imp = mirror.importAll()
        XCTAssertEqual(imp.notes.count, 3)
        let back = imp.notes.first { $0.meta.id == id }!
        XCTAssertEqual(back.meta.folder, "工作")
        XCTAssertTrue(back.meta.pinned)
        XCTAssertEqual(back.meta.color, "yellow")
        XCTAssertEqual(back.meta.kind, "photo")
        XCTAssertEqual(Int(back.meta.created.timeIntervalSince1970), Int(t0.timeIntervalSince1970))
        XCTAssertEqual(back.body, "# 早班交接 / 11月3日\nA线早班 1,280件\n![](附件/9F1C2D4E-a1b2c3.jpg)")
        XCTAssertTrue(imp.notes.contains { $0.adopted && $0.body == "别处写的，没有 front matter" })
    }

    func testImportWaitsForICloudPlaceholders() throws {
        let fs = FakeICloud()
        let mirror = MirrorFolder(root: root, fs: fs)
        try mirror.prepare()
        let id = UUID()
        let text = MirrorFormat.render(MirrorMeta(id: id, created: Date(), modified: Date()), body: "电脑上写的")
        try fs.plantPlaceholder(mirror.notesDir.appendingPathComponent("电脑上写的-\(MirrorFormat.shortID(id)).md"), Data(text.utf8))
        XCTAssertEqual(names(mirror.notesDir).count, 1)
        XCTAssertTrue(names(mirror.notesDir)[0].hasSuffix(".icloud"))
        let imp = mirror.importAll()
        XCTAssertEqual(imp.notes.map(\.body), ["电脑上写的"])
        XCTAssertEqual(fs.downloads, 1)
        XCTAssertEqual(imp.pending, [])
    }

    func testFrontMatterQuotes() {
        let m = MirrorMeta(id: UUID(), created: Date(), modified: Date(), folder: "工作 \"一\" \\ 二")
        let back = MirrorFormat.parse(MirrorFormat.render(m, body: "a\n---\nb"))
        XCTAssertEqual(back.meta?.folder, m.folder)
        XCTAssertEqual(back.body, "a\n---\nb")
    }

    // ---------------------------------------------------------------- 大管家
    let sampleResult = """
    {
      "v": 1,
      "id": "REQ-1",
      "note": "NOTE-1",
      "ok": true,
      "text": "# 11月3日交接\\n\\nA线早班 1,280件\\n早班交接完毕",
      "changes": "改了 3 处：128O→1280，□班→早班，补了标题",
      "error": null,
      "model": "claude-opus-5-5",
      "at": "2026-11-20T08:01:10+08:00"
    }
    """

    func testRequestFileIsPartThenJSON() throws {
        let fs = PlainFileAccess()
        let ch = ButlerChannel(root: root, fs: fs)
        let r = ButlerRequest(id: "REQ-1", note: "NOTE-1", kind: .photo, text: "A线早班 128O件", images: ["附件/9F1C2D4E-原图-1.jpg"], unsure: ["128O件"], at: "2026-11-20T08:00:00+08:00", app: "0.1.0")
        try ch.submit(r)
        XCTAssertEqual(names(ch.inbox), ["REQ-1.json"])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: ch.inbox.appendingPathComponent("REQ-1.json"))) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["kind"] as? String, "photo")
        XCTAssertEqual(obj["ask"] as? String, "fix")
        XCTAssertEqual(obj["images"] as? [String], ["附件/9F1C2D4E-原图-1.jpg"])
        XCTAssertEqual(obj["unsure"] as? [String], ["128O件"])
        XCTAssertEqual(obj["app"] as? String, "0.1.0")
        let raw = try String(contentsOf: ch.inbox.appendingPathComponent("REQ-1.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("附件/9F1C2D4E"))   // 斜杠不转义
        // 打的字：没有 images 字段
        try ch.submit(ButlerRequest(id: "REQ-2", note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: "t", app: "0.1.0"))
        let obj2 = try JSONSerialization.jsonObject(with: Data(contentsOf: ch.inbox.appendingPathComponent("REQ-2.json"))) as! [String: Any]
        XCTAssertNil(obj2["images"])
        XCTAssertNil(obj2["unsure"])
    }

    /// 四条路：自动换上、换回原文、改过不覆盖、出错
    func testFourPaths() throws {
        let fs = PlainFileAccess()
        let ch = ButlerChannel(root: root, fs: fs)
        try ch.prepare()
        let sent = "# 11月3日交接\n\nA线早班 128O件\n□班交接完毕"

        // 1. 自动换上
        var st = ButlerNoteState()
        st.submitted(id: "REQ-1", text: sent, at: Date())
        try fs.write(Data(sampleResult.utf8), to: ch.outbox.appendingPathComponent("REQ-1.json"))
        let r1 = try XCTUnwrap(ch.result("REQ-1"))
        let newText = st.receive(r1, current: sent, currentUnsure: "20,5")
        XCTAssertEqual(newText, "# 11月3日交接\n\nA线早班 1,280件\n早班交接完毕")
        XCTAssertEqual(st.phase, .applied)
        XCTAssertEqual(st.count, 2)
        XCTAssertEqual(st.changes, "改了 3 处：128O→1280，□班→早班，补了标题")
        ch.removeResult("REQ-1")
        XCTAssertNil(ch.result("REQ-1"))

        // 2. 换回原文
        let back = st.revert()
        XCTAssertEqual(back, sent)
        XCTAssertEqual(st.phase, .none)

        // 3. 这期间改过：不覆盖，等着点
        var st3 = ButlerNoteState()
        st3.submitted(id: "REQ-1", text: sent, at: Date())
        let edited = sent + "\n晚班记得加冷却液"
        XCTAssertNil(st3.receive(r1, current: edited))
        XCTAssertEqual(st3.phase, .offer)
        let taken = st3.acceptOffer(current: edited)
        XCTAssertEqual(taken, r1.text)
        XCTAssertEqual(st3.phase, .applied)
        XCTAssertEqual(st3.revert(), edited)

        // 4. 出错：原样显示
        var st4 = ButlerNoteState()
        st4.submitted(id: "REQ-4", text: sent, at: Date())
        let bad = ButlerResult(id: "REQ-4", note: "NOTE-1", ok: false, text: nil, changes: nil, error: "iCloud 还没把原图同步过来：附件/9F1C2D4E-原图-1.jpg")
        XCTAssertNil(st4.receive(bad, current: sent))
        XCTAssertEqual(st4.phase, .failed)
        XCTAssertEqual(st4.error, "iCloud 还没把原图同步过来：附件/9F1C2D4E-原图-1.jpg")
        // 再交一次：状态重来
        st4.submitted(id: "REQ-5", text: sent, at: Date())
        XCTAssertEqual(st4.phase, .waiting)
        XCTAssertNil(st4.error)

        // 版本不对
        var st5 = ButlerNoteState()
        st5.submitted(id: "REQ-6", text: sent, at: Date())
        _ = st5.receive(ButlerResult(v: 2, id: "REQ-6", note: "N", ok: true, text: "x", changes: nil, error: nil), current: sent)
        XCTAssertEqual(st5.error, "接口版本不对：手机 v1，大管家 v2")

        // 别人的结果不认
        var st6 = ButlerNoteState()
        st6.submitted(id: "REQ-7", text: sent, at: Date())
        XCTAssertNil(st6.receive(r1, current: sent))
        XCTAssertEqual(st6.phase, .waiting)

        // 状态存进数据库再读回来
        XCTAssertEqual(ButlerNoteState.decode(st3.encoded()), st3)
    }

    func testResultArrivesAsPlaceholder() throws {
        let fs = FakeICloud()
        let ch = ButlerChannel(root: root, fs: fs)
        try ch.prepare()
        try fs.plantPlaceholder(ch.outbox.appendingPathComponent("REQ-1.json"), Data(sampleResult.utf8))
        XCTAssertEqual(ch.result("REQ-1")?.ok, true)
        XCTAssertEqual(ch.allResults().count, 1)
    }

    func testHeartbeat() throws {
        let fs = PlainFileAccess()
        let ch = ButlerChannel(root: root, fs: fs)
        XCTAssertEqual(ButlerPresence.from(ch.heartbeat()), .never)
        let now = ISOTime.date("2026-11-20T08:30:00+08:00")!
        try fs.write(Data(#"{ "v": 1, "at": "2026-11-20T08:29:10+08:00", "host": "掌机", "model": "claude-opus-5-5" }"#.utf8), to: ch.heartbeatURL)
        XCTAssertEqual(ButlerPresence.from(ch.heartbeat(), now: now), .online)
        XCTAssertEqual(ButlerPresence.from(ButlerHeartbeat(v: 1, at: "2026-11-20T08:25:00+08:00"), now: now), .seen(minutes: 5, offline: false))
        XCTAssertEqual(ButlerPresence.from(ButlerHeartbeat(v: 1, at: "2026-11-20T08:00:00+08:00"), now: now), .seen(minutes: 30, offline: true))
    }

    func testDiffHunks() {
        XCTAssertEqual(TextDiff.hunks("A线早班 128O件", "A线早班 1,280件").count, 1)
        let h = TextDiff.hunks("□班交接，128O件", "早班交接，1280件")
        XCTAssertEqual(h, [TextDiff.Hunk(old: "□", new: "早"), TextDiff.Hunk(old: "O", new: "0")])
        XCTAssertEqual(TextDiff.hunks("一样", "一样"), [])
        XCTAssertEqual(TextDiff.hunks("", "新"), [TextDiff.Hunk(old: "", new: "新")])
    }

    func testISOTimeKeepsOffset() {
        let d = ISOTime.date("2026-11-20T08:00:00+08:00")!
        XCTAssertEqual(ISOTime.string(d, tz: TimeZone(identifier: "Asia/Singapore")!), "2026-11-20T08:00:00+08:00")
        XCTAssertEqual(ISOTime.string(d, tz: TimeZone(identifier: "UTC")!), "2026-11-20T00:00:00+00:00")
    }
}
