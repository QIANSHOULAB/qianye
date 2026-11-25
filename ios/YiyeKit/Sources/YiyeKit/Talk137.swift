import Foundation

// 137 书童「开口说」：聊天窗里一个键，一按像打电话一样一来一回。手机一直听着，他说完一句（停 0.8 秒）就把录音寄给大管家；
// 大管家认字、对声纹，「撤销」「对」「不对」「好了」本地认，别的交给这一场一直开着的大脑，回动作 + 配好音的一句。
// 改标题、挪文件夹、收拾、置顶：听懂了直接做，念回执；扔东西、合并：先念一遍问「对吗」，他说「对」才动手，「不对」、不吭声都不动。
// 这里是不碰界面和话筒的那部分：请求怎么拼、回信里的 cmd、固定的话、秒表。接口见 ios/docs/大管家接口.md「v3.12：书童开口说」。

/// 手机自己念的固定的话（117 一个嗓子：都用晓晓预先配好，随 App 带；加了句子跑 python ios/tools/voice_lines.py）
public enum TalkSays {
    public static let undone = "撤回去了"
    public static let nothingToUndo = "没有能撤的"
    public static let done = "办好了，说撤销能退回去"
    public static let kept = "好，不动"
    public static let silent = "没听到你说对，先不动"
    public static let bye = "好，回去打字"
    public static let doneLook = "办好了，聊天窗里有回执"
    public static let skippedSome = "有几条没动，聊天窗里写了为什么"
    public static let noneDone = "这回一条都没动成，聊天窗里写了为什么"
    public static let busy = "陪玩开着，先关掉陪玩"

    public static let all: [String] = [undone, nothingToUndo, done, kept, silent, bye, doneLook, skippedSome, noneDone, busy]
}

/// 大管家回信里 `shutong.cmd`：空 = 大脑回了动作 / 一句话；别的是本地认出来的
public enum TalkCmd: String, Sendable {
    case act = ""
    case undo, yes, no, bye, misheard
    case notHim = "not-him"
    case need

    public static func of(_ s: String?) -> TalkCmd { TalkCmd(rawValue: s ?? "") ?? .act }
}

public enum TalkTiming {
    /// 念完「要扔这几条，对吗？」以后等他这么久，不吭声就不动
    public static let confirmWait: TimeInterval = 20
    /// 开着的时候每 4 分钟敲一下大管家：大脑、耳朵别下班
    public static let ping: TimeInterval = 240
    /// 寄出去这么久没回：念「大管家没回」
    public static let answerWait: TimeInterval = 45
}

extension ButlerRequest {
    /// 137：他说的一句。audio = 录音在信里的路径（16 kHz 单声道 WAV）；改过字重发的那句没有录音，text 就是改后的字。
    /// prev：上一句手机这头量的秒数（大管家只记日志）
    public static func shutongTalk(id: String, audio: String?, text: String, ask: ShutongAsk, at: String, app: String,
                                   prev: [String: Double] = [:]) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: audio == nil ? .text : .voice, text: text, images: nil, unsure: nil,
                              ask: "shutong-talk", at: at, app: app)
        r.audio = audio
        r.shutong = ask
        r.timing = prev.isEmpty ? nil : prev
        return r
    }

    /// 137：进开口说（每 4 分钟再敲一下）：大管家把耳朵、这一场的大脑热好，先看一遍目录
    public static func shutongTalkWarm(id: String, ask: ShutongAsk, at: String, app: String, prev: [String: Double] = [:]) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "shutong-talk-warm", at: at, app: app)
        r.shutong = ask
        r.timing = prev.isEmpty ? nil : prev
        return r
    }

    /// 137：退出开口说：这一场结束
    public static func shutongTalkOff(id: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "shutong-talk-off", at: at, app: app)
    }

    public static func talkAudioPath(_ id: String) -> String { "书童/\(id.prefix(8))-说.wav" }
}

/// 回执那句念不念大管家配好的：大管家照目录预先算的回执（spoken）跟手机做完真算出来的一样才念；不一样念「办好了，聊天窗里有回执」
public enum TalkReceipt {
    public static let prefix = "好了，"

    public static func matches(spoken: String?, counts: ShutongCounts) -> Bool {
        guard let s = spoken?.trimmingCharacters(in: .whitespacesAndNewlines), let line = ShutongReceipt.line(counts, zh: true) else { return false }
        return s == prefix + line
    }
}

/// 一句话的秒表（ProcessInfo.systemUptime）：说完 → 寄出 → 回信到 → 动手做完 → 出声。只记秒数，跟下一封信走
public struct TalkClock: Equatable, Sendable {
    public var spokeEnd: Double
    public var rec: Double
    public var sent: Double?
    public var back: Double?
    public var acted: Double?
    public var sound: Double?
    public var cmd: String = ""

    public init(spokeEnd: Double, rec: Double) { self.spokeEnd = spokeEnd; self.rec = rec }

    /// talkSent / talkBack / talkActed / talkSound：从他说完算起几秒
    public func summary() -> [String: Double] {
        func d(_ t: Double?) -> Double? { t.map { (($0 - spokeEnd) * 100).rounded() / 100 } }
        var out: [String: Double] = ["talk": 1, "rec": (rec * 100).rounded() / 100]
        if let v = d(sent) { out["talkSent"] = v }
        if let v = d(back) { out["talkBack"] = v }
        if let v = d(acted) { out["talkActed"] = v }
        if let v = d(sound) { out["talkSound"] = v }
        return out
    }
}

/// 截图、UI 测试用的假耳朵：Demo 里没有话筒，假的录音（一小段静音 WAV）+ 他「说」的字一起交给假大管家
public enum TalkDemo {
    /// 假大管家本地认的几句（跟 handheld/shutongtalk.py 的 command 同一个意思，英文界面测试也能说）
    public static func command(_ text: String, confirming: Bool) -> TalkCmd? {
        let t = text.lowercased().filter { !" ，,。.!！?？、".contains($0) }
        if ["撤销", "撤回", "undo", "undoit"].contains(t) { return .undo }
        if confirming, ["对", "对的", "是", "好", "yes", "yeah"].contains(t) { return .yes }
        if confirming, ["不对", "不是", "算了", "no", "nope"].contains(t) { return .no }
        if ["好了", "就这样", "done", "thatsit", "bye"].contains(t) { return .bye }
        return nil
    }

    /// 一小段静音录音（16 kHz 单声道，0.6 秒）：假的「他说了一句」
    public static func clip() -> Data { Wav.encode([Float](repeating: 0, count: 9_600)) }
}
