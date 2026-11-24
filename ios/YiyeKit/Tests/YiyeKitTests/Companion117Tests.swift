import XCTest
@testable import YiyeKit

/// 117：一个嗓子的录音齐不齐、一句一句回来怎么排、插嘴的门槛、等多久、声纹那行字
final class Companion117Tests: XCTestCase {
    /// ios/Yiye/Voice（这个测试文件往上三层是 ios/）
    private var voiceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Yiye/Voice")
    }

    func testEveryFixedLineHasItsXiaoxiaoRecording() throws {
        let fm = FileManager.default
        var missing: [String] = []
        for line in VoiceLines.all {
            let f = voiceDir.appendingPathComponent(VoiceLines.name(line) + ".mp3")
            let size = (try? fm.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            if size < 2_000 { missing.append(line) }
        }
        XCTAssertEqual(missing, [], "这几句没配（或者字改了）：在电脑上跑 python ios/tools/voice_lines.py")
        // lines.json 跟代码里的一样（脚本照它配）
        let data = try Data(contentsOf: voiceDir.appendingPathComponent("lines.json"))
        let table = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(Set(table.keys), Set(VoiceLines.all.map(VoiceLines.name)), "lines.json 跟 VoiceLines.all 对不上：跑一遍 voice_lines.py")
        for (k, v) in table { XCTAssertEqual(VoiceLines.name(v), k, "lines.json 里 \(k) 的字跟名字的哈希对不上") }
    }

    func testFnvMatchesThePythonScript() {
        // python: fnv1a("没听清，再说一遍") —— 两头必须一样
        XCTAssertEqual(VoiceLines.fnv1a(""), "811c9dc5")
        XCTAssertEqual(VoiceLines.fnv1a("a"), "e40c292c")
        XCTAssertNotNil(VoiceLines.file(for: "没听清，再说一遍"))
        XCTAssertNotNil(VoiceLines.file(for: Deep.saysGot))
        XCTAssertNil(VoiceLines.file(for: "Quest 是任务的意思。"))
    }

    func testPartsPlayInOrder() {
        var q = PartQueue()
        XCTAssertEqual(q.add(1, Data([2])), [])
        XCTAssertEqual(q.add(0, Data([1])), [Data([1]), Data([2])])
        XCTAssertEqual(q.add(0, Data([9])), [], "同一句来两遍只放一遍")
        XCTAssertEqual(q.add(2, Data()), [], "没配上声音的跳过")
        XCTAssertEqual(q.add(3, Data([4])), [Data([4])])
        XCTAssertEqual(q.add(5, Data([6])), [])
        XCTAssertEqual(q.finish(total: 6), [Data([6])], "done 来了，缺的第 4 句不等了")
        XCTAssertEqual(q.played, 4)
    }

    func testBargeInNeedsLoudAndLong() {
        var g = VoiceGate()
        for _ in 0..<60 { _ = g.feed(db: -62, ms: 50) }               // 安静的屋子
        // 放回答时漏进来的一点声音（-45 dB）：不算插嘴
        var ev: VoiceGate.Event?
        for _ in 0..<40 { if let e = g.feed(db: -45, ms: 50, strict: true) { ev = e } }
        XCTAssertNil(ev)
        // 够响但只有 0.3 秒：不算
        g = VoiceGate()
        for _ in 0..<60 { _ = g.feed(db: -62, ms: 50) }
        for _ in 0..<6 { if let e = g.feed(db: -20, ms: 50, strict: true) { ev = e } }
        XCTAssertNil(ev)
        // 够响、0.5 秒：插嘴
        for _ in 0..<5 { if let e = g.feed(db: -20, ms: 50, strict: true) { ev = e } }
        XCTAssertEqual(ev, .start)
        // 平时（不在放）：0.12 秒就算开口，跟以前一样
        g = VoiceGate()
        for _ in 0..<60 { _ = g.feed(db: -62, ms: 50) }
        ev = nil
        for _ in 0..<3 { if let e = g.feed(db: -30, ms: 50) { ev = e } }
        XCTAssertEqual(ev, .start)
    }

    func testWaitGrowsWithTheGear() {
        XCTAssertEqual(LookWait.seconds(gear: 1), 45)
        XCTAssertGreaterThan(LookWait.seconds(gear: 4), LookWait.seconds(gear: 3))
        XCTAssertGreaterThan(LookWait.seconds(gear: 3), LookWait.seconds(gear: 2))
    }

    func testVoiceprintLine() {
        XCTAssertNil(VoiceprintLine.of(nil))
        XCTAssertNil(VoiceprintLine.of(["gear": 1]))
        XCTAssertEqual(VoiceprintLine.of(["vpN": 12, "vpOK": 0]), "声纹：攒了 12 句")
        XCTAssertEqual(VoiceprintLine.of(["vpN": 40, "vpOK": 1]), "声纹：好了")
    }

    func testNewRequests() throws {
        let pre = ButlerRequest.lookPre(id: "P1", question: "Q1", image: ButlerRequest.lookPrePath("Q1"), at: "t", app: "0.7.13")
        XCTAssertEqual(pre.ask, "look-pre")
        XCTAssertEqual(pre.note, "Q1")
        let q = ButlerRequest.look(id: "Q1", question: "", audio: "a.wav", image: nil, at: "t", app: "0.7.13", pre: true, stream: true)
        let j = String(data: try JSONEncoder().encode(q), encoding: .utf8) ?? ""
        XCTAssertTrue(j.contains("\"pre\":true") && j.contains("\"stream\":true"))
        let old = ButlerRequest.look(id: "Q2", question: "", audio: "a.wav", image: "x.jpg", at: "t", app: "0.7.13")
        let j2 = String(data: try JSONEncoder().encode(old), encoding: .utf8) ?? ""
        XCTAssertFalse(j2.contains("\"pre\"") || j2.contains("\"stream\""), "不说就不带（老大管家照旧）")
        XCTAssertEqual(ButlerRequest.lookOff(id: "O", at: "t", app: "x").ask, "look-off")
        XCTAssertEqual(ButlerRequest.lookWho(id: "W", audio: "w.wav", at: "t", app: "x").audio, "w.wav")
    }
}
