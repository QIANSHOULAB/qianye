import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import YiyeKit

// 130 备用信箱（谷歌 Firebase）：拆片拼片、事件树、登录换令牌、换管子的状态机、两条路来同一封只办一次。
// 全是假的：内存里的假 Firebase（REST）、假的流；配置、令牌都是编的，不碰网。

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class MemTokens: FbTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    init(_ v: String? = nil) { self.v = v }
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return v }
    func save(_ t: String?) { lock.lock(); v = t; lock.unlock() }
}

/// 内存里的假 Firebase：登录两个地址 + 数据库的 REST（PUT / GET / DELETE，路径一层一层的树）
final class FakeFirebase: MailHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var db: [String: Any] = [:]
    private(set) var log: [String] = []
    private(set) var signUps = 0
    private(set) var refreshes = 0
    private var issued = 0
    var failRefresh = false
    var failSignUp = false
    /// 下一个数据库请求回 401（令牌过期了）
    var rejectNextDB = false
    /// 数据库网不通
    var offline = false
    var now: () -> Date = { Date() }

    func send(_ req: URLRequest) async throws -> (Data, Int) { try handle(req) }

    private func handle(_ req: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        if url.host == "identitytoolkit.googleapis.com" {
            if failSignUp { return (Data(#"{"error":{"message":"bad apiKey fake-api-key"}}"#.utf8), 400) }
            signUps += 1
            issued += 1
            return (try JSONSerialization.data(withJSONObject: ["idToken": "id\(issued)", "refreshToken": "rt\(issued)", "expiresIn": "3600"]), 200)
        }
        if url.host == "securetoken.googleapis.com" {
            let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            if failRefresh || !body.contains("refresh_token=rt") { return (Data("{}".utf8), 400) }
            refreshes += 1
            issued += 1
            return (try JSONSerialization.data(withJSONObject: ["id_token": "id\(issued)", "refresh_token": "rt\(issued)", "expires_in": "3600"]), 200)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if rejectNextDB { rejectNextDB = false; return (Data(), 401) }
        guard let auth = q["auth"], auth.hasPrefix("id") else { return (Data(#"{"error":"Permission denied"}"#.utf8), 401) }
        var path = url.path
        guard path.hasSuffix(".json") else { return (Data(), 404) }
        path.removeLast(5)
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 3, comps[0] == "boxes", comps[1].count == 32 else { return (Data(#"{"error":"Permission denied"}"#.utf8), 401) }
        log.append("\(method) \(comps.dropFirst(2).joined(separator: "/"))")
        switch method {
        case "PUT":
            var v = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data(), options: [.fragmentsAllowed])) as Any
            v = stamp(v)
            FakeFirebase.set(&db, comps[...], v)
            return (req.httpBody ?? Data(), 200)
        case "DELETE":
            FakeFirebase.set(&db, comps[...], nil)
            return (Data("null".utf8), 200)
        case "GET":
            let v = FakeFirebase.get(db, comps[...])
            guard let v else { return (Data("null".utf8), 200) }
            return (try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), 200)
        default:
            return (Data(), 405)
        }
    }

    private func stamp(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            if d[".sv"] as? String == "timestamp" { return now().timeIntervalSince1970 * 1000 }
            return d.mapValues { stamp($0) }
        }
        return v
    }

    private static func set(_ node: inout [String: Any], _ path: ArraySlice<String>, _ value: Any?) {
        guard let k = path.first else { return }
        if path.count == 1 {
            if let value { node[k] = value } else { node.removeValue(forKey: k) }
            return
        }
        var child = (node[k] as? [String: Any]) ?? [:]
        set(&child, path.dropFirst(), value)
        if child.isEmpty { node.removeValue(forKey: k) } else { node[k] = child }
    }

    private static func get(_ node: [String: Any], _ path: ArraySlice<String>) -> Any? {
        guard let k = path.first, let v = node[k] else { return nil }
        if path.count == 1 { return v }
        guard let d = v as? [String: Any] else { return nil }
        return get(d, path.dropFirst())
    }

    // ---- 测试里看、动数据库
    func tree(_ path: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return FakeFirebase.get(db, path.split(separator: "/").map(String.init)[...])
    }

    func put(_ path: String, _ value: Any) {
        lock.lock(); defer { lock.unlock() }
        FakeFirebase.set(&db, path.split(separator: "/").map(String.init)[...], value)
    }

    /// 一封信从数据库里拼回密文（大管家那头怎么收的）
    func letter(_ box: String, dir: String, mid: String) -> Data? {
        guard let node = tree("boxes/\(box)/\(dir)/\(mid)") as? [String: Any], let meta = node["meta"] as? [String: Any],
              let n = (meta["n"] as? NSNumber)?.intValue, let size = (meta["size"] as? NSNumber)?.intValue,
              let p = node["p"] as? [String: Any] else { return nil }
        var parts: [String] = []
        for i in 0..<n { guard let s = p[String(i)] as? String else { return nil }; parts.append(s) }
        return FbChunk.join(parts, size: size)
    }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
}

/// Cloudflare 挂了：每个请求都回这个状态码（-1 = 网不通）
final class DeadRelay: MailHTTP, @unchecked Sendable {
    let code: Int
    private let lock = NSLock()
    private var n = 0
    init(code: Int) { self.code = code }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return n }
    func send(_ req: URLRequest) async throws -> (Data, Int) {
        lock.lock(); n += 1; lock.unlock()
        if code < 0 { throw URLError(.notConnectedToInternet) }
        return (Data(#"{"error":"down"}"#.utf8), code)
    }
}

/// 假的流：一进来就把这些行吐出来，然后一直等着；第 n 次连接可以直接断
final class FakeStreamer: FbStreamer, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[String]]
    private(set) var connects = 0
    /// 每次连接吐的行（用完了就重复最后一份）
    init(_ script: [[String]]) { self.script = script }
    /// nil = 这次连接直接断
    func lines(_ req: URLRequest) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let i = min(connects, script.count - 1)
        connects += 1
        let mine = script[i]
        lock.unlock()
        return AsyncThrowingStream { cont in
            if mine.first == "DROP" { cont.finish(throwing: URLError(.networkConnectionLost)); return }
            for l in mine { cont.yield(l) }
        }
    }
}

final class Collected<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

final class Backup130Tests: XCTestCase {
    let cfg = FbConfig(apiKey: "fake-api-key", databaseURL: "https://fake-db.example.firebasedatabase.app/")
    let box = "0123456789abcdef0123456789abcdef"

    func blob(_ n: Int) -> Data { Data((0..<n).map { UInt8(($0 &* 31 &+ 7) % 251) }) }

    // ---------------------------------------------------------------- 配置
    func testConfigValidity() {
        XCTAssertTrue(cfg.isValid)
        XCTAssertEqual(cfg.baseURL?.absoluteString, "https://fake-db.example.firebasedatabase.app")        // 末尾斜杠去掉
        XCTAssertFalse(FbConfig(apiKey: "", databaseURL: "https://x.example.com").isValid)
        XCTAssertFalse(FbConfig(apiKey: "k", databaseURL: "http://x.example.com").isValid)                 // 不是 https
        XCTAssertFalse(FbConfig(type: "other", apiKey: "k", databaseURL: "https://x.example.com").isValid)
        XCTAssertFalse(FbConfig(apiKey: "k", databaseURL: "not a url").isValid)
    }

    // ---------------------------------------------------------------- 拆片、拼片
    func testChunkSplitJoin() {
        let big = blob(2_500_000)
        let parts = FbChunk.split(big)
        XCTAssertEqual(parts.count, 4)                                       // base64 之后 3_333_336 个字符：3 整片 + 1 零头
        XCTAssertTrue(parts.allSatisfy { $0.count <= FbChunk.piece })
        XCTAssertEqual(FbChunk.join(parts, size: big.count), big)
        XCTAssertNil(FbChunk.join(parts, size: big.count + 1))              // 字节数对不上
        XCTAssertNil(FbChunk.join(Array(parts.dropLast()), size: big.count))
        XCTAssertEqual(FbChunk.split(Data()), [""])
        XCTAssertEqual(FbChunk.join([""], size: 0), Data())
        XCTAssertEqual(FbChunk.split(blob(10)).count, 1)
    }

    // ---------------------------------------------------------------- 事件流
    func testSSEParser() {
        var p = SSEParser()
        XCTAssertNil(p.feed("event: put"))
        XCTAssertEqual(p.feed(#"data: {"path":"/","data":null}"#), FbStreamEvent(event: "put", data: #"{"path":"/","data":null}"#))
        XCTAssertNil(p.feed(""))
        XCTAssertNil(p.feed(": 注释"))
        XCTAssertNil(p.feed("event: keep-alive"))
        XCTAssertEqual(p.feed("data: null"), FbStreamEvent(event: "keep-alive", data: "null"))
        XCTAssertEqual(p.feed("data:{\"a\":1}\r"), FbStreamEvent(event: "message", data: "{\"a\":1}"))
    }

    private func ev(_ name: String, _ path: String, _ data: Any?) -> FbStreamEvent {
        let obj: [String: Any] = ["path": path, "data": data ?? NSNull()]
        return FbStreamEvent(event: name, data: String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    func testTreeAssemblesALetterOnlyWhenMetaAndAllPiecesAreThere() {
        let sealed = blob(2_500_000)
        let parts = FbChunk.split(sealed)
        var t = FbLetterTree()
        XCTAssertTrue(t.apply(ev("put", "/", nil)).letters.isEmpty)                                  // 第一个事件：现在有的（空）
        for (i, s) in parts.enumerated() {
            XCTAssertTrue(t.apply(ev("put", "/MID-0001/p/\(i)", s)).letters.isEmpty, "片 \(i) 到了，meta 还没来")
        }
        let got = t.apply(ev("put", "/MID-0001/meta", ["at": 1_800_000_000_000, "n": parts.count, "size": sealed.count]))
        XCTAssertEqual(got.letters, [FbLetterBody(mid: "MID-0001", body: sealed)])
        XCTAssertTrue(t.apply(ev("put", "/MID-0001/meta", ["at": 1, "n": parts.count, "size": sealed.count])).letters.isEmpty)   // 同一封再来：不交第二次
        XCTAssertTrue(t.apply(ev("put", "/MID-0001", nil)).letters.isEmpty)                         // 被删了
        // 删了以后同一个号又来一封：算新的
        var again = t.apply(ev("put", "/MID-0001/p/0", FbChunk.split(blob(10))[0]))
        XCTAssertTrue(again.letters.isEmpty)
        again = t.apply(ev("put", "/MID-0001/meta", ["at": 2, "n": 1, "size": 10]))
        XCTAssertEqual(again.letters.map(\.mid), ["MID-0001"])
    }

    func testTreeFirstEventCarriesEverythingAndArraysWork() {
        let a = blob(100), b = blob(200)
        var t = FbLetterTree()
        // 重连后第一个 put "/" 把还没删的信都给一遍；p 连着号时 Firebase 回数组
        let all: [String: Any] = [
            "MID-A00001": ["p": FbChunk.split(a), "meta": ["at": 1, "n": 1, "size": a.count]],
            "MID-B00001": ["p": FbChunk.split(b), "meta": ["at": 2, "n": 1, "size": b.count]],
            "MID-C00001": ["p": FbChunk.split(b), "meta": ["at": 3, "n": 2, "size": b.count + 50]],      // 缺一片：还不算
        ]
        let up = t.apply(ev("put", "/", all))
        XCTAssertEqual(Set(up.letters.map(\.mid)), ["MID-A00001", "MID-B00001"])
        XCTAssertEqual(up.letters.first { $0.mid == "MID-A00001" }?.body, a)
        // 缺的那片补上
        let fix = t.apply(ev("put", "/MID-C00001/p/1", ""))
        XCTAssertTrue(fix.letters.isEmpty)                                                          // 空片拼不出 200 字节
        XCTAssertEqual(fix.broken, ["MID-C00001"])                                                  // 到齐了但字节数对不上：报出来
    }

    func testTreePatchAndRevoked() {
        let s = blob(50)
        var t = FbLetterTree()
        let up = t.apply(ev("patch", "/", ["MID-P00001": ["p": ["0": FbChunk.split(s)[0]], "meta": ["at": 1, "n": 1, "size": s.count]]]))
        XCTAssertEqual(up.letters, [FbLetterBody(mid: "MID-P00001", body: s)])
        XCTAssertTrue(t.apply(ev("cancel", "/", nil)).revoked)
        XCTAssertTrue(t.apply(ev("auth_revoked", "/", nil)).revoked)
        XCTAssertTrue(t.apply(ev("keep-alive", "/", nil)).letters.isEmpty)
        XCTAssertTrue(t.apply(FbStreamEvent(event: "put", data: "not json")).letters.isEmpty)
        t.reset()
        let again = t.apply(ev("put", "/", ["MID-P00001": ["p": ["0": FbChunk.split(s)[0]], "meta": ["at": 1, "n": 1, "size": s.count]]]))
        XCTAssertEqual(again.letters.map(\.mid), ["MID-P00001"])                                    // 重连：新树，信再给一遍（按号去重是 app 的事）
    }

    // ---------------------------------------------------------------- 登录
    func testAnonymousSignInThenRefresh() async throws {
        let fb = FakeFirebase()
        let clock = TestClock()
        let store = MemTokens()
        let auth = FbAuth(config: cfg, http: fb, store: store, now: { clock.now })
        let t1 = try await auth.token()
        XCTAssertEqual(t1, "id1")
        XCTAssertEqual(store.load(), "rt1")                                                          // refreshToken 交给钥匙串
        let t1b = try await auth.token()
        XCTAssertEqual(t1b, "id1")                                                                   // 还新鲜：不再登录
        XCTAssertEqual(fb.signUps, 1)
        clock.advance(56 * 60)                                                                       // 提前 5 分钟换
        let t2 = try await auth.token()
        XCTAssertEqual(t2, "id2")
        XCTAssertEqual(fb.refreshes, 1)
        XCTAssertEqual(store.load(), "rt2")
        // 换不成：重新匿名登录
        fb.failRefresh = true
        clock.advance(56 * 60)
        let t3 = try await auth.token()
        XCTAssertEqual(t3, "id3")
        XCTAssertEqual(fb.signUps, 2)
        // 重启 app：钥匙串里有 refreshToken，直接换，不重新登录
        fb.failRefresh = false
        let auth2 = FbAuth(config: cfg, http: fb, store: store, now: { clock.now })
        let t4 = try await auth2.token()
        XCTAssertEqual(t4, "id4")
        XCTAssertEqual(fb.signUps, 2)
        // 401：作废，下一次换新的
        await auth2.invalidate()
        let t5 = try await auth2.token()
        XCTAssertEqual(t5, "id5")
    }

    func testSignInErrorsDoNotCarryTheKey() async {
        let fb = FakeFirebase()
        fb.failSignUp = true
        let auth = FbAuth(config: cfg, http: fb, store: MemTokens())
        do {
            _ = try await auth.token()
            XCTFail("该失败")
        } catch {
            let text = (error as? FbError)?.errorDescription ?? "\(error)"
            XCTAssertFalse(text.contains("fake-api-key"))
            XCTAssertFalse(text.contains(cfg.databaseURL))
        }
    }

    // ---------------------------------------------------------------- 管子
    private func pipe(_ fb: FakeFirebase, clock: TestClock? = nil, streamer: FbStreamer? = nil) -> FbPipe {
        let c = clock
        let auth = FbAuth(config: cfg, http: fb, store: MemTokens(), now: { c?.now ?? Date() })
        return FbPipe(config: cfg, box: box, auth: auth, http: fb, streamer: streamer)
    }

    func testPutWritesPiecesFirstAndMetaLast() async throws {
        let fb = FakeFirebase()
        let p = pipe(fb)
        let sealed = blob(2_500_000)
        try await p.put(sealed, mid: "REQ-00001", to: "pc")
        XCTAssertEqual(fb.calls, ["PUT to_pc/REQ-00001/p/0", "PUT to_pc/REQ-00001/p/1", "PUT to_pc/REQ-00001/p/2", "PUT to_pc/REQ-00001/p/3", "PUT to_pc/REQ-00001/meta"])
        XCTAssertEqual(fb.letter(box, dir: "to_pc", mid: "REQ-00001"), sealed)
        // 同一个号再寄一次：覆盖，不是第二封
        try await p.put(sealed, mid: "REQ-00001", to: "pc")
        XCTAssertEqual((fb.tree("boxes/\(box)/to_pc") as? [String: Any])?.count, 1)
        // 收的一方办完删整封
        try await p.delete(mid: "REQ-00001", dir: "to_pc")
        XCTAssertNil(fb.tree("boxes/\(box)/to_pc/REQ-00001"))
        // 太大不收
        do {
            try await p.put(Data(count: FbChunk.maxRaw + 1), mid: "REQ-00002", to: "pc")
            XCTFail("该拒")
        } catch {
            XCTAssertEqual(error as? FbError, .tooBig(FbChunk.maxRaw + 1))
        }
        // 寄给手机的进 to_phone
        try await p.put(blob(10), mid: "ANS-00001", to: "phone")
        XCTAssertNotNil(fb.letter(box, dir: "to_phone", mid: "ANS-00001"))
    }

    func testRequestsCarryTokenButNeverTheKeyInTheBody() async throws {
        let fb = FakeFirebase()
        let p = pipe(fb)
        try await p.put(blob(10), mid: "REQ-00003", to: "pc")
        XCTAssertFalse(fb.calls.joined().contains("fake-api-key"))
    }

    func test401MakesANewTokenAndTriesOnce() async throws {
        let fb = FakeFirebase()
        let p = pipe(fb)
        try await p.writeSeen("phone")
        XCTAssertEqual(fb.signUps, 1)
        fb.rejectNextDB = true
        try await p.writeSeen("phone")
        XCTAssertEqual(fb.refreshes, 1)                                                              // 401：用 refreshToken 换了新令牌，再来一次
        XCTAssertEqual(fb.signUps, 1)
    }

    func testPcOnlineFromSeen() async throws {
        let fb = FakeFirebase()
        let clock = TestClock()
        fb.now = { clock.now }
        let p = pipe(fb, clock: clock)
        let online0 = await p.pcOnline(now: clock.now)
        XCTAssertFalse(online0)                                                                      // 谁都没写过
        fb.put("boxes/\(box)/seen/desk", clock.now.timeIntervalSince1970 * 1000)
        let online1 = await p.pcOnline(now: clock.now)
        XCTAssertTrue(online1)
        clock.advance(120)
        let online2 = await p.pcOnline(now: clock.now)
        XCTAssertFalse(online2)                                                                      // 超过 90 秒
        fb.put("boxes/\(box)/seen/handheld", clock.now.timeIntervalSince1970 * 1000 - 30_000)
        let online3 = await p.pcOnline(now: clock.now)
        XCTAssertTrue(online3)                                                                       // 掌机在
        try await p.writeSeen("phone")
        XCTAssertNotNil(fb.tree("boxes/\(box)/seen/phone"))
    }

    // ---------------------------------------------------------------- 听
    func testListenerDeliversLettersAndReconnects() async throws {
        let body = blob(3000)
        let all: [String: Any] = ["ANS-00009": ["p": FbChunk.split(body), "meta": ["at": 1, "n": 1, "size": body.count]]]
        let first = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "/", "data": all]), as: UTF8.self)
        let streamer = FakeStreamer([["DROP"], ["event: put", "data: \(first)", "event: keep-alive", "data: null"]])     // 第一次连接就断，重连后来信
        let fb = FakeFirebase()
        let got = Collected<FbLetterBody>()
        let l = FbListener(pipe: pipe(fb, streamer: streamer), onLetter: { got.add($0) })
        l.start()
        for _ in 0..<120 { if !got.all.isEmpty { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        l.stop()
        XCTAssertEqual(got.all, [FbLetterBody(mid: "ANS-00009", body: body)])
        XCTAssertEqual(streamer.connects, 2)                                                         // 断了退避 2 秒重连
    }

    // ---------------------------------------------------------------- 什么时候换管子
    func testGateEntersOnSendFailureAndReturnsAfterFiveGoodMinutes() {
        var g = BackupGate()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(g.on)
        XCTAssertEqual(g.sendFailed(t0), .entered)
        XCTAssertNil(g.sendFailed(t0.addingTimeInterval(1)))                                         // 已经在了
        XCTAssertTrue(g.on)
        g.socketUp(t0.addingTimeInterval(10))
        XCTAssertNil(g.tick(t0.addingTimeInterval(10 + 299)))                                        // 还差 1 秒
        XCTAssertEqual(g.tick(t0.addingTimeInterval(10 + 300)), .left)
        XCTAssertFalse(g.on)
        // 好了一半又断了：重新数
        XCTAssertEqual(g.sendFailed(t0.addingTimeInterval(400)), .entered)
        g.socketUp(t0.addingTimeInterval(410))
        g.socketDown(t0.addingTimeInterval(600))
        g.socketUp(t0.addingTimeInterval(620))
        XCTAssertNil(g.tick(t0.addingTimeInterval(620 + 299)))
        XCTAssertEqual(g.tick(t0.addingTimeInterval(620 + 300)), .left)
    }

    func testGateEntersWhenTheSocketStaysDownSixtySeconds() {
        var g = BackupGate()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        g.socketDown(t0)
        g.socketDown(t0.addingTimeInterval(30))                                                      // 断着，从第一次算
        XCTAssertNil(g.tick(t0.addingTimeInterval(59)))
        XCTAssertEqual(g.tick(t0.addingTimeInterval(60)), .entered)
        // 60 秒内又连上了：不进
        var h = BackupGate()
        h.socketDown(t0)
        h.socketUp(t0.addingTimeInterval(40))
        XCTAssertNil(h.tick(t0.addingTimeInterval(100)))
        // 自己关的（退到后台）：不算断
        var k = BackupGate()
        k.socketDown(t0)
        k.socketStopped()
        XCTAssertNil(k.tick(t0.addingTimeInterval(500)))
    }

    func testWhichErrorsChangeThePipe() {
        for code in [500, 502, 503, 429, 404, 403, 400, 1101] { XCTAssertTrue(BackupGate.failsOver(MailError.http(code, "")), "\(code)") }
        XCTAssertFalse(BackupGate.failsOver(MailError.http(413, "")))
        XCTAssertFalse(BackupGate.failsOver(MailError.tooBig(30_000_000)))
        XCTAssertFalse(BackupGate.failsOver(MailError.crypto))
        XCTAssertFalse(BackupGate.failsOver(MailError.badLetter("x")))
        XCTAssertTrue(BackupGate.failsOver(URLError(.notConnectedToInternet)))
        XCTAssertTrue(BackupGate.failsOver(URLError(.timedOut)))
    }

    // ---------------------------------------------------------------- 大管家递来的配置
    func testConfigLetterFromTheButler() throws {
        let raw = #"{"v":2,"kind":"delivery","kind2":"config","id":"cfg-0123456789ab","at":"2026-11-24T21:00:00+08:00","data":{"id":"cfg-0123456789ab","kind2":"config","at":"2026-11-24T21:00:00+08:00","backup":{"type":"firebase-rtdb","apiKey":"fake-api-key","databaseURL":"https://fake-db.example.firebasedatabase.app"}}}"#
        let env = try MailEnvelope.decode(Data(raw.utf8))
        XCTAssertEqual(env.kind, .delivery)
        XCTAssertNil(env.delivery)
        let c = try XCTUnwrap(env.config)
        XCTAssertEqual(c.id, "cfg-0123456789ab")
        XCTAssertEqual(c.config.apiKey, "fake-api-key")
        XCTAssertEqual(MailAction.decide(env, waiting: [:], dubbing: [:]), .fbConfig(c))
        // 来回一遍
        XCTAssertEqual(try MailEnvelope.decode(MailEnvelope.config(c).encoded()), env)
        // kind2 只在 data 里写了也认
        let onlyData = raw.replacingOccurrences(of: #""kind2":"config","id":"cfg-0123456789ab","at":"2026-11-24T21:00:00+08:00","data""#, with: #""id":"cfg-0123456789ab","at":"2026-11-24T21:00:00+08:00","data""#)
        XCTAssertNotNil(try MailEnvelope.decode(Data(onlyData.utf8)).config)
        // 配置不对（不是 https）：当坏信
        let bad = raw.replacingOccurrences(of: "https://fake-db", with: "http://fake-db")
        XCTAssertThrowsError(try MailEnvelope.decode(Data(bad.utf8)))
    }

    func testConfigReplyRequest() throws {
        let r = ButlerRequest.fbConfigOK(id: "OK-000001", of: "cfg-0123456789ab", at: "t", app: "0.7.16")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(obj["ask"] as? String, "fb-config-ok")
        XCTAssertEqual(obj["of"] as? String, "cfg-0123456789ab")
        XCTAssertEqual(obj["id"] as? String, "OK-000001")
    }

    func testOtherDeliveriesAreUntouched() throws {
        let d = ButlerDelivery(id: "DLV-1", text: "# Hi", audio: nil, marks: nil)
        XCTAssertEqual(MailAction.decide(.delivery(d), waiting: [:], dubbing: [:]), .deliver(d, audio: nil))
    }
}

#if canImport(CryptoKit)
// ================================================================ 要加密的部分（iPhone、macOS 上跑）
final class Backup130MailTests: XCTestCase {
    let cfg = FbConfig(apiKey: "fake-api-key", databaseURL: "https://fake-db.example.firebasedatabase.app")

    private func setUp2(cf: MailHTTP) throws -> (pairing: MailPairing, phone: MailClient, pc: MailClient, hub: MailBackup, fb: FakeFirebase) {
        let pairing = MailPairing.generate()
        let fb = FakeFirebase()
        let auth = FbAuth(config: cfg, http: fb, store: MemTokens())
        let hub = MailBackup()
        hub.setPipe(FbPipe(config: cfg, box: pairing.box, auth: auth, http: fb))
        let phone = try XCTUnwrap(MailClient(pairing: pairing, role: "phone", http: cf, backup: hub))
        let pc = try XCTUnwrap(MailClient(pairing: pairing, role: "pc", http: cf))
        return (pairing, phone, pc, hub, fb)
    }

    private func request(_ id: String, _ text: String = "你好") -> ButlerRequest {
        ButlerRequest(id: id, note: "N", kind: .text, text: text, images: nil, unsure: nil, at: "2026-11-24T21:00:00+08:00", app: "0.7.16")
    }

    func testCloudflareHealthyNeverTouchesGoogle() async throws {
        let relay = FakeRelay()
        let s = try setUp2(cf: relay)
        let sent = try await s.phone.send(.request(request("REQ-10001")))
        XCTAssertGreaterThanOrEqual(sent.seq, 0)
        XCTAssertFalse(s.hub.isOn)
        XCTAssertTrue(s.fb.calls.isEmpty)
        XCTAssertEqual(relay.stored.count, 1)
    }

    func testCloudflareDownSendsThroughGoogleAndEntersBackupMode() async throws {
        for code in [503, 429, 404, -1] {
            let relay = DeadRelay(code: code)
            let s = try setUp2(cf: relay)
            let changes = Collected<String>()
            s.hub.onChange = { changes.add($0 == .entered ? "entered" : "left") }
            let sent = try await s.phone.send(.request(request("REQ-20001", "钥匙之外的话")))
            XCTAssertEqual(sent.seq, -1, "码 \(code)")
            XCTAssertFalse(sent.pc)                                                                  // 谁也没写过 seen
            XCTAssertTrue(s.hub.isOn)
            XCTAssertEqual(changes.all, ["entered"])
            // 大管家那头从数据库里收：拼好、拆开，一个字不差
            let body = try XCTUnwrap(s.fb.letter(s.pairing.box, dir: "to_pc", mid: "REQ-20001"))
            let env = try s.pc.open(body)
            XCTAssertEqual(env.request?.text, "钥匙之外的话")
            // 之后在备用模式：先走谷歌，不再打 Cloudflare
            let before = relay.hits
            _ = try await s.phone.send(.request(request("REQ-20002")))
            XCTAssertEqual(relay.hits, before)
            XCTAssertNotNil(s.fb.letter(s.pairing.box, dir: "to_pc", mid: "REQ-20002"))
        }
    }

    func testPcOnlineFromSeenAndTooBigGoesNowhereNear() async throws {
        let relay = DeadRelay(code: 503)
        let s = try setUp2(cf: relay)
        s.fb.put("boxes/\(s.pairing.box)/seen/desk", Date().timeIntervalSince1970 * 1000)
        let sent = try await s.phone.send(.request(request("REQ-30001")))
        XCTAssertTrue(sent.pc)
        // 413 不换管子（信本身太大）
        let relay413 = DeadRelay(code: 413)
        let s2 = try setUp2(cf: relay413)
        do {
            _ = try await s2.phone.send(.request(request("REQ-30002")))
            XCTFail("该报错")
        } catch {
            XCTAssertEqual(error as? MailError, .http(413, #"{"error":"down"}"#))
        }
        XCTAssertFalse(s2.hub.isOn)
    }

    func testBothPipesDownTellsBothReasons() async throws {
        let relay = DeadRelay(code: 503)
        let s = try setUp2(cf: relay)
        s.fb.offline = true
        do {
            _ = try await s.phone.send(.request(request("REQ-40001")))
            XCTFail("该报错")
        } catch {
            let text = (error as? MailError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("备用也不成"), text)
            XCTAssertFalse(text.contains("fake-api-key"))
        }
    }

    func testInBackupModeButGoogleBrokenFallsBackToCloudflare() async throws {
        let relay = FakeRelay()
        let s = try setUp2(cf: relay)
        s.hub.sendFailed()                                                                           // 已经在备用模式
        s.fb.offline = true
        let sent = try await s.phone.send(.request(request("REQ-50001")))
        XCTAssertGreaterThanOrEqual(sent.seq, 0)                                                     // 走回 Cloudflare
    }

    func testLettersFromTheButlerArriveThroughTheStream() async throws {
        let relay = DeadRelay(code: 503)
        let s = try setUp2(cf: relay)
        // 大管家把回信写进 to_phone
        let answer = ButlerResult(id: "REQ-60001", note: "N", ok: true, text: "理好了", changes: nil, error: nil)
        let sealed = try s.pc.seal(.result(answer), to: "phone")
        let pcPipe = FbPipe(config: cfg, box: s.pairing.box, auth: FbAuth(config: cfg, http: s.fb, store: MemTokens()), http: s.fb)
        try await pcPipe.put(sealed, mid: "REQ-60001", to: "phone")
        // 手机听着：流里第一个事件是现有的全部
        let sub = try XCTUnwrap(s.fb.tree("boxes/\(s.pairing.box)/to_phone"))
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["path": "/", "data": sub]), as: UTF8.self)
        let streamer = FakeStreamer([["event: put", "data: \(line)"]])
        let phonePipe = FbPipe(config: cfg, box: s.pairing.box, auth: FbAuth(config: cfg, http: s.fb, store: MemTokens()), http: s.fb, streamer: streamer)
        let got = Collected<FbLetterBody>()
        let l = FbListener(pipe: phonePipe, onLetter: { got.add($0) })
        l.start()
        for _ in 0..<100 { if !got.all.isEmpty { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        l.stop()
        let letter = try XCTUnwrap(got.all.first)
        XCTAssertEqual(letter.mid, "REQ-60001")
        let env = try s.phone.open(letter.body)
        XCTAssertEqual(env.result?.text, "理好了")
        // 办完删：to_phone 里没了
        try await phonePipe.delete(mid: letter.mid, dir: "to_phone")
        XCTAssertNil(s.fb.tree("boxes/\(s.pairing.box)/to_phone/REQ-60001"))
    }

    func testKeepAliveIsPingNotState() {
        let s = MailSocket(url: URL(string: "wss://example.invalid/x")!, onPush: { _ in }, onDown: { _ in })
        XCTAssertEqual(s.keepAlive, "ping")                                                          // 站里自动回 pong，不叫醒信箱
        XCTAssertEqual(s.stateText, #"{"t":"state"}"#)
        XCTAssertEqual(s.stateEvery, 10)
    }
}
#endif
