import Foundation
import XCTest
@testable import YiyeKit

/// 158：大管家找 Song 的话（送来 kind=tell，pc-butler handheld/tell.py 寄的）认得出、不当听力稿；回执请求带那封的 id
final class Tell158Tests: XCTestCase {
    func testTellIsNotAListeningPiece() throws {
        let raw = #"{"v":2,"kind":"delivery","kind2":"tell","id":"tell-0a1b2c","at":"2026-11-25T15:20:00+08:00","data":{"v":1,"id":"tell-0a1b2c","kind":"tell","kind2":"tell","text":"Claude 登录还剩 2 天","title":"","at":"2026-11-25T15:20:00+08:00","urgent":true}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .tell(d))
        XCTAssertEqual(d.text, "Claude 登录还剩 2 天")
        XCTAssertEqual(d.urgent, true)
        XCTAssertNotNil(ISOTime.date(d.at ?? ""))
    }

    func testListeningStillListening() throws {
        let raw = #"{"v":2,"kind":"delivery","id":"l-1","at":"2026-11-25T15:20:00+08:00","data":{"v":1,"id":"l-1","kind":"listen","text":"Hi there","at":"2026-11-25T15:20:00+08:00"}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        if case .tell = MailAction.decide(env, waiting: [:], dubbing: [:]) { XCTFail("听力稿被当成大管家的话") }
    }

    func testReceiptRequest() {
        let r = ButlerRequest.tellOK(id: "r1", of: "tell-0a1b2c", at: "2026-11-25T15:20:01+08:00", app: "0.7.23")
        XCTAssertEqual(r.ask, "tell-ok")
        XCTAssertEqual(r.note, "tell-0a1b2c")
    }
}
