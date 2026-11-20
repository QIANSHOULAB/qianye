import Foundation

// 拍照认字 → Markdown 草稿。Vision 那头（YiyeOCR）把 RecognizeDocumentsRequest 的段落、清单、行翻成下面这几个纯数据，
// 这里排成草稿：第一行短句当标题，清单各归各位，「名字＋数字」一行一条；拿不准的字记下位置，写字页里标黄。

public struct OCRLine: Equatable, Sendable {
    public var text: String
    public var confidence: Float
    /// 第二、第三候选（跟第一候选不一样的地方就是拿不准的地方）
    public var alternatives: [String]
    /// Vision 说这一行接着下一行（一句话折了行）
    public var wraps: Bool?
    public var isTitle: Bool
    /// 0 = 纸的最上面，1 = 最下面
    public var top: Double
    public var left: Double
    public var height: Double
    public var width: Double
    /// 拿不准的词（Vision 给了逐词结果时才有）
    public var weakWords: [String]
    /// 能不能拿第二遍认字来对（表格里拼起来的行不能）
    public var crossCheck: Bool

    public init(text: String, confidence: Float, alternatives: [String] = [], wraps: Bool? = nil, isTitle: Bool = false,
                top: Double = 0, left: Double = 0, height: Double = 0, width: Double = 0, weakWords: [String] = [], crossCheck: Bool = true) {
        self.text = text; self.confidence = confidence; self.alternatives = alternatives; self.wraps = wraps
        self.isTitle = isTitle; self.top = top; self.left = left; self.height = height; self.width = width
        self.weakWords = weakWords; self.crossCheck = crossCheck
    }
}

public struct OCRBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case paragraph, title, listItem(marker: String) }
    public var kind: Kind
    public var lines: [OCRLine]
    public var centered: Bool
    public init(kind: Kind, lines: [OCRLine], centered: Bool = false) { self.kind = kind; self.lines = lines; self.centered = centered }
    public var top: Double { lines.map(\.top).min() ?? 0 }
}

public struct OCRPage: Equatable, Sendable {
    public var blocks: [OCRBlock]
    public init(blocks: [OCRBlock]) { self.blocks = blocks }
}

public struct OCRDraft: Equatable, Sendable {
    public var markdown: String
    /// 拿不准的字在 markdown 里的位置（UTF-16）
    public var unsure: [NSRange]
    public var unsureTexts: [String] { unsure.map { markdown.sub16($0) } }
    public init(markdown: String, unsure: [NSRange]) { self.markdown = markdown; self.unsure = unsure }
}

public enum DraftBuilder {
    static let bulletMarkers = Set(["•", "-", "·", "*", "●", "○", "▪", "■", "◦", "–", "—"])

    public static func build(_ page: OCRPage, threshold: Float = 0.5) -> OCRDraft {
        // 清单里的行，段落里再出现一遍的，去掉
        var listKeys = Set<String>()
        for b in page.blocks { if case .listItem = b.kind { for l in b.lines { listKeys.insert(key(l)) } } }
        var blocks: [OCRBlock] = page.blocks.compactMap { b in
            if case .listItem = b.kind { return b }
            var c = b
            c.lines = b.lines.filter { !listKeys.contains(key($0)) && !$0.text.trimmed.isEmpty }
            return c.lines.isEmpty ? nil : c
        }
        blocks.sort { $0.top < $1.top }
        // 每个块里的行按上下排
        for i in blocks.indices { blocks[i].lines.sort { abs($0.top - $1.top) < 0.004 ? $0.left < $1.left : $0.top < $1.top } }

        var out = ""
        var unsure: [NSRange] = []
        func newline() { if !out.isEmpty { out += "\n" } }
        /// 写一行：prefix + 各行接起来（drop：第一行开头去掉几个字，比如认成「口」的勾选框）
        func emit(_ prefix: String, _ parts: [OCRLine], suffix: String = "", drop: Int = 0) {
            newline()
            out += prefix
            for (i, l) in parts.enumerated() {
                if i > 0 { out += joiner(parts[i - 1], l) }
                var text = clean(l.text)
                var ranges = weak(text, l, threshold)
                if i == 0 && drop > 0 {
                    let d = min(drop, text.u16)
                    text = text.sub16(NSRange(location: d, length: text.u16 - d)).trimmed
                    let cut = clean(l.text).u16 - text.u16
                    ranges = ranges.compactMap { r in
                        let a = max(r.location - cut, 0), b = r.end - cut
                        return b > a ? NSRange(location: a, length: b - a) : nil
                    }
                }
                let at = out.u16
                out += text
                for r in ranges { unsure.append(r.shifted(at)) }
            }
            out += suffix
        }

        // 标题：Vision 认出来的标题；没有就看第一行是不是短句
        var titleDone = false
        if let ti = blocks.firstIndex(where: { $0.kind == .title }) {
            let b = blocks.remove(at: ti)
            emit("# ", b.lines)
            titleDone = true
        }
        for (bi, b) in blocks.enumerated() {
            switch b.kind {
            case .title:
                emit("## ", b.lines)
            case .listItem(let marker):
                titleDone = true
                let m = marker.trimmed
                let first = b.lines.first.map { clean($0.text) } ?? ""
                let mCore = m.trimmingCharacters(in: CharacterSet(charactersIn: ".、．)）"))
                if bulletMarkers.contains(m) || m.isEmpty {
                    // 圆点、短横：换成 Markdown 列表；认出来的字里要是带着这个记号，去掉
                    emit("- ", b.lines, drop: !m.isEmpty && first.hasPrefix(m) ? m.u16 : 0)
                } else if !mCore.isEmpty && first.hasPrefix(mCore) {
                    // 「1.螺丝」「A线早班」：编号本来就在字里，照原样
                    emit("", b.lines)
                } else {
                    emit(m + " ", b.lines)
                }
            case .paragraph:
                var lines = b.lines
                if !titleDone && bi == 0, let first = lines.first {
                    let rest = lines.count > 1 || blocks.count > 1
                    let t = clean(first.text)
                    if rest && (first.isTitle || looksTitle(t)) {
                        emit("# ", [first])
                        lines.removeFirst()
                    }
                }
                titleDone = true
                if lines.isEmpty { continue }
                // 连着两行以上开头是「口 / □ / ☐」：那是勾选框，变成列表
                let boxes = Set(["口", "□", "☐", "▢"])
                let boxed = lines.count >= 2 && lines.filter { l in
                    let t = clean(l.text)
                    return t.count > 1 && boxes.contains(String(t.prefix(1)))
                }.count >= 2
                if keepLines(lines) || boxed {
                    for l in lines {
                        let t = clean(l.text)
                        if boxed && t.count > 1 && boxes.contains(String(t.prefix(1))) {
                            emit("- ", [l], drop: String(t.prefix(1)).u16)
                        } else {
                            emit("", [l])
                        }
                    }
                } else {
                    // 一句话折了行的接起来；别的照原样分行
                    var group: [OCRLine] = []
                    for (i, l) in lines.enumerated() {
                        group.append(l)
                        let cont = i + 1 < lines.count && continues(l, lines[i + 1])
                        if !cont {
                            let short = group.count == 1 && dw(clean(group[0].text)) <= 24
                            if b.centered && short && lines.count == 1 {
                                emit("<center>", group, suffix: "</center>")
                            } else {
                                emit("", group)
                            }
                            group = []
                        }
                    }
                }
            }
        }
        return OCRDraft(markdown: out, unsure: merge(unsure))
    }

    static func key(_ l: OCRLine) -> String { "\(Int(l.top * 500))|\(Int(l.left * 500))|\(l.text.trimmed)" }

    /// 去掉行首行尾空白；全角字母数字换半角
    static func clean(_ s: String) -> String { halfAlnum(s).trimmed }

    static func looksTitle(_ t: String) -> Bool {
        dw(t) <= 30 && !Structure.endPunctRe.test(t) && Structure.asPair(t) == nil && Structure.asList(t) == nil && !t.hasPrefix("口")
    }

    /// 都是「名字＋数字」、键值、短行：一行一条，不接
    static func keepLines(_ lines: [OCRLine]) -> Bool {
        guard lines.count >= 2 else { return false }
        let texts = lines.map { clean($0.text) }
        let structured = texts.filter { Structure.asPair($0) != nil || Structure.asList($0) != nil || Structure.kvRe.test($0) }.count
        if structured * 2 >= texts.count { return true }
        return texts.allSatisfy { dw($0) <= 24 }
    }

    static func continues(_ a: OCRLine, _ b: OCRLine) -> Bool {
        if let w = a.wraps { return w }
        let t = clean(a.text)
        return dw(t) > 24 && !Structure.endPunctRe.test(t)
    }

    static func joiner(_ a: OCRLine, _ b: OCRLine) -> String {
        let l = clean(a.text).last, f = clean(b.text).first
        if let l, let f, !isWide(l), !isWide(f) { return " " }
        return ""
    }

    /// 一行里拿不准的位置：整行分低 → 整行；候选不一样 → 不一样的那几个字（英文数字扩到整个词）；Vision 标出的弱词
    static func weak(_ text: String, _ l: OCRLine, _ threshold: Float) -> [NSRange] {
        if text.isEmpty { return [] }
        if l.confidence < threshold { return [NSRange(location: 0, length: text.u16)] }
        var out: [NSRange] = []
        if let alt = l.alternatives.first.map(clean), !alt.isEmpty, alt != text {
            out += changedRanges(text, alt)
        }
        for w in l.weakWords where !w.isEmpty {
            if let r = text.range(of: w) { out.append(text.range16(r)) }
        }
        return merge(out).map { expandToWord(text, $0) }
    }

    /// text 里跟 alt 不一样的字的位置
    static func changedRanges(_ text: String, _ alt: String) -> [NSRange] {
        let ops = TextDiff.ops(text, alt)
        var out: [NSRange] = []
        var pos = 0           // text 里的 UTF-16 位置
        var start: Int? = nil
        var pendingIns = false
        for op in ops {
            switch op {
            case .same(let c):
                if let s = start { out.append(NSRange(location: s, length: pos - s)); start = nil }
                else if pendingIns { out.append(NSRange(location: max(0, pos - 1), length: min(2, text.u16 - max(0, pos - 1)))) }
                pendingIns = false
                pos += String(c).u16
            case .del(let c):
                if start == nil { start = pos }
                pos += String(c).u16
            case .ins:
                if start == nil { pendingIns = true }
            }
        }
        if let s = start { out.append(NSRange(location: s, length: pos - s)) }
        else if pendingIns && pos > 0 { out.append(NSRange(location: pos - 1, length: 1)) }
        return out.filter { $0.length > 0 }
    }

    /// 英文、数字拿不准的，扩到整个词（「128O」整个标黄，不是只标「O」）
    static func expandToWord(_ text: String, _ r: NSRange) -> NSRange {
        let u = Array(text.utf16)
        func alnum(_ i: Int) -> Bool {
            guard i >= 0 && i < u.count else { return false }
            let c = u[i]
            return (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 44 || c == 46
        }
        var a = r.location, b = r.end
        if alnum(a) || alnum(a - 1) { while alnum(a - 1) { a -= 1 } }
        if alnum(b - 1) || alnum(b) { while alnum(b) { b += 1 } }
        return NSRange(location: a, length: b - a)
    }

    /// 重叠、挨着的并起来
    public static func merge(_ rs: [NSRange]) -> [NSRange] {
        let s = rs.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var out: [NSRange] = []
        for r in s {
            if let last = out.last, r.location <= last.end {
                out[out.count - 1] = NSRange(location: last.location, length: max(last.end, r.end) - last.location)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
