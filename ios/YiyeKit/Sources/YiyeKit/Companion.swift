import Foundation

// 陪玩模式（pc-butler 施工单 100，Song 11-24 10:07）：手机直播自己的屏幕，开口问一句，取问的那一刻的一帧，
// 连问题一起走信箱交给大管家（ask=look），大管家看图答话、配好音送回来，手机直接放。接口见 ios/docs/大管家接口.md「v3.2」。
// 这里是不碰系统框架、能在 Mac 上单测的那几块：缩图尺寸、扩展和主 App 之间的回环格式、开口 / 说完的判断、请求和回信。

// ================================================================ 缩到大脑看的尺寸
/// Opus 5.5 看图的上限：长边 2576、视觉 token 4784（28×28 一块）。跟 pc-butler `handheld/luru.py` 的 resized_size 一个算法（093）
public enum BrainImage {
    public static let edge = 2576, maxTokens = 4784, patch = 28

    public static func tokens(_ w: Int, _ h: Int) -> Int {
        ((w + patch - 1) / patch) * ((h + patch - 1) / patch)
    }

    static func fits(_ w: Int, _ h: Int, _ maxEdge: Int, _ maxTokens: Int) -> Bool {
        ((w + patch - 1) / patch) * patch <= maxEdge && ((h + patch - 1) / patch) * patch <= maxEdge && tokens(w, h) <= maxTokens
    }

    /// 大脑会把图缩成多大（已经够小就原样）
    public static func resizedSize(_ w: Int, _ h: Int, maxEdge: Int = edge, maxTokens: Int = BrainImage.maxTokens) -> (Int, Int) {
        guard w > 0, h > 0 else { return (w, h) }
        if fits(w, h, maxEdge, maxTokens) { return (w, h) }
        if h > w {
            let (rh, rw) = resizedSize(h, w, maxEdge: maxEdge, maxTokens: maxTokens)
            return (rw, rh)
        }
        let ar = Double(w) / Double(h)
        var lo = 1, hi = w
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if fits(mid, max(Int((Double(mid) / ar).rounded(.toNearestOrEven)), 1), maxEdge, maxTokens) { lo = mid } else { hi = mid }
        }
        return (lo, max(Int((Double(lo) / ar).rounded(.toNearestOrEven)), 1))
    }
}

// ================================================================ 扩展 ⇄ 主 App：本机回环
/// 免费签名、未签名的 .ipa 里 App Group 拿不到（SideStore 照二进制里的权限签，CI 出的包没权限），所以不用共享文件夹：
/// 直播扩展在 127.0.0.1 上开一个口子，只在内存里留最新一帧；主 App 要的时候连上去取一帧，编号对上就回 JPEG。
/// 别的 App 也能连 127.0.0.1：扩展只认直播开始后第一个连上来的人报的口令（主 App 自己存的随机串），之后口令不对的一律不给。
/// Darwin 通知只当门铃：扩展开播、停播各响一声，主 App 听见了就去连。
public enum LiveWire {
    public static let port: UInt16 = 47_833
    public static let host = "127.0.0.1"
    public static let started = "lab.qianshou.yiye.live.started"
    public static let stopped = "lab.qianshou.yiye.live.stopped"
    /// 主 App 关了陪玩：叫扩展停播（停截）
    public static let finish = "lab.qianshou.yiye.live.finish"
    public static let maxFrame = 8_000_000

    /// 主 App 发：「YIYE1 <口令> <编号>\n」
    public static func request(token: String, id: String) -> Data { Data("YIYE1 \(token) \(id)\n".utf8) }

    public static func parseRequest(_ d: Data) -> (token: String, id: String)? {
        guard let s = String(data: d, encoding: .utf8), s.hasSuffix("\n") else { return nil }
        let p = s.dropLast().split(separator: " ", omittingEmptySubsequences: false)
        guard p.count == 3, p[0] == "YIYE1", (16...64).contains(p[1].count), (1...64).contains(p[2].count) else { return nil }
        let ok: (Substring) -> Bool = { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        guard ok(p[1]), ok(p[2]) else { return nil }
        return (String(p[1]), String(p[2]))
    }

    /// 扩展回：状态 1 字节（0 有图、1 还没有图、2 口令不对）+ 长度 4 字节（大端）+ JPEG
    public enum Status: UInt8, Sendable { case frame = 0, none = 1, refused = 2 }

    public static func reply(_ s: Status, jpeg: Data = Data()) -> Data {
        var out = Data([s.rawValue])
        let n = UInt32(s == .frame ? jpeg.count : 0)
        out.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        if s == .frame { out.append(jpeg) }
        return out
    }

    /// 读回复的头：(状态, 后面 JPEG 的长度)
    public static func parseHead(_ d: Data) -> (Status, Int)? {
        guard d.count >= 5, let s = Status(rawValue: d[d.startIndex]) else { return nil }
        let b = [UInt8](d.prefix(5))
        let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard n <= maxFrame else { return nil }
        return (s, n)
    }

    /// 扩展这头认口令：第一个报上来的记下，之后只认它
    public struct Gate: Sendable {
        public private(set) var token: String?
        public init() {}
        public mutating func allow(_ t: String) -> Bool {
            if let token { return token == t }
            token = t
            return true
        }
    }
}

// ================================================================ 开口、说完
/// 听着麦克风，按音量判断开口、说完。每一小块声音（约 20～90 毫秒）报一次分贝。
/// - 底噪 = 最近 windowMs（3 秒）里排在低处（第 10 百分位）的音量：游戏声一直响着，底噪就跟着抬上去，人说话比它高才算。
///   说话的时候底噪不动（不把自己的话算进去）。
/// - 比底噪高 margin 分贝、而且不低于 floorMin，连着 startMs 算开口。
/// - 开口以后安静 endSilenceMs（0.8 秒，单子写的）算说完；说了 maxMs 还没停也算说完。太短的（< minMs）不算一句。
/// - 自己在放声音的时候（mute）什么都不判。
public struct VoiceGate: Sendable {
    public enum Event: Equatable, Sendable { case start, end(seconds: Double), tooShort }

    public var margin: Double = 12
    public var floorMin: Double = -52
    public var startMs: Double = 120
    public var endSilenceMs: Double = 800
    public var maxMs: Double = 15_000
    public var minMs: Double = 350
    public var windowMs: Double = 3_000

    public private(set) var noise: Double = -60
    public private(set) var speaking = false
    private var dbs: [Double] = []
    private var mss: [Double] = []
    private var heldMs: Double = 0
    private var loudMs: Double = 0
    private var quietMs: Double = 0
    private var spokeMs: Double = 0

    public init() {}

    public mutating func reset() {
        speaking = false; loudMs = 0; quietMs = 0; spokeMs = 0
    }

    private mutating func track(_ db: Double, _ ms: Double) {
        dbs.append(db); mss.append(ms); heldMs += ms
        while dbs.count > 1, heldMs - mss[0] >= windowMs {
            heldMs -= mss.removeFirst()
            dbs.removeFirst()
        }
        let sorted = dbs.sorted()
        noise = sorted[Int(Double(sorted.count - 1) * 0.1)]
    }

    /// 一块声音：分贝（dBFS）、多长（毫秒）。返回这一块带来的事
    public mutating func feed(db: Double, ms: Double, mute: Bool = false) -> Event? {
        if mute {
            if speaking { reset() }
            loudMs = 0
            return nil
        }
        if !speaking {
            track(db, ms)
            let loud = db > max(noise + margin, floorMin)
            loudMs = loud ? loudMs + ms : 0
            if loudMs >= startMs {
                speaking = true
                spokeMs = loudMs
                quietMs = 0
                return .start
            }
            return nil
        }
        let loud = db > max(noise + margin, floorMin)
        spokeMs += ms
        quietMs = loud ? 0 : quietMs + ms
        if quietMs >= endSilenceMs || spokeMs >= maxMs {
            let talked = spokeMs - quietMs
            reset()
            return talked < minMs ? .tooShort : .end(seconds: talked / 1000)
        }
        return nil
    }
}

// ================================================================ 请求、回信
extension ButlerRequest {
    /// 陪玩问一句：问的字 + 那一帧（images 里一个路径，图跟着信走）；prev 是上一问手机这头量的秒数（大管家记进日志，验收用）
    public static func look(id: String, question: String, image: String?, at: String, app: String, prev: [String: Double]? = nil) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: question, images: image.map { [$0] }, unsure: nil, ask: "look", at: at, app: app)
        r.timing = (prev?.isEmpty ?? true) ? nil : prev
        return r
    }

    /// 开了陪玩：叫大管家先把大脑热上（不回信）
    public static func lookWarm(id: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "look-warm", at: at, app: app)
    }
}

/// 一问的来回，手机这头记的几个时间点（秒，ProcessInfo.systemUptime）
public struct LookClock: Sendable, Equatable {
    public var spokeEnd: Double
    public var heard: Double?
    public var frame: Double?
    public var sent: Double?
    public var back: Double?
    public var playing: Double?

    public init(spokeEnd: Double) { self.spokeEnd = spokeEnd }

    /// 交给大管家的下一问带着的那份：识别、取图、寄出（含传图）、等回信、放出声、一共；电量另外加
    public func summary(butler: [String: Double] = [:]) -> [String: Double] {
        var out: [String: Double] = [:]
        func put(_ k: String, _ a: Double?, _ b: Double?) { if let a, let b { out[k] = max(0, (b - a) * 100).rounded() / 100 } }
        put("asr", spokeEnd, heard)
        put("frame", heard, frame)
        put("put", frame ?? heard, sent)
        put("wait", sent, back)
        put("play", back, playing)
        put("total", spokeEnd, playing)
        for (k, v) in butler where ["fetch", "brain", "voice"].contains(k) { out["b" + k.prefix(1).uppercased() + k.dropFirst()] = v }
        return out
    }
}
