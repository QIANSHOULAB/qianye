import Foundation

// 听力页按日期分组（088，Song 11-23 15:05：「新闻改写传过来直接进听力那个类别，按日期分好类」）。
// 一天一组，新的一天在上面；组里新的在上面（每日简讯第 1 篇是 08:00 减 1 秒，第 6 篇减 6 秒，所以 1→6 从上往下）。
// 拼起来就是原来的「新的在前」，播放顺序不变：一天放完接着放前一天的。

/// 一天：那天 0 点（按给的时区），这天的东西（新的在前）
public struct ListenDay<ID: Hashable>: Equatable {
    public var start: Date
    public var ids: [ID]
    public init(start: Date, ids: [ID]) { self.start = start; self.ids = ids }
}

public enum ListenDays {
    /// 分组：items 是（id，笔记的 createdAt），顺序随便。时间一样的照原来的先后
    public static func group<ID: Hashable>(_ items: [(id: ID, at: Date)], timeZone: TimeZone = .current) -> [ListenDay<ID>] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let sorted = items.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at > b.element.at : a.offset < b.offset
        }
        var out: [ListenDay<ID>] = []
        for (_, it) in sorted {
            let day = cal.startOfDay(for: it.at)
            if let last = out.last, last.start == day {
                out[out.count - 1].ids.append(it.id)
            } else {
                out.append(ListenDay(start: day, ids: [it.id]))
            }
        }
        return out
    }

    /// 拼回一条：播放的顺序
    public static func flat<ID: Hashable>(_ days: [ListenDay<ID>]) -> [ID] { days.flatMap(\.ids) }

    public enum Label: Equatable, Sendable {
        case today
        case yesterday
        /// 再早的：写日期加星期；跟今天不同年的带上年份
        case date(Date, withYear: Bool)
    }

    /// 组的小标题叫什么（today、yesterday 按手机现在的时间算）
    public static func label(_ start: Date, now: Date = Date(), timeZone: TimeZone = .current) -> Label {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: start)
        if day == today { return .today }
        if let y = cal.date(byAdding: .day, value: -1, to: today), day == y { return .yesterday }
        return .date(day, withYear: cal.component(.year, from: day) != cal.component(.year, from: today))
    }
}
