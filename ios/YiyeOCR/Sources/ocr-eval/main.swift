import Foundation
import CoreGraphics
import ImageIO
import YiyeKit
import YiyeOCR

// 用法：ocr-eval <样张目录> <输出目录>
// 样张目录里每张 xxx.jpg 配一个 xxx.txt（标准答案）。出 report.md、report.json，和每张认出来的草稿 xxx.md。
// 认对几成 = 1 − 编辑距离 / 标准答案字数（去掉 Markdown 标记、空白，全角字母数字换半角）。
// 标黄的里面真错的占几成 = 标黄的那几段里，至少有一个字跟标准答案对不上的段数 / 标黄段数。

let args = CommandLine.arguments
guard args.count >= 3 else { print("用法：ocr-eval <样张目录> <输出目录>"); exit(2) }
let inDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 标准答案里行首的勾选框（□ ☐）是记号不是字，跟草稿里的「- 」一样不算
func stripBox(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    if let f = t.first, "□☐".contains(f) { t.removeFirst() }
    return t
}

func norm(_ s: String, truth: Bool = false) -> [Character] {
    var out: [Character] = []
    for line in s.components(separatedBy: "\n") {
        guard var p = Markdown5.plain(line) else { continue }
        if truth { p = stripBox(p) }
        for c in halfAlnum(p) where !c.isWhitespace { out.append(c) }
    }
    return out
}

func editDistance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

/// 草稿每一行正文的每个字对不对：跟标准答案里最像的那行逐字比
func correctness(draft: String, truth: String) -> [Int: [Bool]] {
    let truthLines = truth.components(separatedBy: "\n").compactMap { Markdown5.plain($0).map(stripBox)?.trimmed }.filter { !$0.isEmpty }
    var out: [Int: [Bool]] = [:]
    for (i, span) in lineSpans(draft).enumerated() {
        let l = Markdown5.parseLine(span.text, at: 0)
        let content = span.text.sub16(l.content)
        if content.trimmed.isEmpty { continue }
        let c = Array(halfAlnum(content))
        let best = truthLines.min { editDistance(c, Array(halfAlnum($0))) < editDistance(c, Array(halfAlnum($1))) } ?? ""
        var ok: [Bool] = []
        for op in TextDiff.ops(String(c), best) {
            switch op {
            case .same(let ch): ok.append(contentsOf: Array(repeating: true, count: String(ch).u16))
            case .del(let ch): ok.append(contentsOf: Array(repeating: ch.isWhitespace, count: String(ch).u16))
            case .ins(let ch): if !ch.isWhitespace, !ok.isEmpty { ok[ok.count - 1] = false }
            }
        }
        out[i] = ok
    }
    return out
}

struct Row: Codable {
    var name: String
    var kind: String
    var accuracy: Double
    var truthChars: Int
    var editDistance: Int
    var yellow: Int
    var yellowWrong: Int
    var wrongChars: Int
    var wrongCharsYellow: Int
    var seconds: Double
    var error: String?
}

var rows: [Row] = []
let files = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

let langs = VisionOCR.languages()
print("支持的语言：\(langs.supported.joined(separator: ", "))")
print("这次用：\(langs.use.map { $0.maximalIdentifier }.joined(separator: ", "))")

for f in files {
    let name = f.deletingPathExtension().lastPathComponent
    let truthURL = f.deletingPathExtension().appendingPathExtension("txt")
    guard let truth = try? String(contentsOf: truthURL, encoding: .utf8) else { continue }
    let kind = name.hasPrefix("h") ? "手写" : "印刷"
    guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        rows.append(Row(name: name, kind: kind, accuracy: 0, truthChars: 0, editDistance: 0, yellow: 0, yellowWrong: 0, wrongChars: 0, wrongCharsYellow: 0, seconds: 0, error: "读不了图"))
        continue
    }
    let t0 = Date()
    do {
        let r = try await PhotoToDraft.run(img)
        let secs = Date().timeIntervalSince(t0)
        let draft = r.draft
        try? (draft.markdown + "\n").write(to: outDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        let a = norm(draft.markdown), b = norm(truth, truth: true)
        // 每行认出来的字、信心、候选（第二遍的排第一），给人看哪里拿不准
        var dump = ""
        for blk in r.page.blocks {
            for l in blk.lines {
                dump += "\(l.text)\t信心 \(String(format: "%.2f", l.confidence))\t候选 \(l.alternatives.joined(separator: " | "))\t词 \(l.note)\n"
            }
        }
        try? dump.write(to: outDir.appendingPathComponent("\(name).lines.txt"), atomically: true, encoding: .utf8)
        let ed = editDistance(a, b)
        let acc = b.isEmpty ? 0 : max(0, 1 - Double(ed) / Double(b.count))
        // 标黄准不准
        let ok = correctness(draft: draft.markdown, truth: truth)
        let spans = lineSpans(draft.markdown)
        var yWrong = 0
        var yellowChars = Set<String>()
        for u in draft.unsure {
            guard let li = spans.firstIndex(where: { u.location >= $0.range.location && u.location < $0.range.end }) else { continue }
            let l = Markdown5.parseLine(spans[li].text, at: spans[li].range.location)
            let flags = ok[li] ?? []
            var wrong = false
            for p in u.location..<u.end {
                let k = p - l.content.location
                yellowChars.insert("\(li):\(k)")
                if k >= 0 && k < flags.count && !flags[k] { wrong = true }
            }
            if wrong { yWrong += 1 }
        }
        var wrongChars = 0, wrongYellow = 0
        for (li, flags) in ok {
            for (k, good) in flags.enumerated() where !good {
                wrongChars += 1
                if yellowChars.contains("\(li):\(k)") { wrongYellow += 1 }
            }
        }
        rows.append(Row(name: name, kind: kind, accuracy: acc, truthChars: b.count, editDistance: ed, yellow: draft.unsure.count, yellowWrong: yWrong,
                        wrongChars: wrongChars, wrongCharsYellow: wrongYellow, seconds: secs, error: nil))
        print("\(name) \(kind) 认对 \(String(format: "%.1f", acc * 100))% 标黄 \(draft.unsure.count) 其中真错 \(yWrong)  \(String(format: "%.1f", secs))s")
    } catch {
        rows.append(Row(name: name, kind: kind, accuracy: 0, truthChars: 0, editDistance: 0, yellow: 0, yellowWrong: 0, wrongChars: 0, wrongCharsYellow: 0, seconds: 0, error: "\(error)"))
        print("\(name) 出错：\(error)")
    }
}

func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
func sum(_ k: String, _ rs: [Row]) -> (acc: Double, yellow: Int, yWrong: Int, wrong: Int, wrongY: Int) {
    let chars = rs.reduce(0) { $0 + $1.truthChars }, ed = rs.reduce(0) { $0 + $1.editDistance }
    return (chars == 0 ? 0 : max(0, 1 - Double(ed) / Double(chars)), rs.reduce(0) { $0 + $1.yellow }, rs.reduce(0) { $0 + $1.yellowWrong },
            rs.reduce(0) { $0 + $1.wrongChars }, rs.reduce(0) { $0 + $1.wrongCharsYellow })
}

var md = "# 拍照认字：10 张样张（CI 上 macOS 26 的 Vision 跑，跟 iPhone 上同一套 RecognizeDocumentsRequest）\n\n"
md += "语言：\(langs.use.map { $0.maximalIdentifier }.joined(separator: "、"))（它报的支持语言共 \(langs.supported.count) 个）\n\n"
md += "| 图 | 类型 | 本机认对 | 标黄段 | 标黄里真错 | 错字被标黄 | 用时 |\n|---|---|---|---|---|---|---|\n"
for r in rows {
    if let e = r.error { md += "| \(r.name) | \(r.kind) | 出错：\(e) | | | | |\n"; continue }
    let yp = r.yellow == 0 ? "—" : "\(r.yellowWrong)/\(r.yellow)（\(pct(Double(r.yellowWrong) / Double(r.yellow)))）"
    let wy = r.wrongChars == 0 ? "—" : "\(r.wrongCharsYellow)/\(r.wrongChars)"
    md += "| \(r.name) | \(r.kind) | \(pct(r.accuracy)) | \(r.yellow) | \(yp) | \(wy) | \(String(format: "%.1f", r.seconds))s |\n"
}
for k in ["印刷", "手写"] {
    let s = sum(k, rows.filter { $0.kind == k && $0.error == nil })
    md += "| **\(k)合计** | | **\(pct(s.acc))** | \(s.yellow) | \(s.yellow == 0 ? "—" : "\(s.yWrong)/\(s.yellow)（\(pct(Double(s.yWrong) / Double(s.yellow)))）") | \(s.wrong == 0 ? "—" : "\(s.wrongY)/\(s.wrong)") | |\n"
}
md += "\n认对 = 1 − 编辑距离 / 标准答案字数（不算空白和 Markdown 标记）。标黄里真错 = 标黄的段里至少一个字跟标准答案对不上。错字被标黄 = 认错的字里有几个落在黄底里。\n"
try? md.write(to: outDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try? enc.encode(rows).write(to: outDir.appendingPathComponent("report.json"))
print(md)
