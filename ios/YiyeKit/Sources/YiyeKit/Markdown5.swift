import Foundation

// Markdown 五招（锤子便签那五招）：标题（# / ## / ###）、无序列表（- ）、粗体（**…**）、引用（> ）、居中（独占一行 <center>…</center>）。
// 外加一样不算招的：图片独占一行 ![](附件/xxx.jpg)。
// 标记字留在字里（写字页里颜色淡），这里只负责认出来在哪、给工具条改字。

public enum MDBlock: Equatable, Sendable {
    case blank
    case plain
    case heading(Int)       // 1...3
    case bullet
    case quote
    case image(String)      // ![](路径) 里的路径
}

public struct MDLine: Equatable, Sendable {
    public var block: MDBlock
    public var centered: Bool
    /// 整行（不含换行），全文里的 UTF-16 位置
    public var range: NSRange
    /// 要变淡的标记字：# 、- 、> 、<center>、</center>、成对的 **
    public var markers: [NSRange]
    /// 粗体里面的字
    public var bold: [NSRange]
    /// 去掉行首标记（和 center 外壳）以后的正文
    public var content: NSRange
    public var text: String
}

public enum MDCommand: String, CaseIterable, Sendable {
    case heading, bullet, bold, quote, center
}

/// 一次改字：把 range 换成 replacement，改完光标 / 选区落在 selection
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range; self.replacement = replacement; self.selection = selection
    }
    public func applied(to s: String) -> String { s.replacing16(range, with: replacement) }
}

public enum Markdown5 {
    static let headRe = Re("^(#{1,3})[ \\t]+")
    static let bulletRe = Re("^[-*+][ \\t]+")
    static let quoteRe = Re("^>[ \\t]?")
    static let centerRe = Re("^<center>(.*)</center>[ \\t]*$")
    static let imageRe = Re("^!\\[[^\\]]*\\]\\(([^)\\s]+)\\)[ \\t]*$")
    static let boldRe = Re("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    static let numberedPrefixRe = Re("^([0-9]{1,3})(?:\\.[ \\t]+|[、．)）][ \\t]*)(?=\\S)")

    /// 一行开头的编号（「1. 」「2、」「3) 」；「1.5 米」「2026.11.27」不算）：prefix 是连空格的那一截，number 是数
    public static func numberedPrefix(_ line: String) -> (prefix: String, number: String)? {
        guard let m = numberedPrefixRe.match(line), let all = m[0], let n = m[1] else { return nil }
        return (all, n)
    }

    public static func parse(_ text: String) -> [MDLine] {
        lineSpans(text).map { parseLine($0.text, at: $0.range.location) }
    }

    public static func parseLine(_ line: String, at offset: Int) -> MDLine {
        let full = NSRange(location: offset, length: line.u16)
        if line.trimmed.isEmpty {
            return MDLine(block: .blank, centered: false, range: full, markers: [], bold: [], content: full, text: line)
        }
        if let m = imageRe.match(line), let path = m[1] {
            return MDLine(block: .image(path), centered: false, range: full, markers: [full], bold: [], content: full, text: line)
        }
        var markers: [NSRange] = []
        var inner = line, innerAt = 0
        var centered = false
        if let m = centerRe.match(line), let body = m[1] {
            centered = true
            inner = body; innerAt = 8   // "<center>" 8 个字
            markers.append(NSRange(location: offset, length: 8))
            let closeAt = 8 + body.u16
            markers.append(NSRange(location: offset + closeAt, length: line.u16 - closeAt))
        }
        var block: MDBlock = .plain
        var prefix = 0
        if let m = headRe.match(inner), let hashes = m[1], let all = m[0] {
            block = .heading(hashes.count); prefix = all.u16
        } else if let m = bulletRe.match(inner), let all = m[0] {
            // 「**粗体**」开头不算列表
            if !inner.hasPrefix("**") { block = .bullet; prefix = all.u16 }
        } else if let m = quoteRe.match(inner), let all = m[0] {
            block = .quote; prefix = all.u16
        }
        if prefix > 0 { markers.append(NSRange(location: offset + innerAt, length: prefix)) }
        let contentStr = inner.sub16(NSRange(location: prefix, length: inner.u16 - prefix))
        let contentAt = offset + innerAt + prefix
        var bold: [NSRange] = []
        for hit in boldRe.all(contentStr) {
            let r = hit.range
            markers.append(NSRange(location: contentAt + r.location, length: 2))
            markers.append(NSRange(location: contentAt + r.end - 2, length: 2))
            bold.append(NSRange(location: contentAt + r.location + 2, length: r.length - 4))
        }
        markers.sort { $0.location < $1.location }
        return MDLine(block: block, centered: centered, range: full, markers: markers, bold: bold,
                      content: NSRange(location: contentAt, length: contentStr.u16), text: line)
    }

    // ================================================================ 去标记：标题、摘要、出图用
    /// 一行去掉五招标记以后的字（图片行返回 nil）
    public static func plain(_ line: String) -> String? {
        let l = parseLine(line, at: 0)
        if case .image = l.block { return nil }
        var s = line.sub16(l.content)
        s = boldRe.re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.u16), withTemplate: "$1")
        return s
    }

    /// 标题：第一行有字的（去标记）
    public static func title(_ text: String) -> String {
        for span in lineSpans(text) {
            if let p = plain(span.text)?.trimmed, !p.isEmpty { return String(p.prefix(80)) }
        }
        return ""
    }

    /// 摘要：标题下面接着的几行，去标记，用空格连起来；上一行以中文标点收尾就直接接（「交上来。就这些」）
    public static func summary(_ text: String, maxChars: Int = 90) -> String {
        var seenTitle = false
        var s = ""
        for span in lineSpans(text) {
            guard let p = plain(span.text)?.trimmed, !p.isEmpty else { continue }
            if !seenTitle { seenTitle = true; continue }
            if let last = s.last, !closesTight.contains(last) { s += " " }
            s += p
            if s.count >= maxChars { break }
        }
        return s.count > maxChars ? String(s.prefix(maxChars)) + "…" : s
    }

    /// 这些标点后面不再补空格
    static let closesTight: Set<Character> = ["。", "！", "？", "；", "：", "，", "、", "）", "」", "』", "》", "…"]

    /// 正文里引用的图片路径（按出现顺序）
    public static func imagePaths(_ text: String) -> [String] {
        lineSpans(text).compactMap { span in
            if case .image(let p) = parseLine(span.text, at: 0).block { return p }
            return nil
        }
    }

    public static func imageLine(_ path: String) -> String { "![](\(path))" }

    // ================================================================ 工具条：五招改字
    /// selection：当前选区（UTF-16）。标题、列表、引用、居中改选区碰到的每一行；粗体包选区。
    public static func apply(_ cmd: MDCommand, to text: String, selection sel: NSRange) -> TextEdit {
        if cmd == .bold { return bold(text, sel) }
        let spans = lineSpans(text)
        // 选区碰到的行
        var idx: [Int] = []
        for (i, s) in spans.enumerated() {
            let r = s.range
            let caretLine = sel.length == 0 && sel.location >= r.location && sel.location <= r.end
            let hit = sel.length > 0 && sel.location <= r.end && sel.end > r.location || (sel.length > 0 && sel.end == r.location && r.length == 0 && false)
            if caretLine || hit { idx.append(i) }
        }
        if idx.isEmpty { idx = [spans.count - 1] }
        if sel.length > 0, idx.count > 1, let last = idx.last, spans[last].range.location == sel.end, spans[last].range.length > 0 {
            idx.removeLast()   // 选到下一行行首不算那行
        }
        let parsed = idx.map { parseLine(spans[$0].text, at: spans[$0].range.location) }
        let caretLineIndex = idx.firstIndex { sel.location >= spans[$0].range.location && sel.location <= spans[$0].range.end } ?? 0

        var newLines: [String] = []
        switch cmd {
        case .heading:
            // 一行一行各自往下一级：无 → # → ## → ### → 无
            newLines = parsed.map { l in
                var level = 0
                if case .heading(let n) = l.block { level = n }
                let next = level >= 3 ? 0 : level + 1
                return rebuild(l, block: next == 0 ? .plain : .heading(next))
            }
        case .bullet, .quote:
            let want: MDBlock = cmd == .bullet ? .bullet : .quote
            let nonBlank = parsed.filter { $0.block != .blank }
            let allHave = !nonBlank.isEmpty && nonBlank.allSatisfy { $0.block == want }
            newLines = parsed.map { l in
                if l.block == .blank && parsed.count > 1 { return l.text }
                if case .image = l.block { return l.text }
                return rebuild(l, block: allHave ? .plain : want)
            }
        case .center:
            let nonBlank = parsed.filter { $0.block != .blank }
            let allHave = !nonBlank.isEmpty && nonBlank.allSatisfy { $0.centered }
            newLines = parsed.map { l in
                if l.block == .blank && parsed.count > 1 { return l.text }
                if case .image = l.block { return l.text }
                return rebuild(l, block: l.block == .blank ? .plain : l.block, centered: !allHave)
            }
        case .bold:
            break
        }
        let first = spans[idx.first!].range.location
        let lastR = spans[idx.last!].range
        let range = NSRange(location: first, length: lastR.end - first)
        let replacement = newLines.joined(separator: "\n")
        // 光标：落在它那行的正文里，跟着正文平移
        let oldLine = parsed[caretLineIndex]
        let lineStartNew = first + newLines.prefix(caretLineIndex).reduce(0) { $0 + $1.u16 + 1 }
        let newParsed = parseLine(newLines[caretLineIndex], at: lineStartNew)
        func mapCaret(_ p: Int) -> Int {
            let inContent = p - oldLine.content.location
            if inContent < 0 { return newParsed.content.location }
            return min(newParsed.content.location + inContent, newParsed.content.end)
        }
        let selection: NSRange
        if sel.length == 0 {
            selection = NSRange(location: mapCaret(sel.location), length: 0)
        } else {
            selection = NSRange(location: first, length: replacement.u16)
        }
        return TextEdit(range: range, replacement: replacement, selection: selection)
    }

    /// 按新的块类型重写一行：正文不动，换行首标记和居中外壳
    static func rebuild(_ l: MDLine, block: MDBlock, centered: Bool? = nil) -> String {
        let fullText = l.text
        let body = fullText.sub16(NSRange(location: l.content.location - l.range.location, length: l.content.length))
        var prefix = ""
        switch block {
        case .heading(let n): prefix = String(repeating: "#", count: n) + " "
        case .bullet: prefix = "- "
        case .quote: prefix = "> "
        default: prefix = ""
        }
        let inner = prefix + body
        let c = centered ?? l.centered
        return c ? "<center>\(inner)</center>" : inner
    }

    static func bold(_ text: String, _ sel: NSRange) -> TextEdit {
        if sel.length == 0 {
            // 没选字：插一对 **，光标放中间
            return TextEdit(range: sel, replacement: "****", selection: NSRange(location: sel.location + 2, length: 0))
        }
        let picked = text.sub16(sel)
        // 选的字本身带着 **…**：拆掉
        if picked.hasPrefix("**"), picked.hasSuffix("**"), picked.u16 >= 4 {
            let inner = picked.sub16(NSRange(location: 2, length: picked.u16 - 4))
            return TextEdit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: inner.u16))
        }
        // 选区两边挨着 **：拆掉
        if sel.location >= 2, sel.end + 2 <= text.u16,
           text.sub16(NSRange(location: sel.location - 2, length: 2)) == "**",
           text.sub16(NSRange(location: sel.end, length: 2)) == "**" {
            let r = NSRange(location: sel.location - 2, length: sel.length + 4)
            return TextEdit(range: r, replacement: picked, selection: NSRange(location: sel.location - 2, length: sel.length))
        }
        // 跨行的选区：每行各包各的
        if picked.contains("\n") {
            let parts = picked.components(separatedBy: "\n").map { $0.trimmed.isEmpty ? $0 : "**\($0)**" }
            let rep = parts.joined(separator: "\n")
            return TextEdit(range: sel, replacement: rep, selection: NSRange(location: sel.location, length: rep.u16))
        }
        let rep = "**\(picked)**"
        return TextEdit(range: sel, replacement: rep, selection: NSRange(location: sel.location + 2, length: sel.length))
    }
}

// ================================================================ 写字页显示用：图片行在屏幕上是一个附件字符
/// Markdown 正文 ⇄ 写字页里的字。图片行 `![](路径)` 在写字页里换成一个 U+FFFC（附件），别的字一个不动。
public struct DisplayMap: Equatable, Sendable {
    public static let attachmentChar: Character = "\u{FFFC}"
    public var display: String
    /// 每张图：在 Markdown 里的位置、在写字页里的位置、路径
    public var images: [(md: NSRange, display: NSRange, path: String)]

    public static func == (a: DisplayMap, b: DisplayMap) -> Bool {
        a.display == b.display && a.images.count == b.images.count &&
        zip(a.images, b.images).allSatisfy { $0.md == $1.md && $0.display == $1.display && $0.path == $1.path }
    }

    public init(markdown: String) {
        var out = ""
        var imgs: [(NSRange, NSRange, String)] = []
        let spans = lineSpans(markdown)
        for (i, span) in spans.enumerated() {
            if case .image(let p) = Markdown5.parseLine(span.text, at: span.range.location).block {
                imgs.append((span.range, NSRange(location: out.u16, length: 1), p))
                out.append(DisplayMap.attachmentChar)
            } else {
                out += span.text
            }
            if i < spans.count - 1 { out += "\n" }
        }
        display = out
        images = imgs
    }

    /// Markdown 里的位置 → 写字页里的位置（落在图片行里的，算到那个附件字符上）
    public func toDisplay(_ r: NSRange) -> NSRange {
        NSRange(location: mapPoint(r.location, mdToDisplay: true), length: 0).union16(mapPoint(r.end, mdToDisplay: true))
    }

    public func toMarkdown(_ r: NSRange) -> NSRange {
        NSRange(location: mapPoint(r.location, mdToDisplay: false), length: 0).union16(mapPoint(r.end, mdToDisplay: false))
    }

    func mapPoint(_ p: Int, mdToDisplay: Bool) -> Int {
        var delta = 0
        for img in images {
            let from = mdToDisplay ? img.md : img.display
            let to = mdToDisplay ? img.display : img.md
            if p >= from.end { delta = to.end - from.end; continue }
            if p > from.location { return to.location + (p - from.location >= from.length ? to.length : 0) }
            return p + (to.location - from.location)
        }
        return p + delta
    }
}

extension NSRange {
    /// 从 self.location 到 end 拉成一段
    func union16(_ end: Int) -> NSRange { NSRange(location: location, length: max(0, end - location)) }
}

/// 写字页里的字拼回 Markdown。paths：附件字符的 UTF-16 位置 → 图片路径（没路径的附件字符丢掉）。
/// 图片一定独占一行：附件字符前后要是挨着字，补一个换行。
public func markdownFromDisplay(_ display: String, paths: [Int: String]) -> String {
    var out = ""
    var pos = 0
    let chars = Array(display)
    for (i, ch) in chars.enumerated() {
        let w = String(ch).u16
        defer { pos += w }
        if ch == DisplayMap.attachmentChar {
            guard let p = paths[pos] else { continue }
            if let last = out.last, last != "\n" { out += "\n" }
            out += Markdown5.imageLine(p)
            if i + 1 < chars.count, chars[i + 1] != "\n" { out += "\n" }
        } else {
            out.append(ch)
        }
    }
    return out
}
