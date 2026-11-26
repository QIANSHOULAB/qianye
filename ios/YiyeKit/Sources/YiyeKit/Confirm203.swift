import Foundation

// 203 在外面点自动工的确认（Song 11-26 20:58：「他必须要我点的，那我就去把那个打开点一下吧」）。
// 大管家寄一张卡（送来 kind2=confirm）：哪台、哪张单、要做什么；下面原样给那件事（工具名 + 命令或路径，最多三行）。
// 他点「同意」「不同意」，寄 ask=ok 回给在问的那台；只放这一回。到点没点：当不同意，卡片写过期了。
// 这里是不碰界面的那部分：卡片怎么读、还能不能点、回什么。

/// 他点的那一下（请求里的 ok）
public struct ConfirmTap: Codable, Equatable, Sendable {
    public var confirm: String
    public var yes: Bool
    public init(confirm: String, yes: Bool) { self.confirm = confirm; self.yes = yes }
}

/// 回信里的 confirm（stage = confirm）：这一下大管家收下没有
public struct ConfirmReply: Codable, Equatable, Sendable {
    public var id: String
    public var taken: Bool
    public init(id: String, taken: Bool) { self.id = id; self.taken = taken }
}

public struct ConfirmCard: Codable, Equatable, Sendable, Identifiable {
    public static let kind = "confirm"
    /// 这一张的号（点的时候带回去）
    public var id: String
    /// ask（等他点）/ yes / no / expired
    public var status: String
    /// 第一行人话：哪台哪单做什么
    public var text: String
    /// 工具名 + 命令或路径，最多三行
    public var detail: String
    /// 哪台在问：desk / handheld
    public var host: String
    public var order: String
    public var expires: Date?
    /// 他点了、寄出去了："yes" / "no"
    public var sent: String?
    /// 大管家没收下时回的那句、或者没寄出去的原因
    public var said: String?

    public init(id: String, status: String = "ask", text: String, detail: String = "", host: String = "handheld",
                order: String = "", expires: Date? = nil) {
        self.id = id; self.status = status; self.text = text; self.detail = detail; self.host = host
        self.order = order; self.expires = expires
    }

    /// 送来的那封是要他点头的卡就读出来，别的 nil
    public init?(_ d: ButlerDelivery) {
        guard d.kind == ConfirmCard.kind, let c = d.confirm, !c.isEmpty else { return nil }
        self.init(id: c, status: d.status ?? "ask", text: d.text, detail: d.detail ?? "", host: d.host ?? "handheld",
                  order: d.order ?? "", expires: d.expires.flatMap { ISOTime.date($0) })
    }

    /// 现在这张该是什么样：过了点还没点、大管家也还没来话，手机自己写过期
    public func shown(at now: Date) -> String {
        if status == "ask", sent == nil, let e = expires, now > e { return "expired" }
        return status
    }

    /// 还能点
    public func open(at now: Date) -> Bool { shown(at: now) == "ask" && sent == nil }

    /// 大管家来话换状态：定了的（yes / no / expired）不被后到的 ask 盖掉
    public func updated(by new: ConfirmCard) -> ConfirmCard {
        guard new.status != "ask" else { return self }
        var c = self
        c.status = new.status
        c.said = nil
        return c
    }
}

extension ButlerRequest {
    /// 接口 v3.19：他在卡上点了一下。for = 在问的那台（电脑不接写给掌机的，信箱 20 秒后转给掌机）
    public static func confirm(id: String, card: ConfirmCard, yes: Bool, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "ok", at: at, app: app)
        r.ok = ConfirmTap(confirm: card.id, yes: yes)
        r.for = card.host
        return r
    }
}
