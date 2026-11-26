import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 130 备用信箱（谷歌 Firebase Realtime Database，REST）：Cloudflare 叫不应时，信走这根管子。
// 只换管子：信箱号、钥匙、信封、信的 id、各种 kind 一个不改；加密照旧（AES-256-GCM，AAD yiye-dgj/2/<box>/<to>）。
// 协议在 ios/docs/大管家接口.md「v3.9 备用信箱」。配置（apiKey、databaseURL）这个仓库是公开的，不写在这里：
// 大管家经 Cloudflare 递来一封 kind2=config，手机存钥匙串。日志里不出现配置、令牌、信的内容。

// ================================================================ 配置
public struct FbConfig: Codable, Equatable, Sendable {
    public var type: String
    public var apiKey: String
    public var databaseURL: String

    public init(type: String = "firebase-rtdb", apiKey: String, databaseURL: String) {
        self.type = type; self.apiKey = apiKey; self.databaseURL = databaseURL
    }

    /// 数据库根地址（去掉末尾的斜杠）；不是 https 的不要
    public var baseURL: URL? {
        var s = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), u.scheme?.lowercased() == "https", u.host != nil else { return nil }
        return u
    }

    public var isValid: Bool {
        type == "firebase-rtdb" && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && baseURL != nil
    }
}

/// 大管家递来的配置：`kind=delivery, kind2=config`，data 里 `backup`（信封和 data 里各写了一份 kind2，认哪个都行）
public struct FbConfigLetter: Equatable, Sendable {
    public var id: String
    public var at: String
    public var config: FbConfig
    public init(id: String, at: String, config: FbConfig) { self.id = id; self.at = at; self.config = config }
}

// ================================================================ 一封信怎么放进数据库
public enum FbChunk {
    /// 每片最多这么多个字符（base64 之后）
    public static let piece = 1_000_000
    /// 一封最大这么多字节（密文）；超了这条管子不收，走 Cloudflare
    public static let maxRaw = 10 * 1024 * 1024

    /// 密文 → base64 → 切成每片 ≤ piece 个字符（空的也有一片）
    public static func split(_ sealed: Data) -> [String] {
        let b = sealed.base64EncodedString()
        if b.isEmpty { return [""] }
        var out: [String] = []
        var i = b.startIndex
        while i < b.endIndex {
            let j = b.index(i, offsetBy: piece, limitedBy: b.endIndex) ?? b.endIndex
            out.append(String(b[i..<j]))
            i = j
        }
        return out
    }

    /// 片拼回去、核对字节数；不对 nil
    public static func join(_ parts: [String], size: Int) -> Data? {
        guard let d = Data(base64Encoded: parts.joined()), d.count == size else { return nil }
        return d
    }
}

// ================================================================ 事件流（Server-Sent Events）
public struct FbStreamEvent: Equatable, Sendable {
    public var event: String
    public var data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}

/// 一行一行喂。Firebase 的 data 总是一行，所以「event:」记下名字，遇到「data:」就交出一条（不靠空行，URLSession 的 lines 会吞空行）
public struct SSEParser: Sendable {
    private var event = ""
    public init() {}

    public mutating func feed(_ rawLine: String) -> FbStreamEvent? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line.isEmpty || line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let d = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let e = event.isEmpty ? "message" : event
            event = ""
            return FbStreamEvent(event: e, data: d)
        }
        return nil
    }
}

/// 流里 put / patch 事件拼出来的那棵树：`to_phone/<mid>/p/<i>` 和 `meta`。meta 和所有片都到了、字节数对，就是一封到齐的信
public struct FbLetterTree {
    public struct Update: Equatable, Sendable {
        /// 刚到齐的信：信封号、密文
        public var letters: [FbLetterBody] = []
        /// 令牌不行了（cancel / auth_revoked）：换令牌重连
        public var revoked = false
        /// 到齐了但字节数对不上的信封号
        public var broken: [String] = []
    }

    private var root: [String: Any] = [:]
    private var emitted: Set<String> = []

    public init() {}

    /// 重连：一棵新树（还没删的信会再给一遍，按信封号去重）
    public mutating func reset() {
        root = [:]
        emitted = []
    }

    static func norm(_ v: Any?) -> Any? {
        if v is NSNull { return nil }
        if let a = v as? [Any] {
            var d: [String: Any] = [:]
            for (i, x) in a.enumerated() { if let n = norm(x) { d[String(i)] = n } }
            return d
        }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d { if let n = norm(x) { out[k] = n } }
            return out
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

    public mutating func apply(_ ev: FbStreamEvent) -> Update {
        var up = Update()
        switch ev.event {
        case "cancel", "auth_revoked":
            up.revoked = true
            return up
        case "put", "patch":
            break
        default:
            return up
        }
        guard let raw = ev.data.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? [String: Any],
              let path = obj["path"] as? String else { return up }
        let comps = path.split(separator: "/").map(String.init)
        let data = FbLetterTree.norm(obj["data"])
        var touched: Set<String> = []
        if ev.event == "put" {
            if comps.isEmpty {
                root = (data as? [String: Any]) ?? [:]
                touched = Set(root.keys)
            } else {
                FbLetterTree.set(&root, comps[...], data)
                touched = [comps[0]]
            }
        } else {                                       // patch：把 data 里的每个键并到 path 下面
            guard let d = data as? [String: Any] else { return up }
            for (k, v) in d {
                FbLetterTree.set(&root, (comps + [k])[...], v)
                touched.insert(comps.first ?? k)
            }
        }
        emitted = emitted.intersection(Set(root.keys))
        for mid in touched.sorted() where !emitted.contains(mid) {
            guard let node = root[mid] as? [String: Any],
                  let meta = node["meta"] as? [String: Any],
                  let n = (meta["n"] as? NSNumber)?.intValue, n >= 1,
                  let size = (meta["size"] as? NSNumber)?.intValue else { continue }
            let p = (node["p"] as? [String: Any]) ?? [:]
            var parts: [String] = []
            for i in 0..<n {
                guard let s = p[String(i)] as? String else { break }
                parts.append(s)
            }
            guard parts.count == n else { continue }
            if let body = FbChunk.join(parts, size: size) {
                emitted.insert(mid)
                up.letters.append(FbLetterBody(mid: mid, body: body))
            } else if !up.broken.contains(mid) {
                emitted.insert(mid)
                up.broken.append(mid)
            }
        }
        return up
    }
}

public struct FbLetterBody: Equatable, Sendable {
    public var mid: String
    public var body: Data
    public init(mid: String, body: Data) { self.mid = mid; self.body = body }
}

// ================================================================ 匿名登录
public protocol FbTokenStore: Sendable {
    func load() -> String?
    func save(_ refreshToken: String?)
}

public enum FbError: Error, Equatable, LocalizedError {
    case noConfig
    case http(Int, String)
    case auth(String)
    case tooBig(Int)
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .noConfig: return "备用信箱没配置"
        case .http(let c, let s): return "谷歌回了 \(c)：\(s)"
        case .auth(let s): return "谷歌登录不成：\(s)"
        case .tooBig(let n): return "信太大了，备用信箱不收：\(n) 字节"
        case .incomplete: return "备用信箱的信没到齐"
        }
    }
}

/// 匿名登录：signUp 拿 idToken（1 小时）和 refreshToken；快到点（提前 5 分钟）用 refreshToken 换新的，换不成重新匿名登录。
/// refreshToken 交给 store 存（手机放钥匙串）。令牌、apiKey 不进日志，错误里也不带。
public actor FbAuth {
    private let config: FbConfig
    private let http: MailHTTP
    private let store: FbTokenStore
    private let now: @Sendable () -> Date
    private var idToken: String?
    private var expires = Date.distantPast
    private var refresh: String?

    public init(config: FbConfig, http: MailHTTP, store: FbTokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.http = http; self.store = store; self.now = now
        self.refresh = store.load()
    }

    /// 现在能用的 idToken
    public func token() async throws -> String {
        if let t = idToken, now() < expires.addingTimeInterval(-300) { return t }
        if let r = refresh {
            if (try? await renew(r)) != nil, let t = idToken { return t }
        }
        try await signUp()
        guard let t = idToken else { throw FbError.auth("没拿到令牌") }
        return t
    }

    /// 谷歌说令牌不行（401）：下次换一个
    public func invalidate() { idToken = nil }

    private func parse(_ d: Data, _ keys: (String, String, String)) throws {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let id = o[keys.0] as? String, !id.isEmpty else { throw FbError.auth("回的不对") }
        idToken = id
        if let r = o[keys.1] as? String, !r.isEmpty {
            refresh = r
            store.save(r)
        }
        let secs: Double
        if let s = o[keys.2] as? String, let v = Double(s) { secs = v } else if let v = (o[keys.2] as? NSNumber)?.doubleValue { secs = v } else { secs = 3600 }
        expires = now().addingTimeInterval(secs)
    }

    private func signUp() async throws {
        var comps = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp")!
        comps.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"returnSecureToken":true}"#.utf8)
        let (d, code) = try await http.send(req)
        guard code == 200 else { throw FbError.auth("登录 \(code)") }
        try parse(d, ("idToken", "refreshToken", "expiresIn"))
    }

    private func renew(_ r: String) async throws {
        var comps = URLComponents(string: "https://securetoken.googleapis.com/v1/token")!
        comps.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let enc = r.addingPercentEncoding(withAllowedCharacters: allowed) ?? r
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(enc)".utf8)
        let (d, code) = try await http.send(req)
        guard code == 200 else { throw FbError.auth("换令牌 \(code)") }
        try parse(d, ("id_token", "refresh_token", "expires_in"))
    }
}

// ================================================================ 管子
/// 流：一行一行的文字（手机上是 URLSession.bytes 的 lines；测试里是假的）
public protocol FbStreamer: Sendable {
    func lines(_ req: URLRequest) -> AsyncThrowingStream<String, Error>
}

public final class FbPipe: @unchecked Sendable {
    public let box: String
    public let config: FbConfig
    let auth: FbAuth
    let http: MailHTTP
    let streamer: FbStreamer?

    public init(config: FbConfig, box: String, auth: FbAuth, http: MailHTTP, streamer: FbStreamer? = nil) {
        self.config = config; self.box = box; self.auth = auth; self.http = http; self.streamer = streamer
    }

    /// 给谁的信放哪个目录
    public static func dir(to peer: String) -> String { peer == "phone" ? "to_phone" : "to_pc" }

    func url(_ path: String, token: String) throws -> URL {
        guard let base = config.baseURL else { throw FbError.noConfig }
        var comps = URLComponents(url: base.appendingPathComponent("boxes/\(box)/\(path).json"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "auth", value: token)]
        guard let u = comps?.url else { throw FbError.noConfig }
        return u
    }

    /// 带令牌调一次；401 换个令牌再来一次
    func call(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) async throws -> (Data, Int) {
        for attempt in 0..<2 {
            let tok = try await auth.token()
            var req = URLRequest(url: try url(path, token: tok), timeoutInterval: timeout)
            req.httpMethod = method
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (d, code) = try await http.send(req)
            if code == 401 && attempt == 0 {
                await auth.invalidate()
                continue
            }
            return (d, code)
        }
        throw FbError.auth("401")
    }

    static func short(_ d: Data) -> String { String(decoding: d.prefix(120), as: UTF8.self) }

    /// 寄一封：先写片 p/0…p/n-1，最后写 meta（有 meta 才算到齐）
    public func put(_ sealed: Data, mid: String, to peer: String, timeout: TimeInterval = 60) async throws {
        guard sealed.count <= FbChunk.maxRaw else { throw FbError.tooBig(sealed.count) }
        let dir = FbPipe.dir(to: peer)
        let parts = FbChunk.split(sealed)
        for (i, s) in parts.enumerated() {
            let (d, code) = try await call("PUT", "\(dir)/\(mid)/p/\(i)", body: try JSONEncoder().encode(s), timeout: timeout)
            guard code == 200 else { throw FbError.http(code, FbPipe.short(d)) }
        }
        let meta = #"{"at":{".sv":"timestamp"},"n":\#(parts.count),"size":\#(sealed.count)}"#
        let (d, code) = try await call("PUT", "\(dir)/\(mid)/meta", body: Data(meta.utf8), timeout: timeout)
        guard code == 200 else { throw FbError.http(code, FbPipe.short(d)) }
    }

    /// 删整封：收的一方办完（ack）、寄的人撤回，都是这个
    public func delete(mid: String, dir: String) async throws {
        let (d, code) = try await call("DELETE", "\(dir)/\(mid)", timeout: 20)
        guard code == 200 else { throw FbError.http(code, FbPipe.short(d)) }
    }

    /// 我在这儿：seen/<who> = 服务器时间戳
    public func writeSeen(_ who: String) async throws {
        let (d, code) = try await call("PUT", "seen/\(who)", body: Data(#"{".sv":"timestamp"}"#.utf8), timeout: 20)
        guard code == 200 else { throw FbError.http(code, FbPipe.short(d)) }
    }

    /// 大管家在不在：电脑或掌机的 seen 在 90 秒内。读不到当不在
    public func pcOnline(now: Date = Date()) async -> Bool {
        for who in ["desk", "handheld"] {
            guard let (d, code) = try? await call("GET", "seen/\(who)", timeout: 15), code == 200,
                  let ms = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? NSNumber else { continue }
            if now.timeIntervalSince1970 * 1000 - ms.doubleValue < 90_000 { return true }
        }
        return false
    }

    /// 听自己的目录（只读，不写东西）。拿不到令牌、连不上，流以错误结束
    public func events(dir: String) -> AsyncThrowingStream<FbStreamEvent, Error> {
        AsyncThrowingStream { cont in
            guard let streamer else { cont.finish(throwing: FbError.noConfig); return }
            let task = Task {
                do {
                    let tok = try await auth.token()
                    var req = URLRequest(url: try url(dir, token: tok), timeoutInterval: 3600)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var parser = SSEParser()
                    for try await line in streamer.lines(req) {
                        if let ev = parser.feed(line) { cont.yield(ev) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

// ================================================================ 听
/// 一直听 to_phone：来一封到齐的信就交出去；断了退避重连（143：2、5、10、30、60、120、300 秒，连上稳住 60 秒才从头数）；
/// 75 秒没有任何东西当断了；令牌快到点（50 分钟）主动重连
public final class FbListener: @unchecked Sendable {
    let pipe: FbPipe
    let dir: String
    let onLetter: @Sendable (FbLetterBody) -> Void
    let onBroken: @Sendable (String) -> Void
    let idleLimit: TimeInterval
    let reconnectEvery: TimeInterval
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(pipe: FbPipe, dir: String = "to_phone", idleLimit: TimeInterval = 75, reconnectEvery: TimeInterval = 3000,
                onLetter: @escaping @Sendable (FbLetterBody) -> Void, onBroken: @escaping @Sendable (String) -> Void = { _ in }) {
        self.pipe = pipe; self.dir = dir; self.idleLimit = idleLimit; self.reconnectEvery = reconnectEvery
        self.onLetter = onLetter; self.onBroken = onBroken
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [self] in await self.loop() }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func loop() async {
        var back = Backoff()
        while !Task.isCancelled {
            let got = Flag()
            let started = Date()
            do {
                try await session { got.set() }
            } catch {
                // 断了：退避重连
            }
            if Task.isCancelled { return }
            back.wake()
            if got.value { back.succeeded(started) }                       // 从连上那会儿起算稳没稳 60 秒
            let w = back.failed(Date())
            try? await Task.sleep(nanoseconds: UInt64(w * 1_000_000_000))
        }
    }

    private struct Dead: Error {}

    /// 连一次，听到断
    private func session(_ touched: @escaping @Sendable () -> Void) async throws {
        let clock = Clock()
        let started = Date()
        let limit = idleLimit, every = reconnectEvery
        try await withThrowingTaskGroup(of: Void.self) { group in
            let stream = pipe.events(dir: dir)
            group.addTask {
                var tree = FbLetterTree()
                for try await ev in stream {
                    clock.touch()
                    touched()
                    let up = tree.apply(ev)
                    if up.revoked {
                        await self.pipe.auth.invalidate()
                        throw Dead()
                    }
                    for l in up.letters { self.onLetter(l) }
                    for m in up.broken { self.onBroken(m) }
                }
                throw Dead()
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if clock.idle > limit || Date().timeIntervalSince(started) > every { throw Dead() }
                }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

// ================================================================ 什么时候换管子
/// 进「备用模式」：寄不出去（Cloudflare 连不上、5xx、4xx（413 除外）、429），或者 WebSocket 断了超过 60 秒；
/// 回去：Cloudflare（WebSocket）连续好 5 分钟。进、出都不弹提示。
public struct BackupGate: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case entered, left }

    public private(set) var on = false
    public private(set) var since: Date?
    public private(set) var wsDownSince: Date?
    public private(set) var cfGoodSince: Date?
    public var downAfter: TimeInterval = 60
    public var returnAfter: TimeInterval = 300

    public init() {}

    /// 一封信寄不出去：马上进备用模式
    public mutating func sendFailed(_ now: Date) -> Change? {
        cfGoodSince = nil
        guard !on else { return nil }
        on = true
        since = now
        return .entered
    }

    public mutating func socketDown(_ now: Date) {
        cfGoodSince = nil
        if wsDownSince == nil { wsDownSince = now }
    }

    public mutating func socketUp(_ now: Date) {
        wsDownSince = nil
        if cfGoodSince == nil { cfGoodSince = now }
    }

    /// 自己把 WebSocket 关了（退到后台）：不算断
    public mutating func socketStopped() {
        wsDownSince = nil
        cfGoodSince = nil
    }

    public mutating func tick(_ now: Date) -> Change? {
        if !on, let d = wsDownSince, now.timeIntervalSince(d) >= downAfter {
            on = true
            since = now
            return .entered
        }
        if on, let g = cfGoodSince, now.timeIntervalSince(g) >= returnAfter {
            on = false
            since = nil
            return .left
        }
        return nil
    }

    /// 这个错该不该换管子：连不上、5xx、429、4xx（413 太大除外）。信本身不对的（拆不开、太大）不换
    public static func failsOver(_ error: Error) -> Bool {
        if let e = error as? MailError {
            switch e {
            case .http(let code, _): return code != 413 && code >= 400
            case .held: return true                     // 143：信箱叫等着：走备胎，不干等
            case .gone, .crypto, .badLetter, .badPairing, .tooBig: return false
            }
        }
        return true
    }
}

/// MailClient 手里的备用管子：状态机 + 管子。线程安全；进、出备用模式通知 onChange（app 那头起、停听流和 seen）
public final class MailBackup: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = BackupGate()
    private var pipe: FbPipe?
    public var onChange: (@Sendable (BackupGate.Change) -> Void)?

    public init() {}

    public func setPipe(_ p: FbPipe?) {
        lock.lock(); pipe = p; lock.unlock()
    }

    public var currentPipe: FbPipe? { lock.lock(); defer { lock.unlock() }; return pipe }
    public var isOn: Bool { lock.lock(); defer { lock.unlock() }; return gate.on }
    public var hasPipe: Bool { currentPipe != nil }

    func mutate(_ f: (inout BackupGate) -> BackupGate.Change?) {
        lock.lock()
        let c = pipe == nil ? nil : f(&gate)
        lock.unlock()
        if let c { onChange?(c) }
    }

    public func sendFailed(_ now: Date = Date()) { mutate { $0.sendFailed(now) } }
    public func socketDown(_ now: Date = Date()) { mutate { $0.socketDown(now); return nil } }
    public func socketUp(_ now: Date = Date()) { mutate { $0.socketUp(now); return nil } }
    public func socketStopped() { mutate { $0.socketStopped(); return nil } }
    public func tick(_ now: Date = Date()) { mutate { $0.tick(now) } }

    /// 走备用管子寄一封。-1 是备用管子寄的「号」（没有信箱里的号）；pc 看 seen
    func put(_ body: Data, mid: String, to peer: String) async throws -> MailSent {
        guard let p = currentPipe else { throw FbError.noConfig }
        try await p.put(body, mid: mid, to: peer)
        return MailSent(seq: -1, again: false, pc: await p.pcOnline())
    }
}
