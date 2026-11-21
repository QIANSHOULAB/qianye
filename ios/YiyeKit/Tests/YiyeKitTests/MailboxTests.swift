import Foundation
import XCTest
@testable import YiyeKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 接口 v2（Cloudflare 信箱）：配对、加解密、信的格式、推送、收发（假信箱）、在线状态、iCloud 备胎
final class MailboxTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-mail-\(UUID().uuidString)/一叶笺", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    // ---------------------------------------------------------------- 配对
    func testPairingParseAndValidate() throws {
        let p = MailPairing.generate(at: ISOTime.date("2026-11-22T00:00:00+08:00")!)
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.box.count, 32)
        XCTAssertEqual(p.keyData?.count, 32)
        XCTAssertEqual(p.relay, "https://luruseng-relay.lunzigeju.workers.dev")
        XCTAssertNotEqual(MailPairing.generate().box, p.box)                  // 每次都是新的随机号
        // 二维码 / 配对码：一行 JSON，读回来一样；前后带空白、换行也认
        XCTAssertFalse(p.code.contains("\n"))
        XCTAssertEqual(MailPairing.parse(p.code), p)
        XCTAssertEqual(MailPairing.parse("\n  " + p.code + "  \n"), p)
        // 掌机写的配对.json（多几个字段、没写 relay 用默认的）
        let file = #"{"v":2,"box":"0123456789abcdef0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","host":"掌机","at":"2026-11-22T00:00:00+08:00","extra":1}"#
        let f = try XCTUnwrap(MailPairing.parse(file))
        XCTAssertEqual(f.relay, MailPairing.defaultRelay)
        XCTAssertEqual(f.keyData, Data((0..<32).map { UInt8($0) }))
        // 不对的一律不认
        let bad = [
            #"{"v":1,"box":"0123456789abcdef0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#,   // 版本
            #"{"v":2,"box":"0123456789ABCDEF0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#,   // 大写
            #"{"v":2,"box":"0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#,                   // 号太短
            #"{"v":2,"box":"0123456789abcdef0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODw"}"#,                        // 钥匙 16 字节
            #"{"v":2,"relay":"ftp://x","box":"0123456789abcdef0123456789abcdef","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}"#,
            "大管家", "",
        ]
        for b in bad { XCTAssertNil(MailPairing.parse(b), b) }
        XCTAssertEqual(Base64URL.decode(Base64URL.encode(Data([0xFB, 0xFF, 0xBF]))), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF, 0xBF])), "-_-_")
    }

    func testPairingAdoptOnlyNewer() {
        let old = MailPairing.generate(at: ISOTime.date("2026-11-22T00:00:00+08:00")!)
        let new = MailPairing.generate(at: ISOTime.date("2026-11-23T00:00:00+08:00")!)
        XCTAssertTrue(MailPairing.shouldAdopt(old, over: nil))                // 手里没有：要
        XCTAssertFalse(MailPairing.shouldAdopt(old, over: old))               // 一样的：不换
        XCTAssertTrue(MailPairing.shouldAdopt(new, over: old))                // 掌机重配了：换
        XCTAssertFalse(MailPairing.shouldAdopt(old, over: new))               // 扫码配的比 iCloud 里的新：不换回去
        var broken = new
        broken.key = "short"
        XCTAssertFalse(MailPairing.shouldAdopt(broken, over: nil))
    }

    func testPairingFileFromICloudPlaceholder() throws {
        let fs = FakeICloud()
        let ch = ButlerChannel(root: root, fs: fs)
        try ch.prepare()
        XCTAssertNil(ch.pairing())                                            // 掌机还没写
        let p = MailPairing.generate()
        try fs.plantPlaceholder(ch.pairingURL, Data(p.code.utf8))             // 掌机写了，手机上还只是占位
        XCTAssertEqual(ch.pairing(), p)
        XCTAssertEqual(fs.downloads, 1)
        try fs.write(Data("{坏的".utf8), to: ch.pairingURL)
        XCTAssertNil(ch.pairing())
    }

    // ---------------------------------------------------------------- 信、推送、在线状态（不用加密的部分）
    func testPushParsing() {
        let hello = #"{"t":"hello","role":"phone","pc":false,"pcSeen":1763740800000,"phone":true,"pending":{"pc":0,"phone":2},"items":[{"seq":3,"mid":"RES-0001","to":"phone","at":1763740801234,"size":319,"data":"AAAA"},{"seq":4,"mid":"DLV-0002","to":"phone","at":1763740802000,"size":2000000}]}"#
        guard case let .hello(items, pc, seen) = MailPush.parse(hello) else { return XCTFail("不是 hello") }
        XCTAssertEqual(items.map(\.seq), [3, 4])
        XCTAssertEqual(items[0].data, "AAAA")
        XCTAssertNil(items[1].data)
        XCTAssertFalse(pc)
        XCTAssertEqual(seen, Date(timeIntervalSince1970: 1_763_740_800))
        XCTAssertEqual(MailPush.parse(#"{"t":"hello","role":"phone","pc":true,"pcSeen":null,"phone":true,"pending":{"pc":0,"phone":0},"items":[]}"#),
                       .hello(items: [], pc: true, pcSeen: nil))
        XCTAssertEqual(MailPush.parse(#"{"t":"msg","item":{"seq":9,"mid":"RES-0009","to":"phone","at":1,"size":5}}"#),
                       .msg(MailItem(seq: 9, mid: "RES-0009", to: "phone", at: 1, size: 5)))
        XCTAssertEqual(MailPush.parse(#"{"t":"gone","seq":9,"mid":"REQ-0009","to":"pc"}"#), .gone(seq: 9, mid: "REQ-0009", to: "pc", expired: false))
        XCTAssertEqual(MailPush.parse(#"{"t":"gone","seq":2,"mid":"OLD-0002","to":"pc","expired":true}"#), .gone(seq: 2, mid: "OLD-0002", to: "pc", expired: true))
        XCTAssertEqual(MailPush.parse(#"{"t":"pc","on":false,"seen":1763740800000}"#), .pc(on: false, seen: Date(timeIntervalSince1970: 1_763_740_800)))
        XCTAssertEqual(MailPush.parse(#"{"t":"pc","on":true,"seen":1763740800000}"#), .pc(on: true, seen: Date(timeIntervalSince1970: 1_763_740_800)))
        XCTAssertEqual(MailPush.parse(#"{"t":"state","pc":true,"pcSeen":1763740800000,"phone":true,"pending":{"pc":1,"phone":0}}"#),
                       .state(pc: true, pcSeen: Date(timeIntervalSince1970: 1_763_740_800)))
        XCTAssertEqual(MailPush.parse("pong"), .pong)
        XCTAssertEqual(MailPush.parse(#"{"t":"phone","on":true}"#), .other("phone"))
        XCTAssertEqual(MailPush.parse("乱码"), .other("乱码"))
    }

    func testPresenceFromRelayOrHeartbeat() {
        let seen = ISOTime.date("2026-11-22T23:41:00+08:00")!
        XCTAssertEqual(ButlerPresence.relay(on: true, seen: seen), .online)
        XCTAssertEqual(ButlerPresence.relay(on: false, seen: seen), .away(since: seen))
        XCTAssertFalse(ButlerPresence.away(since: seen).isHere)
        XCTAssertFalse(ButlerPresence.away(since: nil).isHere)
        // 信箱连着：听信箱的（就算 iCloud 心跳说在）
        XCTAssertEqual(ButlerPresence.current(relayUp: true, relayOn: false, relaySeen: seen, heartbeat: .online), .away(since: seen))
        XCTAssertEqual(ButlerPresence.current(relayUp: true, relayOn: true, relaySeen: nil, heartbeat: .never), .online)
        // 信箱连不上：看 iCloud 心跳（v1 备胎）
        XCTAssertEqual(ButlerPresence.current(relayUp: false, relayOn: true, relaySeen: nil, heartbeat: .seen(minutes: 5, offline: false)), .seen(minutes: 5, offline: false))
        XCTAssertEqual(ButlerPresence.current(relayUp: false, relayOn: false, relaySeen: nil, heartbeat: .never), .never)
    }

    func testEnvelopeRoundTrip() throws {
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0] + (0..<5000).map { UInt8($0 % 251) })
        let req = ButlerRequest(id: "9F1C2D4E-0B7A-4C61-9E52-2A6F1D3B8C70", note: "NOTE-1", kind: .photo, text: "A线早班 128O件",
                                images: ["附件/9F1C2D4E-原图-1.jpg"], unsure: ["128O件"], at: "2026-11-22T08:00:00+08:00", app: "0.5.0")
        let env = MailEnvelope.request(req, files: ["附件/9F1C2D4E-原图-1.jpg": jpg])
        let raw = try env.encoded()
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 2)                                    // 信封是 v2
        XCTAssertEqual(obj["kind"] as? String, "request")
        XCTAssertEqual((obj["data"] as? [String: Any])?["v"] as? Int, 1)       // 里面还是 v1 的对象，一字不改
        XCTAssertEqual((obj["data"] as? [String: Any])?["ask"] as? String, "fix")
        XCTAssertEqual((obj["files"] as? [String: String])?["附件/9F1C2D4E-原图-1.jpg"], jpg.base64EncodedString())
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("附件/9F1C2D4E"))   // 斜杠不转义
        XCTAssertEqual(try MailEnvelope.decode(raw), env)

        let res = MailEnvelope.result(ButlerResult(id: req.id, note: "NOTE-1", ok: true, text: "A线早班 1,280件", changes: "改了 1 处", error: nil, at: "2026-11-22T08:00:09+08:00"))
        XCTAssertEqual(try MailEnvelope.decode(res.encoded()), res)
        XCTAssertNil((try JSONSerialization.jsonObject(with: res.encoded()) as! [String: Any])["files"])   // 结果不带文件
        let mp3 = Data((0..<20_000).map { UInt8(($0 * 7) % 256) })
        let dlv = MailEnvelope.delivery(ButlerDelivery(id: "6B2E1A2C-5D3F-4E8A-9B10-77C2D4E5F601", title: "Bitcoin", text: "# Bitcoin\nIt fell.",
                                                       audio: "附件/6B2E1A2C-听-1.mp3", marks: [ListenMark(t: 0, s: "Bitcoin"), ListenMark(t: 1.5, s: "It fell.")],
                                                       folder: "英语", at: "2026-11-22T09:00:00+08:00"),
                                        files: ["附件/6B2E1A2C-听-1.mp3": mp3])
        XCTAssertEqual(try MailEnvelope.decode(dlv.encoded()), dlv)

        // 不对的：版本、不是 JSON、不认得的 kind、字段缺了
        XCTAssertThrowsError(try MailEnvelope.decode(Data(#"{"v":1,"kind":"result","id":"x","data":{}}"#.utf8))) {
            XCTAssertEqual($0 as? MailError, .badLetter("接口版本不对：手机 v2，信 v1"))
        }
        XCTAssertThrowsError(try MailEnvelope.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try MailEnvelope.decode(Data(#"{"v":2,"kind":"boss","id":"x","data":{}}"#.utf8)))
        XCTAssertThrowsError(try MailEnvelope.decode(Data(#"{"v":2,"kind":"result","id":"x","data":{"v":1}}"#.utf8)))
    }

    func testWhatThePhoneDoesWithEachLetter() {
        let n1 = UUID(), n2 = UUID()
        let ok = ButlerResult(id: "REQ-1", note: n1.uuidString, ok: true, text: "理好的", changes: nil, error: nil)
        XCTAssertEqual(MailAction.decide(.result(ok), waiting: ["REQ-1": n1], dubbing: [:]), .apply(ok, note: n1))
        let bad = ButlerResult(id: "DUB-1", note: n2.uuidString, ok: false, text: nil, changes: nil, error: "ElevenLabs 额度用完了")
        XCTAssertEqual(MailAction.decide(.result(bad), waiting: [:], dubbing: ["DUB-1": n2]), .dubFailed(bad, note: n2))
        XCTAssertEqual(MailAction.decide(.result(ok), waiting: [:], dubbing: [:]), .drop("没人在等 REQ-1"))   // 重复来的、撤回了的
        let d = ButlerDelivery(id: "DLV-1", text: "# Hi", audio: "附件/DLV-1-听-1.mp3", marks: nil)
        let mp3 = Data([1, 2, 3])
        XCTAssertEqual(MailAction.decide(.delivery(d, files: ["附件/DLV-1-听-1.mp3": mp3]), waiting: [:], dubbing: [:]), .deliver(d, audio: mp3))
        XCTAssertEqual(MailAction.decide(.delivery(d), waiting: [:], dubbing: [:], localAudio: { _ in mp3 }), .deliver(d, audio: mp3))   // 信里没带：iCloud 里有
        XCTAssertEqual(MailAction.decide(.delivery(d), waiting: [:], dubbing: [:]), .later)                                        // 都没有：下回再拿
        let noAudio = ButlerDelivery(id: "DLV-2", text: "# Hi", audio: nil, marks: nil)
        XCTAssertEqual(MailAction.decide(.delivery(noAudio), waiting: [:], dubbing: [:]), .deliver(noAudio, audio: nil))
        let req = ButlerRequest(id: "REQ-9", note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: "t", app: "0.5.0")
        XCTAssertEqual(MailAction.decide(.request(req), waiting: [:], dubbing: [:]), .drop("手机不收请求"))
    }
}

#if canImport(CryptoKit)
// ================================================================ 要加密的部分（iPhone、macOS 上跑；Linux 没有 CryptoKit）
/// 假信箱：照 luruseng-relay 的 /dgj 回话，信放在内存里
final class FakeRelay: MailHTTP, @unchecked Sendable {
    struct Letter { var seq: Int; var mid: String; var to: String; var at: Double; var data: Data }
    private let lock = NSLock()
    private var letters: [Letter] = []
    private var next = 1
    var pcOn = true
    /// 下一个请求回这个状态码（模拟站里出错）；-1 = 网不通
    var failNext: Int?
    private(set) var hits: [String] = []

    var stored: [Letter] { lock.lock(); defer { lock.unlock() }; return letters }

    func send(_ req: URLRequest) async throws -> (Data, Int) { try handle(req) }

    private func handle(_ req: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        hits.append("\(method) \(url.path)")
        if let f = failNext {
            failNext = nil
            if f < 0 { throw URLError(.notConnectedToInternet) }
            return (Data(#"{"error":"busy"}"#.utf8), f)
        }
        let parts = url.path.split(separator: "/").map(String.init)      // dgj, box, what, arg?
        guard parts.count >= 3, parts[0] == "dgj", parts[1].count == 32 else { return (Data(), 404) }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        func json(_ o: Any) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: o), 200) }
        func meta(_ l: Letter) -> [String: Any] { ["seq": l.seq, "mid": l.mid, "to": l.to, "at": l.at, "size": l.data.count] }
        switch (method, parts[2], parts.count > 3 ? parts[3] : nil) {
        case ("PUT", "msg", nil):
            let to = q["to"] ?? "", mid = q["mid"] ?? ""
            guard ["pc", "phone"].contains(to), !mid.isEmpty, let body = req.httpBody, !body.isEmpty else { return (Data(), 400) }
            if let had = letters.first(where: { $0.to == to && $0.mid == mid }) { return json(["seq": had.seq, "again": true, "pc": pcOn]) }
            let l = Letter(seq: next, mid: mid, to: to, at: Date().timeIntervalSince1970 * 1000, data: body)
            next += 1
            letters.append(l)
            return json(["seq": l.seq, "at": l.at, "parts": 1, "pc": pcOn, "phone": false])
        case ("GET", "msg", let s?):
            guard let l = letters.first(where: { String($0.seq) == s }) else { return (Data(#"{"error":"gone"}"#.utf8), 404) }
            return (l.data, 200)
        case ("DELETE", "msg", let s?):
            let had = letters.contains { String($0.seq) == s }
            letters.removeAll { String($0.seq) == s }
            return json(["ok": true, "had": had])
        case ("GET", "msgs", nil):
            return json(letters.filter { q["for"] == nil || $0.to == q["for"] }.map(meta))
        case ("GET", "state", nil):
            return json(["pc": pcOn, "pcSeen": 1_763_740_800_000, "phone": false, "pending": ["pc": letters.filter { $0.to == "pc" }.count, "phone": letters.filter { $0.to == "phone" }.count]])
        default:
            return (Data(), 404)
        }
    }
}

final class MailboxCryptoTests: XCTestCase {
    var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-mailc-\(UUID().uuidString)/一叶笺", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let box = "0123456789abcdef0123456789abcdef"
    var key: Data { Data((0..<32).map { UInt8($0) }) }

    func testSealOpenAndDirection() throws {
        let plain = Data("A线早班 128O件".utf8)
        let a = try MailCrypto.seal(plain, key: key, box: box, to: "pc")
        let b = try MailCrypto.seal(plain, key: key, box: box, to: "pc")
        XCTAssertEqual(a.count, 12 + plain.count + 16)                       // nonce ‖ 密文 ‖ tag
        XCTAssertNotEqual(a, b)                                               // 每封新取 nonce
        XCTAssertNil(a.range(of: Data("128O".utf8)))                          // 寄出去的字节里看不到原文
        XCTAssertEqual(try MailCrypto.open(a, key: key, box: box, to: "pc"), plain)
        XCTAssertThrowsError(try MailCrypto.open(a, key: key, box: box, to: "phone")) { XCTAssertEqual($0 as? MailError, .crypto) }   // 方向对不上
        XCTAssertThrowsError(try MailCrypto.open(a, key: key, box: "f" + box.dropFirst(), to: "pc"))                                 // 别的信箱
        XCTAssertThrowsError(try MailCrypto.open(a, key: Data(repeating: 7, count: 32), box: box, to: "pc"))                         // 钥匙不对
        var bad = a
        bad[20] ^= 0x01
        XCTAssertThrowsError(try MailCrypto.open(bad, key: key, box: box, to: "pc"))                                                 // 改过一个字节
        XCTAssertThrowsError(try MailCrypto.open(Data([1, 2, 3]), key: key, box: box, to: "pc"))
    }

    /// 别的语言加密的（Node 的 WebCrypto 出的，Python 的 cryptography 也拆得开，见接口文档 v2「对一下」）：手机拆得开
    func testOpensWhatNodeAndPythonSeal() throws {
        let sealed = Data(base64Encoded: "oKGio6SlpqeoqaqrnToKD3/5Lp0JDOm3JUDirBXfLHzmlW5O9WoEvF35MFD/RnfPngB/Hz7oJvIrSLPLcTZ3eU/iKCpxZjFulUq0gJ+MvVUAlcbM1oaebO7s9sHvfYme9O27E4pXBLjj3xy5v7QbmiGCrfXxr2Nyv6qjZ3AVTJ/8GblTRO3k0MYgl2HnZdUHp2C6NRR5z7r01hnlbk4IjwR0HAJYkdOpwYbTkXn+iBhR5e02syYZGl82DVdVCt/7agfAWefxVAN+ZIvu0IzK6VHxXkl3svxVeBYK+rBvdtkTUeCIz+16gC+0tRVKa1xU1QH1Ha3TJjouKXpdaNGjSu03Xegb2N5HUB4dsDsdqPPN9oDSVpFhqFYKQeEKRTpogYryEMlXPerairQduTU77V26Lki9VmeJ/1c0jIjbiw==")!
        let env = try MailEnvelope.decode(MailCrypto.open(sealed, key: key, box: box, to: "phone"))
        XCTAssertEqual(env.kind, .result)
        XCTAssertEqual(env.result?.text, "# 11月3日交接\n\nA线早班 1,280件")
        XCTAssertEqual(env.result?.changes, "改了 1 处：128O→1,280")
        XCTAssertEqual(env.result?.ok, true)
        XCTAssertEqual(env.result?.v, 1)
    }

    /// 收发：手机寄请求（带原图）→ 假掌机从信箱取、拆、回结果 → 手机取、拆 → 两头 ack，信箱空了
    func testSendAndReceiveThroughTheRelay() async throws {
        let relay = FakeRelay()
        let pairing = MailPairing.generate(relay: "https://relay.test/")
        let phone = try XCTUnwrap(MailClient(pairing: pairing, role: "phone", http: relay))
        let pc = try XCTUnwrap(MailClient(pairing: pairing, role: "pc", http: relay))
        XCTAssertEqual(phone.socketURL?.absoluteString, "wss://relay.test/dgj/\(pairing.box)/ws?as=phone")
        let jpg = Data((0..<300_000).map { UInt8($0 % 253) })
        let req = ButlerRequest(id: UUID().uuidString, note: UUID().uuidString, kind: .photo, text: "□班交接，128O件",
                                images: ["附件/AAAA-原图-1.jpg"], unsure: ["128O件"], at: ISOTime.string(Date()), app: "0.5.0")
        let sent = try await phone.send(.request(req, files: ["附件/AAAA-原图-1.jpg": jpg]))
        XCTAssertEqual(sent.again, false)
        XCTAssertTrue(sent.pc)
        let again = try await phone.send(.request(req, files: ["附件/AAAA-原图-1.jpg": jpg]))
        XCTAssertEqual(again.again, true)                                     // 重寄不存第二份
        XCTAssertEqual(relay.stored.count, 1)
        XCTAssertNil(relay.stored[0].data.range(of: Data("128O".utf8)))      // 信箱里只有密文

        // 假掌机
        let waiting = try await pc.pending()
        XCTAssertEqual(waiting.map(\.mid), [req.id])
        let got = try await pc.receive(waiting[0])
        XCTAssertEqual(got.request, req)
        XCTAssertEqual(got.files["附件/AAAA-原图-1.jpg"], jpg)
        await XCTAssertThrowsAsync(try await phone.receive(waiting[0])) { XCTAssertEqual($0 as? MailError, .crypto) }   // 寄给掌机的，手机拆不开
        let res = ButlerResult(id: req.id, note: req.note, ok: true, text: "早班交接，1280件", changes: "改了 2 处", error: nil, at: ISOTime.string(Date()))
        _ = try await pc.send(.result(res))
        try await pc.ack(waiting[0].seq)

        // 手机
        let mine = try await phone.pending()
        XCTAssertEqual(mine.count, 1)
        let back = try await phone.receive(mine[0])
        XCTAssertEqual(back.result, res)
        try await phone.ack(mine[0].seq)
        XCTAssertTrue(relay.stored.isEmpty)
        await XCTAssertThrowsAsync(try await phone.receive(mine[0])) { XCTAssertEqual($0 as? MailError, .gone) }

        // 推送带着内容（小信）：不用再去取
        let sealed = try pc.seal(.result(res), to: "phone")
        let before = relay.hits.count
        let inline = MailItem(seq: 99, mid: res.id, to: "phone", at: 0, size: sealed.count, data: sealed.base64EncodedString())
        let fromPush = try await phone.receive(inline)
        XCTAssertEqual(fromPush.result, res)
        XCTAssertEqual(relay.hits.count, before)

        let st = try await phone.state()
        XCTAssertTrue(st.pc)
        XCTAssertEqual(st.pcSeen, Date(timeIntervalSince1970: 1_763_740_800))
    }

    /// iCloud 备胎：信箱寄不出去（网不通、站里出错）就写 iCloud 文件夹（v1）；没配信箱直接走 iCloud；两条都没有就失败
    func testFallsBackToICloud() async throws {
        let fs = PlainFileAccess()
        let ch = ButlerChannel(root: root, fs: fs)
        let icloud: @Sendable (ButlerRequest) async throws -> Void = { r in try ch.submit(r) }
        let relay = FakeRelay()
        let mail = try XCTUnwrap(MailClient(pairing: MailPairing.generate(), http: relay))
        func req(_ id: String) -> ButlerRequest {
            ButlerRequest(id: id, note: "N", kind: .text, text: "x", images: nil, unsure: nil, at: ISOTime.string(Date()), app: "0.5.0")
        }
        func inbox() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: ch.inbox.path)) ?? []).sorted() }

        // 信箱好好的：走信箱，iCloud 里什么都没有
        let r1 = await ButlerOutbox.submit(req("REQ-0001"), files: [:], mail: mail, icloud: icloud)
        XCTAssertEqual(r1, .mailbox(seq: 1))
        XCTAssertEqual(inbox(), [])
        // 网不通：写进 iCloud 的 待理顺/（v1 的文件，v 还是 1）
        relay.failNext = -1
        guard case .icloud(let why?) = await ButlerOutbox.submit(req("REQ-0002"), files: [:], mail: mail, icloud: icloud) else { return XCTFail("没走 iCloud") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(inbox(), ["REQ-0002.json"])
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: ch.inbox.appendingPathComponent("REQ-0002.json"))) as! [String: Any]
        XCTAssertEqual(obj["v"] as? Int, 1)
        // 站里出错（满了）：也走 iCloud
        relay.failNext = 429
        let r3 = await ButlerOutbox.submit(req("REQ-0003"), files: [:], mail: mail, icloud: icloud)
        XCTAssertEqual(r3, .icloud(why: MailError.http(429, #"{"error":"busy"}"#).errorDescription))
        // 没配信箱：直接 iCloud
        let r4 = await ButlerOutbox.submit(req("REQ-0004"), files: [:], mail: nil, icloud: icloud)
        XCTAssertEqual(r4, .icloud(why: nil))
        XCTAssertEqual(inbox(), ["REQ-0002.json", "REQ-0003.json", "REQ-0004.json"])
        // 两条都没有
        relay.failNext = 500
        guard case .failed = await ButlerOutbox.submit(req("REQ-0005"), files: [:], mail: mail, icloud: nil) else { return XCTFail("应该失败") }
        guard case .failed = await ButlerOutbox.submit(req("REQ-0006"), files: [:], mail: nil, icloud: nil) else { return XCTFail("应该失败") }
        // 信太大：不往信箱寄，走 iCloud
        let big = Data(count: MailClient.maxLetter)
        guard case .icloud = await ButlerOutbox.submit(req("REQ-0007"), files: ["附件/big.jpg": big], mail: mail, icloud: icloud) else { return XCTFail("太大的没走 iCloud") }
        XCTAssertEqual(relay.stored.map(\.mid), ["REQ-0001"])
    }
}

/// XCTAssertThrowsError 的 async 版
func XCTAssertThrowsAsync<T>(_ expr: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line, _ check: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expr()
        XCTFail("没抛错", file: file, line: line)
    } catch {
        check(error)
    }
}
#endif
