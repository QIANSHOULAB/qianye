import Foundation

// 139 打电话式（Song 11-25 07:56「我说挂掉，它自己可以把这个挂掉……我就不用去掏手机」，07:57「我跟你说完话，我就要听歌去」）：
// 喊一声接通大管家，说完就发（深聊那套），说「挂掉」就挂，挂了别家的歌接着放。
// 挂断词手机本地认（SpeechTranscriber），不过信箱、不等大管家：信箱断了、电脑关着也挂得掉。
// 规则都在这儿（纯算，能单测）；pc-butler handheld/deep.py 的 hangup() 是同一张单子（交到大管家那头的兜底）。

public enum HangUp {
    /// 整句就是这些才挂
    public static let core: Set<String> = ["挂掉", "挂了", "挂吧", "挂断", "挂", "拜拜", "拜", "再见", "bye", "byebye", "goodbye"]
    /// 电话里「不聊了 / 结束 / 退出」也等于挂掉（陪玩的深聊里还是只退深聊，那边照旧交大管家认）
    public static let ends: Set<String> = ["不聊了", "结束", "结束吧", "退出", "不说了", "先这样", "就这样", "那就这样", "没事了", "好了没事了"]
    /// 前后可以带的：「好，挂了」「那先挂了」「嗯嗯，拜拜」
    static let padHead = ["那就这样", "就这样", "那就", "好的", "行吧", "好吧", "那我", "我先", "嗯", "好", "那", "行", "先", "啊", "哦", "呃",
                          "okay", "ok", "我"]
    static let padTail: Set<Character> = ["吧", "了", "啊", "哈", "呀", "啦", "哦", "咯", "喽"]
    /// 只有短的一句才在手机上认（挂断词都短）；长的照常交大管家
    public static let maxSeconds: Double = 3.5

    static func squeeze(_ text: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，。.!！?？、~～…:：;；-—"))
        return String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { !drop.contains($0) }))
    }

    /// 去掉前后可以带的字，剩下的
    static func bare(_ text: String) -> String {
        var t = squeeze(text)
        for _ in 0..<6 {
            guard let p = padHead.first(where: { t.hasPrefix($0) && t.count > $0.count }) else { break }
            t = String(t.dropFirst(p.count))
        }
        while t.count > 1, let last = t.last, padTail.contains(last), !core.contains(t), !ends.contains(t) {
            t = String(t.dropLast())
        }
        return t
    }

    /// 整句是挂断词（「挂掉」「好，挂了」「那先挂了」「bye」）。「把那个会话挂掉」「挂个后台」不算
    public static func isHangUp(_ text: String) -> Bool { core.contains(bare(text)) }

    /// 电话里这句要不要挂：挂断词，或者「不聊了 / 结束 / 退出」
    public static func endsCall(_ text: String) -> Bool {
        let b = bare(text)
        return core.contains(b) || ends.contains(b) || ends.contains(squeeze(text))
    }
}

/// 挂电话那几步（app 那头接 AVAudioSession、话筒、播放；测试接假的）
public protocol CallPort: AnyObject {
    /// 「嘟」n 声短音（接通 1 声、挂断 2 声）
    func beep(_ times: Int)
    func stopMic()
    func stopPlaying()
    /// 放掉音频会话：setActive(false, options: .notifyOthersOnDeactivation)，别家的歌自己接着放
    func releaseSession(notifyOthers: Bool)
}

/// 一通电话：接通、他说话、它答完、60 秒没话自己挂、挂断
public struct CallLine: Equatable, Sendable {
    public enum Why: String, Equatable, Sendable { case words, end, idle, button, butler }

    public private(set) var on = false
    /// 接通时陪玩开着（打游戏）：陪玩里不自动挂；挂断词挂的时候整个陪玩都停
    public var companion = false
    /// 60 秒没听到他说话就挂
    public var idleSeconds: Double = 60
    /// 自动挂开没开：锁屏喊不回来的话先关着（不然骑车时它自己挂了，他得掏手机才叫得回来）
    public var idleOn: Bool
    /// 最后一次有动静（接通、他说完一句、它答完）
    public private(set) var lastAt: Date = .distantPast
    /// 挂的时候还在等的回答（不扔：到了存成深聊便签，下次接通第一句提一下）
    public private(set) var waiting: Set<String> = []
    public private(set) var hungBy: Why?

    public init(idleOn: Bool) { self.idleOn = idleOn }

    public mutating func connect(now: Date, companion: Bool) {
        on = true
        self.companion = companion
        lastAt = now
        hungBy = nil
    }

    /// 他开口了 / 说完一句
    public mutating func heard(now: Date) { if on { lastAt = now } }
    /// 它答完一句（念完）
    public mutating func answered(now: Date) { if on { lastAt = now } }

    public mutating func asked(_ id: String) { waiting.insert(id) }
    public mutating func got(_ id: String) { waiting.remove(id) }

    /// 该不该自己挂：开着自动挂、不在陪玩、没在说也没在放（busy）、离最后一次动静满 60 秒
    public func idleDue(now: Date, busy: Bool) -> Bool {
        on && idleOn && !companion && !busy && now.timeIntervalSince(lastAt) >= idleSeconds
    }

    /// 挂：嘟嘟两声、停话筒、停播放、放掉会话（叫别家的歌接着放）。返回挂的时候还在等的回答
    @discardableResult
    public mutating func hangUp(_ why: Why, port: CallPort) -> Set<String> {
        guard on else { return [] }
        on = false
        hungBy = why
        port.beep(2)
        port.stopMic()
        port.stopPlaying()
        port.releaseSession(notifyOthers: true)
        return waiting
    }

    /// 挂了以后到的回答：存起来，下次接通先提一句
    public static func carryLine(titles: [String], zh: Bool) -> String? {
        guard !titles.isEmpty else { return nil }
        let t = titles.prefix(2).map { zh ? "「\($0)」" : "“\($0)”" }.joined(separator: zh ? "、" : ", ")
        return zh ? "上回挂了以后答好了：\(t)，存在深聊里" : "Answered after you hung up: \(t). It's in Deep Talk."
    }
}

public extension Wav {
    /// 139：Wav.encode 编的 16 位 PCM WAV → 浮点样本（手机本地认挂断词用）。不是这种格式的回空
    static func decode(_ d: Data) -> [Float] {
        guard d.count > 44, d.prefix(4) == Data("RIFF".utf8) else { return [] }
        let body = d.dropFirst(44)
        var out = [Float]()
        out.reserveCapacity(body.count / 2)
        var it = body.makeIterator()
        while let lo = it.next(), let hi = it.next() {
            out.append(Float(Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8)) / 32767)
        }
        return out
    }
}
