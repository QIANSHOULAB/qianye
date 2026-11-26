import Foundation

// 172 遥控（Song 11-25 22:58–23:02）：手机上看电脑（或掌机）的屏幕，点哪儿那台就点哪儿；打一行字；递密码。
// 走现在的加密信箱（ask=remote，一个动作一封信），不装第三方远程桌面。这里是不碰界面的那部分：
// 一个动作长什么样、回信怎么读、手机图上的一点怎么换成那张图上的比例、密码那一封怎么装。
// 密码：只在寄出前那一下在内存里；信里单独一个 secret 字段（整封信本来就两头加密，跟 128 飞鸽传书一样），不进 text、不进别的字段；
// 不存便签、不进日志、不进截图。大管家那头只交给「敲键盘」那一小段（pc-butler handheld/remote.py）。

/// 一个遥控动作（请求里的 remote）
public struct RemoteOp: Codable, Equatable, Sendable {
    /// open / shot / tap / double（197 双击）/ right / scroll / type / pass / close
    public var op: String
    /// 这一场的号（open 时定，之后每个动作都带）
    public var session: String?
    /// 第几块屏（0 = 主屏）
    public var screen: Int?
    /// 点、滚的那一点是按哪一张图算的（回信里的 shot）
    public var shot: Int?
    /// 那张图上的位置：0–1 的比例（左上 0,0）
    public var x: Double?
    public var y: Double?
    /// 滚几格：正 = 往上
    public var dy: Int?
    /// type：打的字（密码不走这里，走请求的 secret）
    public var text: String?
    /// 197：这一下是照哪张带路的卡点的
    public var guide: String?

    public init(op: String, session: String? = nil, screen: Int? = nil, shot: Int? = nil, x: Double? = nil, y: Double? = nil,
                dy: Int? = nil, text: String? = nil, guide: String? = nil) {
        self.op = op; self.session = session; self.screen = screen; self.shot = shot; self.x = x; self.y = y; self.dy = dy; self.text = text
        self.guide = guide
    }

    /// 算「动作」的（5 分钟没有这些，那台自己结束遥控）；截图不算
    public var isMove: Bool { ["open", "tap", "double", "right", "scroll", "type", "pass"].contains(op) }
}

/// 回信里的 remote：这一下之后那台的样子
public struct RemoteState: Codable, Equatable, Sendable {
    public var on: Bool?
    public var session: String?
    public var screen: Int?
    /// 跟着这封回来的那张图的号（点的时候带回去）
    public var shot: Int?
    /// 那块屏的真大小（物理像素）
    public var w: Int?
    public var h: Int?
    /// 一共几块屏
    public var screens: Int?
    /// 图在信里的路径（files 里的 key）
    public var image: String?
    /// 截到的是黑的
    public var black: Bool?
    /// 系统不让远程点（UAC、锁屏）：这一下没做
    public var blocked: Bool?
    /// 遥控结束了（手机点了结束、5 分钟没动作、开关关着、那台不在线）
    public var ended: Bool?

    public init(on: Bool? = nil, session: String? = nil, screen: Int? = nil, shot: Int? = nil, w: Int? = nil, h: Int? = nil,
                screens: Int? = nil, image: String? = nil, black: Bool? = nil, blocked: Bool? = nil, ended: Bool? = nil) {
        self.on = on; self.session = session; self.screen = screen; self.shot = shot; self.w = w; self.h = h; self.screens = screens
        self.image = image; self.black = black; self.blocked = blocked; self.ended = ended
    }
}

public enum RemoteTarget: String, CaseIterable, Sendable {
    case desk, handheld

    /// 信箱说谁在线（hello / state 里的 pcs）：只有在线的那台点得动
    public static func online(_ pcs: [String]) -> Set<RemoteTarget> {
        Set(pcs.compactMap { RemoteTarget(rawValue: $0) })
    }
}

/// 手机图上的一点 → 那张图上的比例。图在框里是「等比缩放、居中」放的（aspect fit），框里图外面的空白不算（nil）
public enum RemoteMap {
    public static func fitRect(view: (w: Double, h: Double), image: (w: Double, h: Double)) -> (x: Double, y: Double, w: Double, h: Double) {
        guard view.w > 0, view.h > 0, image.w > 0, image.h > 0 else { return (0, 0, 0, 0) }
        let s = min(view.w / image.w, view.h / image.h)
        let w = image.w * s, h = image.h * s
        return ((view.w - w) / 2, (view.h - h) / 2, w, h)
    }

    public static func normalized(_ p: (x: Double, y: Double), view: (w: Double, h: Double), image: (w: Double, h: Double)) -> (x: Double, y: Double)? {
        let r = fitRect(view: view, image: image)
        guard r.w > 0, r.h > 0 else { return nil }
        let nx = (p.x - r.x) / r.w, ny = (p.y - r.y) / r.h
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return (nx, ny)
    }

    /// 两指上下滑 dragY 点 → 滚几格，跟手机上翻页一个方向：往上滑 = 看下面 = 滚轮往下 = 负的。一格算 40 点，最多一次 10 格
    public static func notches(dragY: Double) -> Int {
        let n = Int((dragY / 40).rounded())
        return max(-10, min(10, n))
    }
}

/// 密码开关：开着的时候屏幕上只有点点；发出去走 secret，不走 text
public enum RemotePass {
    public static func shown(_ s: String, password: Bool) -> String {
        password ? String(repeating: "•", count: s.count) : s
    }
}

extension ButlerRequest {
    /// 一个遥控动作。target：寄给哪台（desk / handheld；电脑在线时寄给掌机的，电脑不接，20 秒后信箱转给掌机）
    public static func remote(id: String, op: RemoteOp, target: RemoteTarget, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "remote", at: at, app: app)
        var o = op
        if o.op == "pass" { o.text = nil }                    // 密码不走 text
        r.remote = o
        r.for = target.rawValue
        return r
    }

    /// 递密码：secret 单独一个字段（整封信两头加密），remote 里只有 op=pass 和这一场的号
    public static func remotePass(id: String, secret: String, session: String, target: RemoteTarget, at: String, app: String) -> ButlerRequest {
        var r = remote(id: id, op: RemoteOp(op: "pass", session: session), target: target, at: at, app: app)
        r.secret = secret
        return r
    }
}
