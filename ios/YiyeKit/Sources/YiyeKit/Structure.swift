import Foundation

// 认结构：一段字 → 标题、名字＋数字、清单、键值、正文、落款（网页版 index.html 的 parse() 搬过来），
// 再认 Markdown 五招（标题、列表、粗体、引用、居中）和图片行。出图排版用它。

public struct Run: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public init(_ text: String, bold: Bool = false) { self.text = text; self.bold = bold }
}

public struct Num: Equatable, Sendable {
    public var int: String
    public var frac: String
    public var value: Double
}

public struct RowItem: Equatable, Sendable {
    public var marker: String?
    public var label: [Run]
    public var num: Num?
    public var unit: String
    public var total: Bool
}

public struct KVItem: Equatable, Sendable {
    public var key: String
    public var val: [Run]
}

public enum SBlock: Equatable, Sendable {
    case title(String, center: Bool)
    case meta(String)
    case heading([Run], level: Int, center: Bool)
    case sub(String)
    case rows([RowItem])
    case kvs([KVItem], bare: Bool)
    case para([Run], quote: Bool, center: Bool, salute: Bool)
    case image(String)
    case sign([String], dash: Bool)
    case gap
}

public struct SModel: Equatable, Sendable {
    public var blocks: [SBlock]
    public var titleText: String
}

public enum Structure {
    static let UNIT = "(?:[%％‰]|[a-zA-Z]{1,5}|[\\x{4e00}-\\x{9fa5}]{1,2})"
    static let NUM = "[-+]?[¥$￥€£]?[0-9][0-9,，]*(?:[.．][0-9]+)?"
    static let pairRe = Re("^(.*?\\S)(?:\\s*[:：=＝]\\s*|\\s+|(?<=[^0-9\\s.,，:：]))(\(NUM))\\s*(\(UNIT))?$")
    static let kvRe = Re("^([^\\s:：]{1,10})\\s*[:：]\\s*(\\S.*)$")
    static let kvLooseRe = Re("^([^\\s:：]{1,10})\\s*[:：]\\s*(.+)$")
    static let numUnitRe = Re("^\(NUM)\\s*\(UNIT)?$")
    static let numUnitTightRe = Re("^\(NUM)\(UNIT)?$")
    static let listRes: [(Re, ([String?]) -> String)] = [
        (Re("^([0-9]{1,3})\\s*[.、．)）]\\s*(\\S.*)$"), { ($0[1] ?? "") + "." }),
        (Re("^[（(]([0-9]{1,3})[)）]\\s*(\\S.*)$"), { "(\($0[1] ?? ""))" }),
        (Re("^([①-⑳])\\s*(\\S.*)$"), { $0[1] ?? "" }),
        (Re("^([-*•·●○▪■□☐✓√])\\s*(\\S.*)$"), { m in
            let c = m[1] ?? ""
            return "-*·▪■".contains(c) ? "•" : c
        }),
    ]
    static let cnNumRe = Re("^([一二三四五六七八九十]{1,3})[、.．]\\s*(\\S.*)$")
    static let totalRe = Re("^(合计|总计|共计|小计|总数|合共|累计|总共|总产量|总量|total\\b|subtotal\\b|grand total\\b)", [.caseInsensitive])
    static let dateOnlyRe = Re("^\\s*([0-9]{4}\\s*[年./-]\\s*)?[0-9]{1,2}\\s*[月./-]\\s*[0-9]{1,2}\\s*[日号]?\\s*([（(]?(星期|周)[一二三四五六日天][）)]?)?\\s*$")
    static let endPunctRe = Re("[。.！!？?；;，,、…]$")
    static let KNOWN_UNIT = "(?:件|个|只|台|套|箱|包|袋|瓶|桶|张|本|支|条|根|块|片|卷|米|公斤|斤|吨|kg|KG|g|元|人|名|次|天|小时|分钟|h|H|pcs|PCS|%|％)"
    static let clockRe = Re("^[0-9]{1,2}[:：][0-9]{2}$")
    static let tailDigitColonRe = Re("[0-9]\\s*[:：]?$")
    static let colonRe = Re("[:：]")
    static let dateTailRe = Re("[0-9][/\\-.．]$")
    static let labelTrimRe = Re("[\\s:：=＝\\-—…·.]+$")
    static let hasLetterRe = Re("[一-龥A-Za-z]")
    static let bracketTitleRe = Re("^[【\\[《].{1,20}[】\\]》]$")
    static let bracketStartRe = Re("^[【\\[]")
    static let bracketSubRe = Re("^[【\\[].{1,20}[】\\]]$")
    static let splitSepRe = Re("\\s*[，,；;、]\\s*|\\s{2,}")
    static let headColonRe = Re("^(.{1,12}?)\\s*[:：]\\s*(.+)$")
    static let nonDigitWordRe = Re("[^0-9\\s.,]")
    static let blobRe = Re("([^\\s0-9，,；;、:：]{2,16}?)\\s*(\(NUM))\\s*(\(KNOWN_UNIT))(?=\\s|[，,；;、]|$|[^\\s0-9，,；;、])")
    static let timeWordEndRe = Re("[年月日号点时分秒]$")
    static let timeWordStartRe = Re("^[年月日号点时分秒]")
    static let numberedRe = Re("(?:^|\\s)([0-9]{1,2})[.、．]\\s*(?=\\S)")
    static let twoWordRe = Re("^\\S{1,8}\\s+\\S.{0,20}$")
    static let innerSpaceRe = Re("\\s\\S+\\s")
    static let firstWordRe = Re("^(\\S+)\\s+(.+)$")
    static let dashStartRe = Re("^[—-]{1,2}")
    static let dashStripRe = Re("^[—-]{1,2}\\s*")
    static let colonEndRe = Re("[:：]$")
    static let httpRe = Re("^https?$", [.caseInsensitive])
    static let numberSignRe = Re("(?:#|＃|No\\.?|no\\.?|第)\\s*$")
    static let monthTailRe = Re("\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\\.?$", [.caseInsensitive])
    static let sentenceRe = Re("[,，。;；]")
    static let numParseRe = Re("^([-+]?)([¥$€£￥]?)([0-9][0-9,]*)(\\.[0-9]+)?$")

    // 238：称呼词开头（「致谢」不算；「To do」「To buy」是清单名，也不算）
    static let saluteStartRe = Re("^(?:各位|尊敬的|亲爱的|致(?!谢)|(?:dear|hi|hello|to(?![ -]?(?:do|buy)s?\\b))(?![a-z]))", [.caseInsensitive])
    // 238：落款认的日期：2026年11月26日、11月26日、2026-11-26、2026.11.26（斜线一样），后面可以带星期
    static let signDateRe = Re("^\\s*(?:(?:[0-9]{4}\\s*年\\s*)?[0-9]{1,2}\\s*月\\s*[0-9]{1,2}\\s*[日号]|[0-9]{4}\\s*([./-])\\s*[0-9]{1,2}\\s*\\1\\s*[0-9]{1,2})\\s*(?:[（(]?(?:星期|周)[一二三四五六日天][）)]?)?\\s*$")

    // ---------------------------------------------------------------- 小件
    /// 称呼行（238）：冒号结尾、称呼词开头、整行不超过 20 个字
    static func isSalute(_ s: String) -> Bool {
        let t = s.trimmed
        return t.count <= 20 && colonEndRe.test(t) && saluteStartRe.test(t)
    }

    /// 日期上面那行能不能算落款（238）：不超过 15 个字、不带句号；清单、数字行、键值、小标题不算
    static func signName(_ s: String) -> Bool {
        let t = s.trimmed
        if t.isEmpty || t.count > 15 || t.contains("。") || endPunctRe.test(t) || colonEndRe.test(t) { return false }
        return asPair(t) == nil && asList(t) == nil && !kvRe.test(t) && !cnNumRe.test(t) && !bracketSubRe.test(t)
    }

    public static func parseNum(_ raw: String) -> Num? {
        let s = half(raw).replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "．", with: ".")
        guard let m = numParseRe.match(s) else { return nil }
        let sign = m[1] ?? "", cur = m[2] ?? "", int = m[3] ?? "", frac = m[4] ?? ""
        let v = Double((sign + int).replacingOccurrences(of: ",", with: "") + frac) ?? 0
        return Num(int: sign + cur + int, frac: frac, value: v)
    }

    public static func asPair(_ line: String) -> (label: String, num: Num, unit: String, total: Bool)? {
        if dateOnlyRe.test(line) || clockRe.test(line.trimmed) { return nil }
        guard let m = pairRe.match(line), let m1 = m[1], let m2 = m[2] else { return nil }
        let after = line.sub16(NSRange(location: m1.u16, length: min(3, line.u16 - m1.u16)))
        if tailDigitColonRe.test(m1) && colonRe.test(after) { return nil }        // 「8:00」的冒号不是分隔
        if dateTailRe.test(m1) { return nil }                                       // 「11/1」的后半截不是数
        if let kv = kvLooseRe.match(line), let v = kv[2], !numUnitRe.test(v.trimmed) { return nil }   // 「时间：11月8日…」是键值
        if numberSignRe.test(m1) { return nil }                                     // 「#3」「No. 5」「第3」是编号，不是数
        let label = labelTrimRe.re.stringByReplacingMatches(in: m1, options: [], range: NSRange(location: 0, length: m1.u16), withTemplate: "").trimmed
        if label.isEmpty || !hasLetterRe.test(label) || dw(label) > 36 { return nil }
        if monthTailRe.test(label) { return nil }                                   // 「Shift report, Nov 18」是日期
        if sentenceRe.test(label) && dw(label) > 20 { return nil }                  // 带逗号的长句子，末尾碰巧是个数

        guard let n = parseNum(m2) else { return nil }
        return (label, n, (m[3] ?? "").trimmed, totalRe.test(label))
    }

    /// 一行字（带粗细）开头是「1. 」「2、」这样的编号：拆成编号和后面的字。不是：nil
    static func numbered(_ runs: [Run]) -> (marker: String, rest: [Run])? {
        guard let first = runs.first, !first.bold, let p = Markdown5.numberedPrefix(plainOf(runs)),
              first.text.count >= p.prefix.count else { return nil }
        var rest = runs
        rest[0].text = String(first.text.dropFirst(p.prefix.count))
        if rest[0].text.isEmpty { rest.removeFirst() }
        return rest.isEmpty ? nil : (p.number + ".", rest)
    }

    public static func asList(_ line: String) -> (marker: String, body: String)? {
        for (re, mk) in listRes {
            if let m = re.match(line), let body = m[2] { return (mk(m), body) }
        }
        return nil
    }

    static func titleish(_ s: String) -> Bool {
        let t = s.trimmed
        if t.isEmpty || asPair(t) != nil || asList(t) != nil || (kvRe.test(t) && !bracketStartRe.test(t)) { return false }
        if bracketTitleRe.test(t) { return true }
        let noColon = colonEndRe.re.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: t.u16), withTemplate: "")
        return dw(t) <= 30 && !endPunctRe.test(noColon)
    }

    /// 一坨字拆成行：一行里 3 段以上「名字＋数字」，或者夹着 2 个以上「1. 2.」编号
    public static func splitBlob(_ line: String) -> [String] {
        let t = line.trimmed
        if dw(t) < 16 { return [t] }
        var parts = splitParts(t)
        let head = parts.first.flatMap { headColonRe.match($0) }
        let headPair = head.flatMap { h in h[2].flatMap { asPair($0) } } != nil
        if let h = head, headPair, let a = h[1], let b = h[2] { parts = [a, b] + parts.dropFirst() }
        let body = headPair ? Array(parts.dropFirst()) : parts
        if body.count >= 3 && body.allSatisfy({ dw($0) <= 40 }) &&
            body.filter({ asPair($0) != nil }).count >= max(3, Int((Double(body.count) * 0.7).rounded(.up))) {
            return parts
        }
        // 「A线 120 B线 98 C线 143」：没单位，名字和数交替
        let toks = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if toks.count >= 6 && toks.count % 2 == 0 &&
            toks.enumerated().allSatisfy({ i, w in i % 2 == 1 ? numUnitTightRe.test(w) : (nonDigitWordRe.test(w) && dw(w) <= 16) }) {
            return stride(from: 0, to: toks.count, by: 2).map { "\(toks[$0]) \(toks[$0 + 1])" }
        }
        // 没分隔符的一坨：每段带常见单位，名字至少两个字，不能是年月日钟点
        if !colonRe.test(t) {
            let hits = blobRe.all(t).filter { h in
                let name = h.groups[1] ?? ""
                return !timeWordEndRe.test(name) && !timeWordStartRe.test(name)
            }
            if hits.count >= 3 {
                let covered = hits.reduce(0) { acc, h in acc + t.sub16(h.range).filter { !$0.isWhitespace }.u16 }
                let total = t.filter { !$0.isWhitespace && !"，,；;、".contains($0) }.u16
                if Double(covered) >= 0.92 * Double(total) { return hits.map { t.sub16($0.range).trimmed } }
            }
        }
        let nums = numberedRe.all(t)
        if nums.count >= 2, nums[0].range.location == 0 {
            let cuts = nums.map { n -> Int in
                let whole = t.sub16(n.range)
                return n.range.location + (whole.hasPrefix(" ") ? 1 : 0)
            }
            var out: [String] = []
            for (i, c) in cuts.enumerated() {
                let end = i + 1 < cuts.count ? cuts[i + 1] : t.u16
                let piece = t.sub16(NSRange(location: c, length: end - c)).trimmed
                if !piece.isEmpty { out.append(piece) }
            }
            return out
        }
        return [t]
    }

    static func splitParts(_ t: String) -> [String] {
        var out: [String] = []
        var last = 0
        for hit in splitSepRe.all(t) {
            out.append(t.sub16(NSRange(location: last, length: hit.range.location - last)))
            last = hit.range.end
        }
        out.append(t.sub16(NSRange(location: last, length: t.u16 - last)))
        return out.filter { !$0.isEmpty }
    }

    // ---------------------------------------------------------------- 行
    struct Line {
        var s: String
        var id: String
        var md: MDLine?        // 有五招标记（或图片、粗体）的行
        var used = false
    }

    static func runs(of l: MDLine) -> [Run] {
        let text = l.text
        let base = l.range.location
        var out: [Run] = []
        var cur = l.content.location
        for b in l.bold {
            let plainR = NSRange(location: cur - base, length: (b.location - 2) - cur)
            if plainR.length > 0 { out.append(Run(text.sub16(plainR))) }
            out.append(Run(text.sub16(NSRange(location: b.location - base, length: b.length)), bold: true))
            cur = b.end + 2
        }
        let tail = NSRange(location: cur - base, length: l.content.end - cur)
        if tail.length > 0 { out.append(Run(text.sub16(tail))) }
        return out
    }

    static func plainOf(_ runs: [Run]) -> String { runs.map(\.text).joined() }

    static func toLines(_ text: String) -> [Line] {
        var out: [Line] = []
        let cleaned = halfAlnum(text).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "  ")
        for (i, raw) in cleaned.components(separatedBy: "\n").enumerated() {
            var s = raw
            while let last = s.last, last.isWhitespace { s.removeLast() }
            if s.trimmed.isEmpty { out.append(Line(s: "", id: "\(i)")); continue }
            let md = Markdown5.parseLine(s, at: 0)
            let styled: Bool = {
                if md.centered || !md.bold.isEmpty { return true }
                switch md.block { case .plain, .blank: return false; default: return true }
            }()
            if styled { out.append(Line(s: s.trimmed, id: "\(i)", md: md)); continue }
            let parts = splitBlob(s)
            for (j, p) in parts.enumerated() {
                out.append(Line(s: p.trimmed, id: parts.count > 1 ? "\(i).\(j)" : "\(i)"))
            }
        }
        return out
    }

    enum Kind {
        case gap
        case row(RowItem)
        case kv(KVItem)
        case block(SBlock)
    }

    // ---------------------------------------------------------------- 主函数
    public static func parse(_ text: String) -> SModel {
        var lines = toLines(text)
        let live = lines.indices.filter { !lines[$0].s.isEmpty }
        if live.isEmpty { return SModel(blocks: [], titleText: "") }

        var blocks: [SBlock] = []
        var tIdx = -1
        var meta = ""
        var titleCenter = false
        let first = lines[live[0]]
        if let md = first.md {
            if case .heading = md.block { tIdx = live[0]; titleCenter = md.centered }
            else if md.block == .plain && md.centered && md.bold.isEmpty && live.count > 1 && dw(plainOf(runs(of: md))) <= 30 { tIdx = live[0]; titleCenter = true }
        } else {
            let second = live.count > 1 ? lines[live[1]] : nil
            if dateOnlyRe.test(first.s), let sec = second, sec.md == nil, titleish(sec.s), !isSalute(sec.s), live.count > 2 {
                tIdx = live[1]; meta = first.s
            } else if titleish(first.s) && !isSalute(first.s) && live.count > 1 {      // 称呼不是标题（238）
                tIdx = live[0]
            }
        }
        var titleText = ""
        if tIdx >= 0 {
            if let md = lines[tIdx].md { titleText = plainOf(runs(of: md)).trimmed }
            else {
                var t = lines[tIdx].s
                t = colonEndRe.re.stringByReplacingMatches(in: t, options: [], range: NSRange(location: 0, length: t.u16), withTemplate: "")
                if let m = Re("^[【\\[](.*)[】\\]]$").match(t), let inner = m[1] { t = inner }
                titleText = t.trimmed
            }
            blocks.append(.title(titleText, center: titleCenter))
            // 标题下面紧跟一行日期：当副标题
            if meta.isEmpty, let after = lines.indices.first(where: { $0 > tIdx && !lines[$0].s.isEmpty }),
               lines[after].md == nil, dateOnlyRe.test(lines[after].s) {
                meta = lines[after].s; lines[after].used = true
            }
            if !meta.isEmpty {
                for i in lines.indices where lines[i].s == meta && i != tIdx { lines[i].used = true; break }
                blocks.append(.meta(meta))
            }
        }
        var body = lines.indices.filter { $0 != tIdx && !lines[$0].used }.map { lines[$0] }
        while let f = body.first, f.s.isEmpty { body.removeFirst() }
        while let l = body.last, l.s.isEmpty { body.removeLast() }

        // 落款，两种认法：
        // 1. 全文最后一行是日期：它靠右；紧挨着的上一行是短名字（signName）就一起靠右（238）。不看正文长短
        // 2. 最后一行不是上面那种日期：最后一两行短字，前面空一行、或者以「——」开头、或者最后是「11/26」这样的日期；上面得有长正文
        let hasPara = body.contains { $0.md == nil && !$0.s.isEmpty && asPair($0.s) == nil && asList($0.s) == nil && !kvRe.test($0.s) && dw($0.s) > 30 }
        var sign: [Line] = []
        if let last = body.last, last.md == nil, signDateRe.test(last.s), tIdx >= 0 || body.count > 1 {
            sign = [last]
            body.removeLast()
            if let name = body.last, name.md == nil, signName(name.s) {
                sign.insert(name, at: 0)
                body.removeLast()
            }
        } else if hasPara {
            var k = body.count - 1
            var cand: [Line] = []
            while k >= 0 && cand.count < 2 {
                let l = body[k]
                if l.md != nil || l.s.isEmpty || dw(l.s) > 28 || asPair(l.s) != nil || asList(l.s) != nil || endPunctRe.test(l.s) { break }
                cand.insert(l, at: 0); k -= 1
            }
            let before: Line? = k >= 0 ? body[k] : nil
            if let end = cand.last, (before.map { $0.s.isEmpty } ?? false) || dashStartRe.test(cand[0].s) || dateOnlyRe.test(end.s) {
                sign = cand
                body.removeLast(cand.count)
            }
        }

        func kindOf(_ l: Line) -> Kind {
            if let md = l.md {
                let r = runs(of: md)
                switch md.block {
                case .heading(let n): return .block(.heading(r, level: n, center: md.centered))
                case .bullet:
                    let content = plainOf(r)
                    if md.bold.isEmpty, let p = asPair(content) {
                        return .row(RowItem(marker: "•", label: [Run(p.label)], num: p.num, unit: p.unit, total: p.total))
                    }
                    return .row(RowItem(marker: "•", label: r, num: nil, unit: "", total: false))
                case .quote: return .block(.para(r, quote: true, center: md.centered, salute: false))
                case .image(let p): return .block(.image(p))
                default:
                    // 228：编号步骤带粗体（大管家 227 起会写「3. 换上 **T12** …」）也按清单排：编号挂左边，折行跟第一行的字对齐
                    if md.block == .plain && !md.centered, let n = numbered(r) {
                        return .row(RowItem(marker: n.marker, label: n.rest, num: nil, unit: "", total: false))
                    }
                    return .block(.para(r, quote: false, center: md.centered, salute: false))
                }
            }
            if l.s.isEmpty { return .gap }
            if let li = asList(l.s) {
                if let p = asPair(li.body) { return .row(RowItem(marker: li.marker, label: [Run(p.label)], num: p.num, unit: p.unit, total: p.total)) }
                return .row(RowItem(marker: li.marker, label: [Run(li.body)], num: nil, unit: "", total: false))
            }
            if let cn = cnNumRe.match(l.s), let n = cn[1], let b = cn[2] {
                if dw(b) <= 24 && !endPunctRe.test(b) { return .block(.sub("\(n)、\(b)")) }
                return .row(RowItem(marker: "\(n)、", label: [Run(b)], num: nil, unit: "", total: false))
            }
            if let p = asPair(l.s) { return .row(RowItem(marker: nil, label: [Run(p.label)], num: p.num, unit: p.unit, total: p.total)) }
            if let kv = kvRe.match(l.s), let k = kv[1], let v = kv[2], dw(k) <= 12, dw(v) <= 48, !httpRe.test(k) {
                return .kv(KVItem(key: k, val: [Run(v)]))
            }
            if colonEndRe.test(l.s) && dw(l.s) <= 26 {
                let s = colonEndRe.re.stringByReplacingMatches(in: l.s, options: [], range: NSRange(location: 0, length: l.s.u16), withTemplate: "")
                return .block(.sub(s + "\u{0}" + l.s))     // 带着原样（称呼要用），\0 隔开
            }
            if bracketSubRe.test(l.s) { return .block(.sub(String(l.s.dropFirst().dropLast()))) }
            return .block(.para([Run(l.s)], quote: false, center: false, salute: false))
        }

        // 逐行认类型，相邻同类并成一块
        var plainParaFlags: [Bool] = []   // 跟 blocks 对齐：这一块是不是没标记的普通正文行（认「两列对齐」用）
        plainParaFlags = Array(repeating: false, count: blocks.count)
        var curRows: [RowItem]? = nil, curKVs: [KVItem]? = nil
        func flush() {
            if let r = curRows { blocks.append(.rows(r)); plainParaFlags.append(false) }
            if let k = curKVs { blocks.append(.kvs(k, bare: false)); plainParaFlags.append(false) }
            curRows = nil; curKVs = nil
        }
        for l in body {
            switch kindOf(l) {
            case .gap:
                flush()
                if let last = blocks.last, last != .gap { blocks.append(.gap); plainParaFlags.append(false) }
            case .row(let r):
                if curKVs != nil { flush() }
                if curRows == nil { curRows = [] }
                curRows!.append(r)
            case .kv(let k):
                if curRows != nil { flush() }
                if curKVs == nil { curKVs = [] }
                curKVs!.append(k)
            case .block(let b):
                flush()
                blocks.append(b)
                plainParaFlags.append(l.md == nil && { if case .para = b { return true }; return false }())
            }
        }
        flush()

        // 「周一 张师傅 / 周二 李师傅 / 周三 王师傅」：连着 3 行以上「短词 空格 短词」，两列对齐
        var i = 0
        while i < blocks.count {
            var j = i
            func two(_ k: Int) -> Bool {
                guard k < blocks.count, plainParaFlags[k], case .para(let r, _, _, _) = blocks[k] else { return false }
                let s = plainOf(r)
                guard twoWordRe.test(s) else { return false }
                let rest = Re("^\\S+\\s+").re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: s.u16), withTemplate: " ")
                return !innerSpaceRe.test(rest)
            }
            while two(j) { j += 1 }
            if j - i >= 3 {
                let items: [KVItem] = blocks[i..<j].compactMap { b in
                    guard case .para(let r, _, _, _) = b, let m = firstWordRe.match(plainOf(r)), let k = m[1], let v = m[2] else { return nil }
                    return KVItem(key: k, val: [Run(v)])
                }
                blocks.replaceSubrange(i..<j, with: [.kvs(items, bare: true)])
                plainParaFlags.replaceSubrange(i..<j, with: [false])
            }
            i += 1
        }

        // 称呼：只认正文第一行。「各位同事：」这类（isSalute，238）后面空不空行都当正文排；
        // 别的冒号行（「各车间：」）下面紧接着正文，也当正文排
        if let fb = blocks.firstIndex(where: { b in
            switch b { case .title, .meta, .gap: return false; default: return true }
        }), case .sub(let packed) = blocks[fb], packed.contains("\u{0}") {
            let raw = String(packed.split(separator: "\u{0}", omittingEmptySubsequences: false).last ?? "")
            let followed: Bool = { if fb + 1 < blocks.count, case .para = blocks[fb + 1] { return true }; return false }()
            if followed || isSalute(raw) { blocks[fb] = .para([Run(raw)], quote: false, center: false, salute: true) }
        }
        // sub 里带的原样去掉
        blocks = blocks.map { b in
            if case .sub(let packed) = b, packed.contains("\u{0}") {
                return .sub(String(packed.split(separator: "\u{0}", omittingEmptySubsequences: false).first ?? ""))
            }
            return b
        }
        if !sign.isEmpty {
            let dash = dashStartRe.test(sign[0].s)
            let ls = sign.map { s in dashStripRe.re.stringByReplacingMatches(in: s.s, options: [], range: NSRange(location: 0, length: s.s.u16), withTemplate: "") }
            blocks.append(.sign(ls, dash: dash))
        }
        return SModel(blocks: blocks, titleText: titleText)
    }
}
