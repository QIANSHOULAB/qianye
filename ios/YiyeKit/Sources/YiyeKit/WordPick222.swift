import Foundation
#if canImport(CoreGraphics)
import CoreGraphics        // iOS 上 CGRect 的 minX、width 这些在这里头
#endif

// 222：听力原文里点一下选一个词、点两下选整句。切词、认点两下、手指落点归哪个词、什么时候能自己滚，不碰 UIKit，能单测。

public enum WordPick {
    /// 选得上的词在 UTF-16 里的范围（UITextView 用的就是这个数法）。
    /// 一个词 = 连着的字母、数字；中间的撇号、连字符不断开（don't、well-known、COVID-19），U.S. 这种一个字母一个点的也算一个。
    /// 一个字母都没有的（数字、金额）、标点、空白不选；中日韩的字不算（只翻英文）。
    public static func words(in text: String) -> [NSRange] {
        let chars = Array(text)
        var offsets: [Int] = []                 // 第 i 个字从 UTF-16 的第几个开始
        offsets.reserveCapacity(chars.count + 1)
        var at = 0
        for c in chars { offsets.append(at); at += c.utf16.count }
        offsets.append(at)

        var out: [NSRange] = []
        var i = 0
        while i < chars.count {
            guard isPart(chars[i]) else { i += 1; continue }
            var j = initialsEnd(chars, i)
            if j == nil {
                var k = i + 1
                while k < chars.count {
                    if isPart(chars[k]) { k += 1; continue }
                    if joiners.contains(chars[k]), k + 1 < chars.count, isPart(chars[k + 1]) { k += 2; continue }
                    break
                }
                j = k
            }
            let end = j ?? i + 1
            if chars[i..<end].contains(where: { $0.isLetter }) {
                out.append(NSRange(location: offsets[i], length: offsets[end] - offsets[i]))
            }
            i = end
        }
        return out
    }

    /// 词中间不断开的记号
    private static let joiners: Set<Character> = ["'", "’", "-", "‐", "‑"]

    /// U.S.、e.g.：从 i 起至少两组「一个字母 + 点」，连最后那个点算一个词；不是这种：nil
    private static func initialsEnd(_ chars: [Character], _ i: Int) -> Int? {
        var k = i
        var groups = 0
        while k + 1 < chars.count, isPart(chars[k]), chars[k].isLetter, chars[k + 1] == "." {
            groups += 1
            k += 2
        }
        guard groups >= 2, k >= chars.count || !isPart(chars[k]) else { return nil }
        return k
    }

    /// 能算进词里的字：字母、数字；中日韩的字、全角的不算
    private static func isPart(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber, let u = c.unicodeScalars.first?.value else { return false }
        let cjk: [ClosedRange<UInt32>] = [0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x3FFFF]
        return !cjk.contains { $0.contains(u) }
    }

    /// 手指落在哪个词上：正落在某个词的框里就是它；落在缝里（词间、行间、边上）归离得最近的那个，超过 slop 点谁也不算。
    /// rects[i] 是第 i 个词占的框（折了行的有好几个）
    public static func hit(x: Double, y: Double, rects: [[CGRect]], slop: Double = 9) -> Int? {
        var best: (index: Int, d: Double)?
        for (i, list) in rects.enumerated() {
            for r in list where r.width > 0 && r.height > 0 {
                let dx = max(Double(r.minX) - x, 0, x - Double(r.maxX))
                let dy = max(Double(r.minY) - y, 0, y - Double(r.maxY))
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= slop, d < (best?.d ?? Double.greatestFiniteMagnitude) { best = (i, d) }
            }
        }
        return best?.index
    }
}

/// 点一下还是点两下：第一下马上算「一下」（不等，手感快）；0.4 秒内在差不多的地方又点一下算「两下」。第三下重新数
public struct TapCount: Sendable {
    public static let window: TimeInterval = 0.4
    public static let radius: Double = 34
    private var lastAt: TimeInterval?
    private var lastX: Double = 0
    private var lastY: Double = 0
    public init() {}

    public mutating func tap(x: Double, y: Double, at time: TimeInterval) -> Int {
        if let l = lastAt, time - l <= TapCount.window {
            let dx = x - lastX, dy = y - lastY
            if (dx * dx + dy * dy).squareRoot() <= TapCount.radius {
                lastAt = nil
                return 2
            }
        }
        lastAt = time; lastX = x; lastY = y
        return 1
    }
}

/// 跟着放（自己滚到正在放的那句）：开关开着、没开着卡片、没选着字、手最近没碰文字才滚。手一碰（滚、点词），停 5 秒
public struct FollowHold: Equatable, Sendable {
    public static let pause: TimeInterval = 5
    public private(set) var until: Date?
    public init() {}

    public mutating func touched(at now: Date = Date()) { until = now.addingTimeInterval(FollowHold.pause) }
    public mutating func clear() { until = nil }

    /// 还要停几秒（0 = 不用停）
    public func left(now: Date = Date()) -> TimeInterval { max(0, until?.timeIntervalSince(now) ?? 0) }

    public func mayScroll(on: Bool, card: Bool, selecting: Bool, now: Date = Date()) -> Bool {
        on && !card && !selecting && left(now: now) <= 0
    }
}
