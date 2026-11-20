import Foundation

// 语音（0.2.0）：录一段 → 手机本机转成字 → 存成笔记（上面是录音，下面是字）→ 交大管家理顺。
// 录音存成附件「<短id>-语音-<n>.m4a」，不进正文；正文只有字，交给大管家的也只有字（接口 v1 不用改）。

public enum VoiceText {
    /// 认出来的一段段接成一段字：挨着汉字或中文标点的不加空格，两边都是西文的加一个
    public static func join(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if let last = out.last, let first = p.first, !isWide(last), !isWide(first) { out += " " }
            out += p
        }
        return out
    }

    /// 时长：0:05、1:23、1:02:03
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// 录音文件名：<短id>-语音-<n>.m4a（n 从 1 起）
    public static func fileName(note: UUID, index: Int) -> String {
        "\(MirrorFormat.shortID(note))-语音-\(index).m4a"
    }

    /// 导入时按名字找回录音：附件/<短id>-语音-1…n.m4a，exists 说有没有
    public static func paths(note: UUID, upTo n: Int = 30, exists: (String) -> Bool) -> [String] {
        (1...n).map { "\(MirrorFolder.attachName)/\(fileName(note: note, index: $0))" }.filter(exists)
    }

    /// 转出来的字变成笔记正文：只做最少的——去头尾空白、连着的空白并成一个（分段、标题交给大管家）
    public static func markdown(from text: String) -> String {
        var out = ""
        var lastSpace = false
        for c in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c == "\n" { out.append(c); lastSpace = false; continue }
            if c.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(c)
                lastSpace = false
            }
        }
        return out
    }
}
