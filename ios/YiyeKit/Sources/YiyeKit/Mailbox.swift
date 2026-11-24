import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// 一叶笺 ⇄ 大管家 接口 v2（ios/docs/大管家接口.md「v2」）：走 Cloudflare 信箱（luruseng-relay 的 /dgj）。
// 信里装的还是 v1 那几样（请求、结果、送来），字段一个不改，图和录音跟着信走。
// 两头加密（AES-256-GCM），钥匙只在手机（钥匙串）和掌机上，站里只有密文。信箱连不上才走 iCloud 文件夹（v1，Butler.swift）。

// ================================================================ 配对
/// 掌机生成，写进 iCloud 的 _大管家/配对.json（只写一次），也在掌机屏幕上出成二维码。手机读到一次就存进钥匙串。
public struct MailPairing: Codable, Equatable, Sendable {
    public var v: Int
    public var relay: String
    /// 信箱号：16 字节随机，32 个小写十六进制字
    public var box: String
    /// 钥匙：32 字节随机，base64url（不带 =）
    public var key: String
    public var host: String?
    public var at: String?

    public static let version = 2
    public static let fileName = "配对.json"
    public static let defaultRelay = "https://luruseng-relay.lunzigeju.workers.dev"

    public init(v: Int = MailPairing.version, relay: String = MailPairing.defaultRelay, box: String, key: String, host: String? = nil, at: String? = nil) {
        self.v = v; self.relay = relay; self.box = box; self.key = key; self.host = host; self.at = at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? MailPairing.version
        relay = try c.decodeIfPresent(String.self, forKey: .relay) ?? MailPairing.defaultRelay
        box = try c.decode(String.self, forKey: .box)
        key = try c.decode(String.self, forKey: .key)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        at = try c.decodeIfPresent(String.self, forKey: .at)
    }

    /// 新配一对（掌机那头做的事；测试、假掌机也用）
    public static func generate(relay: String = MailPairing.defaultRelay, host: String = "掌机", at: Date = Date()) -> MailPairing {
        var g = SystemRandomNumberGenerator()
        let box = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })
        return MailPairing(relay: relay, box: box, key: Base64URL.encode(key), host: host, at: ISOTime.string(at))
    }

    public var keyData: Data? {
        guard let d = Base64URL.decode(key), d.count == 32 else { return nil }
        return d
    }

    public var relayURL: URL? {
        guard let u = URL(string: relay), let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return nil }
        return u
    }

    public var isValid: Bool {
        v == MailPairing.version && box.count == 32 && box.allSatisfy({ "0123456789abcdef".contains($0) }) && keyData != nil && relayURL != nil
    }

    /// 配对.json、二维码、粘贴进来的字：一段 JSON（前后的空白、换行不管）。不对就 nil
    public static func parse(_ data: Data) -> MailPairing? {
        guard let p = try? JSONDecoder().decode(MailPairing.self, from: data), p.isValid else { return nil }
        return p
    }

    public static func parse(_ text: String) -> MailPairing? {
        parse(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    /// 二维码、配对码里的字：压成一行的 JSON
    public var code: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? e.encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// iCloud 里读到的这份要不要换掉手里的：手里没有就要；一样的不换；不一样的，比手里的新才换（掌机重配过）
    public static func shouldAdopt(_ found: MailPairing, over current: MailPairing?) -> Bool {
        guard found.isValid else { return false }
        guard let current else { return true }
        if found.box == current.box && found.key == current.key && found.relay == current.relay { return false }
        guard let a = found.at.flatMap({ ISOTime.date($0) }) else { return false }
        guard let b = current.at.flatMap({ ISOTime.date($0) }) else { return true }
        return a > b
    }
}

public enum Base64URL {
    public static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

extension ButlerChannel {
    /// _大管家/配对.json（掌机写的；手机只读）
    public var pairingURL: URL { dir.appendingPathComponent(MailPairing.fileName) }

    /// 读 iCloud 里的配对（占位的先叫它下载）。没有、没下好、不对：nil
    public func pairing() -> MailPairing? {
        let url = pairingURL
        if !fs.exists(url) {
            guard fs.exists(dir.appendingPathComponent(".\(MailPairing.fileName).icloud")) else { return nil }
        }
        guard fs.ensureDownloaded(url), let d = try? fs.read(url) else { return nil }
        return MailPairing.parse(d)
    }
}

// ================================================================ 信
public enum MailKind: String, Codable, Sendable {
    /// 手机 → 大管家：v1 的请求（理顺 ask=fix、配音 ask=speak）
    case request
    /// 大管家 → 手机：v1 的结果（已理顺/ 那一份）
    case result
    /// 大管家 → 手机：v1 的「送来」（配好音的听力稿）
    case delivery
}

/// 一封信（加密前的样子）。data 是 v1 的对象原样（v 还是 1）；files 是跟着信走的文件（相对镜像根的路径 → 内容）
public struct MailEnvelope: Equatable, Sendable {
    public static let version = 2
    public var kind: MailKind
    public var id: String
    public var at: String
    public var request: ButlerRequest?
    public var result: ButlerResult?
    public var delivery: ButlerDelivery?
    public var files: [String: Data]

    public init(kind: MailKind, id: String, at: String, request: ButlerRequest? = nil, result: ButlerResult? = nil,
                delivery: ButlerDelivery? = nil, files: [String: Data] = [:]) {
        self.kind = kind; self.id = id; self.at = at
        self.request = request; self.result = result; self.delivery = delivery; self.files = files
    }

    public static func request(_ r: ButlerRequest, files: [String: Data] = [:]) -> MailEnvelope {
        MailEnvelope(kind: .request, id: r.id, at: r.at, request: r, files: files)
    }

    public static func result(_ r: ButlerResult) -> MailEnvelope {
        MailEnvelope(kind: .result, id: r.id, at: r.at ?? ISOTime.string(Date()), result: r)
    }

    public static func delivery(_ d: ButlerDelivery, files: [String: Data] = [:]) -> MailEnvelope {
        MailEnvelope(kind: .delivery, id: d.id, at: d.at ?? ISOTime.string(Date()), delivery: d, files: files)
    }

    private struct Head: Codable { var v: Int; var kind: MailKind; var id: String; var at: String? }
    private struct Wire<T: Codable>: Codable { var v: Int; var kind: MailKind; var id: String; var at: String?; var data: T; var files: [String: Data]? }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let f: [String: Data]? = files.isEmpty ? nil : files
        let v = MailEnvelope.version
        switch kind {
        case .request:
            guard let r = request else { throw MailError.badLetter("request 没有 data") }
            return try e.encode(Wire(v: v, kind: kind, id: id, at: at, data: r, files: f))
        case .result:
            guard let r = result else { throw MailError.badLetter("result 没有 data") }
            return try e.encode(Wire(v: v, kind: kind, id: id, at: at, data: r, files: f))
        case .delivery:
            guard let d = delivery else { throw MailError.badLetter("delivery 没有 data") }
            return try e.encode(Wire(v: v, kind: kind, id: id, at: at, data: d, files: f))
        }
    }

    public static func decode(_ data: Data) throws -> MailEnvelope {
        let d = JSONDecoder()
        let head: Head
        do { head = try d.decode(Head.self, from: data) } catch { throw MailError.badLetter("拆开了不是一封信") }
        guard head.v == version else { throw MailError.badLetter("接口版本不对：手机 v\(version)，信 v\(head.v)") }
        var env = MailEnvelope(kind: head.kind, id: head.id, at: head.at ?? "")
        do {
            switch head.kind {
            case .request:
                let w = try d.decode(Wire<ButlerRequest>.self, from: data)
                env.request = w.data; env.files = w.files ?? [:]
            case .result:
                let w = try d.decode(Wire<ButlerResult>.self, from: data)
                env.result = w.data; env.files = w.files ?? [:]
            case .delivery:
                let w = try d.decode(Wire<ButlerDelivery>.self, from: data)
                env.delivery = w.data; env.files = w.files ?? [:]
            }
        } catch {
            throw MailError.badLetter("\(head.kind.rawValue) 的字段不对")
        }
        return env
    }
}

public enum MailError: Error, Equatable, LocalizedError {
    case badPairing
    case crypto
    /// 信箱里已经没有这封了（被取走、撤回、过期）
    case gone
    case tooBig(Int)
    case http(Int, String)
    case badLetter(String)

    public var errorDescription: String? {
        switch self {
        case .badPairing: return "配对不对"
        case .crypto: return "拆不开：钥匙对不上，或者信坏了"
        case .gone: return "信箱里已经没有这封了"
        case .tooBig(let n): return "信太大了：\(n) 字节"
        case .http(let c, let s): return "信箱回了 \(c)：\(s)"
        case .badLetter(let s): return s
        }
    }

    /// 再试也没用的（拆不开、不是信、已经没了）：收的一方直接 ack 掉，别让它堵在信箱里
    public var isPermanent: Bool {
        switch self {
        case .crypto, .badLetter, .gone: return true
        default: return false
        }
    }
}

// ================================================================ 信箱推过来的
/// 信箱里一封信的样子（不含内容；小信的 data 是 base64 的密文，跟着推送来了）
public struct MailItem: Codable, Equatable, Sendable {
    public var seq: Int
    public var mid: String
    public var to: String
    public var at: Double
    public var size: Int
    public var data: String?
    public init(seq: Int, mid: String, to: String, at: Double, size: Int, data: String? = nil) {
        self.seq = seq; self.mid = mid; self.to = to; self.at = at; self.size = size; self.data = data
    }
}

public enum MailPush: Equatable, Sendable {
    /// 刚连上：攒着的信、大管家在不在、上次在线
    case hello(items: [MailItem], pc: Bool, pcSeen: Date?)
    case msg(MailItem)
    case gone(seq: Int, mid: String, to: String, expired: Bool)
    case pc(on: Bool, seen: Date?)
    case state(pc: Bool, pcSeen: Date?)
    case pong
    case other(String)

    private struct Wire: Decodable {
        var t: String
        var items: [MailItem]?
        var item: MailItem?
        var pc: Bool?
        var pcSeen: Double?
        var seq: Int?
        var mid: String?
        var to: String?
        var on: Bool?
        var seen: Double?
        var expired: Bool?
    }

    public static func parse(_ text: String) -> MailPush {
        if text == "pong" { return .pong }
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(text.utf8)) else { return .other(String(text.prefix(120))) }
        func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        switch w.t {
        case "hello": return .hello(items: w.items ?? [], pc: w.pc ?? false, pcSeen: date(w.pcSeen))
        case "msg": if let it = w.item { return .msg(it) }
        case "gone": if let s = w.seq { return .gone(seq: s, mid: w.mid ?? "", to: w.to ?? "", expired: w.expired ?? false) }
        case "pc": return .pc(on: w.on ?? false, seen: date(w.seen))
        case "state": return .state(pc: w.pc ?? false, pcSeen: date(w.pcSeen))
        default: break
        }
        return .other(w.t)
    }
}

extension ButlerPresence {
    /// 信箱报的：在线，或者不在、最后一次见到是几点
    public static func relay(on: Bool, seen: Date?) -> ButlerPresence { on ? .online : .away(since: seen) }

    /// 横条听谁的：信箱连着就听信箱的；信箱连不上（没配对、断网）才看 iCloud 心跳
    public static func current(relayUp: Bool, relayOn: Bool, relaySeen: Date?, heartbeat: ButlerPresence) -> ButlerPresence {
        relayUp ? relay(on: relayOn, seen: relaySeen) : heartbeat
    }
}

/// 收到一封信，手机这头该干什么（笔记在 app 里，这里只按 id 认）
public enum MailAction: Equatable, Sendable {
    /// 理好的结果：换进在等它的那条笔记（ButlerNoteState.receive 那一套）
    case apply(ButlerResult, note: UUID)
    /// 配音没配成：清掉那条的「在等配音」
    case dubFailed(ButlerResult, note: UUID)
    /// 「会了 / 不会」的回信（088）：ok 就从队里拿掉，不 ok 过一会儿再寄
    case word(ButlerResult)
    /// 陪玩的回答（100）：配好的音跟着信来，直接放；没配成音的，手机用自己的声音念 text
    case look(ButlerResult, audio: Data?)
    /// 抄到电脑的回信（111）：电脑回 ok + host=电脑 才算寄到；掌机回 desk-only 不算
    case keep(ButlerResult)
    /// 送来的听力稿 / 配好的音
    case deliver(ButlerDelivery, audio: Data?)
    /// 送来的录音信里没带、本地也没有：先别 ack，下回再拿
    case later
    /// 没人在等（重复的、撤回了的）、不是给手机的：ack 掉就行
    case drop(String)

    /// waiting：在等理顺结果的「请求 id → 笔记」；dubbing：在等配音的「请求 id → 笔记」；words：排着队的「会了 / 不会」的请求 id；
    /// localAudio：信里没带录音时去 iCloud 找
    public static func decide(_ env: MailEnvelope, waiting: [String: UUID], dubbing: [String: UUID], words: Set<String> = [],
                              looks: Set<String> = [], keeps: Set<String> = [], localAudio: (String) -> Data? = { _ in nil }) -> MailAction {
        switch env.kind {
        case .result:
            guard let r = env.result else { return .drop("result 没有 data") }
            if looks.contains(r.id) { return .look(r, audio: r.audio.flatMap { env.files[$0] }) }
            if keeps.contains(r.re ?? r.id) { return .keep(r) }
            if words.contains(r.id) { return .word(r) }
            if let n = waiting[r.id] { return .apply(r, note: n) }
            if !r.ok, let n = dubbing[r.id] { return .dubFailed(r, note: n) }
            return .drop("没人在等 \(r.id)")
        case .delivery:
            guard let d = env.delivery else { return .drop("delivery 没有 data") }
            guard let a = d.audio else { return .deliver(d, audio: nil) }
            if let data = env.files[a] ?? localAudio(a) { return .deliver(d, audio: data) }
            return .later
        case .request:
            return .drop("手机不收请求")
        }
    }
}

#if canImport(CryptoKit)
// ================================================================ 加密：AES-256-GCM
/// 寄出去的字节 = nonce(12) ‖ 密文 ‖ tag(16)；附加数据「yiye-dgj/2/<信箱号>/<收信的一方>」，方向对不上拆不开
public enum MailCrypto {
    public static func aad(box: String, to: String) -> Data { Data("yiye-dgj/2/\(box)/\(to)".utf8) }

    public static func seal(_ plain: Data, key: Data, box: String, to: String) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(), authenticating: aad(box: box, to: to))
        guard let out = sealed.combined else { throw MailError.crypto }
        return out
    }

    public static func open(_ data: Data, key: Data, box: String, to: String) throws -> Data {
        do {
            let sb = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sb, using: SymmetricKey(data: key), authenticating: aad(box: box, to: to))
        } catch {
            throw MailError.crypto
        }
    }
}

// ================================================================ 收发
/// 发 HTTP 这一层抽出来：手机上走 URLSession，测试里换成假的信箱
public protocol MailHTTP: Sendable {
    func send(_ req: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionHTTP: MailHTTP {
    public init() {}
    public func send(_ req: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct MailSent: Equatable, Sendable {
    public var seq: Int
    public var again: Bool
    /// 寄到的时候大管家在不在线
    public var pc: Bool
}

/// 一头（手机 role=phone；假掌机、测试 role=pc）对着信箱寄信、取信、ack
public final class MailClient: Sendable {
    public static let maxLetter = 24_000_000
    public let pairing: MailPairing
    public let role: String
    let http: MailHTTP
    let keyBytes: Data

    public init?(pairing: MailPairing, role: String = "phone", http: MailHTTP = URLSessionHTTP()) {
        guard pairing.isValid, let k = pairing.keyData, role == "phone" || role == "pc" else { return nil }
        self.pairing = pairing; self.role = role; self.http = http; self.keyBytes = k
    }

    /// 寄给谁：手机寄给 pc，掌机寄给 phone
    public var peer: String { role == "phone" ? "pc" : "phone" }

    var base: String {
        var s = pairing.relay
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func url(_ tail: String) throws -> URL {
        guard let u = URL(string: "\(base)/dgj/\(pairing.box)/\(tail)") else { throw MailError.badPairing }
        return u
    }

    /// WebSocket 的地址：wss://…/dgj/<信箱号>/ws?as=<role>
    public var socketURL: URL? {
        var s = base
        if s.hasPrefix("https://") { s = "wss://" + String(s.dropFirst(8)) } else if s.hasPrefix("http://") { s = "ws://" + String(s.dropFirst(7)) }
        return URL(string: "\(s)/dgj/\(pairing.box)/ws?as=\(role)")
    }

    public func seal(_ env: MailEnvelope, to: String) throws -> Data {
        try MailCrypto.seal(env.encoded(), key: keyBytes, box: pairing.box, to: to)
    }

    /// 拆一封寄给自己的
    public func open(_ data: Data) throws -> MailEnvelope {
        try MailEnvelope.decode(MailCrypto.open(data, key: keyBytes, box: pairing.box, to: role))
    }

    static func safeID(_ id: String) throws -> String {
        guard (6...64).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw MailError.badLetter("信的 id 不对：\(id)")
        }
        return id
    }

    /// 寄一封给对面：加密、PUT。同一个 id 重寄，信箱不存第二份
    public func send(_ env: MailEnvelope, timeout: TimeInterval = 20) async throws -> MailSent {
        let body = try seal(env, to: peer)
        guard body.count <= MailClient.maxLetter else { throw MailError.tooBig(body.count) }
        let mid = try MailClient.safeID(env.id)
        let u = try url("msg?to=\(peer)&mid=\(mid)")
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (d, code) = try await http.send(req)
        guard code == 200 else { throw MailError.http(code, String(decoding: d.prefix(300), as: UTF8.self)) }
        struct R: Decodable { var seq: Int; var again: Bool?; var pc: Bool? }
        guard let r = try? JSONDecoder().decode(R.self, from: d) else { throw MailError.http(code, "回的不是 JSON") }
        return MailSent(seq: r.seq, again: r.again ?? false, pc: r.pc ?? false)
    }

    /// 取一封：推送带着内容就直接拆，没带就去信箱取
    public func receive(_ item: MailItem, timeout: TimeInterval = 30) async throws -> MailEnvelope {
        if let b = item.data, let d = Data(base64Encoded: b) { return try open(d) }
        let u = try url("msg/\(item.seq)")
        let (d, code) = try await http.send(URLRequest(url: u, timeoutInterval: timeout))
        if code == 404 { throw MailError.gone }
        guard code == 200 else { throw MailError.http(code, String(decoding: d.prefix(300), as: UTF8.self)) }
        return try open(d)
    }

    /// 收到了（处理完）：删。寄的人撤回还没被取走的，也是这个
    public func ack(_ seq: Int, timeout: TimeInterval = 15) async throws {
        let u = try url("msg/\(seq)")
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "DELETE"
        let (d, code) = try await http.send(req)
        guard code == 200 else { throw MailError.http(code, String(decoding: d.prefix(300), as: UTF8.self)) }
    }

    /// 寄给自己、还没取的（连不上 WebSocket 时用）
    public func pending(timeout: TimeInterval = 15) async throws -> [MailItem] {
        let u = try url("msgs?for=\(role)")
        let (d, code) = try await http.send(URLRequest(url: u, timeoutInterval: timeout))
        guard code == 200 else { throw MailError.http(code, String(decoding: d.prefix(300), as: UTF8.self)) }
        return try JSONDecoder().decode([MailItem].self, from: d)
    }

    /// 大管家在不在、上次在线
    public func state(timeout: TimeInterval = 15) async throws -> (pc: Bool, pcSeen: Date?) {
        let u = try url("state")
        let (d, code) = try await http.send(URLRequest(url: u, timeoutInterval: timeout))
        guard code == 200 else { throw MailError.http(code, String(decoding: d.prefix(300), as: UTF8.self)) }
        struct S: Decodable { var pc: Bool; var pcSeen: Double? }
        let s = try JSONDecoder().decode(S.self, from: d)
        return (s.pc, s.pcSeen.map { Date(timeIntervalSince1970: $0 / 1000) })
    }
}

/// 交一个请求走哪条路
public enum ButlerRoute: Equatable, Sendable {
    /// 走信箱寄到了（seq：信箱里的号，撤回用）
    case mailbox(seq: Int)
    /// 走 iCloud（v1）：why 是信箱为什么没走成（没配对就是 nil）
    case icloud(why: String?)
    /// 两条都不行
    case failed(String)
}

public enum ButlerOutbox {
    /// 配了信箱先走信箱；寄不出去（网不通、站里出错、太大、满了）再走 iCloud；两条都没有就失败
    public static func submit(_ r: ButlerRequest, files: [String: Data], mail: MailClient?,
                              icloud: (@Sendable (ButlerRequest) async throws -> Void)?) async -> ButlerRoute {
        var why: String? = nil
        if let mail {
            do {
                let sent = try await mail.send(.request(r, files: files))
                return .mailbox(seq: sent.seq)
            } catch {
                why = (error as? MailError)?.errorDescription ?? error.localizedDescription
            }
        }
        guard let icloud else { return .failed(why ?? "没配信箱，也没选镜像文件夹") }
        do {
            try await icloud(r)
            return .icloud(why: why)
        } catch {
            return .failed([why, error.localizedDescription].compactMap { $0 }.joined(separator: "；"))
        }
    }
}

// ================================================================ 长连接
/// 连着信箱的那根 WebSocket。断了自己重连（等 2、5、10、30、60 秒），每 keepAliveEvery 秒发一句 keepAlive（保活，顺便问状态）。
/// 手机：app 在前台时开着，keepAlive 是 {"t":"state"}；掌机那头用文本 "ping"（站里自动回 pong，不算额度）。
public final class MailSocket: @unchecked Sendable {
    public let url: URL
    public var keepAlive = #"{"t":"state"}"#
    public var keepAliveEvery: TimeInterval = 30
    private let q = DispatchQueue(label: "lab.qianshou.yiye.mailsocket")
    private let onPush: @Sendable (MailPush) -> Void
    private let onDown: @Sendable (String) -> Void
    /// 收到的原文（111：从 hello / state / pc 里读 pcs，哪几台大管家在线）
    public var onText: (@Sendable (String) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var attempt = 0
    private var gen = 0

    public init(url: URL, onPush: @escaping @Sendable (MailPush) -> Void, onDown: @escaping @Sendable (String) -> Void) {
        self.url = url; self.onPush = onPush; self.onDown = onDown
    }

    public func start() {
        q.async {
            guard !self.running else { return }
            self.running = true
            self.attempt = 0
            self.connect()
        }
    }

    public func stop() {
        q.async {
            self.running = false
            self.gen += 1
            self.timer?.cancel()
            self.timer = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    public func send(_ text: String) {
        q.async { self.task?.send(.string(text)) { _ in } }
    }

    private func connect() {
        gen += 1
        let g = gen
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t, g)
        startTimer(g)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard g == self.gen, self.running else { return }
                switch result {
                case .success(let m):
                    self.attempt = 0
                    switch m {
                    case .string(let s): self.onText?(s); self.onPush(MailPush.parse(s))
                    case .data(let d): let s = String(decoding: d, as: UTF8.self); self.onText?(s); self.onPush(MailPush.parse(s))
                    @unknown default: break
                    }
                    self.receive(t, g)
                case .failure(let e):
                    self.drop(t, e.localizedDescription)
                }
            }
        }
    }

    private func drop(_ t: URLSessionWebSocketTask, _ why: String) {
        t.cancel(with: .goingAway, reason: nil)
        timer?.cancel()
        timer = nil
        task = nil
        onDown(why)
        let waits: [Double] = [2, 5, 10, 30, 60]
        let w = waits[min(attempt, waits.count - 1)]
        attempt += 1
        gen += 1
        let g = gen
        q.asyncAfter(deadline: .now() + w) { [weak self] in
            guard let self, self.running, self.gen == g else { return }
            self.connect()
        }
    }

    private func startTimer(_ g: Int) {
        timer?.cancel()
        let tm = DispatchSource.makeTimerSource(queue: q)
        tm.schedule(deadline: .now() + keepAliveEvery, repeating: keepAliveEvery)
        tm.setEventHandler { [weak self] in
            guard let self, self.gen == g, let t = self.task else { return }
            t.send(.string(self.keepAlive)) { _ in }
        }
        tm.resume()
        timer = tm
    }
}
#endif
