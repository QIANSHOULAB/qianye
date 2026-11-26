import XCTest
@testable import YiyeKit

/// 143：信箱出事时别把小故障敲成风暴
final class Backoff143Tests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testStepsDoubleUpToFiveMinutes() {
        var b = Backoff()
        var t = t0
        var waits: [Double] = []
        for _ in 0..<9 {
            let w = b.failed(t)
            waits.append(w)
            t = t.addingTimeInterval(w)
        }
        XCTAssertEqual(waits, [2, 5, 10, 30, 60, 120, 300, 300, 300])
    }

    func testBurstOfFailuresCountsOnce() {
        var b = Backoff()
        b.failed(t0)
        b.failed(at(0.2))
        b.failed(at(1))
        XCTAssertEqual(b.fails, 1)
        XCTAssertEqual(b.wait(at(1)), 1, accuracy: 0.001)
    }

    func testCountOnlyClearsAfterSixtyGoodSeconds() {
        var b = Backoff()
        for t in [0.0, 2, 7] { b.failed(at(t)) }                    // 3 次
        b.succeeded(at(20))
        XCTAssertEqual(b.wait(at(20)), 0)                            // 通了马上能用
        XCTAssertEqual(b.failed(at(25)), 30)                         // 才好了 5 秒又断：接着往上数
        b.succeeded(at(60))
        b.succeeded(at(100))                                         // 稳住从第一回通算起
        XCTAssertEqual(b.failed(at(121)), 2)                         // 稳住超过 60 秒：从头数
    }

    func testRetryAfterSecondsAndDates() {
        XCTAssertEqual(RelayRules.retryAfter("30", now: t0), 30)
        XCTAssertEqual(RelayRules.retryAfter(" 600 ", now: t0), 600)
        XCTAssertNil(RelayRules.retryAfter(nil, now: t0))
        XCTAssertNil(RelayRules.retryAfter("", now: t0))
        XCTAssertNil(RelayRules.retryAfter("soon", now: t0))
        XCTAssertNil(RelayRules.retryAfter("-5", now: t0))
        XCTAssertNil(RelayRules.retryAfter("nan", now: t0))
        XCTAssertNil(RelayRules.retryAfter("999999999", now: t0))
        let d = Date(timeIntervalSince1970: 1_445_412_480)           // Wed, 21 Oct 2015 07:28:00 GMT
        XCTAssertEqual(RelayRules.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: d.addingTimeInterval(-90)) ?? 0, 90, accuracy: 0.001)
    }

    let quotaBody = Data(#"{"error":"do_quota","message":"Exceeded allowed volume of requests in Durable Objects free tier."}"#.utf8)

    func testQuotaWaitsPastUtcMidnight() {
        let day = Date(timeIntervalSince1970: 20_000 * 86_400)       // 某天 00:00 UTC
        let noon = day.addingTimeInterval(12 * 3600)
        let h = RelayRules.hold(status: 503, retryAfter: "600", body: quotaBody, now: noon)
        XCTAssertEqual(h?.quota, true)
        XCTAssertEqual(h?.until, day.addingTimeInterval(86_400 + 60))
        // 过了 0 点头一个小时 Cloudflare 解封晚：照 Retry-After
        let early = day.addingTimeInterval(1200)
        XCTAssertEqual(RelayRules.hold(status: 503, retryAfter: "600", body: quotaBody, now: early)?.until, early.addingTimeInterval(600))
        XCTAssertEqual(RelayRules.hold(status: 503, retryAfter: nil, body: quotaBody, now: early)?.until, early.addingTimeInterval(600))
    }

    func testOtherHolds() {
        let h = RelayRules.hold(status: 429, retryAfter: "30", body: nil, now: t0)
        XCTAssertEqual(h, RelayHold(until: at(30), status: 429, quota: false))
        // 站里限速：秒数也写在正文里
        XCTAssertEqual(RelayRules.hold(status: 429, retryAfter: nil, body: Data(#"{"error":"slow down","retry_after":12}"#.utf8), now: t0)?.until, at(12))
        // 「信箱满了」没带 Retry-After：不硬等，交给退避
        XCTAssertNil(RelayRules.hold(status: 429, retryAfter: nil, body: Data(#"{"error":"信箱满了"}"#.utf8), now: t0))
        // CPU 超了也叫 do_quota：照 Retry-After，不等到明天
        let cpu = Data(#"{"error":"do_quota","message":"Worker exceeded CPU time limit."}"#.utf8)
        XCTAssertEqual(RelayRules.hold(status: 503, retryAfter: "600", body: cpu, now: t0), RelayHold(until: at(600), status: 503, quota: false))
        // 最多等一小时
        XCTAssertEqual(RelayRules.hold(status: 429, retryAfter: "86000", body: nil, now: t0)?.until, at(3600))
        XCTAssertNil(RelayRules.hold(status: 500, retryAfter: "30", body: nil, now: t0))
    }

    func testItemGatePicksAndBacksOff() {
        var g = ItemGate()
        XCTAssertEqual(g.pick(["a", "b", "c"], ready: false, limit: 5, now: t0), [])
        XCTAssertEqual(g.pick(["a", "b", "c"], ready: true, limit: 2, now: t0), ["a", "b"])
        XCTAssertEqual(g.pick(["a", "b", "c"], ready: true, limit: 2, inflight: 2, now: t0), [])
        g.failed("a", t0)
        XCTAssertEqual(g.pick(["a", "b", "c"], ready: true, limit: 2, now: at(1)), ["b", "c"])
        XCTAssertEqual(g.pick(["a"], ready: true, limit: 2, now: at(2)), ["a"])
        g.failed("a", at(2))
        XCTAssertEqual(g.pick(["a"], ready: true, limit: 2, now: at(6)), [])
        g.succeeded("a")
        XCTAssertEqual(g.pick(["a"], ready: true, limit: 2, now: at(6)), ["a"])
    }

    func testQuotaLine() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let until = Date(timeIntervalSince1970: 20_000 * 86_400 + 60)     // 00:01 UTC = 08:01 新加坡
        XCTAssertEqual(RelayRules.quotaLine(until, spare: .backup, zh: true, calendar: cal), "信箱今天满了，8 点恢复，先走备用")
        XCTAssertEqual(RelayRules.quotaLine(until, spare: .icloud, zh: true, calendar: cal), "信箱今天满了，8 点恢复，先走 iCloud")
        XCTAssertEqual(RelayRules.quotaLine(until.addingTimeInterval(36 * 60), spare: .none, zh: true, calendar: cal), "信箱今天满了，08:37 恢复")
        XCTAssertEqual(RelayRules.quotaLine(until, spare: .backup, zh: false, calendar: cal), "Mailbox full for today, back at 08:01. Using the backup for now")
    }

    func testWordsAreNotGivenUpWhenTheMailboxIsSick() {
        var q = WordQueue()
        q.add("ledger", .learning, note: "N", at: "a")
        for i in 0..<(WordQueue.maxTries * 3) { q.sending("ledger", id: "R\(i)"); q.deferred("R\(i)") }
        XCTAssertEqual(q.due().map(\.word), ["ledger"])
        XCTAssertEqual(q.items[0].tries, 0)
    }
}

#if canImport(CryptoKit)
// ================================================================ 假信箱一直出事，手机跑 10 分钟
final class Clock143: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 20_000 * 86_400 + 12 * 3600)   // UTC 中午
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class SickRelay: MailHTTP, @unchecked Sendable {
    enum Mode { case quota, tooMany, offline, fine }
    private let lock = NSLock()
    private var current: Mode
    private var count = 0
    private var stored: Set<String> = []
    init(_ mode: Mode) { current = mode }
    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    var mids: Set<String> { lock.lock(); defer { lock.unlock() }; return stored }

    func send(_ req: URLRequest) async throws -> (Data, Int) {
        let r = try answer(req)
        return (r.data, r.status)
    }
    func exchange(_ req: URLRequest) async throws -> MailReply { try answer(req) }

    private func answer(_ req: URLRequest) throws -> MailReply {
        lock.lock(); defer { lock.unlock() }
        count += 1
        switch current {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .quota:
            let body = #"{"error":"do_quota","message":"Exceeded allowed volume of requests in Durable Objects free tier."}"#
            return MailReply(data: Data(body.utf8), status: 503, retryAfter: "600")
        case .tooMany:
            return MailReply(data: Data(#"{"error":"slow down","retry_after":30}"#.utf8), status: 429, retryAfter: "30")
        case .fine:
            let mid = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mid" }?.value
            if let mid { stored.insert(mid) }
            return MailReply(data: Data(#"{"seq":1,"pc":true}"#.utf8), status: 200)
        }
    }
}

/// 手机这头照 app 里那样跑：每 5 秒抄给电脑、会了不会、待办、小书童收拾、遥控要图各挑一轮；长连接到点就连
struct PhoneSim {
    let clock: Clock143
    let relay: SickRelay
    let mail: MailClient
    var gate = ItemGate()
    var wsTries = 0
    var wsUp = false
    var queues: [[String]] = [
        (0..<20).map { String(format: "KEEP-%04d", $0) },
        (0..<5).map { String(format: "WORD-%04d", $0) },
        (0..<3).map { String(format: "TODO-%04d", $0) },
        (0..<3).map { String(format: "TIDY-%04d", $0) },
        ["SHOT-0001"],
    ]
    var left: Int { queues.reduce(0) { $0 + $1.count } }

    init?(_ mode: SickRelay.Mode, backup: MailBackup? = nil, pairing: MailPairing = MailPairing.generate()) {
        let c = Clock143()
        let r = SickRelay(mode)
        guard let m = MailClient(pairing: pairing, role: "phone", http: r, backup: backup, brake: MailBrake(clock: { c.now })) else { return nil }
        clock = c; relay = r; mail = m
    }

    mutating func run(seconds: Int) async {
        for _ in 0..<(seconds / 5) {
            await connectIfDue()
            for i in queues.indices {
                for key in gate.pick(queues[i], ready: mail.autoReady, limit: mail.autoLimit, now: clock.now) {
                    let req = ButlerRequest(id: key, note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: "", app: "0.7.31")
                    do {
                        _ = try await mail.send(.request(req))
                        gate.succeeded(key)
                        queues[i].removeAll { $0 == key }
                    } catch {
                        gate.failed(key, clock.now)
                    }
                }
            }
            clock.advance(5)
        }
    }

    /// 跟 MailSocket.retry / drop 一个判断：到点才连；握手被拒记下来，503 问一次原因
    private mutating func connectIfDue() async {
        let brake = mail.brake
        guard !wsUp, brake.wait(.ws) <= 0 else { return }
        wsTries += 1
        switch relay.mode {
        case .offline: brake.unreachable(.ws)
        case .quota:
            brake.refused(.ws, status: 503, retryAfter: "600")
            if brake.quota() == nil { _ = try? await mail.state() }
        case .tooMany: brake.refused(.ws, status: 429, retryAfter: "30")
        case .fine: brake.ok(.ws); brake.connected(); wsUp = true
        }
    }
}

final class MailStormTests: XCTestCase {
    private func tenMinutes(_ mode: SickRelay.Mode, http: Int, ws: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        var phone = try XCTUnwrap(PhoneSim(mode))
        let all = phone.left
        await phone.run(seconds: 600)
        print("143 \(mode)：10 分钟敲了 HTTP \(phone.relay.hits) 次、长连接 \(phone.wsTries) 次")
        XCTAssertGreaterThan(phone.relay.hits + phone.wsTries, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(phone.relay.hits, http, "HTTP", file: file, line: line)
        XCTAssertLessThanOrEqual(phone.wsTries, ws, "长连接", file: file, line: line)
        XCTAssertEqual(phone.left, all, "一条都没丢，都还排着", file: file, line: line)
        // 信箱好了：排着的全寄出去（额度用光的等到明天 0 点以后）
        phone.relay.mode = .fine
        if mode == .quota { phone.clock.advance(12 * 3600) }
        await phone.run(seconds: 900)
        XCTAssertEqual(phone.left, 0, "好了以后没寄完", file: file, line: line)
        XCTAssertEqual(phone.relay.mids.count, all, file: file, line: line)
    }

    func testQuotaForTenMinutes() async throws { try await tenMinutes(.quota, http: 3, ws: 2) }
    func testRateLimitedForTenMinutes() async throws { try await tenMinutes(.tooMany, http: 12, ws: 10) }
    func testOfflineForTenMinutes() async throws { try await tenMinutes(.offline, http: 20, ws: 10) }

    /// 额度用光、有谷歌备胎：不干等，全从备胎走；信箱只敲头一两下
    func testQuotaGoesThroughTheSparePipe() async throws {
        let pairing = MailPairing.generate()
        let fb = FakeFirebase()
        let cfg = FbConfig(apiKey: "fake-api-key", databaseURL: "https://fake-db.example.firebasedatabase.app")
        let hub = MailBackup()
        hub.setPipe(FbPipe(config: cfg, box: pairing.box, auth: FbAuth(config: cfg, http: fb, store: MemTokens()), http: fb))
        var phone = try XCTUnwrap(PhoneSim(.quota, backup: hub, pairing: pairing))
        await phone.run(seconds: 600)
        XCTAssertEqual(phone.left, 0)
        XCTAssertTrue(hub.isOn)
        XCTAssertLessThanOrEqual(phone.relay.hits, 3)
        XCTAssertNotNil(fb.letter(pairing.box, dir: "to_pc", mid: "KEEP-0000"))
    }

    /// 信箱叫等着：连用户点的那一下也不敲，说人话
    func testHeldSaysSoWithoutKnocking() async throws {
        let c = Clock143()
        let relay = SickRelay(.quota)
        let mail = try XCTUnwrap(MailClient(pairing: MailPairing.generate(), http: relay, brake: MailBrake(clock: { c.now })))
        let req = ButlerRequest(id: "REQ-14301", note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: "", app: "0.7.31")
        for _ in 0..<3 {
            do {
                _ = try await mail.send(.request(req))
                XCTFail("该报错")
            } catch {
                guard case .held(let h)? = error as? MailError else { return XCTFail("\(error)") }
                XCTAssertTrue(h.quota)
                XCTAssertTrue((error as? MailError)?.errorDescription?.hasPrefix("信箱今天满了") ?? false)
                XCTAssertTrue(BackupGate.failsOver(error))
            }
        }
        XCTAssertEqual(relay.hits, 1)
        mail.brake.wake()                                            // 回到前台也不敲：叫等的照等
        _ = try? await mail.ack(1)
        XCTAssertEqual(relay.hits, 1)
        c.advance(13 * 3600)
        relay.mode = .fine
        _ = try await mail.send(.request(req))
        XCTAssertEqual(relay.hits, 2)
    }

    /// 太大、对面不认的那种错是那一封自己的事：不拖住别的
    func testOneBadLetterDoesNotHoldTheOthers() {
        XCTAssertFalse(MailClient.sick(MailError.http(413, "")))
        XCTAssertFalse(MailClient.sick(MailError.tooBig(30_000_000)))
        XCTAssertTrue(MailClient.sick(MailError.http(429, "")))
        XCTAssertTrue(MailClient.sick(MailError.http(500, "")))
        XCTAssertTrue(MailClient.sick(URLError(.timedOut)))
    }
}
#endif
