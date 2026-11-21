import Foundation
import XCTest
@testable import YiyeKit

final class ListenTests: XCTestCase {
    func testSentences() {
        let md = "# Bitcoin falls\nBitcoin fell to $62,000 on Monday. That is 1.5 percent lower! Why? The U.S. Fed may raise rates.\n- Mr. Powell spoke.\n![](附件/x.jpg)\n比特币跌了。为什么？"
        XCTAssertEqual(Listen.sentences(md), [
            "Bitcoin falls",
            "Bitcoin fell to $62,000 on Monday.",
            "That is 1.5 percent lower!",
            "Why?",
            "The U.S. Fed may raise rates.",
            "Mr. Powell spoke.",
            "比特币跌了。",
            "为什么？",
        ])
        XCTAssertEqual(Listen.sentences("He said \"stop.\" Then he left."), ["He said \"stop.\"", "Then he left."])
    }

    func testIndexAndSpan() {
        let marks = [ListenMark(t: 0, s: "A."), ListenMark(t: 2.5, s: "B."), ListenMark(t: 6, s: "C.")]
        XCTAssertEqual(Listen.index(at: 0, in: marks), 0)
        XCTAssertEqual(Listen.index(at: 2.49, in: marks), 0)
        XCTAssertEqual(Listen.index(at: 2.5, in: marks), 1)
        XCTAssertEqual(Listen.index(at: 99, in: marks), 2)
        XCTAssertNil(Listen.index(at: 1, in: []))
        XCTAssertEqual(Listen.span(1, in: marks, duration: 9).start, 2.5)
        XCTAssertEqual(Listen.span(1, in: marks, duration: 9).end, 6)
        XCTAssertEqual(Listen.span(2, in: marks, duration: 9).end, 9)
        let enc = Listen.encode(["附件/a.m4a": marks])
        XCTAssertEqual(Listen.decode(enc)["附件/a.m4a"], marks)
        XCTAssertEqual(Listen.decode(""), [:])
        XCTAssertEqual(Listen.sidecar(for: "附件/a.m4a"), "附件/a.m4a.marks.json")
        let id = UUID(uuidString: "9F1C2D4E-0B7A-4C61-9E52-2A6F1D3B8C70")!
        XCTAssertEqual(Listen.speakName(note: id), "9F1C2D4E-念-1.m4a")
        XCTAssertEqual(Listen.deliveryName(note: id, ext: "mp3"), "9F1C2D4E-听-1.mp3")
        XCTAssertTrue(Listen.isListenAudio("附件/9F1C2D4E-听-1.mp3"))
        XCTAssertFalse(Listen.isListenAudio("附件/9F1C2D4E-语音-1.m4a"))
        let have: Set<String> = ["附件/9F1C2D4E-语音-1.m4a", "附件/9F1C2D4E-听-1.mp3"]
        XCTAssertEqual(Listen.importPaths(note: id) { have.contains($0) }, ["附件/9F1C2D4E-听-1.mp3", "附件/9F1C2D4E-语音-1.m4a"])
    }

    func testDeliveryInbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-\(UUID().uuidString)/一叶笺", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let fs = FakeICloud()
        let ch = ButlerChannel(root: root, fs: fs)
        try fs.makeDir(ch.delivered)
        let sample = #"""
        { "v": 1, "id": "D-1", "kind": "listen", "title": "Bitcoin falls", "text": "# Bitcoin falls\nBitcoin fell.", "audio": "附件/D-1.mp3",
          "marks": [{"t": 0, "s": "Bitcoin falls"}, {"t": 1.8, "s": "Bitcoin fell."}], "folder": "英语", "at": "2026-11-21T09:00:00+08:00" }
        """#
        try fs.plantPlaceholder(ch.delivered.appendingPathComponent("D-1.json"), Data(sample.utf8))
        try fs.write(Data("x".utf8), to: ch.delivered.appendingPathComponent("D-2.json.part"))
        let got = ch.deliveries()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].item.marks?.count, 2)
        XCTAssertEqual(got[0].item.folder, "英语")
        // 录音还没同步过来：拿不到，下回再拿
        XCTAssertNil(ch.deliveryAudio("附件/D-1.mp3"))
        try fs.plantPlaceholder(root.appendingPathComponent("附件/D-1.mp3"), Data([1, 2, 3]))
        XCTAssertEqual(ch.deliveryAudio("附件/D-1.mp3"), Data([1, 2, 3]))
        ch.removeDelivery(got[0].url)
        XCTAssertEqual(ch.deliveries().count, 0)
    }
}
