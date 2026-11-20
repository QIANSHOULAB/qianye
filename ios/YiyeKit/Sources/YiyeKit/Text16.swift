import Foundation

// UIKit 的 NSRange 都是 UTF-16 下标。这里的小工具只用 Swift 标准库 + Foundation，Linux 上也能跑。

public extension String {
    /// UTF-16 长度（跟 NSString.length 一样）
    var u16: Int { utf16.count }

    func index16(_ offset: Int) -> String.Index {
        let o = max(0, min(offset, utf16.count))
        return String.Index(utf16Offset: o, in: self)
    }

    func sub16(_ r: NSRange) -> String {
        let a = index16(r.location), b = index16(r.location + r.length)
        return String(self[a..<b])
    }

    func range16(_ r: Range<String.Index>) -> NSRange {
        let a = r.lowerBound.utf16Offset(in: self), b = r.upperBound.utf16Offset(in: self)
        return NSRange(location: a, length: b - a)
    }

    func replacing16(_ r: NSRange, with s: String) -> String {
        let a = index16(r.location), b = index16(r.location + r.length)
        var t = self
        t.replaceSubrange(a..<b, with: s)
        return t
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 一行字在全文里的位置（不含换行符）
public struct LineSpan: Equatable, Sendable {
    public var range: NSRange
    public var text: String
    public init(range: NSRange, text: String) { self.range = range; self.text = text }
}

/// 按 \n 切行，记下每行的 UTF-16 位置。最后一行没换行也算一行；空文本算一行空行。
public func lineSpans(_ s: String) -> [LineSpan] {
    var out: [LineSpan] = []
    let units = Array(s.utf16)
    var start = 0
    for (k, u) in units.enumerated() where u == 10 {
        out.append(LineSpan(range: NSRange(location: start, length: k - start),
                            text: String(decoding: units[start..<k], as: UTF16.self)))
        start = k + 1
    }
    out.append(LineSpan(range: NSRange(location: start, length: units.count - start),
                        text: String(decoding: units[start..<units.count], as: UTF16.self)))
    return out
}

public extension NSRange {
    var end: Int { location + length }
    func contains16(_ i: Int) -> Bool { i >= location && i < location + length }
    func intersects16(_ o: NSRange) -> Bool { max(location, o.location) < min(end, o.end) }
    func shifted(_ d: Int) -> NSRange { NSRange(location: location + d, length: length) }
}

// ================================================================ 正则：NSRegularExpression 包一层，返回捕获组字符串
public final class Re: @unchecked Sendable {
    public let re: NSRegularExpression
    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // 写错了就是程序员的错，直接崩，测试里会抓到
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    public func test(_ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.u16)) != nil
    }
    /// 第一处匹配的全部捕获组（0 = 整段）；没匹配到的组是 nil
    public func match(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.u16)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : s.sub16(r)
        }
    }
    /// 所有匹配：每处匹配的捕获组 + 整段的位置
    public func all(_ s: String) -> [(groups: [String?], range: NSRange)] {
        re.matches(in: s, options: [], range: NSRange(location: 0, length: s.u16)).map { m in
            ((0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : s.sub16(r)
            }, m.range)
        }
    }
}

// ================================================================ 宽度、全角半角
/// 汉字、全角标点算「宽」字
public func isWide(_ c: Character) -> Bool {
    guard let v = c.unicodeScalars.first?.value else { return false }
    return (0x2E80...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v) || (0x3000...0x303F).contains(v)
}

/// 显示宽度：汉字算 2，别的算 1（跟网页版 dw() 一样）
public func dw(_ s: String) -> Int { s.reduce(0) { $0 + (isWide($1) ? 2 : 1) } }

/// 全角的 ASCII（！到～）换成半角，全角空格换成空格
public func half(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if u.value >= 0xFF01 && u.value <= 0xFF5E, let h = Unicode.Scalar(u.value - 0xFEE0) { out.append(h) }
        else if u.value == 0x3000 { out.append(" ") }
        else { out.append(u) }
    }
    return String(out)
}

/// 只把全角字母数字换成半角（中文标点留着），全角空格换成空格
public func halfAlnum(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        let v = u.value
        if (0xFF10...0xFF19).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v), let h = Unicode.Scalar(v - 0xFEE0) { out.append(h) }
        else if v == 0x3000 { out.append(" ") }
        else { out.append(u) }
    }
    return String(out)
}

public extension Character {
    var isAsciiAlnum: Bool { guard let a = asciiValue else { return false }; return (48...57).contains(a) || (65...90).contains(a) || (97...122).contains(a) }
}
