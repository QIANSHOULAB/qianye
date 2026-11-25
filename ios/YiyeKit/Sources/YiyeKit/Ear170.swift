import Foundation

// 170（Song 11-25 22:46–23:09）：陪玩、小书童通话、深聊一起「听不见他说话」，开着的时候整个界面卡。
// 查下来：三个入口共用的那只耳朵（app 里 Companion.swift 的 Ear）收到「话筒的配置变了」就在主线程上整只重开，
// 重开没有冷却、没有次数上限。新引擎一开回声消除，系统又改一遍硬件格式、又喊一次「配置变了」→ 又重开……
// 每回都在主线程上停会话、开会话、开回声消除、起引擎（一回几百毫秒到一秒多），切句也每回清零：界面卡、什么都听不见，
// 直到某一回 start 抛错，弹出「话筒的配置变了：The operation couldn't be completed…」。
// 这里是重开的规矩（纯逻辑，单测走得到）：
// - 刚开起来的头 settle 秒，「配置变了」不算掉线：等满再看；过了也先等 wait 秒（会话稳下来），再看引擎还在不在跑，在跑就不动；
// - 真要重开：换一只新的（新的 AVAudioEngine、重新装 tap、重新开回声消除）；开不起来隔 0.5、1 秒再试，最多 tries 次；
// - 开了回声消除开不起来、或者一分钟里重开到第 echoAfter 回（回声消除一开就出事）：以后不开回声消除，陪玩照样能用（117 的退路）；
// - 一分钟里重开到第 stopAfter 回：不再转圈，停下、报错（带错误码）。

/// 耳朵重开的规矩
public struct EarRestart: Equatable, Sendable {
    /// 开起来头几秒里来的「配置变了」不算掉线
    public static let settle: Double = 1.5
    /// 「配置变了」以后至少等多久再看（会话稳下来）
    public static let wait: Double = 0.4
    /// 一回重开里，开不起来最多试几次
    public static let tries = 3
    /// 第 1、2 次开不起来以后隔多久再试
    public static let delays: [Double] = [0.5, 1.0]
    /// 数重开的那段时间
    public static let window: Double = 60
    /// 一分钟里第几回重开起不开回声消除
    public static let echoAfter = 3
    /// 一分钟里第几回重开就不重开了（停下报错）
    public static let stopAfter = 6

    /// 退路：以后不开回声消除
    public private(set) var echoOff = false
    /// 这一场一共重开了几回（诊断用）
    public private(set) var rebuilds = 0
    /// 这一场「配置变了」来了、看了一眼引擎还在跑、没动它的次数（诊断用）
    public private(set) var ignored = 0
    private var recent: [Double] = []

    public init() {}

    /// 「配置变了」以后隔多久看一眼引擎：开起来不到 settle 秒的，等到满 settle 秒；至少等 wait 秒
    public static func checkDelay(sinceStart: Double) -> Double {
        max(wait, settle - max(0, sinceStart))
    }

    /// 看过了：引擎还在跑（话筒还有声音进来）就不动它
    public mutating func check(running: Bool) -> Bool {
        if running { ignored += 1; return false }
        return true
    }

    public enum Plan: Equatable, Sendable {
        /// 重开，这回开不开回声消除
        case rebuild(echo: Bool)
        /// 一分钟里重开太多回：不重开了，停下报错
        case stop
    }

    /// 要重开一回：记账，定这回开不开回声消除，太频繁就停
    public mutating func willRebuild(now: Double) -> Plan {
        recent = recent.filter { now - $0 < EarRestart.window }
        recent.append(now)
        rebuilds += 1
        if recent.count >= EarRestart.stopAfter { return .stop }
        if recent.count >= EarRestart.echoAfter { echoOff = true }
        return .rebuild(echo: !echoOff)
    }

    /// 开了回声消除的一次 start 失败了：下一次不开
    public mutating func echoFailed() { echoOff = true }

    /// 一回重开里第 attempt 次（0 起）开不起来以后等多久再试；nil = 试满了
    public static func retryDelay(after attempt: Int) -> Double? {
        guard attempt + 1 < tries, attempt >= 0 else { return nil }
        return delays[min(attempt, delays.count - 1)]
    }
}

// ================================================================ 报错写全
/// avfaudio 的错误：原来只露 localizedDescription（「The operation couldn't be completed. (com.apple.coreaudio.avfa…」被截掉），
/// 现在错误码（那个数）放在前面：截掉一半也看得到。四个字的码（像 '!pri'）一起写出来
public enum AudioErrorLine {
    public static func of(domain: String, code: Int, text: String) -> String {
        "错误码 \(code)\(fourCC(code).map { " '\($0)'" } ?? "")（\(short(domain))）：\(text)"
    }

    /// 32 位、四个字节都是看得见的 ASCII：当四个字的码念出来
    public static func fourCC(_ code: Int) -> String? {
        guard code >= Int(Int32.min), code <= Int(UInt32.max) else { return nil }
        let u = UInt32(truncatingIfNeeded: code)
        let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// com.apple.coreaudio.avfaudio → avfaudio；NSOSStatusErrorDomain → OSStatus
    public static func short(_ domain: String) -> String {
        if domain == "NSOSStatusErrorDomain" { return "OSStatus" }
        return domain.split(separator: ".").last.map(String.init) ?? domain
    }
}

// ================================================================ 自动回传的诊断（170）
/// 说话的功能出错、或者界面卡住超过 1 秒：手机把一小段诊断经信箱寄给大管家，存在电脑上（logs/yiye-diag.jsonl）。
/// 只有：出了什么错、错误码、哪个入口、哪一版（信里本来就带）、重开了几回、卡了多久、回声消除开没开。不带录音、不带便签内容。
/// 走 look-check 那封信（108 体检）：老大管家也认（只记数），新大管家看到 diag=1 把那行字一起存下
public struct EarDiag: Equatable, Sendable {
    public enum Kind: String, Sendable { case failed, rebuilt, gaveUp, stall }
    public enum Entry: Int, Sendable { case none = 0, companion = 1, deep = 2, call = 3, shutong = 4 }

    public var kind: Kind
    public var entry: Entry
    /// 一句话：哪一步、错误的全文（已经去掉换行，最长 300 字）
    public var line: String
    public var code: Int?
    public var rebuilds: Int = 0
    public var ignored: Int = 0
    public var echo: Bool?
    /// 卡了几秒（stall）
    public var stall: Double?
    /// 一场里重开花了几秒（rebuilt）
    public var took: Double?

    public init(kind: Kind, entry: Entry, line: String, code: Int? = nil, rebuilds: Int = 0, ignored: Int = 0,
                echo: Bool? = nil, stall: Double? = nil, took: Double? = nil) {
        self.kind = kind; self.entry = entry
        self.line = EarDiag.clean(line)
        self.code = code; self.rebuilds = rebuilds; self.ignored = ignored; self.echo = echo; self.stall = stall; self.took = took
    }

    static func clean(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return one.count > 300 ? String(one.prefix(300)) : one
    }

    public var numbers: [String: Double] {
        var out: [String: Double] = ["diag": 1, "entry": Double(entry.rawValue), "rebuilds": Double(rebuilds), "ignored": Double(ignored)]
        switch kind {
        case .failed: out["failed"] = 1
        case .rebuilt: out["rebuilt"] = 1
        case .gaveUp: out["gaveUp"] = 1
        case .stall: out["stall"] = 1
        }
        if let code { out["code"] = Double(code) }
        if let echo { out["echo"] = echo ? 1 : 0 }
        if let stall { out["stallSec"] = (stall * 100).rounded() / 100 }
        if let took { out["took"] = (took * 100).rounded() / 100 }
        return out
    }
}

/// 别寄太多：同一种一分钟最多一封，一天最多 30 封
public struct DiagGate: Equatable, Sendable {
    public static let every: Double = 60
    public static let perDay = 30
    private var last: [String: Double] = [:]
    private var day: Int = -1
    private var count = 0

    public init() {}

    /// now：秒（任意起点，单调）；dayNumber：今天是第几天（换天清零）
    public mutating func allow(_ kind: EarDiag.Kind, now: Double, dayNumber: Int) -> Bool {
        if dayNumber != day { day = dayNumber; count = 0 }
        guard count < DiagGate.perDay else { return false }
        if let t = last[kind.rawValue], now - t < DiagGate.every { return false }
        last[kind.rawValue] = now
        count += 1
        return true
    }
}

extension ButlerRequest {
    /// 170 诊断：一封 look-check（大管家只记、不回信），timing 里 diag=1，text 是那一行
    public static func yiyeDiag(id: String, diag: EarDiag, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "\(diag.kind.rawValue)：\(diag.line)", images: nil, unsure: nil,
                              ask: "look-check", at: at, app: app)
        r.timing = diag.numbers
        return r
    }
}

/// 界面卡顿：后台每 0.25 秒往主线程丢一下，主线程晚了多少秒到就是卡了多久（超过 limit 才算）
public enum StallRule {
    public static let limit: Double = 1.0
    public static let every: Double = 0.25
    /// 刚回前台的这几秒不算（开 app 时 SwiftData 读库、建界面本来就慢）
    public static let graceAfterActive: Double = 5
    public static func isStall(posted: Double, ran: Double) -> Double? {
        let lag = ran - posted
        return lag > limit ? lag : nil
    }
}

// ================================================================ 开耳朵、重开耳朵（170）
/// 一场（陪玩 / 深聊 / 电话 / 小书童通话从开到关）里管那只耳朵：开、听「配置变了」、该重开才重开、开不起来再试、退路、太频繁就停。
/// 耳朵是什么不管（app 里是 Ear，单测里是假的）：怎么开、怎么撒手、在不在跑，都由 Hooks 给。
/// 开、撒手都是 async：app 那头放在一条后台队列上做（setActive、开回声消除、起引擎都慢，不在主线程上卡界面）。
@MainActor
public final class EarKeeper<E: AnyObject> {
    public struct Hooks {
        /// 开一只新的（echo：开不开回声消除）。开不起来抛错
        public var make: (_ echo: Bool) async throws -> E
        /// 撒手（keepSession：重开时不放掉音频会话，免得一放一开又惹出「配置变了」）
        public var release: (_ ear: E, _ keepSession: Bool) async -> Void
        /// 引擎还在跑、话筒最近还有声音进来
        public var running: (E) -> Bool
        /// 它开起来的那一刻（now 的钟）
        public var startedAt: (E) -> Double
        public var sleep: (Double) async -> Void
        public var now: () -> Double

        public init(make: @escaping (_ echo: Bool) async throws -> E, release: @escaping (_ ear: E, _ keepSession: Bool) async -> Void,
                    running: @escaping (E) -> Bool, startedAt: @escaping (E) -> Double,
                    sleep: @escaping (Double) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000)) },
                    now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
            self.make = make; self.release = release; self.running = running; self.startedAt = startedAt; self.sleep = sleep; self.now = now
        }
    }

    public private(set) var ear: E?
    public private(set) var rules = EarRestart()
    /// 在开 / 在重开（这时候别的地方别再叫重开、别再开新的）
    public private(set) var busy = false
    /// 关掉了（这一场结束）
    public private(set) var closed = false
    /// 最后一次开不起来的错（诊断用）
    public private(set) var lastError: Error?

    /// 要重开了（老的这就撒手）：为什么
    public var onRebuilding: ((String) -> Void)?
    /// 重开好了：新耳朵、为什么重开、花了几秒
    public var onRebuilt: ((E, String, Double) -> Void)?
    /// 重开不成：为什么重开、最后的错（nil = 一分钟里重开太多回，停了）
    public var onGaveUp: ((String, Error?) -> Void)?
    /// 「配置变了」来了，看了一眼引擎还在跑，没动它
    public var onIgnored: ((String) -> Void)?

    private let hooks: Hooks
    private var gen = 0
    private var checking: Set<ObjectIdentifier> = []

    public init(_ hooks: Hooks) { self.hooks = hooks }

    /// 开第一只。开了回声消除开不起来，下一次就不开；最多试 tries 次
    public func open() async throws -> E {
        let g = gen
        busy = true
        defer { busy = false }
        let e = try await attempt(g)
        ear = e
        return e
    }

    /// 这一场结束：以后不再重开。耳朵交回去，由调用的那头自己停
    @discardableResult
    public func close() -> E? {
        gen += 1
        closed = true
        busy = false
        let e = ear
        ear = nil
        return e
    }

    /// 耳朵喊「配置变了」：刚开的头 settle 秒里等满再看，过了也先等 wait 秒；那时引擎还在跑就不动它，真停了才重开
    public func configChanged(_ e: E, why: String) {
        let id = ObjectIdentifier(e)
        guard e === ear, !busy, !closed, !checking.contains(id) else { return }
        checking.insert(id)
        let g = gen
        let d = EarRestart.checkDelay(sinceStart: hooks.now() - hooks.startedAt(e))
        Task { @MainActor in
            await self.hooks.sleep(d)
            self.checking.remove(id)
            guard g == self.gen, e === self.ear, !self.busy else { return }
            if !self.rules.check(running: self.hooks.running(e)) {
                self.onIgnored?(why)
                return
            }
            await self.rebuild(why)
        }
    }

    /// 整只换新的（话筒没声音了、被打断了接不上、媒体服务重置、配置变了引擎停了）
    public func rebuild(_ why: String) async {
        guard let old = ear, !busy, !closed else { return }
        let g = gen
        busy = true
        let t0 = hooks.now()
        if case .stop = rules.willRebuild(now: t0) {
            busy = false
            onGaveUp?(why, nil)
            return
        }
        onRebuilding?(why)
        await hooks.release(old, true)
        guard g == gen else { busy = false; return }
        do {
            let e = try await attempt(g)
            ear = e
            busy = false
            onRebuilt?(e, why, hooks.now() - t0)
        } catch {
            busy = false
            guard g == gen else { return }
            onGaveUp?(why, error)
        }
    }

    private struct Closed: Error {}

    /// 开一只：开不起来隔 0.5、1 秒再试，最多 tries 次；开了回声消除的失败一次，后面都不开
    private func attempt(_ g: Int) async throws -> E {
        var last: Error = Closed()
        for i in 0..<EarRestart.tries {
            let echo = !rules.echoOff
            do {
                let e = try await hooks.make(echo)
                guard g == gen else {
                    await hooks.release(e, false)
                    throw Closed()
                }
                return e
            } catch let c as Closed {
                throw c
            } catch {
                last = error
                lastError = error
                if echo { rules.echoFailed() }
                guard let d = EarRestart.retryDelay(after: i) else { break }
                await hooks.sleep(d)
                guard g == gen else { throw Closed() }
            }
        }
        throw last
    }
}
