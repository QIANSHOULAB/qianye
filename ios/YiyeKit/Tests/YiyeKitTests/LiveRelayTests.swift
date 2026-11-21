#if canImport(CryptoKit)
import Foundation
import XCTest
@testable import YiyeKit

/// 对着真的信箱跑 N 次来回（手机这头用的就是 app 里那套 MailClient + MailSocket），对面是假掌机（ios/tools/relay/fake_butler.mjs）。
/// CI 的 ios-relay.yml 跑它：线上 luruseng-relay 有 /dgj 就对着线上，没有就在机器上起一个 wrangler dev。
/// 没给 YIYE_LIVE_PAIRING 就跳过（平常的 swift test 不碰网）。
final class LiveRelayTests: XCTestCase {
    /// 推送到了就记下几点到的
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [(Date, MailPush)] = []
        func add(_ p: MailPush) { lock.lock(); got.append((Date(), p)); lock.unlock() }
        func find(_ pred: (MailPush) -> Bool) -> (Date, MailPush)? {
            lock.lock(); defer { lock.unlock() }
            return got.first { pred($0.1) }
        }
    }

    func wait(_ inbox: Inbox, seconds: Double, _ pred: @escaping (MailPush) -> Bool) async throws -> (Date, MailPush) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let hit = inbox.find(pred) { return hit }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MailError.http(0, "等了 \(Int(seconds)) 秒没等到")
    }

    func testRoundTripsAgainstTheRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["YIYE_LIVE_PAIRING"], let pairing = MailPairing.parse(raw) else {
            throw XCTSkip("没给 YIYE_LIVE_PAIRING：不跑真信箱")
        }
        let rounds = Int(env["YIYE_LIVE_ROUNDS"] ?? "") ?? 10
        let phone = try XCTUnwrap(MailClient(pairing: pairing, role: "phone"))
        let inbox = Inbox()
        let sock = MailSocket(url: try XCTUnwrap(phone.socketURL), onPush: { inbox.add($0) }, onDown: { _ in })
        sock.start()
        defer { sock.stop() }
        let (_, hello) = try await wait(inbox, seconds: 30) { if case .hello = $0 { return true }; return false }
        guard case .hello(_, let pcOn, _) = hello else { return XCTFail("没收到 hello") }
        XCTAssertTrue(pcOn, "假掌机没连上信箱")

        var lines = [
            "| # | 请求（加密后，字节） | 交出去：加密+PUT | 交出去→假掌机收到 | 假掌机拆信+回信 | 回信→手机收到推送 | 手机拆开 | 合计 |",
            "|---|---|---|---|---|---|---|---|",
        ]
        var totals: [Double] = []
        let ms = { (a: Date, b: Date) -> Int in Int((b.timeIntervalSince(a) * 1000).rounded()) }
        for i in 1...rounds {
            let id = UUID().uuidString
            let req = ButlerRequest(id: id, note: UUID().uuidString, kind: .photo, text: "第 \(i) 条：A线早班 128O件",
                                    images: ["附件/T-原图-1.jpg"], unsure: ["128O件"], at: ISOTime.string(Date()), app: "live-test")
            let jpg = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })   // 一张 400KB 的「原图」
            let t0 = Date()
            let sent = try await phone.send(.request(req, files: ["附件/T-原图-1.jpg": jpg]))
            let t1 = Date()
            XCTAssertTrue(sent.pc)
            let (t4, push) = try await wait(inbox, seconds: 20) { if case .msg(let it) = $0 { return it.mid == id }; return false }
            guard case .msg(let item) = push else { return XCTFail("不是 msg") }
            let back = try await phone.receive(item)
            let t5 = Date()
            try await phone.ack(item.seq)
            let r = try XCTUnwrap(back.result)
            XCTAssertEqual(r.id, id)
            XCTAssertTrue(r.ok)
            XCTAssertEqual(r.text, "第 \(i) 条：A线早班 1280件")
            // 假掌机把它那头的时间写在 changes 里：fake|got=<毫秒>|sent=<毫秒>|bytes=<n>
            var kv: [String: Double] = [:]
            for p in (r.changes ?? "").split(separator: "|") {
                let a = p.split(separator: "=")
                if a.count == 2 { kv[String(a[0])] = Double(a[1]) }
            }
            let t2 = kv["got"].map { Date(timeIntervalSince1970: $0 / 1000) } ?? t1
            let t3 = kv["sent"].map { Date(timeIntervalSince1970: $0 / 1000) } ?? t4
            totals.append(t5.timeIntervalSince(t0) * 1000)
            lines.append("| \(i) | \(Int(kv["bytes"] ?? 0)) | \(ms(t0, t1)) | \(ms(t0, t2)) | \(ms(t2, t3)) | \(ms(t3, t4)) | \(ms(t4, t5)) | \(ms(t0, t5)) |")
        }
        let s = totals.sorted()
        func q(_ p: Double) -> Int { Int(s[min(s.count - 1, max(0, Int((p * Double(s.count)).rounded(.up)) - 1))].rounded()) }
        lines.append("")
        lines.append("合计（毫秒）：最快 \(q(0)) ，中位 \(q(0.5))，p90 \(q(0.9))，最慢 \(q(1))；\(rounds)/\(rounds) 收到。信箱：\(pairing.relay)")
        let table = lines.joined(separator: "\n")
        print("\n" + table + "\n")
        if let path = env["YIYE_LIVE_REPORT"] { try? table.write(toFile: path, atomically: true, encoding: .utf8) }
        XCTAssertLessThan(q(0.9), 15_000)                                     // 端到端（不算大脑）远低于 15 秒
    }
}
#endif
