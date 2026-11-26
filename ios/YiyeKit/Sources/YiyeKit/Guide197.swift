import Foundation

// 197 遥控带路（Song 11-26 18:32：「他没有权限的我就去点，然后它告诉我点哪里，我点哪里。」）。
// 大管家点不了的地方，寄一张截图、一个圈、一句话过来（送来 kind2=guide）；小书童里一张卡，点开是遥控画面、圈画在上面。
// 圈里点一下（要双击的照双击发），点了大管家自己看成没成：成了回 done，没成换一句再请，3 次不成回 stuck。
// 这里是不碰界面的那部分：卡片怎么读、手指点没点在圈里、这一下按什么发。

public struct GuideCard: Codable, Equatable, Sendable, Identifiable {
    /// 带路的号（点的时候带回去）
    public var id: String
    /// ask（请他点）/ done（点上了、不用点了）/ stuck（点了几次没成）
    public var status: String
    public var text: String
    /// 哪台：desk / handheld
    public var host: String
    public var screen: Int
    /// 圈心（0–1，图上的比例）和半径（按图宽的比例）；没有 = 只有话和图
    public var x: Double?
    public var y: Double?
    public var r: Double?
    /// 这一下要双击
    public var twice: Bool

    public init(id: String, status: String = "ask", text: String, host: String = "handheld", screen: Int = 0,
                x: Double? = nil, y: Double? = nil, r: Double? = nil, twice: Bool = false) {
        self.id = id; self.status = status; self.text = text; self.host = host; self.screen = screen
        self.x = x; self.y = y; self.r = r; self.twice = twice
    }

    /// 送来的那封是带路的卡就读出来，别的 nil
    public init?(_ d: ButlerDelivery) {
        guard d.kind == GuideCard.kind, let g = d.guide, !g.isEmpty else { return nil }
        self.init(id: g, status: d.status ?? "ask", text: d.text, host: d.host ?? "handheld", screen: d.screen ?? 0,
                  x: d.x, y: d.y, r: d.r, twice: d.double ?? false)
    }

    public static let kind = "guide"

    public var target: RemoteTarget { RemoteTarget(rawValue: host) ?? .handheld }

    /// 图上这一点（0–1）在不在圈里。aspect = 图高 / 图宽（圈是按图宽量的，竖向要换算）。圈放宽两成，最小 0.03：手指粗
    public func contains(_ px: Double, _ py: Double, aspect: Double) -> Bool {
        guard let x, let y else { return false }
        let rr = max((r ?? 0.04) * 1.2, 0.03)
        let dx = px - x
        let dy = (py - y) * aspect
        return dx * dx + dy * dy <= rr * rr
    }

    /// 在图上点一下该怎么发：圈里 → 带上带路的号，要双击的发 double；圈外 → 照普通的点（大管家照样会再看一眼）
    public func tapPlan(_ px: Double, _ py: Double, aspect: Double) -> (op: String, guide: String?) {
        guard status == "ask", contains(px, py, aspect: aspect) else { return ("tap", nil) }
        return (twice ? "double" : "tap", id)
    }
}
