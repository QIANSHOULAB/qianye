import Foundation

// 144：听力循环挑哪几天（Song 11-25 10:07「可以选循环今天，昨天和两个一起，还有循环所有」）。
// 底下的 🔁 照旧是总开关；开着时每一天的标题右边一个小圈，亮 = 这天在循环里，可以亮好几天，也能一下全亮。
// 天用「yyyy-MM-dd」（手机的时区）记，好存、好比。规则都在这儿（纯算，能单测），界面在 ListenViews。

public struct ListenLoop: Equatable, Sendable {
    /// 全亮：以后来的新的一天也算亮着
    public static let every = "*"

    /// 🔁 总开关
    public var on: Bool
    /// 亮着的天（every = 全亮）
    public var lit: Set<String>
    /// 这套亮法是哪天定的：换了一天第一次打开听力，回到只亮今天
    public var litDay: String

    public init(on: Bool = false, lit: Set<String> = [], litDay: String = "") {
        self.on = on; self.lit = lit; self.litDay = litDay
    }

    /// 一个时刻落在哪天
    public static func key(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 读设置：没存过亮法的老用户（112 的整串循环）。loopAll 开着的迁成 🔁 开着、全亮，今天定的（今天不会被翻回只亮今天）
    public static func load(loopAll: Bool, lit: [String]?, litDay: String?, today: String) -> ListenLoop {
        guard let lit, let litDay else {
            return ListenLoop(on: loopAll, lit: loopAll ? [every] : [today], litDay: today)
        }
        return ListenLoop(on: loopAll, lit: Set(lit), litDay: litDay)
    }

    /// 打开听力时：换了一天就回到只亮今天（早上有新稿子）；同一天里他挑的记住
    public mutating func open(today: String) {
        guard litDay != today else { return }
        lit = [today]
        litDay = today
    }

    public func isLit(_ day: String) -> Bool { lit.contains(ListenLoop.every) || lit.contains(day) }

    /// days 里每一天都亮着
    public func allLit(_ days: [String]) -> Bool { days.allSatisfy(isLit) }

    /// 页面上看到的亮法：亮着的那几天一篇都没有了（比如今天还没来稿子），就亮最上面那天，免得循环空转
    public func shown(_ days: [String]) -> Set<String> {
        let mine = Set(days.filter(isLit))
        if mine.isEmpty, let first = days.first { return [first] }
        return mine
    }

    /// 点一下某天的小圈：亮的灭、灭的亮。最后一天也点灭了 = 关 🔁（亮法回到只亮今天）
    public mutating func toggle(_ day: String, days: [String], today: String) {
        var now = shown(days)
        if now.contains(day) { now.remove(day) } else { now.insert(day) }
        if now.isEmpty {
            on = false
            lit = [today]
        } else {
            lit = now
        }
        litDay = today
    }

    /// 全亮
    public mutating func lightAll(today: String) {
        lit = [ListenLoop.every]
        litDay = today
    }

    /// 🔁 开着时点了一篇：那天亮着照常；没亮，循环换成只亮那一天
    public mutating func played(day: String, days: [String], today: String) {
        guard on, !shown(days).contains(day) else { return }
        lit = [day]
        litDay = today
    }

    /// 放完一篇（遍数也够了）接哪篇。dayOf：队里每篇是哪天的（跟队一样长）。
    /// 🔁 关：照列表往下，到底就停（nil）。🔁 开：只在亮着的那几天里走，最后一篇放完回亮着的第一篇；
    /// 起点不在亮着的里面，就接它后面第一篇亮着的。
    public func next(after i: Int, dayOf: [String]) -> Int? {
        guard !dayOf.isEmpty else { return nil }
        guard on else { return i + 1 < dayOf.count ? i + 1 : nil }
        let lit = shown(ListenLoop.ordered(dayOf))
        if i + 1 < dayOf.count, let k = (i + 1 ..< dayOf.count).first(where: { lit.contains(dayOf[$0]) }) { return k }
        return dayOf.indices.first { lit.contains(dayOf[$0]) }
    }

    /// 队里出现过的天，照出现的先后，不重复
    public static func ordered(_ dayOf: [String]) -> [String] {
        var seen = Set<String>()
        return dayOf.filter { seen.insert($0).inserted }
    }
}
