import Foundation

// 117（pc-butler 施工单，Song 11-24 14:02–14:54）：一叶笺陪玩照掌机那套「语音陪玩」改。这里是能在 Mac 上单测的几块：
// 一个嗓子（随 App 带的晓晓录音叫什么名字）、一句一句回来的回答怎么排队、档越高等得越久、声纹那一行字。

// ================================================================ 一个嗓子（原 116）
/// 手机自己念的固定的话，全用大管家那个嗓子（微软晓晓 zh-CN-XiaoxiaoNeural，+5%），预先配好随 App 带着（Yiye/Voice/*.mp3），
/// 不再临时用苹果的系统嗓子（Song 11-24 14:02：「他会换电脑的那个非常差的声音，不是微软那个好一点的」）。
/// 文件名 = "v-" + 字的 FNV-1a 32 位哈希（UTF-8）：字改了名字就变，没重配就找不到文件，单测（VoiceLinesTests）当场红。
/// 重配：在电脑上跑 `python ios/tools/voice_lines.py`（读 Yiye/Voice/lines.json，缺的配上，多的删掉）。
public enum VoiceLines {
    /// 手机会自己念的每一句（出错就说、深聊的几句）。加了新的固定句子就加在这里，再跑一遍 voice_lines.py
    public static var all: [String] {
        var out = CompanionTrouble.allCases.map(\.words)
        out += [Deep.saysGot, Deep.saysEnd, Deep.saysTopic]
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// 这句话的录音文件名（不带 .mp3）；不是固定句子（大管家的回答、带变数的）回 nil
    public static func file(for text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard all.contains(t) else { return nil }
        return name(t)
    }

    public static func name(_ text: String) -> String { "v-" + fnv1a(text) }

    /// FNV-1a 32 位，UTF-8 字节，8 位小写十六进制（ios/tools/voice_lines.py 一模一样算）
    public static func fnv1a(_ text: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for b in text.utf8 {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return String(format: "%08x", h)
    }
}

// ================================================================ 边想边说：一句一句回来
/// 大管家一句一句寄回来（stage=part，timing.part 是第几句，从 0 起）。信箱不保证先寄的先到：到了先放进来，按号连着的才交出去放
public struct PartQueue: Sendable, Equatable {
    public private(set) var next = 0
    public private(set) var waiting: [Int: Data] = [:]
    /// 交出去放了几句
    public private(set) var played = 0

    public init() {}

    /// 第 n 句到了（data 空 = 这句没配上声音，跳过）。返回现在能接着放的（按顺序）
    public mutating func add(_ n: Int, _ data: Data) -> [Data] {
        guard n >= next, waiting[n] == nil else { return [] }
        waiting[n] = data
        var out: [Data] = []
        while let d = waiting.removeValue(forKey: next) {
            next += 1
            if !d.isEmpty {
                out.append(d)
                played += 1
            }
        }
        return out
    }

    /// done 来了，说总共 total 句：中间缺的不等了，后面到了的都交出去
    public mutating func finish(total: Int) -> [Data] {
        var out: [Data] = []
        for n in next..<max(next, total) {
            if let d = waiting.removeValue(forKey: n), !d.isEmpty {
                out.append(d)
                played += 1
            }
        }
        next = max(next, total)
        return out
    }
}

/// 档越高想得越久：寄出去以后等多久算「大管家没回」（每来一句，从那一刻重新算）
public enum LookWait {
    public static func seconds(gear: Int) -> TimeInterval {
        switch gear {
        case 2: return 100
        case 3: return 200
        case 4: return 420
        default: return 45
        }
    }
}

/// 工具箱「陪玩」下面那行：声纹攒到哪了（大管家每封回信的 timing 里带 vpN 攒了几句、vpOK 建好没有）
public enum VoiceprintLine {
    public static func of(_ timing: [String: Double]?) -> String? {
        guard let t = timing, let n = t["vpN"] else { return nil }
        if (t["vpOK"] ?? 0) > 0 { return "声纹：好了" }
        return "声纹：攒了 \(Int(n)) 句"
    }
}
