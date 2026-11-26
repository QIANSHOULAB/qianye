import Foundation
import XCTest
@testable import YiyeKit

/// 204：提醒里的链接认得出；Bark 响过的手机不再弹；加密钥匙 16 个字符、交给大管家的请求长得对
final class Bark204Tests: XCTestCase {
    private func link(_ s: String) -> YiyeLink? { URL(string: s).flatMap { YiyeLink.parse($0) } }

    func testLinks() {
        XCTAssertEqual(link("yiye://shutong?id=tell-0a1b2c3d4e"), .shutong(id: "tell-0a1b2c3d4e"))
        XCTAssertEqual(link("YIYE://Shutong?id=tell-1"), .shutong(id: "tell-1"))
        XCTAssertEqual(link("yiye://shutong"), .shutong(id: nil))
        XCTAssertEqual(link("yiye://shutong?id="), .shutong(id: nil))
        XCTAssertEqual(link("yiye://todo"), .todo)
        XCTAssertNil(link("yiye://elsewhere"))
        XCTAssertNil(link("https://shutong?id=tell-1"))
    }

    private func fresh() throws -> UserDefaults {
        let name = "bark204-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOneRingOnly() throws {
        let d = try fresh()
        XCTAssertTrue(BarkNotice.todoNeedsLocal(in: d), "没听说过 Bark：照旧弹")
        XCTAssertFalse(BarkNotice.heard(bark: true, in: d), "Bark 响了：手机不弹")
        XCTAssertFalse(BarkNotice.todoNeedsLocal(in: d))
        XCTAssertTrue(BarkNotice.heard(bark: nil, in: d), "大管家关了 Bark：手机接着弹")
        XCTAssertTrue(BarkNotice.todoNeedsLocal(in: d))
        XCTAssertTrue(BarkNotice.heard(bark: false, in: d))
    }

    func testTellLetterCarriesTheMark() throws {
        let raw = #"{"v":2,"kind":"delivery","kind2":"tell","id":"tell-0a1b2c","at":"2026-11-27T15:20:00+08:00","data":{"v":1,"id":"tell-0a1b2c","kind":"tell","kind2":"tell","text":"大管家来话","title":"","at":"2026-11-27T15:20:00+08:00","urgent":false,"bark":true}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        let d = try XCTUnwrap(env.delivery)
        XCTAssertEqual(d.bark, true)
    }

    func testSecret() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let k = BarkSecret.make()
            XCTAssertEqual(k.utf8.count, 16, k)
            XCTAssertTrue(k.allSatisfy { BarkSecret.alphabet.contains($0) }, k)
            seen.insert(k)
        }
        XCTAssertEqual(seen.count, 200)
        XCTAssertFalse(BarkSecret.alphabet.contains { "0O1lI".contains($0) })
    }

    func testSecretRequest() {
        let r = ButlerRequest.barkSecret(id: "r1", key: "AbCdEfGhJkMnPqRs", at: "2026-11-27T15:20:01+08:00", app: "0.7.37")
        XCTAssertEqual(r.ask, "key")
        XCTAssertEqual(r.name, "bark加密")
        XCTAssertEqual(r.key, "AbCdEfGhJkMnPqRs")
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(ButlerRequest.barkSecret(id: "r2", key: BarkSecret.off, at: "", app: "0.7.37").key, "off")
    }
}
