import SwiftUI
import Translation
import UIKit
import YiyeKit

// 222：听力原文里点一下一个词、点两下一整句，旁边弹一张小卡片给中文意思。
// 225：大管家送稿时译好的（trans）先用它的；没有的、查不到的才用 iOS 自带的 Translation 框架兜底
//（只在手机上翻，字不发到外面），卡片角上写「系统翻译」。

/// 点中的词或整句（开着卡片）
struct TextPick: Equatable {
    var line: Int
    /// nil = 整句
    var range: NSRange?
    var text: String
    /// 卡片别盖住的那一块（原文页的坐标）
    var area: CGRect
    /// 一个英文词都没有的句子：没得翻，卡片只给按钮
    var translatable: Bool
    /// 225：大管家译好的意思；nil = 手机系统翻
    var butler: String? = nil
}

/// 各句在原文页里的框：卡片靠它找地方。放在引用里，滚动时记它不引起重画
final class RowFrames {
    var map: [Int: CGRect] = [:]
}

// ---------------------------------------------------------------- 翻译
@MainActor @Observable
final class PhoneTranslator {
    enum Why: Equatable { case noPair, noPack, other(String) }
    enum State: Equatable { case idle, working, needsPack, done(String), failed(Why) }

    private(set) var state: State = .idle
    /// 卡片上现在这个意思是不是系统翻译给的（要写「系统翻译」）
    private(set) var system = false
    /// 交给 .translationTask 的：一变（或 invalidate）它就跑一回
    private(set) var config: TranslationSession.Configuration?
    @ObservationIgnored private var job: (id: Int, text: String)?
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var cache: [String: String] = [:]

    private static var english: Locale.Language { Locale.Language(identifier: "en") }
    private static var chinese: Locale.Language { Locale.Language(identifier: "zh-Hans") }

    /// 要翻这段。demo：截图和 UI 测试用假的（模拟器里系统翻译不能用）
    func ask(_ text: String, demo: Bool) {
        seq += 1
        let id = seq
        job = (id, text)
        system = true
        if demo {
            state = UserDefaults.standard.bool(forKey: "YiyeNoTranslate") ? .failed(.noPack) : .done(PhoneTranslator.demoMeaning(text))
            return
        }
        if let got = cache[text] { state = .done(got); return }
        state = .working
        Task {
            let status = await LanguageAvailability().status(from: PhoneTranslator.english, to: PhoneTranslator.chinese)
            guard job?.id == id else { return }
            switch status {
            case .unsupported:
                state = .failed(.noPair)
                return
            case .supported:
                state = .needsPack          // 语言包还没下：系统这时候弹它自己的下载提示
            default:
                break
            }
            if config == nil {
                config = TranslationSession.Configuration(source: PhoneTranslator.english, target: PhoneTranslator.chinese)
            } else {
                config?.invalidate()
            }
        }
    }

    func run(_ session: TranslationSession) async {
        guard let j = job else { return }
        do {
            let r = try await session.translate(j.text)
            cache[j.text] = r.targetText
            if job?.id == j.id { state = .done(r.targetText) }
        } catch {
            guard job?.id == j.id, !Task.isCancelled else { return }
            let status = await LanguageAvailability().status(from: PhoneTranslator.english, to: PhoneTranslator.chinese)
            guard job?.id == j.id else { return }
            state = .failed(status == .installed ? .other(error.localizedDescription) : .noPack)
        }
    }

    func cancel() {
        job = nil
        system = false
        state = .idle
    }

    /// 大管家译好的：直接摆上去，不叫系统翻译
    func show(_ meaning: String) {
        job = nil
        system = false
        state = .done(meaning)
    }

    private static func demoMeaning(_ text: String) -> String {
        switch text {
        case "Bitcoin": return "比特币"
        case "Bitcoin fell below 62,000 dollars on Monday.": return "周一，比特币跌破了 6.2 万美元。"
        default: return "译：\(text)"
        }
    }
}

// ---------------------------------------------------------------- 卡片
struct WordCard: View {
    let pick: TextPick
    let state: PhoneTranslator.State
    /// 意思是系统翻译给的
    let system: Bool
    let marked: WordMark?
    /// 这篇标了句子时间：能「从这句放」「单句循环」
    let timed: Bool
    let looping: Bool
    let t: Lang
    let onMark: (WordMark) -> Void
    let onPlay: () -> Void
    let onLoop: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pick.range != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pick.text)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(Ink.text))
                        .lineLimit(2)
                        .accessibilityIdentifier("listen.card.word")
                    Spacer(minLength: 0)
                    if system { systemMark }
                }
            } else if system && pick.translatable {
                HStack { Spacer(minLength: 0); systemMark }
            }
            if pick.translatable { meaning }
            if pick.range != nil || timed { buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Ink.paper)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(Ink.btnBorder), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listen.card")
    }

    /// 225：这张卡的意思不是大管家译的
    private var systemMark: some View {
        Text(t.t("word.system"))
            .font(.system(size: 11))
            .foregroundStyle(Color(Ink.text3))
            .fixedSize()
            .accessibilityIdentifier("listen.card.system")
    }

    @ViewBuilder private var meaning: some View {
        switch state {
        case .idle, .working:
            note(t.t("word.translating"))
        case .needsPack:
            note(t.t("word.pack"))
        case .done(let s):
            // 长句的译文放不下就在卡片里滚
            ViewThatFits(in: .vertical) {
                meaningText(s).fixedSize(horizontal: false, vertical: true)
                ScrollView { meaningText(s).frame(maxWidth: .infinity, alignment: .leading) }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 2) {
                note(reason(why))
                if why != .noPair {
                    Button(t.t("word.retry"), action: onRetry)
                        .buttonStyle(SmartButtonStyle())
                        .accessibilityIdentifier("listen.card.retry")
                }
            }
        }
    }

    private func meaningText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 17))
            .foregroundStyle(Color(Ink.text))
            .lineSpacing(3)
            .accessibilityIdentifier("listen.card.meaning")
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14))
            .foregroundStyle(Color(Ink.text2))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("listen.card.note")
    }

    private func reason(_ why: PhoneTranslator.Why) -> String {
        switch why {
        case .noPair: return t.t("word.noPair")
        case .noPack: return t.t("word.noPack")
        case .other(let s): return t.f("word.failed", s)
        }
    }

    /// 一行放得下就一行，放不下分两行
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { marks; listen }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) { marks }
                HStack(spacing: 4) { listen }
            }
        }
    }

    @ViewBuilder private var marks: some View {
        if pick.range != nil {
            markButton(.learning, t.t("word.markLearning"), "listen.card.hard")
            markButton(.known, t.t("word.markKnown"), "listen.card.known")
        }
    }

    private func markButton(_ m: WordMark, _ title: String, _ id: String) -> some View {
        let on = marked == m
        return Button { onMark(m) } label: {
            HStack(spacing: 4) {
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                Text(title).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(SmartButtonStyle(prominent: on))
        .accessibilityIdentifier(id)
        .accessibilityValue(on ? "on" : "off")
    }

    @ViewBuilder private var listen: some View {
        if timed {
            Button(action: onPlay) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 12))
                    Text(t.t("listen.playHere")).lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(SmartButtonStyle())
            .accessibilityIdentifier("listen.card.play")
            if pick.range == nil {
                Button(action: onLoop) {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat.1").font(.system(size: 13))
                        Text(t.t("listen.loopOne")).lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(SmartButtonStyle(prominent: looping))
                .accessibilityIdentifier("listen.card.loop")
                .accessibilityValue(looping ? "on" : "off")
            }
        }
    }
}

// ---------------------------------------------------------------- 一句话的文字
/// 手指在一句上点了什么
enum SentenceTap {
    /// 词的范围、词本身、词的框（这个文字视图的坐标）
    case word(NSRange, String, CGRect)
    /// 点两下：整句
    case sentence
    /// 没点着词（标点、数字、空白）
    case blank
}

/// 系统自带的点、点两下选词关掉（点归一叶笺管）；长按拖选照旧
final class SentenceTextView: UITextView {
    weak var ownTap: UIGestureRecognizer?
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UITapGestureRecognizer, g !== ownTap { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// 一句话的文字：只读。点一下选一个词，点两下整句；长按拖选照旧，系统菜单最前面多「已掌握」「难词」（走 AppModel.markWord）
struct SentenceText: UIViewRepresentable {
    let text: String
    let color: UIColor
    /// 点中标出来的词
    let picked: NSRange?
    let titles: (known: String, learning: String)
    let name: String
    let onWord: (String, WordMark) -> Void
    let onTap: (SentenceTap) -> Void
    /// 手碰了一下（跟着放先停一会儿）
    let onTouch: () -> Void
    /// 长按选着字没有
    let onSelecting: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SentenceTextView {
        let tv = SentenceTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        // 四边的空也算这一句的：点在边上归最近的词
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        tv.textContainer.lineFragmentPadding = 0
        tv.accessibilityIdentifier = name
        tv.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tv.ownTap = tap
        tv.addGestureRecognizer(tap)
        context.coordinator.tv = tv
        return tv
    }

    func updateUIView(_ tv: SentenceTextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // 放音时整张表每秒刷新好几回：字、颜色、标的词没变就别重设，免得选中的词被清掉
        guard c.lastText != text || c.lastColor != color || c.lastPicked != picked else { return }
        c.lastText = text
        c.lastColor = color
        c.lastPicked = picked
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 18), .foregroundColor: color, .paragraphStyle: para,
        ])
        if let r = picked, r.location + r.length <= s.length {
            s.addAttribute(.backgroundColor, value: Ink.accent.withAlphaComponent(0.3), range: r)
        }
        tv.attributedText = s
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SentenceTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 320
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: ceil(s.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: SentenceText?
        weak var tv: SentenceTextView?
        var lastText = ""
        var lastColor: UIColor?
        var lastPicked: NSRange?
        private var taps = TapCount()
        private var selecting = false
        /// 刚点了两下：系统要是跟着选了字、弹菜单，不算数
        private var doubleAt: TimeInterval = 0
        private var justDouble: Bool { CACurrentMediaTime() - doubleAt < 0.8 }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let p = parent, let tv else { return }
            p.onTouch()
            let at = g.location(in: tv)
            // 点两下要先认：这时候系统多半已经顺手选上了一个词（CI 模拟器上就是这样），不能当成「收掉选中」
            if taps.tap(x: Double(at.x), y: Double(at.y), at: CACurrentMediaTime()) == 2 {
                doubleAt = CACurrentMediaTime()
                tv.selectedTextRange = nil
                p.onTap(.sentence)
                return
            }
            // 长按选着字：这一下只收掉选中和菜单
            if tv.selectedRange.length > 0 {
                tv.selectedTextRange = nil
                taps = TapCount()
                return
            }
            let text = tv.textStorage.string
            let words = WordPick.words(in: text)
            let rects = words.map { Coordinator.rects($0, in: tv) }
            if let k = WordPick.hit(x: Double(at.x), y: Double(at.y), rects: rects, slop: 12), let first = rects[k].first {
                let r = words[k]
                p.onTap(.word(r, (text as NSString).substring(with: r), rects[k].reduce(first) { $0.union($1) }))
            } else {
                p.onTap(.blank)
            }
        }

        /// 一个词占的框（折了行的有好几个）
        private static func rects(_ r: NSRange, in tv: UITextView) -> [CGRect] {
            guard let s = tv.position(from: tv.beginningOfDocument, offset: r.location),
                  let e = tv.position(from: s, offset: r.length),
                  let range = tv.textRange(from: s, to: e) else { return [] }
            return tv.selectionRects(for: range).map { $0.rect }.filter { $0.width > 0 }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // 重画途中也会走到这儿：等这一轮画完再看现在选没选着、再告诉页面
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let on = textView.selectedRange.length > 0
                if on && self.justDouble {          // 点两下之后系统才选上的：抹掉
                    textView.selectedTextRange = nil
                    return
                }
                guard on != self.selecting else { return }
                self.selecting = on
                self.parent?.onSelecting(on)
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            if justDouble { return UIMenu(children: []) }
            guard let p = parent, range.length > 0, range.location + range.length <= textView.textStorage.length,
                  let w = WordMark.clean(textView.textStorage.string.sub16(range)) else { return nil }
            let known = UIAction(title: p.titles.known, image: UIImage(systemName: "checkmark")) { _ in p.onWord(w, .known) }
            let learning = UIAction(title: p.titles.learning, image: UIImage(systemName: "arrow.counterclockwise")) { _ in p.onWord(w, .learning) }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [known, learning])] + suggestedActions)
        }
    }
}
