import Foundation

// 240 遥控优化（Song 11-27 07:38「掌机连得慢；连着的时候要能打字问『点上没』、要有反馈；截图刷新要流畅」）：
// 不碰界面的那部分。大管家那头（pc-butler handheld/remote.py）先寄一张小图、之后只寄变了的块、点完连拍 0.2 / 0.6 / 1.2 秒，
// 等画面变了才回；手机这头：收到一张马上要下一张，块拼在手上那张上，反馈栏照 after 说人话。

/// 一块：信里的文件、贴在图上的哪儿（像素）。JSON 里是 [路径, x, y, w, h]
public struct RemoteTile: Codable, Equatable, Sendable {
    public var path: String
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(path: String, x: Int, y: Int, w: Int, h: Int) {
        self.path = path; self.x = x; self.y = y; self.w = w; self.h = h
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        path = try c.decode(String.self)
        x = try c.decode(Int.self); y = try c.decode(Int.self); w = try c.decode(Int.self); h = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(path); try c.encode(x); try c.encode(y); try c.encode(w); try c.encode(h)
    }
}

public enum RemoteFeed {
    /// 一封回信拿来怎么办
    public enum Step: Equatable, Sendable {
        /// 整张换上
        case full
        /// 块拼到手上那张上
        case tiles
        /// 没变：图不动
        case same
        /// 晚到的、对不上的：不要（下一封 have 还是手上那张，大管家照它比）
        case skip
    }

    /// shown：手上显示的是第几张（nil = 还没有）；hasImage：信里带了整张图
    public static func step(shown: Int?, state st: RemoteState, hasImage: Bool) -> Step {
        if let t = st.tiles, !t.isEmpty {
            guard let b = st.base, b == shown, let n = st.shot, n > b else { return .skip }
            return .tiles
        }
        if hasImage {
            if let c = shown, let n = st.shot, n < c { return .skip }        // 先寄的那张晚到了
            return .full
        }
        return .same
    }

    /// 下一张什么时候要：聪明截图的那台收到就要（它自己等画面变）；老的那台照旧隔 1.5 秒
    public static func nextDelay(live: Bool) -> Double { live ? 0 : 1.5 }

    /// 一张 shot 寄出去多久没回算丢了：聪明截图那台最多等 5 秒才回，留够路上的
    public static func lostAfter(live: Bool) -> Double { live ? 12 : 8 }

    /// 点、双击、右键算「点」；别的（滚、打字、密码）算「动」
    public static func isTap(_ op: String) -> Bool { ["tap", "double", "right"].contains(op) }

    /// 反馈栏那一句（界面文字的 key）。sent：刚寄出去；after：大管家说的；op：刚做的那一下
    public static func line(op: String, sent: Bool = false, after: String?) -> String? {
        let tap = isTap(op)
        if sent {
            switch op {
            case "scroll": return "remote.fb.scrolled"
            case "type", "pass": return "remote.fb.typed"
            default: return tap ? "remote.fb.tapped" : nil
            }
        }
        switch after {
        case "wait": return "remote.fb.waiting"
        case "moved": return tap ? "remote.fb.done" : "remote.fb.changed"
        case "none": return tap ? "remote.fb.none" : "remote.fb.unchanged"
        default: return nil
        }
    }
}
