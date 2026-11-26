import Foundation

// 143：信箱出事时别把小故障敲成风暴（11-24 免费额度被用光停了一天，125、140 报告列过手机这头的缝）。
// 规则照掌机大管家 pc-butler handheld/dgjbox.py 的 Brake（142）：
// - 失败指数退避 2、5、10、30、60、120、300 秒，封顶 5 分钟；通了以后稳住 60 秒没再出错，下一次出错才从头数。
// - 429 / 503 带 Retry-After：照它等（最多 1 小时）。额度用光（503 do_quota）：等到 UTC 0 点过 1 分钟；
//   UTC 0 点过后头一个小时 Cloudflare 解封会晚（140：00:27 才通），那一小时照 Retry-After 一遍遍问。
// - 等着的时候有谷歌备胎（130）就走备胎，不干等。

/// 指数退避。纯值类型，时间从外面传，好测
public struct Backoff: Equatable, Sendable {
    public static let steps: [Double] = [2, 5, 10, 30, 60, 120, 300]
    public static let stable: TimeInterval = 60

    public private(set) var fails = 0
    public private(set) var until: Date?
    /// 上次出错以后第一回通的时间
    private var goodSince: Date?

    public init() {}

    /// 出错了。-> 还要等几秒。正在等的时候又来一个错（同一批寄出去的）不多记
    @discardableResult
    public mutating func failed(_ now: Date) -> TimeInterval {
        if let g = goodSince, now.timeIntervalSince(g) >= Backoff.stable { fails = 0 }
        goodSince = nil
        if let u = until, u > now { return u.timeIntervalSince(now) }
        let w = Backoff.steps[min(fails, Backoff.steps.count - 1)]
        fails += 1
        until = now.addingTimeInterval(w)
        return w
    }

    /// 通了：马上能再用；次数不清（稳住 60 秒、下一次出错时才清）
    public mutating func succeeded(_ now: Date) {
        until = nil
        if goodSince == nil { goodSince = now }
    }

    /// 他自己回到前台了：这一下不等，次数留着
    public mutating func wake() { until = nil }

    public func wait(_ now: Date) -> TimeInterval { until.map { max(0, $0.timeIntervalSince(now)) } ?? 0 }
}

/// 自动寄的那些，每一条各自退避（太大的、对面不认的：别 5 秒一次地撞）。挑哪几条也在这儿
public struct ItemGate: Equatable, Sendable {
    private var items: [String: Backoff] = [:]

    public init() {}

    public func open(_ key: String, _ now: Date = Date()) -> Bool { (items[key]?.wait(now) ?? 0) <= 0 }

    public mutating func failed(_ key: String, _ now: Date = Date()) {
        var b = items[key] ?? Backoff()
        b.failed(now)
        items[key] = b
    }

    public mutating func succeeded(_ key: String) { items[key] = nil }

    /// 这一轮寄哪几条：信箱让寄（ready），最多 limit 条（扣掉还在路上的），自己还在退避的跳过
    public func pick(_ keys: [String], ready: Bool, limit: Int, inflight: Int = 0, now: Date = Date()) -> [String] {
        guard ready, limit > inflight else { return [] }
        return Array(keys.filter { open($0, now) }.prefix(limit - inflight))
    }
}

/// 敲信箱的两扇门：中转站按门分别限速
public enum MailDoor: String, Sendable { case http, ws }

/// 信箱叫「过会儿再来」
public struct RelayHold: Equatable, Sendable {
    public var until: Date
    public var status: Int
    /// 额度用光（两扇门一起关）
    public var quota: Bool
    public init(until: Date, status: Int, quota: Bool) { self.until = until; self.status = status; self.quota = quota }
}

public enum RelayRules {
    /// Retry-After：秒数，或者 HTTP 日期 -> 从现在起几秒。读不懂、过去了、离谱的：nil
    public static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        let s: Double
        if let n = Double(v) {
            s = n
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let d = f.date(from: v) else { return nil }
            s = d.timeIntervalSince(now)
        }
        return s > 0 && s < 7 * 86_400 ? s : nil
    }

    /// 一个不是 200 的回答里有没有「过会儿再来」。body 里的 retry_after（站里限速的 429 也写在里头）一样认
    public static func hold(status: Int, retryAfter header: String?, body: Data?, now: Date) -> RelayHold? {
        guard status == 429 || status == 503 else { return nil }
        let j = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let inBody = (j["retry_after"] as? NSNumber)?.stringValue ?? (j["retry_after"] as? String)
        var wait = retryAfter(header, now: now) ?? retryAfter(inBody, now: now)
        // 中转站把任何「limit / exceeded」都叫 do_quota（CPU 超了也算）：只有免费额度那一种要等一天
        let message = (j["message"] as? String ?? "").lowercased()
        if status == 503, j["error"] as? String == "do_quota", message.isEmpty || message.contains("free tier") {
            let t = now.timeIntervalSince1970
            let day = (t / 86_400).rounded(.down) * 86_400
            if t - day >= 3600 {
                wait = max(wait ?? 0, day + 86_400 + 60 - t)
            } else {
                wait = wait ?? 600
            }
            return RelayHold(until: now.addingTimeInterval(max(wait ?? 600, 1)), status: status, quota: true)
        }
        guard let w = wait else { return nil }
        return RelayHold(until: now.addingTimeInterval(max(min(w, 3600), 1)), status: status, quota: false)
    }

    /// 几点恢复：整点（差一分以内）写「8 点」，别的写「08:37」
    public static func clockWords(_ d: Date, zh: Bool, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        if zh && m <= 1 { return "\(h) 点" }
        return String(format: "%02d:%02d", h, m)
    }

    /// 额度用光时走哪条路
    public enum Spare: Equatable, Sendable { case backup, icloud, none }

    /// 设置里大管家那一行、寄不出去的那句话
    public static func quotaLine(_ until: Date, spare: Spare, zh: Bool, calendar: Calendar = .current) -> String {
        let at = clockWords(until, zh: zh, calendar: calendar)
        if zh {
            let head = "信箱今天满了，\(at)\(at.hasSuffix("点") ? "" : " ")恢复"
            switch spare {
            case .backup: return head + "，先走备用"
            case .icloud: return head + "，先走 iCloud"
            case .none: return head
            }
        }
        let head = "Mailbox full for today, back at \(at)"
        switch spare {
        case .backup: return head + ". Using the backup for now"
        case .icloud: return head + ". Using iCloud for now"
        case .none: return head
        }
    }
}

/// 一台手机一个：MailClient 和 MailSocket 共用，换配对、重开长连接都不忘。线程安全
public final class MailBrake: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var holds: [MailDoor: RelayHold] = [:]
    private var quotaHeld: RelayHold?
    private var soft: [MailDoor: Backoff] = [:]
    /// 自动寄的总闸：几条路都寄不出去了就退避
    private var out = Backoff()
    private var outFailed = false
    /// 额度状态变了（设置页那一行要跟着改）
    private var changed: (@Sendable () -> Void)?

    public init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    public var onChange: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changed }
        set { lock.lock(); changed = newValue; lock.unlock() }
    }

    public var now: Date { clock() }

    /// 信箱叫等着（Retry-After / 额度用光）：没到点之前这扇门一下都不敲
    public func held(_ door: MailDoor) -> RelayHold? {
        lock.lock(); defer { lock.unlock() }
        return locked(door, clock())
    }

    private func locked(_ door: MailDoor, _ t: Date) -> RelayHold? {
        if let q = quotaHeld, q.until > t { return q }
        if let h = holds[door], h.until > t { return h }
        return nil
    }

    /// 额度用光着：到几点
    public func quota() -> RelayHold? {
        lock.lock(); defer { lock.unlock() }
        guard let q = quotaHeld, q.until > clock() else { return nil }
        return q
    }

    /// 这扇门现在还要等几秒（叫等的、退避的，取长的）
    public func wait(_ door: MailDoor) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let t = clock()
        let h = locked(door, t).map { $0.until.timeIntervalSince(t) } ?? 0
        return max(h, soft[door]?.wait(t) ?? 0)
    }

    /// 回了不是 200。长连接握手被拒一律记一次退避；HTTP 只记 429、5xx（413、404 这些是那一封自己的事）
    public func refused(_ door: MailDoor, status: Int, retryAfter: String? = nil, body: Data? = nil) {
        lock.lock()
        let t = clock()
        var notify: (@Sendable () -> Void)?
        if let h = RelayRules.hold(status: status, retryAfter: retryAfter, body: body, now: t) {
            if h.quota {
                if (quotaHeld?.until ?? .distantPast) < h.until { quotaHeld = h; notify = changed }
            } else if (holds[door]?.until ?? .distantPast) < h.until {
                holds[door] = h
            }
        }
        if door == .ws || status == 429 || status >= 500 {
            var b = soft[door] ?? Backoff()
            b.failed(t)
            soft[door] = b
        }
        lock.unlock()
        notify?()
    }

    /// 连不上、超时、连上又断了
    public func unreachable(_ door: MailDoor) {
        lock.lock(); defer { lock.unlock() }
        var b = soft[door] ?? Backoff()
        b.failed(clock())
        soft[door] = b
    }

    public func ok(_ door: MailDoor) {
        lock.lock(); defer { lock.unlock() }
        var b = soft[door] ?? Backoff()
        b.succeeded(clock())
        soft[door] = b
    }

    /// 长连接这一回连上了（第一句话到了）：网是通的，寄信那头不用接着等退避（叫等着的照等）
    public func connected() {
        lock.lock(); defer { lock.unlock() }
        soft[.http]?.wake()
        out.wake()
    }

    /// 他回到前台：退避的这一下不等了（次数留着）；信箱叫等的、额度用光的照等
    public func wake() {
        lock.lock(); defer { lock.unlock() }
        soft[.http]?.wake()
        soft[.ws]?.wake()
        out.wake()
    }

    // ------------------------------------------------ 自动寄的总闸
    public func autoWait() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return out.wait(clock())
    }

    /// 上一封没寄出去：先只拿一封探路
    public var autoProbing: Bool { lock.lock(); defer { lock.unlock() }; return outFailed }

    public func sendOK() {
        lock.lock(); defer { lock.unlock() }
        outFailed = false
        out.succeeded(clock())
    }

    public func sendFailed() {
        lock.lock(); defer { lock.unlock() }
        outFailed = true
        out.failed(clock())
    }
}
