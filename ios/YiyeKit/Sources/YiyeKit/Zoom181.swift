import Foundation

// 181 遥控放大（Song 11-26 11:07：截图太小「不好点」，右上角那个叉点不中）。
// 两指张合 = 只在手机上放大缩小这张图，不寄给那台；两指平着滑 = 滚轮照旧寄过去。放大了一指拖 = 挪图（不寄），点和长按照旧。
// 位置都按「框的几分之几」记（框 = 整张图等比放进去的那一块），弹键盘框变小了不用重算。

/// 手机上看这张截图的放大倍数和挪到哪儿
public struct RemoteZoom: Equatable, Sendable {
    public static let maxScale = 5.0

    /// 1 = 整屏
    public private(set) var scale: Double = 1
    /// 放大后的图左上角相对框左上角挪了多少（按框宽、框高的几分之几，永远在 1-scale…0，边贴住画面边）
    public private(set) var x: Double = 0
    public private(set) var y: Double = 0

    public init() {}

    public var zoomed: Bool { scale > 1.001 }

    /// 框里的一点（0…1）手指下面是图上哪一点（0…1）
    public func picture(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (Self.unit((p.x - x) / scale), Self.unit((p.y - y) / scale))
    }

    /// 两指张合：self 是认定缩放那一下的样子。起手两指中点下面那一点，跟着现在的中点走，倍数乘 factor
    public func pinched(factor: Double, from start: (x: Double, y: Double), to mid: (x: Double, y: Double)) -> RemoteZoom {
        guard factor.isFinite, factor > 0 else { return self }
        let anchor = picture(start)
        var z = self
        z.scale = min(max(scale * factor, 1), RemoteZoom.maxScale)
        if z.scale < 1.001 { return RemoteZoom() }
        z.x = mid.x - anchor.x * z.scale
        z.y = mid.y - anchor.y * z.scale
        z.clamp()
        return z
    }

    /// 一指拖：dx、dy 按框的几分之几。没放大挪不动
    public func moved(dx: Double, dy: Double) -> RemoteZoom {
        var z = self
        z.x += dx
        z.y += dy
        z.clamp()
        return z
    }

    private mutating func clamp() {
        x = min(0, max(1 - scale, x))
        y = min(0, max(1 - scale, y))
    }

    private static func unit(_ v: Double) -> Double { min(1, max(0, v)) }
}

/// 两根手指：先变的是间距（变过 8%）就是缩放，先变的是位置（中点挪过 20 点）就是滚轮；认定了到抬手不换
public struct TwoFingers: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case undecided, zoom, scroll }
    public static let spread = 0.08
    /// 两指挨得近的时候 8% 只有几点，手一抖就算数：间距至少还要变这么多点
    public static let spreadPoints = 8.0
    public static let travel = 20.0

    public private(set) var kind: Kind = .undecided
    public let startSpan: Double
    public let startX: Double
    public let startY: Double
    /// 现在两指的间距、中点
    public private(set) var span: Double
    public private(set) var midX: Double
    public private(set) var midY: Double

    public init(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) {
        let s = hypot(a.x - b.x, a.y - b.y)
        startSpan = s; span = s
        startX = (a.x + b.x) / 2; startY = (a.y + b.y) / 2
        midX = startX; midY = startY
    }

    @discardableResult
    public mutating func move(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Kind {
        span = hypot(a.x - b.x, a.y - b.y)
        midX = (a.x + b.x) / 2
        midY = (a.y + b.y) / 2
        if kind == .undecided {
            let change = abs(span - startSpan)
            let spreading = startSpan > 0 ? min(change / startSpan / TwoFingers.spread, change / TwoFingers.spreadPoints) : 0
            let sliding = hypot(midX - startX, midY - startY) / TwoFingers.travel
            if spreading >= 1 || sliding >= 1 { kind = spreading >= sliding ? .zoom : .scroll }
        }
        return kind
    }

    /// 张开了几倍
    public var factor: Double { startSpan > 0 ? span / startSpan : 1 }
    /// 中点上下挪了多少点（往下是正的）
    public var travelY: Double { midY - startY }
}
