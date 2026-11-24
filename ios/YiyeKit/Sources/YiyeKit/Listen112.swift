import Foundation

// 112：听力搬家。听力（kind == "listen"）只住小耳机，便签这边一条都不出现；听完满 7 天自己进废纸篓；整串循环。
// 规则都放这儿（纯算，能单测），界面和数据库在 app 里。

public enum ListenRule {
    /// 听完满这么多天，进废纸篓（走 111 的废纸篓，留 3 天能放回）
    public static let cleanDays = 7
    public static let cleanSeconds: TimeInterval = 7 * 86_400

    /// 听力 = 大管家送来的新闻简写、试听，配没配上音都算
    public static func isListen(kind: String) -> Bool { kind == "listen" }

    /// 便签这边（主页、文件夹、搜索、计数）显示不显示：听力一律不显示
    public static func showsInNotes(kind: String, trashed: Bool) -> Bool { !trashed && !isListen(kind: kind) }

    /// 小耳机收不收：没进废纸篓，并且是听力；或者 Song 自己点小耳机放进来的普通便签（inListen）。哪条路进来的都算
    public static func inPlaylist(kind: String, inListen: Bool, trashed: Bool) -> Bool {
        !trashed && (isListen(kind: kind) || inListen)
    }

    /// 只装听力的文件夹：里面有便签（没进废纸篓的），而且每一条都是听力。空文件夹不算
    public static func isListenOnlyFolder(kinds: [String]) -> Bool {
        !kinds.isEmpty && kinds.allSatisfy { isListen(kind: $0) }
    }

    /// 该不该自动清：只管听力；听完（heardAt 有值）满 7 天。没听完的、普通便签一律不清
    public static func shouldClean(kind: String, heardAt: Date?, now: Date) -> Bool {
        guard isListen(kind: kind), let h = heardAt else { return false }
        return now.timeIntervalSince(h) >= cleanSeconds
    }

    /// 从废纸篓放回来：听完过的，从放回这天重新算 7 天；没听完过的还是没听完
    public static func heardAtAfterPutBack(_ heardAt: Date?, now: Date) -> Date? {
        heardAt == nil ? nil : now
    }

    /// 一篇放完（遍数也够了）接下一篇：队尾了，整串循环开着就回第一条，关着就停（nil）
    public static func nextIndex(after i: Int, count: Int, loopAll: Bool) -> Int? {
        guard count > 0 else { return nil }
        if i + 1 < count { return i + 1 }
        return loopAll ? 0 : nil
    }

    /// 第一次完整放完一遍才记 heardAt，以后不改
    public static func firstHeard(current: Date?, now: Date) -> Date { current ?? now }
}
