import Foundation

// 160 右滑扔便签（Song 11-25 15:12「这个删除到 70% 就能删除，不用拉满」）：拖过纸条宽的 70% 松手就扔，不用拉满、不用再点按钮。
// 这里是纯算的那部分（能单测）：起不起手、过线没过线（震不震）、松手扔不扔、垃圾桶放哪；拖的手势在 app 的 ListScreen（NoteListSwipe）。

public struct SwipeTrash: Equatable, Sendable {
    /// 线：纸条宽的 70%（以后好调）
    public static let line: Double = 0.7
    /// 手指往右走过这么多点、横比竖多才算起手。iOS 26 的拖动识别器手指走 3 点就来问（11-25 CI 量的），门槛高了就永远起不来
    public static let start: Double = 2

    public enum Buzz: Equatable, Sendable { case none, crossed, back }

    public var width: Double
    /// 现在在线外
    public private(set) var past = false

    public init(width: Double) { self.width = max(1, width) }

    /// 起手：往右、横比竖多、走过 start 点；批量选里不认；某条左滑开着（系统的置顶、小耳机露着）不认，让系统收回去
    public static func begins(dx: Double, dy: Double, selecting: Bool, swipeOpen: Bool) -> Bool {
        !selecting && !swipeOpen && dx >= start && dx > abs(dy)
    }

    /// 线在哪（点）
    public var at: Double { width * SwipeTrash.line }

    /// 拖到 dx：这一下要不要轻震（刚过线 / 刚回到线内）
    public mutating func move(_ dx: Double) -> Buzz {
        let now = dx >= at
        defer { past = now }
        if now && !past { return .crossed }
        if !now && past { return .back }
        return .none
    }

    /// 松手：线外扔，线内弹回
    public func release(_ dx: Double) -> Bool { dx >= at }

    /// 垃圾桶（连字）左边放在红底里的哪儿：没过线停在最左边；过了线跟着纸条左边走（邮件 app 那种）
    public func iconX(_ dx: Double, iconWidth: Double, inset: Double = 18) -> Double {
        guard dx >= at else { return inset }
        return max(inset, dx - iconWidth - inset)
    }
}
