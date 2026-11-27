import Foundation

// 陪玩模式（pc-butler 施工单 100，Song 11-24 10:07）：手机直播自己的屏幕，开口问一句，取问的那一刻的一帧，
// 连问题一起走信箱交给大管家（ask=look），大管家看图答话、配好音送回来，手机直接放。接口见 ios/docs/大管家接口.md「v3.2」「v3.3」。
// 108（Song 11-24 12:20 选 A）：手机不再用苹果听写。一句话录成 16 kHz 单声道 WAV 寄过去，大管家用本机 SenseVoice 认字。
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
/// - 开口以后安静 endSilenceMs（0.8 秒，单子写的）算说完；说了 maxMs（20 秒，108）还没停也算说完。太短的（< minMs）不算一句。
/// - floorMin 108 从 -52 降到 -60：话筒开了回声消除（voiceProcessing）以后电平整体变低，-52 可能把人声也挡在门外（11-24 12:12 真机一点反应都没有）。
/// - 自己在放声音的时候（mute）什么都不判。
public struct VoiceGate: Sendable {
    public enum Event: Equatable, Sendable { case start, end(seconds: Double), tooShort }

    public var margin: Double = 12
    public var floorMin: Double = -60
    public var startMs: Double = 120
    public var endSilenceMs: Double = 800
    public var maxMs: Double = 20_000
    public var minMs: Double = 350
    public var windowMs: Double = 3_000
    /// 117 插嘴：自己在放回答时（回声消除开着）也判开口，但要更响、更长：比底噪高 strictMargin、不低于 strictFloor、连着 strictStartMs（0.5 秒）
    public var strictMargin: Double = 18
    public var strictFloor: Double = -38
    public var strictStartMs: Double = 500

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

    /// 一块声音：分贝（dBFS）、多长（毫秒）。返回这一块带来的事。strict（117）：在放回答，只认够响、够长的开口（插嘴）
    public mutating func feed(db: Double, ms: Double, mute: Bool = false, strict: Bool = false) -> Event? {
        if mute {
            if speaking { reset() }
            loudMs = 0
            return nil
        }
        if !speaking {
            if !strict { track(db, ms) }                 // 放回答时漏进来的那点声音不算底噪
            let loud = strict ? db > max(noise + strictMargin, strictFloor) : db > max(noise + margin, floorMin)
            loudMs = loud ? loudMs + ms : 0
            if loudMs >= (strict ? strictStartMs : startMs) {
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

// ================================================================ 切句录音（108）
/// 每一小块声音（16 kHz 单声道的浮点样本）喂进来：VoiceGate 判开口、说完；开口前 preMs（0.3 秒）的声音一起要，
/// 最长 maxSeconds（20 秒）。说完交出这一句的样本。只在内存里，不落盘。
public struct ClipCutter: Sendable {
    public static let rate = 16_000

    public enum Out: Equatable, Sendable {
        case start
        /// 一句：样本、多长（秒）、说话时最响的一块（dBFS）
        case clip(samples: [Float], seconds: Double, peak: Double)
        case tooShort
    }

    public var gate = VoiceGate()
    public var preMs: Double = 300
    public var maxSeconds: Double = 20
    public private(set) var pre: [Float] = []
    public private(set) var clip: [Float] = []
    private var peak: Double = -120

    public init() {}

    public var noise: Double { gate.noise }
    public var speaking: Bool { gate.speaking }

    /// 缓冲留多少样本：0.3 秒 + 判开口要的那段（插嘴要 0.5 秒，按长的留）；开口时再按这次用的那段裁，交出去的一句从开口前 0.3 秒开始
    var preCap: Int { Int((preMs + max(gate.startMs, gate.strictStartMs)) / 1000 * Double(ClipCutter.rate)) }
    var maxCount: Int { Int(maxSeconds * Double(ClipCutter.rate)) }

    public static func level(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return -120 }
        var sum: Double = 0
        for v in s { sum += Double(v) * Double(v) }
        return 20 * log10(max(sqrt(sum / Double(s.count)), 1e-6))
    }

    public mutating func feed(_ s: [Float], mute: Bool = false, strict: Bool = false) -> Out? {
        guard !s.isEmpty else { return nil }
        let db = ClipCutter.level(s)
        let ms = Double(s.count) / Double(ClipCutter.rate) * 1000
        let was = gate.speaking
        let ev = gate.feed(db: db, ms: ms, mute: mute, strict: strict)
        switch ev {
        case .start?:
            // 144：缓冲按插嘴的长度留，交出去时按这次判开口实际用的长度裁：普通开口从开口前 0.3 秒起，插嘴才多留
            let keep = Int((preMs + (strict ? gate.strictStartMs : gate.startMs)) / 1000 * Double(ClipCutter.rate)) - s.count
            clip = Array(pre.suffix(max(0, keep))) + s
            pre = []
            peak = db
            if clip.count >= maxCount { return finish() }
            return .start
        case .end?:
            clip += s
            return finish()
        case .tooShort?:
            clip = []
            return .tooShort
        case nil:
            if gate.speaking {
                clip += s
                peak = max(peak, db)
                if clip.count >= maxCount { return finish() }
            } else {
                if was { clip = [] }                 // 说到一半自己开始放声音了（mute）：这一句不要了
                pre += s
                if pre.count > preCap { pre.removeFirst(pre.count - preCap) }
            }
            return nil
        }
    }

    private mutating func finish() -> Out {
        if clip.count > maxCount { clip.removeLast(clip.count - maxCount) }
        let out = clip
        clip = []
        pre = []
        gate.reset()
        return .clip(samples: out, seconds: Double(out.count) / Double(ClipCutter.rate), peak: (peak * 10).rounded() / 10)
    }
}

/// 16 位 PCM 的 WAV（电脑那头 Python 自带的 wave 就能读，不用装东西）
public enum Wav {
    public static func encode(_ samples: [Float], rate: Int = ClipCutter.rate) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for v in samples {
            let x = Int16(max(-1, min(1, v)) * 32767)
            u16(UInt16(bitPattern: x))
        }
        return d
    }
}

// ================================================================ 小圆点（108）
/// 陪玩现在在干嘛
public enum CompanionPhase: Equatable, Sendable { case off, listening, hearing, asking, speaking, failed(String) }

/// 工具箱小圆点：在听绿，判到他在说绿色一闪一闪，寄出去等大管家、放回答橙，出错红；没直播没有点
public enum CompanionLight: Equatable, Sendable {
    case green, greenBlink, orange, red

    /// alert：这一问哪一步出了错（念过了），下次开口前一直红
    public static func of(_ p: CompanionPhase, alert: Bool) -> CompanionLight? {
        switch p {
        case .off: return nil
        case .failed: return .red
        case .hearing: return .greenBlink        // 他又开口了：先让他看见在听
        case _ where alert: return .red
        case .listening: return .green
        case .asking, .speaking: return .orange
        }
    }
}

// ================================================================ 出错就说（108）
/// 凡是会让「他说了话却什么都不发生」的地方，都弹一行字 + 用苹果的中文嗓子念出来，小圆点变红
public enum CompanionTrouble: Equatable, Sendable, CaseIterable {
    case noMic, earFailed, noFrame, frameRefused, liveDown, noPair, away, noMail, noAnswer, cantPlay, misheard, brainFailed
    /// 117：话筒被系统停了（来电、Siri、别的 App、换耳机……），自动重开成了 / 重开不了
    case earBack, earLost
    /// 深聊（107）：10 分钟没想好；来电话把话筒打断了、续不上
    case deepNoAnswer, deepCut

    /// 念的（也是弹的那行字）：短，说清哪一步坏了
    public var words: String {
        switch self {
        case .noMic: return "麦克风没开，去设置里给 ONE 开麦克风"
        case .earFailed: return "话筒打不开，停一下直播再开"
        case .noFrame: return "没截到屏幕，只问了话"
        case .frameRefused: return "直播不认这个 ONE，停了重开"
        case .liveDown: return "直播断了，只问了话"
        case .noPair: return "还没配大管家的信箱"
        case .away: return "大管家不在"
        case .noMail: return "信箱连不上"
        case .noAnswer: return "大管家没回，再问一次？"
        case .cantPlay: return "回答的声音放不出来"
        case .misheard: return "没听清，再说一遍"
        case .brainFailed: return "大管家这回没答上来"
        case .earBack: return "话筒刚才断了，又接上了"
        case .earLost: return "话筒被停了，重开不了，点一下陪玩重开"
        case .deepNoAnswer: return "大管家没想出来，再问一次？"
        case .deepCut: return "深聊被电话打断了，点一下重开"
        }
    }

    /// 这一问还接着走（只是少了图）：不打断等回答
    public var keepsGoing: Bool { self == .noFrame || self == .frameRefused || self == .liveDown }
}

// ================================================================ 体检（108）
/// 每次开听记一行：话筒权限、直播在不在、信箱连没连上、门槛的底噪。工具箱「陪玩」下面显示，也寄一封 look-check 给大管家记日志（只有是 / 否和数）
public struct CompanionHealth: Equatable, Sendable {
    public var mic: Bool
    public var live: Bool
    public var mail: Bool
    public var noise: Double?
    /// 话筒的回声消除开上了没有（开了电平会低，调门槛用）
    public var echo: Bool

    public init(mic: Bool, live: Bool, mail: Bool, noise: Double?, echo: Bool) {
        self.mic = mic; self.live = live; self.mail = mail; self.noise = noise; self.echo = echo
    }

    public var numbers: [String: Double] {
        var out: [String: Double] = ["mic": mic ? 1 : 0, "live": live ? 1 : 0, "mail": mail ? 1 : 0, "echo": echo ? 1 : 0]
        if let noise { out["noise"] = (noise * 10).rounded() / 10 }
        return out
    }

    public var line: String {
        func m(_ b: Bool) -> String { b ? "✓" : "✗" }
        var s = "话筒\(m(mic)) 直播\(m(live)) 信箱\(m(mail))"
        if let noise { s += " 底噪 \(Int(noise.rounded())) dB" }
        return s
    }
}

// ================================================================ 请求、回信
extension ButlerRequest {
    /// 陪玩问一句：录音（audio，108 起）或者问的字（question，留给以后打字问），二选一；那一帧（images 里一个路径）。图、录音都跟着信走。
    /// prev 是上一问手机这头量的秒数和是 / 否（大管家记进日志，验收用）
    public static func look(id: String, question: String, audio: String? = nil, image: String?, at: String, app: String,
                            prev: [String: Double]? = nil, pre: Bool = false, stream: Bool = false) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: audio == nil ? .text : .voice, text: audio == nil ? question : "",
                              images: image.map { [$0] }, unsure: nil, ask: "look", at: at, app: app)
        r.audio = audio
        r.timing = (prev?.isEmpty ?? true) ? nil : prev
        if pre { r.pre = true }
        if stream { r.stream = true }
        return r
    }

    /// 117 边说边传：他一开口就先把那一刻的截图寄出去（note = 这一问将来的 id），说完寄的那封只带录音（pre=true）
    public static func lookPre(id: String, question: String, image: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: question, kind: .text, text: "", images: [image], unsure: nil, ask: "look-pre", at: at, app: app)
    }

    /// 117 关了陪玩：这一场结束（大管家关掉这一场的大脑，前面聊的不再记）。不回信
    public static func lookOff(id: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "look-off", at: at, app: app)
    }

    /// 117 插嘴：他插嘴的头 1 秒录音，问大管家是不是他的声音（回 stage=who，timing.him 1/0）
    public static func lookWho(id: String, audio: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .voice, text: "", images: nil, unsure: nil, ask: "look-who", at: at, app: app)
        r.audio = audio
        return r
    }

    /// 插嘴那一秒录音在信里的路径
    public static func lookWhoPath(_ id: String) -> String { "陪玩/\(id.prefix(8))-谁.wav" }

    /// 先寄的截图在信里的路径
    public static func lookPrePath(_ id: String) -> String { "陪玩/\(id.prefix(8))-屏.jpg" }

    /// 开了陪玩：叫大管家先把大脑热上（不回信）
    public static func lookWarm(id: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "look-warm", at: at, app: app)
    }

    /// 陪玩体检（108）：大管家只记一行日志，不回信
    public static func lookCheck(id: String, health: CompanionHealth, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "look-check", at: at, app: app)
        r.timing = health.numbers
        return r
    }

    /// 录音在信里的路径
    public static func lookAudioPath(_ id: String) -> String { "陪玩/\(id.prefix(8))-问.wav" }

    /// 深聊（107）一句：只有录音（不截屏），带话题号。是不是在问大管家由大管家认完字判（127：过一道门，不用喊「大管家」），不是的当场扔
    public static func deep(id: String, audio: String, topic: String, at: String, app: String, prev: [String: Double]? = nil) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .voice, text: "", images: nil, unsure: nil, ask: "deep", at: at, app: app)
        r.audio = audio
        r.topic = topic
        r.timing = (prev?.isEmpty ?? true) ? nil : prev
        return r
    }

    /// 进了深聊：叫大管家先把耳朵装上（不回信）
    public static func deepWarm(id: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "deep-warm", at: at, app: app)
    }

    /// 深聊录音在信里的路径
    public static func deepAudioPath(_ id: String) -> String { "深聊/\(id.prefix(8))-问.wav" }
}

// ================================================================ 深聊（107）
/// 深聊的几个数（Song 11-24 11:58：「我不需要快速回答……他可以去思考 5 分钟再回答我，但是回答的问题要有深度」）
public enum Deep {
    /// 说完停 1.5 秒才算一句（深问题边想边说）
    public static let endSilenceMs: Double = 1_500
    /// 一句最长 60 秒
    public static let maxSeconds: Double = 60
    /// 30 分钟一句没问（没有「收到」）就退出深聊；话题号也是 30 分钟
    public static let idle: TimeInterval = 30 * 60
    /// 大管家收到以后 15 分钟没回：念「大管家没想出来，再问一次？」（它想 10 分钟、写到一半的再给 3 分钟收尾，加上配音和路上）
    public static let answerWait: TimeInterval = 15 * 60
    /// 信箱连不上、大管家不在：深聊里每一句都会寄（不知道是不是在问），所以这种话 10 分钟最多念一回
    public static let troubleEvery: TimeInterval = 10 * 60
    /// 大管家说收到了，手机马上念的
    public static let saysGot = "收到，想好了叫你"
    public static let saysEnd = "好，深聊结束"
    public static let saysTopic = "好，换个话题"
}

/// 话题号：30 分钟内接着问的是同一个话题；隔了 30 分钟（或者说了「换个话题」）换一个新号
public struct DeepTopic: Sendable, Equatable {
    public private(set) var id: String
    /// 上一次真的在问（大管家回了 ack）的时候
    public private(set) var last: Date?

    public init(id: String = UUID().uuidString) { self.id = id }

    /// 寄一句之前取号：离上次真问超过 30 分钟就换新号
    public mutating func current(_ now: Date, make: () -> String = { UUID().uuidString }) -> String {
        if let last, now.timeIntervalSince(last) > Deep.idle {
            id = make()
            self.last = nil
        }
        return id
    }

    /// 大管家说这一句是在问它（ack）
    public mutating func asked(_ now: Date) { last = now }

    /// 换个话题
    public mutating func renew(make: () -> String = { UUID().uuidString }) {
        id = make()
        last = nil
    }
}

/// 深聊里只念一回的出错话：同一类 troubleEvery 之内不再念
public struct TroubleLimiter: Sendable, Equatable {
    public private(set) var said: [String: Date] = [:]
    public init() {}
    public mutating func allow(_ key: String, now: Date, every: TimeInterval = Deep.troubleEvery) -> Bool {
        if let t = said[key], now.timeIntervalSince(t) < every { return false }
        said[key] = now
        return true
    }
}

/// 一问的来回，手机这头记的（时间点是秒，ProcessInfo.systemUptime；ok 是这一步成没成，没走到是 nil）
public struct LookClock: Sendable, Equatable {
    /// 说完的那一刻
    public var spokeEnd: Double
    /// 录音几秒
    public var rec: Double = 0
    /// 说话时最响一块的 dB
    public var peak: Double?
    public var frame: Double?
    public var frameOK: Bool?
    public var sent: Double?
    public var sentOK: Bool?
    public var back: Double?
    public var playing: Double?
    public var playOK: Bool?

    public init(spokeEnd: Double, rec: Double = 0, peak: Double? = nil) {
        self.spokeEnd = spokeEnd; self.rec = rec; self.peak = peak
    }

    /// 交给大管家的下一问带着的那份：门槛开口、录音几秒、取帧（秒、成没成）、寄出（秒、成没成）、等回信、回信到没到、放出声（秒、成没成）、一共；
    /// 大管家那头的几段加 b 前缀；电量另外加
    public func summary(butler: [String: Double] = [:]) -> [String: Double] {
        var out: [String: Double] = ["gate": 1, "rec": (rec * 100).rounded() / 100]
        func put(_ k: String, _ a: Double?, _ b: Double?) { if let a, let b { out[k] = max(0, (b - a) * 100).rounded() / 100 } }
        func ok(_ k: String, _ v: Bool?) { if let v { out[k] = v ? 1 : 0 } }
        if let peak { out["peak"] = (peak * 10).rounded() / 10 }
        put("frame", spokeEnd, frame)
        ok("frameOK", frameOK)
        put("put", frame ?? spokeEnd, sent)
        ok("sentOK", sentOK)
        put("wait", sent, back)
        if sentOK == true { out["backOK"] = back == nil ? 0 : 1 }
        put("play", back, playing)
        ok("playOK", playOK)
        put("total", spokeEnd, playing)
        for (k, v) in butler where ["fetch", "brain", "voice", "asr", "first", "brainFirst", "parts", "gear", "pre"].contains(k) {
            out["b" + k.prefix(1).uppercased() + k.dropFirst()] = v                 // 117：第一段配好、几段、几档、截图先寄了没有
        }
        return out
    }
}
