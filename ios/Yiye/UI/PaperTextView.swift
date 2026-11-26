import UIKit
import SwiftUI
import YiyeKit

// 写字页：横线信纸。字一行一个行高，横线跟着行走；图片占整数行，横线照样对得上。
// Markdown 记号留在字里（存的还是 Markdown），写字页只在光标所在的行露出来（淡色），别的行藏起来（123）；拿不准的字黄底，点一下整段选中，直接打字替换。

extension NSAttributedString.Key {
    static let yiyeUnsure = NSAttributedString.Key("yiyeUnsure")
    /// 195：这一段是网址（值是 URL）。不用系统的 .link：能打字的框里系统不认它
    static let yiyeLink = NSAttributedString.Key("yiyeLink")
}

/// 正文里的一张图：记着它在附件里的路径
final class ImageAttachment: NSTextAttachment {
    var path = ""
    /// 占的高度（行高的整数倍）
    var slot: CGFloat = 0
}

/// 横线：一条线一个行高（图案平铺，随字滚动）
final class RuledLinesView: UIView {
    var lineHeight: CGFloat = 32 { didSet { if oldValue != lineHeight { refresh() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        refresh()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: RuledLinesView, _: UITraitCollection) in v.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func refresh() {
        let h = lineHeight
        let fmt = UIGraphicsImageRendererFormat(for: traitCollection)
        fmt.opaque = false
        let lineW: CGFloat = 0.8
        let color = Ink.rule.resolvedColor(with: traitCollection)
        let img = UIGraphicsImageRenderer(size: CGSize(width: 4, height: h), format: fmt).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: h - lineW, width: 4, height: lineW))
        }
        backgroundColor = UIColor(patternImage: img)
    }
}

final class PaperTextView: UITextView {
    let lines = RuledLinesView()
    static let topInset: CGFloat = 4
    static let side: CGFloat = 20
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0
    /// 195：网址的点和长按（没弹键盘时点一下就打开；长按链接弹菜单，弹不弹键盘都一样）
    var linkTitles = LinkTitles()
    private let linkTap = UITapGestureRecognizer()
    private let linkHold = UILongPressGestureRecognizer()
    private lazy var linkGate = LinkGate(self)

    var metrics = EditorMetrics.of(1) {
        didSet { lines.lineHeight = metrics.line; setNeedsLayout() }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: PaperTextView.topInset, left: PaperTextView.side, bottom: 160, right: PaperTextView.side)
        textContainer.lineFragmentPadding = 0
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        insertSubview(lines, at: 0)
        lines.lineHeight = metrics.line
        tintColor = Ink.accent
        LinkOpener.watchPasteboardInDemo()
        linkTap.addTarget(self, action: #selector(tappedLink(_:)))
        linkHold.addTarget(self, action: #selector(heldLink(_:)))
        linkHold.minimumPressDuration = 0.35
        for g in [linkTap, linkHold] as [UIGestureRecognizer] {
            g.delegate = linkGate
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    // ---------------------------------------------------------------- 195 网址
    /// 手指下面是哪个链接（连它在哪一块地方）
    func link(at p: CGPoint) -> (url: URL, rect: CGRect)? { linkHit(.yiyeLink, at: p) }

    func isLinkGesture(_ g: UIGestureRecognizer) -> Bool { g === linkTap || g === linkHold }

    /// 没弹键盘时手指刚落在链接上：这一下归链接，不进编辑（系统用哪个手势放光标都一样）
    private var linkTouchUntil: TimeInterval = 0
    func fingerDown(onLink: Bool) { linkTouchUntil = onLink ? ProcessInfo.processInfo.systemUptime + 1.0 : 0 }
    override var canBecomeFirstResponder: Bool {
        super.canBecomeFirstResponder && ProcessInfo.processInfo.systemUptime >= linkTouchUntil
    }

    /// 链接上的点、长按归链接：系统那套放光标、放大镜让开。弹着键盘时点链接照旧是放光标（要改网址得点得进去）
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if !isLinkGesture(g), g is UITapGestureRecognizer || g is UILongPressGestureRecognizer,
           !isFirstResponder || g is UILongPressGestureRecognizer, link(at: g.location(in: self)) != nil {
            return false
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    @objc private func tappedLink(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, !isFirstResponder, let l = link(at: g.location(in: self)) else { return }
        LinkOpener.open(l.url)
    }

    @objc private func heldLink(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let l = link(at: g.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        LinkOpener.menu(l.url, from: self, at: l.rect, titles: linkTitles)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = max(contentSize.height, bounds.height) + bounds.height
        let f = CGRect(x: 12, y: textContainerInset.top, width: max(0, bounds.width - 24), height: h)
        if lines.frame != f { lines.frame = f }
        if subviews.first !== lines { sendSubviewToBack(lines) }
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onWidthChange?(bounds.width)
        }
    }
}

/// 五招的样子：标题大、粗；列表、引用、居中的标记字淡；粗体里的字粗；引用的字灰一点
@MainActor
struct MarkdownStyler {
    var m: EditorMetrics

    func font(_ size: CGFloat, _ w: UIFont.Weight = .regular) -> UIFont { UIFont.systemFont(ofSize: size, weight: w) }

    func para(_ align: NSTextAlignment = .natural, height: CGFloat? = nil, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let h = height ?? m.line
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        p.alignment = align
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.lineBreakStrategy = .pushOut
        return p
    }

    // 不用 baselineOffset：TextKit 2 里它会把固定行高吃掉一截（11-20 第 1 轮截图：行高成了 28，横线是 32，越往下越错位）。
    // 行高固定时字贴着行底，正好坐在横线上，跟信纸一样。

    func base() -> [NSAttributedString.Key: Any] {
        let f = font(m.size)
        return [.font: f, .foregroundColor: Ink.text, .paragraphStyle: para()]
    }

    /// 藏起来的记号：字小到几乎没有宽度，颜色透明。行高是固定的，藏了也不影响横线对齐
    static let hiddenFont = UIFont.systemFont(ofSize: 0.01)

    /// active：光标 / 选区（写字页开着键盘才有；没开着就 nil，全藏）。光标碰到的行露记号，别的行藏记号
    func apply(_ s: NSTextStorage, active: NSRange? = nil) {
        let full = NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return }
        let text = s.string
        let ns = text as NSString
        s.beginEditing()
        s.addAttributes(base(), range: full)
        s.removeAttribute(.backgroundColor, range: full)
        s.removeAttribute(.baselineOffset, range: full)
        s.removeAttribute(.underlineStyle, range: full)
        s.removeAttribute(.yiyeLink, range: full)
        for l in Markdown5.parse(text) {
            guard l.range.length > 0, l.range.location + l.range.length <= s.length else { continue }
            let lineR = ns.paragraphRange(for: l.range)
            if l.centered { s.addAttribute(.paragraphStyle, value: para(.center), range: lineR) }
            let reveal = active.map { MarkerVisibility.reveals(line: lineR, selection: $0, total: s.length) } ?? false
            var isImage = false
            if case .image = l.block { isImage = true }
            // 藏着记号的清单、引用行：整行缩进对齐，替代行首的「- 」「> 」
            if !reveal && !l.centered {
                if case .bullet = l.block { s.addAttribute(.paragraphStyle, value: para(indent: 18), range: lineR) }
                if case .quote = l.block { s.addAttribute(.paragraphStyle, value: para(indent: 14), range: lineR) }
            }
            var cf = font(m.size)
            var color = Ink.text
            switch l.block {
            case .heading(let n):
                let k: CGFloat = n == 1 ? 1.36 : (n == 2 ? 1.18 : 1.06)
                cf = font((m.size * k).rounded(), n == 3 ? .semibold : .bold)
            case .quote:
                color = Ink.text2
            default:
                break
            }
            if l.content.length > 0 {
                s.addAttributes([.font: cf, .foregroundColor: color], range: l.content)
            }
            for b in l.bold where b.length > 0 {
                let bf = font(cf.pointSize, .bold)
                s.addAttribute(.font, value: bf, range: b)
            }
            for mk in l.markers where mk.length > 0 {
                if !reveal && !isImage {
                    s.addAttributes([.font: MarkdownStyler.hiddenFont, .foregroundColor: UIColor.clear], range: mk)
                    continue
                }
                let piece = ns.substring(with: mk)
                if piece.hasPrefix("<") {
                    let sf = font((m.size * 0.72).rounded())
                    s.addAttributes([.font: sf, .foregroundColor: Ink.text3], range: mk)
                } else {
                    s.addAttribute(.foregroundColor, value: Ink.text3, range: mk)
                }
            }
        }
        // 195：网址标成链接的样子
        for l in Links.find(text) where l.range.location + l.range.length <= s.length {
            s.addAttributes([.foregroundColor: Ink.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .yiyeLink: l.url],
                            range: l.range)
        }
        s.enumerateAttribute(.attachment, in: full, options: []) { v, r, _ in
            guard let a = v as? ImageAttachment else { return }
            s.addAttribute(.paragraphStyle, value: para(.center, height: a.slot), range: ns.paragraphRange(for: r))
        }
        s.enumerateAttribute(.yiyeUnsure, in: full, options: []) { v, r, _ in
            if v != nil { s.addAttribute(.backgroundColor, value: Ink.doubt, range: r) }
        }
        s.endEditing()
    }
}

/// 195：链接那两个手势只在手指落在链接上时接（系统自带的那几个在 PaperTextView.gestureRecognizerShouldBegin 里让开）
private final class LinkGate: NSObject, UIGestureRecognizerDelegate {
    private weak var view: PaperTextView?

    init(_ view: PaperTextView) { self.view = view }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        let onLink = view.link(at: touch.location(in: view)) != nil
        if !view.isFirstResponder { view.fingerDown(onLink: onLink) }
        return onLink && (g is UILongPressGestureRecognizer || !view.isFirstResponder)
    }
}

/// 写字页的大脑：装字、取字、五招、插图、黄字整段选中
@MainActor
final class EditorController: NSObject, UITextViewDelegate {
    private(set) var tv: PaperTextView?
    var store: AttachmentStore?
    var metrics = EditorMetrics.of(1)
    var onChange: (() -> Void)?
    var onFocus: ((Bool) -> Void)?
    /// 088：选中一个词点了「会了」「不会」
    var onWord: ((String, WordMark) -> Void)?
    /// 那两项菜单上的字（跟着语言走，写字页给）
    var wordTitles = (known: "Got it", learning: "Not yet")
    private var programmatic = false

    var styler: MarkdownStyler { MarkdownStyler(m: metrics) }

    func makeView() -> PaperTextView {
        if let tv { return tv }
        let v = PaperTextView()
        v.delegate = self
        v.metrics = metrics
        v.onWidthChange = { [weak self] _ in self?.resizeAttachments() }
        tv = v
        return v
    }

    /// 换了颜色的纸：字、横线、标黄都按白天的颜色
    func setForceLight(_ on: Bool) {
        tv?.overrideUserInterfaceStyle = on ? .light : .unspecified
    }

    func setMetrics(_ m: EditorMetrics) {
        guard m != metrics else { return }
        metrics = m
        tv?.metrics = m
        resizeAttachments()
        restyle()
    }

    // ---------------------------------------------------------------- 装字、取字
    func load(markdown: String, unsure: [NSRange]) {
        guard let tv else { return }
        let map = DisplayMap(markdown: markdown)
        let s = NSMutableAttributedString(string: map.display, attributes: styler.base())
        for img in map.images.reversed() {
            s.replaceCharacters(in: img.display, with: NSAttributedString(attachment: attachment(img.path)))
        }
        for r in unsure {
            let d = map.toDisplay(r)
            if d.length > 0, d.location + d.length <= s.length { s.addAttribute(.yiyeUnsure, value: true, range: d) }
        }
        programmatic = true
        let offset = tv.contentOffset
        tv.attributedText = s
        restyle()
        tv.contentOffset = offset
        programmatic = false
    }

    /// 写字页里现在的字 → Markdown + 拿不准的位置
    func current() -> (markdown: String, unsure: [NSRange]) {
        guard let tv else { return ("", []) }
        let st = tv.textStorage
        let full = NSRange(location: 0, length: st.length)
        var paths: [Int: String] = [:]
        st.enumerateAttribute(.attachment, in: full, options: []) { v, r, _ in
            if let a = v as? ImageAttachment { paths[r.location] = a.path }
        }
        let md = markdownFromDisplay(st.string, paths: paths)
        var disp: [NSRange] = []
        st.enumerateAttribute(.yiyeUnsure, in: full, options: []) { v, r, _ in if v != nil { disp.append(r) } }
        let map = DisplayMap(markdown: md)
        return (md, disp.map { map.toMarkdown($0) }.filter { $0.length > 0 })
    }

    /// 光标在 Markdown 里的位置（拍照认字的字插在这儿）
    func caretInMarkdown() -> Int? {
        guard let tv else { return nil }
        let md = current().markdown
        return DisplayMap(markdown: md).toMarkdown(tv.selectedRange).location
    }

    /// 露记号的那几行（光标 / 选区碰到的整段）。没开着键盘（没有光标）是 nil：全藏
    private func revealKey() -> NSRange? {
        guard let tv, tv.isFirstResponder else { return nil }
        let ns = tv.textStorage.string as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange
        let loc = min(sel.location, ns.length)
        return ns.paragraphRange(for: NSRange(location: loc, length: min(sel.length, ns.length - loc)))
    }

    private var lastRevealKey: NSRange?

    func restyle() {
        guard let tv, tv.markedTextRange == nil else { return }
        let sel = tv.selectedRange
        lastRevealKey = revealKey()
        styler.apply(tv.textStorage, active: tv.isFirstResponder ? sel : nil)
        tv.typingAttributes = styler.base()
        if tv.selectedRange != sel { tv.selectedRange = sel }
    }

    // ---------------------------------------------------------------- 图
    func attachment(_ path: String) -> ImageAttachment {
        let a = ImageAttachment()
        a.path = path
        fit(a)
        return a
    }

    private func fit(_ a: ImageAttachment) {
        let width = (tv?.bounds.width ?? 0) > 50 ? tv!.bounds.width : 390
        let maxW = width - PaperTextView.side * 2
        let L = metrics.line
        if let img = store?.image(a.path), img.size.width > 0 {
            let ar = img.size.height / img.size.width
            let slot = max(L * 2, ((maxW * ar + 8) / L).rounded(.up) * L)
            let h = slot - 8
            let w = min(maxW, h / ar)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = tv?.traitCollection.displayScale ?? 3
            a.image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
                img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            a.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            a.slot = slot
        } else {
            let h = L * 3 - 8
            let fmt = UIGraphicsImageRendererFormat()
            a.image = UIGraphicsImageRenderer(size: CGSize(width: maxW, height: h), format: fmt).image { ctx in
                Ink.rule.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: maxW, height: h))
            }
            a.bounds = CGRect(x: 0, y: 0, width: maxW, height: h)
            a.slot = L * 3
        }
    }

    private func resizeAttachments() {
        guard let tv else { return }
        let st = tv.textStorage
        var any = false
        st.enumerateAttribute(.attachment, in: NSRange(location: 0, length: st.length), options: []) { v, _, _ in
            if let a = v as? ImageAttachment { fit(a); any = true }
        }
        if any {
            restyle()
            tv.setNeedsLayout()
        }
    }

    /// 插一张图：独占一行，插完光标落在图下面。gap（默认）：跟上下的字、图都隔一个空行，一个字没有时上面也空一行（Song 11-22）
    func insertImage(path: String, gap: Bool) {
        guard let tv else { return }
        let att = attachment(path)
        let sel = tv.selectedRange
        let ns = tv.textStorage.string as NSString
        let plan = ImageSpacing.insertion(before: ns.substring(to: sel.location), after: ns.substring(from: sel.location + sel.length), gap: gap)
        let s = NSMutableAttributedString()
        if plan.prefix > 0 { s.append(NSAttributedString(string: String(repeating: "\n", count: plan.prefix))) }
        s.append(NSAttributedString(attachment: att))
        if plan.suffix > 0 { s.append(NSAttributedString(string: String(repeating: "\n", count: plan.suffix))) }
        tv.textStorage.replaceCharacters(in: sel, with: s)
        tv.selectedRange = NSRange(location: min(sel.location + plan.caret, tv.textStorage.length), length: 0)
        restyle()
        onChange?()
    }

    /// 整条的图重排：上下各空一格，或者全靠拢。只增删图旁边的空行（能撤销），图、字、黄底都不动
    func respaceImages(gap: Bool) {
        guard let tv, tv.markedTextRange == nil else { return }
        let old = tv.textStorage.string
        let new = ImageSpacing.respace(old, gap: gap)
        guard new != old, ImageSpacing.onlyBlanksDiffer(old, new) else { return }
        let caret = ImageSpacing.caret(tv.selectedRange.location, from: old, to: new)
        programmatic = true
        applyMinimal(NSRange(location: 0, length: (old as NSString).length), new)
        tv.selectedRange = NSRange(location: min(caret, tv.textStorage.length), length: 0)
        programmatic = false
        restyle()
        onChange?()
    }

    // ---------------------------------------------------------------- 五招
    func apply(_ cmd: MDCommand) {
        guard let tv else { return }
        let e = Markdown5.apply(cmd, to: tv.textStorage.string, selection: tv.selectedRange)
        programmatic = true
        applyMinimal(e.range, e.replacement)
        tv.selectedRange = e.selection
        programmatic = false
        restyle()
        onChange?()
    }

    /// 只换真变了的那几个字（别的字上的黄底、图都不动）
    private func applyMinimal(_ range: NSRange, _ newText: String) {
        guard let tv else { return }
        let old = tv.textStorage.string.sub16(range)
        var chunks: [(NSRange, String)] = []
        var pos = 0
        var start: Int? = nil
        var ins = ""
        for op in TextDiff.ops(old, newText) {
            switch op {
            case .same(let c):
                if let st = start { chunks.append((NSRange(location: st, length: pos - st), ins)); start = nil; ins = "" }
                pos += String(c).u16
            case .del(let c):
                if start == nil { start = pos }
                pos += String(c).u16
            case .ins(let c):
                if start == nil { start = pos }
                ins.append(c)
            }
        }
        if let st = start { chunks.append((NSRange(location: st, length: pos - st), ins)) }
        for (r, s) in chunks.reversed() { replace(r.shifted(range.location), with: s) }
    }

    /// 走 UITextInput 换字（能撤销）
    func replace(_ r: NSRange, with s: String) {
        guard let tv,
              let a = tv.position(from: tv.beginningOfDocument, offset: r.location),
              let b = tv.position(from: a, offset: r.length),
              let tr = tv.textRange(from: a, to: b) else { return }
        tv.replace(tr, withText: s)
    }

    func focus() { tv?.becomeFirstResponder() }
    func endEditing() { tv?.resignFirstResponder() }

    // ---------------------------------------------------------------- UITextViewDelegate
    func textViewDidChange(_ textView: UITextView) {
        if textView.markedTextRange == nil { restyle() }
        if !programmatic { onChange?() }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // 新打的字不带黄底
        textView.typingAttributes = styler.base()
        if text == "\n", !programmatic, continueList(range) { return false }
        return true
    }

    /// 列表、引用行末回车：自动接上「- 」「> 」；空的那行再回车：去掉标记
    private func continueList(_ range: NSRange) -> Bool {
        guard let tv, range.length == 0 else { return false }
        let text = tv.textStorage.string
        guard let l = lineSpans(text).first(where: { range.location >= $0.range.location && range.location <= $0.range.end }),
              range.location == l.range.location + l.range.length else { return false }
        let md = Markdown5.parseLine(l.text, at: l.range.location)
        let prefix: String
        switch md.block {
        case .bullet: prefix = "- "
        case .quote: prefix = "> "
        default: return false
        }
        programmatic = true
        if md.content.length == 0 {
            replace(l.range, with: "")
        } else {
            replace(range, with: "\n" + prefix)
        }
        programmatic = false
        restyle()
        onChange?()
        return true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !programmatic, textView.markedTextRange == nil else { return }
        // 123：光标走到另一行，那行的记号露出来、这行的藏起来；同一行里挪光标不用重染
        if MarkerVisibility.needsRestyle(oldKey: lastRevealKey, newKey: revealKey()) { restyle() }
        let sel = textView.selectedRange
        guard sel.length == 0, sel.location < textView.textStorage.length else { return }
        var eff = NSRange(location: 0, length: 0)
        if textView.textStorage.attribute(.yiyeUnsure, at: sel.location, effectiveRange: &eff) != nil, eff.length > 0 {
            programmatic = true
            textView.selectedRange = eff
            programmatic = false
        }
    }

    /// 088：选中的是一个词或词组，系统菜单最前面多「会了」「不会」两项；选中一整段、没有字母的照系统原样
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, let onWord, range.location + range.length <= textView.textStorage.length,
              let w = WordMark.clean(textView.textStorage.string.sub16(range)) else { return nil }
        let known = UIAction(title: wordTitles.known, image: UIImage(systemName: "checkmark")) { _ in onWord(w, .known) }
        let learning = UIAction(title: wordTitles.learning, image: UIImage(systemName: "arrow.counterclockwise")) { _ in onWord(w, .learning) }
        return UIMenu(children: [UIMenu(options: .displayInline, children: [known, learning])] + suggestedActions)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { onFocus?(true); restyle() }
    func textViewDidEndEditing(_ textView: UITextView) { onFocus?(false); restyle() }
}

struct NoteTextEditor: UIViewRepresentable {
    let controller: EditorController
    func makeUIView(context: Context) -> PaperTextView { controller.makeView() }
    func updateUIView(_ uiView: PaperTextView, context: Context) {}
}
