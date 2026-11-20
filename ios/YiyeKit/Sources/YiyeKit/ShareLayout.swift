import Foundation

// 出图排版：块 → 绘制指令（网页版 index.html 的 layout() 搬过来，只留「便签」「白纸」两个版式），
// 再加 Markdown 五招（分级标题、引用、居中、粗体）和图片。
// 量字宽靠 TextMeasurer：手机上用 CoreText 量，测试里用假的。

public struct RGBA: Equatable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: String, alpha: Double = 1) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, alpha)
    }
}

public struct FontSpec: Equatable, Hashable, Sendable {
    public var size: Double
    public var weight: Int        // 400 / 500 / 600 / 700 / 800
    public var latinFirst: Bool   // 英文落款：西文字体在前
    public init(_ size: Double, _ weight: Int = 400, latinFirst: Bool = false) { self.size = size; self.weight = weight; self.latinFirst = latinFirst }
}

public protocol TextMeasurer {
    func width(_ s: String, _ f: FontSpec) -> Double
}

public enum TextAlign: Equatable, Sendable { case left, center, right }

public enum DrawOp: Equatable, Sendable {
    case text(String, x: Double, y: Double, font: FontSpec, color: RGBA, align: TextAlign, tracking: Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double, color: RGBA, width: Double)
    case rect(x: Double, y: Double, w: Double, h: Double, fill: RGBA?, stroke: RGBA?, radius: Double)
    case dot(x: Double, y: Double, r: Double, color: RGBA)
    case image(String, x: Double, y: Double, w: Double, h: Double)
}

public enum FooterKind: Sendable { case note, plain }

public struct ShareTheme: Sendable, Equatable {
    public static func == (a: ShareTheme, b: ShareTheme) -> Bool { a.id == b.id }
    public var id: String
    public var bg: RGBA
    public var noiseAlpha: Double
    public var noiseSeed: Int
    public var pad: (t: Double, r: Double, b: Double, l: Double)
    public var ink, body, muted, accent, rule: RGBA
    public var titleSize: Double, titleWeight: Int, titleLh: Double, titleGap: Double
    public var metaSize: Double
    public var size: Double, lh: Double, rowLh: Double
    public var subSize: Double, subWeight: Int, subColor: RGBA, subRule: Bool
    public var markerColor: RGBA, markerDot: Bool
    public var quoteColor: RGBA, quoteBar: RGBA
    public var footer: FooterKind

    /// 便签（默认）：暖白纸、细噪点、橙红点缀
    public static let note = ShareTheme(
        id: "note", bg: RGBA(hex: "#F6F2EA"), noiseAlpha: 0.05, noiseSeed: 11, pad: (34, 30, 26, 30),
        ink: RGBA(hex: "#2B2926"), body: RGBA(hex: "#3D3A35"), muted: RGBA(hex: "#9A938A"), accent: RGBA(hex: "#C2410C"), rule: RGBA(hex: "#E3DCD0"),
        titleSize: 23, titleWeight: 700, titleLh: 1.32, titleGap: 10, metaSize: 12.5,
        size: 16, lh: 1.72, rowLh: 1.95,
        subSize: 13, subWeight: 600, subColor: RGBA(hex: "#C2410C"), subRule: true,
        markerColor: RGBA(hex: "#C2410C"), markerDot: false,
        quoteColor: RGBA(hex: "#8A8276"), quoteBar: RGBA(hex: "#DCCFBC"), footer: .note)

    /// 白纸：纯白、苹果灰、黄点
    public static let white = ShareTheme(
        id: "white", bg: RGBA(hex: "#FFFFFF"), noiseAlpha: 0, noiseSeed: 0, pad: (36, 28, 26, 28),
        ink: RGBA(hex: "#1D1D1F"), body: RGBA(hex: "#424245"), muted: RGBA(hex: "#8E8E93"), accent: RGBA(hex: "#E0A100"), rule: RGBA(hex: "#E5E5EA"),
        titleSize: 28, titleWeight: 800, titleLh: 1.22, titleGap: 8, metaSize: 13,
        size: 16.5, lh: 1.62, rowLh: 1.9,
        subSize: 15, subWeight: 700, subColor: RGBA(hex: "#1D1D1F"), subRule: false,
        markerColor: RGBA(hex: "#E0A100"), markerDot: true,
        quoteColor: RGBA(hex: "#6E6E73"), quoteBar: RGBA(hex: "#E0A100", alpha: 0.55), footer: .plain)

    public static let all: [ShareTheme] = [.note, .white]
    public static func byID(_ id: String) -> ShareTheme { all.first { $0.id == id } ?? .note }
}

public struct ShareLayoutResult: Sendable {
    public var ops: [DrawOp]
    public var height: Double
    public var width: Double
}

/// 一段字里的一截：字、是不是粗体
struct Seg { var text: String; var bold: Bool }

public struct ShareLayout {
    public static let width: Double = 390     // 逻辑宽，出图按 3 倍画
    static let noStart = Set("，。、；：！？）」』”’》】…,.;:!?)]}%％‰·")
    static let noEnd = Set("（「『“‘《【([{¥$￥")

    let t: ShareTheme
    let m: TextMeasurer
    let latin: Bool

    /// mark：落款（中文「一叶笺」，英文「Yiye」）；imageSize：图片路径 → 原始宽高（拿不到就不画那张）
    public static func layout(_ model: SModel, theme: ShareTheme, measurer: TextMeasurer, mark: String, latinMark: Bool = false,
                              imageSize: (String) -> (w: Double, h: Double)? = { _ in nil }) -> ShareLayoutResult {
        ShareLayout(t: theme, m: measurer, latin: latinMark).run(model, mark: mark, imageSize: imageSize)
    }

    func font(_ size: Double, _ weight: Int = 400) -> FontSpec { FontSpec(size, weight) }
    func mw(_ s: String, _ f: FontSpec) -> Double { s.isEmpty ? 0 : m.width(s, f) }

    func run(_ model: SModel, mark: String, imageSize: (String) -> (w: Double, h: Double)?) -> ShareLayoutResult {
        var ops: [DrawOp] = []
        let W = ShareLayout.width
        let x0 = t.pad.l, x1 = W - t.pad.r, cw = x1 - x0
        let size = t.size
        let bodyFont = font(size), boldFont = font(size, 700)
        let bodyLh = size * t.lh, rowLh = size * t.rowLh
        var y = t.pad.t
        func text(_ s: String, _ x: Double, _ yb: Double, _ f: FontSpec, _ c: RGBA, _ a: TextAlign = .left, _ tr: Double = 0) {
            ops.append(.text(s, x: x, y: yb, font: f, color: c, align: a, tracking: tr))
        }
        func line(_ xa: Double, _ ya: Double, _ xb: Double, _ yb: Double, _ c: RGBA, _ w: Double = 1) {
            ops.append(.line(x1: xa, y1: ya, x2: xb, y2: yb, color: c, width: w))
        }
        /// 一行若干截（粗细混排）：从 x 起画；align=center 时整行居中
        func segs(_ ss: [Seg], _ x: Double, _ yb: Double, _ c: RGBA, boldColor: RGBA, center: Bool = false, base: FontSpec? = nil) {
            let bf = base ?? bodyFont
            let bb = FontSpec(bf.size, max(bf.weight, 700))
            let total = ss.reduce(0) { $0 + mw($1.text, $1.bold ? bb : bf) }
            var cx = center ? (W - total) / 2 : x
            for s in ss {
                let f = s.bold ? bb : bf
                text(s.text, cx, yb, f, s.bold ? boldColor : c)
                cx += mw(s.text, f)
            }
        }

        // 标题下面写了一行日期才印副标题（版式自己不印日期）：便签、白纸放在标题上面
        var metaText: String? = nil
        for b in model.blocks { if case .meta(let s) = b { metaText = s } }
        if let s = metaText {
            text(s, x0, y + t.metaSize, font(t.metaSize, 500), t.muted)
            y += t.metaSize + 14
        }

        for b in model.blocks {
            switch b {
            case .meta:
                continue
            case .gap:
                y += size * 0.7
            case .title(let s, let center):
                let f = font(t.titleSize, t.titleWeight)
                let ls = wrapBalance(s, f, cw)
                let lh = t.titleSize * t.titleLh
                for (i, l) in ls.enumerated() {
                    let yb = y + lh * Double(i) + t.titleSize * 0.92 + (lh - t.titleSize) / 2
                    text(l, center ? W / 2 : x0, yb, f, t.ink, center ? .center : .left)
                }
                y += Double(ls.count) * lh
                y += t.titleGap + 6
            case .heading(let runs, let level, let center):
                let hs: Double, hw: Int, color: RGBA
                switch level {
                case 1: hs = (t.titleSize + size) / 2 + 1; hw = 700; color = t.ink
                case 2: hs = max(t.subSize, size * 0.95); hw = max(t.subWeight, 600); color = t.subColor
                default: hs = size; hw = 700; color = t.ink
                }
                y += level == 1 ? 8 : 6
                let f = font(hs, hw)
                let flat = runs.map { Run($0.text, bold: false) }
                let ls = wrapRuns(flat, f, f, cw)
                let lh = hs * 1.4
                for (i, l) in ls.enumerated() {
                    segs(l, x0, y + lh * Double(i) + hs * 0.92 + (lh - hs) / 2, color, boldColor: color, center: center, base: f)
                }
                y += Double(ls.count) * lh
                if level == 2 && t.subRule { y += 4; line(x0, y, x1, y, t.rule, 0.8) }
                y += level == 1 ? 8 : 6
            case .sub(let s):
                let f = font(t.subSize, t.subWeight)
                y += 6
                let ls = wrap(s, f, cw)
                for (i, l) in ls.enumerated() { text(l, x0, y + t.subSize * Double(i + 1) * 1.35 - t.subSize * 0.25, f, t.subColor) }
                y += Double(ls.count) * t.subSize * 1.35
                if t.subRule { y += 6; line(x0, y, x1, y, t.rule, 0.8) }
                y += 10
            case .para(let runs, let quote, let center, _):
                let inset: Double = quote ? 16 : 0
                let ls = wrapRuns(runs, bodyFont, boldFont, cw - inset, orphanFix: true)
                let y0 = y
                for (i, l) in ls.enumerated() {
                    let yb = y + bodyLh * Double(i) + size * 0.92 + (bodyLh - size) / 2
                    segs(l, x0 + inset, yb, quote ? t.quoteColor : t.body, boldColor: quote ? t.quoteColor : t.ink, center: center)
                }
                y += Double(ls.count) * bodyLh
                if quote {
                    ops.append(.rect(x: x0 + 1, y: y0 + bodyLh * 0.22, w: 3, h: max(2, y - y0 - bodyLh * 0.44), fill: t.quoteBar, stroke: nil, radius: 1.5))
                }
                y += 4
            case .kvs(let items, let bare):
                let kFont = font(size, 600)
                let kw = items.map { mw($0.key + (bare ? "" : "："), kFont) + (bare ? 14 : 0) }.max() ?? 0
                let vx = x0 + min(kw + 6, cw * 0.45)
                for it in items {
                    let ls = wrapRuns(it.val, bodyFont, boldFont, x1 - vx, orphanFix: true)
                    text(it.key + (bare ? "" : "："), x0, y + size * 0.92 + (rowLh - size) / 2, kFont, t.muted)
                    for (i, l) in ls.enumerated() {
                        segs(l, vx, y + (i == 0 ? 0 : bodyLh * Double(i)) + size * 0.92 + (rowLh - size) / 2, t.body, boldColor: t.ink)
                    }
                    y += rowLh + Double(max(0, ls.count - 1)) * bodyLh
                }
                y += 4
            case .rows(let items):
                let numFont = font(size, 600)
                let mkFont = font(size * (t.markerDot ? 1 : 0.94), 600)
                let mkW = items.compactMap { $0.marker }.map { mw($0, mkFont) }.max() ?? 0
                let mkGap: Double = mkW > 0 ? 9 : 0
                let nums = items.compactMap { $0.num }
                let intW = nums.map { mw($0.int, numFont) }.max() ?? 0
                let fracW = nums.map { mw($0.frac, numFont) }.max() ?? 0
                let unitFont = font(size * 0.86)
                let unitW = items.filter { $0.num != nil }.map { $0.unit.isEmpty ? 0 : mw($0.unit, unitFont) }.max() ?? 0
                let numColW = nums.isEmpty ? 0 : intW + fracW + (unitW > 0 ? 3 + unitW : 0)
                let labX = x0 + mkW + mkGap
                let valX = x1 - numColW
                let anchor = valX + intW
                for it in items {
                    let avail = (it.num != nil ? valX - 16 : x1) - labX
                    let lf = it.total ? boldFont : bodyFont
                    let lab = wrapRuns(it.label, lf, boldFont, avail, orphanFix: true)
                    let hRow = rowLh + Double(max(0, lab.count - 1)) * bodyLh
                    let yb = y + size * 0.92 + (rowLh - size) / 2
                    if it.total { line(x0, y + 1, x1, y + 1, t.rule, 0.8) }
                    if let mk = it.marker {
                        if t.markerDot && (mk == "•" || mk == "·") {
                            ops.append(.dot(x: x0 + mkW / 2, y: yb - size * 0.33, r: 3, color: t.markerColor))
                        } else {
                            text(mk, x0 + mkW, yb, mkFont, t.markerColor, .right)
                        }
                    }
                    for (i, l) in lab.enumerated() {
                        segs(l, labX, yb + Double(i) * bodyLh, it.total ? t.ink : t.body, boldColor: t.ink, base: lf)
                    }
                    if let n = it.num {
                        let ny = yb + Double(max(0, lab.count - 1)) * bodyLh
                        text(n.int, anchor, ny, numFont, t.ink, .right)
                        if !n.frac.isEmpty { text(n.frac, anchor, ny, numFont, t.ink, .left) }
                        if !it.unit.isEmpty { text(it.unit, anchor + fracW + 3, ny, unitFont, t.muted, .left) }
                    }
                    y += hRow
                }
                y += 4
            case .image(let path):
                guard let sz = imageSize(path), sz.w > 0, sz.h > 0 else { continue }
                y += 6
                let w = cw, h = (cw * sz.h / sz.w).rounded()
                ops.append(.image(path, x: x0, y: y, w: w, h: h))
                ops.append(.rect(x: x0, y: y, w: w, h: h, fill: nil, stroke: t.rule, radius: 0))
                y += h + 12
            case .sign(let lines, let dash):
                y += 12
                for (i, l) in lines.enumerated() {
                    text((dash && i == 0 ? "—— " : "") + l, x1, y + bodyLh * Double(i) + size * 0.92 + (bodyLh - size) / 2, bodyFont, t.body, .right)
                }
                y += Double(lines.count) * bodyLh
            }
        }
        // 页脚落款
        let fs = 11.0
        let mf = FontSpec(fs, t.footer == .note ? 500 : 600, latinFirst: latin)
        y += 18
        switch t.footer {
        case .note:
            line(x0, y, x1, y, t.rule, 0.8); y += 14
            text(mark, x1, y + fs, mf, t.muted, .right, 1)
            y += fs
        case .plain:
            text(mark, x1, y + fs, mf, t.muted, .right, 1)
            y += fs
        }
        return ShareLayoutResult(ops: ops, height: (y + t.pad.b).rounded(.up), width: W)
    }

    // ---------------------------------------------------------------- 折行
    /// 切词：英文数字整词，空白一段，别的一个字一个字
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        enum K { case word, space, other }
        var k = K.other
        let wordCont = Set(".,:%'’-_/@#&+")
        for ch in s {
            if !cur.isEmpty {
                if k == .word && (ch.isAsciiAlnum || wordCont.contains(ch)) { cur.append(ch); continue }
                if k == .space && ch.isWhitespace { cur.append(ch); continue }
                out.append(cur); cur = ""
            }
            cur.append(ch)
            k = ch.isAsciiAlnum ? .word : (ch.isWhitespace ? .space : .other)
            if k == .other { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 按宽度折行：汉字一个一个折，英文数字整词折；标点不放行首（挂在行尾），左括号不留行尾
    func wrapRuns(_ runs: [Run], _ f: FontSpec, _ bf: FontSpec, _ maxW: Double, orphanFix: Bool = false) -> [[Seg]] {
        let go = { (w: Double) in self.wrapRunsRaw(runs, f, bf, w) }
        var ls = go(maxW)
        if orphanFix && ls.count >= 2 {
            // 最后一行只剩一两个字：把行宽收一点，让上一行匀几个字下来；行数不许变多
            func tail(_ x: [[Seg]]) -> Int {
                var s = x.last!.map(\.text).joined()
                while let c = s.last, ShareLayout.noStart.contains(c) { s.removeLast() }
                return s.count
            }
            if tail(ls) <= 2 {
                let ch = mw("字", f)
                for k in 1...6 {
                    let t2 = go(maxW - Double(k) * ch)
                    if t2.count > ls.count { break }
                    if tail(t2) >= 3 { ls = t2; break }
                }
            }
        }
        return ls
    }

    func wrapRunsRaw(_ runs: [Run], _ f: FontSpec, _ bf: FontSpec, _ maxW: Double) -> [[Seg]] {
        var toks: [Seg] = []
        for r in runs { for tk in ShareLayout.tokens(r.text) { toks.append(Seg(text: tk, bold: r.bold)) } }
        var lines: [[Seg]] = []
        var cur: [Seg] = []
        var w = 0.0
        func width(_ s: Seg) -> Double { mw(s.text, s.bold ? bf : f) }
        func curText() -> String { cur.map(\.text).joined() }
        func push() {
            // 去掉行尾空白
            while let last = cur.last, last.text.allSatisfy({ $0.isWhitespace }) { cur.removeLast() }
            lines.append(cur); cur = []; w = 0
        }
        func append(_ s: Seg) {
            if let last = cur.last, last.bold == s.bold { cur[cur.count - 1].text += s.text } else { cur.append(s) }
        }
        for var tk in toks {
            let isSpace = tk.text.allSatisfy { $0.isWhitespace }
            if cur.isEmpty && isSpace { continue }
            let tw = width(tk)
            if w + tw <= maxW || cur.isEmpty {
                if tw > maxW && tk.text.count > 1 {          // 一个词比一行还长：硬折
                    for ch in tk.text {
                        let cs = Seg(text: String(ch), bold: tk.bold)
                        let cwid = width(cs)
                        if w + cwid > maxW && !cur.isEmpty { push() }
                        append(cs); w += cwid
                    }
                    continue
                }
                append(tk); w += tw; continue
            }
            if tk.text.count == 1, let c = tk.text.first, ShareLayout.noStart.contains(c) { append(tk); w += tw; continue }
            var carry: [Seg] = []
            while let last = cur.last, let c = last.text.last, ShareLayout.noEnd.contains(c) {
                carry.insert(Seg(text: String(c), bold: last.bold), at: 0)
                cur[cur.count - 1].text.removeLast()
                if cur[cur.count - 1].text.isEmpty { cur.removeLast() }
            }
            push()
            if isSpace { tk.text = "" }
            for c in carry { append(c) }
            if !tk.text.isEmpty { append(tk) }
            w = cur.reduce(0) { $0 + width($1) }
        }
        if !cur.isEmpty || lines.isEmpty { push() }
        return lines
    }

    func wrap(_ s: String, _ f: FontSpec, _ maxW: Double) -> [String] {
        wrapRunsRaw([Run(s)], f, f, maxW).map { $0.map(\.text).joined() }
    }

    /// 标题折成几行时尽量一样长：行数不变的前提下把行宽收到最窄
    func wrapBalance(_ s: String, _ f: FontSpec, _ cw: Double) -> [String] {
        let ls = wrap(s, f, cw)
        if ls.count < 2 { return ls }
        var lo = cw * 0.5, hi = cw
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if wrap(s, f, mid).count > ls.count { lo = mid } else { hi = mid }
        }
        return wrap(s, f, hi)
    }
}

// ================================================================ 纸纹：按种子撒噪点（网页版 noise() 一样的算法），同一张图每次画得一样
public enum PaperNoise {
    public struct Speck: Equatable, Sendable { public var x, y, size: Double; public var white: Bool; public var alpha: Double }
    public static let tile: Double = 128

    public static func specks(width w: Double, height h: Double, alpha: Double, seed: Int, size: Double = 1) -> [Speck] {
        guard alpha > 0 else { return [] }
        var out: [Speck] = []
        var ty = 0
        while Double(ty) * tile < h {
            var s = (seed * 7919 + ty * 104729) % 2147483647
            if s == 0 { s = 1 }
            func rnd() -> Double { s = (s * 16807) % 2147483647; return Double(s) / 2147483647 }
            let n = Int((w * tile / (size * size) * 0.18).rounded(.up))
            for _ in 0..<n {
                let white = rnd() >= 0.5
                let a = alpha * rnd()
                let x = rnd() * w, y = Double(ty) * tile + rnd() * tile
                out.append(Speck(x: x, y: y, size: size, white: white, alpha: a))
            }
            ty += 1
        }
        return out
    }
}
