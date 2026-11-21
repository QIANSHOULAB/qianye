import XCTest
@testable import YiyeKit

final class VoiceTests: XCTestCase {
    func testJoin() {
        XCTAssertEqual(VoiceText.join(["明天上午九点开会，", "记得带报表。"]), "明天上午九点开会，记得带报表。")
        XCTAssertEqual(VoiceText.join(["Meeting at nine.", "Bring the report."]), "Meeting at nine. Bring the report.")
        XCTAssertEqual(VoiceText.join(["A线", "1280件"]), "A线1280件")
        XCTAssertEqual(VoiceText.join(["  ", "好", ""]), "好")
    }

    func testClock() {
        XCTAssertEqual(VoiceText.clock(0), "0:00")
        XCTAssertEqual(VoiceText.clock(5.9), "0:05")
        XCTAssertEqual(VoiceText.clock(83), "1:23")
        XCTAssertEqual(VoiceText.clock(3723), "1:02:03")
    }

    func testNamesAndImport() {
        let id = UUID(uuidString: "9F1C2D4E-0B7A-4C61-9E52-2A6F1D3B8C70")!
        XCTAssertEqual(VoiceText.fileName(note: id, index: 2), "9F1C2D4E-语音-2.m4a")
        let have: Set<String> = ["附件/9F1C2D4E-语音-1.m4a", "附件/9F1C2D4E-语音-3.m4a"]
        XCTAssertEqual(VoiceText.paths(note: id, exists: { have.contains($0) }), ["附件/9F1C2D4E-语音-1.m4a", "附件/9F1C2D4E-语音-3.m4a"])
    }

    func testMarkdown() {
        XCTAssertEqual(VoiceText.markdown(from: "  明天  开会\n带报表  "), "明天 开会\n带报表")
    }

    func testVoiceRequestHasNoImages() throws {
        let r = ButlerRequest(id: "x", note: "n", kind: .voice, text: "明天开会", images: nil, unsure: nil, at: "2026-11-20T23:00:00+08:00", app: "0.2.0")
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"kind\":\"voice\""))
        XCTAssertFalse(json.contains("images"))
        XCTAssertTrue(json.contains("\"ask\":\"fix\""))
        let speak = ButlerRequest(id: "y", note: "n", kind: .text, text: "Hello.", images: nil, unsure: nil, ask: "speak", at: "2026-11-21T19:30:00+08:00", app: "0.4.0")
        XCTAssertTrue(String(data: try JSONEncoder().encode(speak), encoding: .utf8)!.contains("\"ask\":\"speak\""))
    }
}
