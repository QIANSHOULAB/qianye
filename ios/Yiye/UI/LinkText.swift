import SwiftUI
import UIKit
import YiyeKit

/// 195 网址能点、能单独拷；文字能选一段再拷。
/// 气泡用 LinkText（只读的 UITextView：点链接开浏览器，长按链接弹「打开 / 拷贝链接 / 分享…」，长按别处拖着选一段）；
/// 写字页能打字，链接的点和长按在 PaperTextView 里接。认网址的规则在 YiyeKit Links195.swift。
@MainActor
enum LinkOpener {
    private static let demo = DemoConfig.fromLaunch() != nil

    static func open(_ url: URL) {
        if demo {                                   // 截图、UI 测试：不跳出去，写在屏幕角上给测试读
            opened += 1
            report("link.opened", "\(opened)|\(url.absoluteString)")
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// 长按链接：打开 / 拷贝链接 / 分享…
    static func menu(_ url: URL, from view: UIView, at rect: CGRect, titles: LinkTitles) {
        guard let top = topController(of: view.window) else { return }
        let full = url.absoluteString
        let sheet = UIAlertController(title: nil, message: full.count > 140 ? String(full.prefix(140)) + "…" : full,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: titles.open, style: .default) { _ in LinkOpener.open(url) })
        sheet.addAction(UIAlertAction(title: titles.copy, style: .default) { _ in UIPasteboard.general.string = full })
        sheet.addAction(UIAlertAction(title: titles.share, style: .default) { [weak view] _ in
            guard let view, let top = LinkOpener.topController(of: view.window) else { return }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = rect
            top.present(share, animated: true)
        })
        sheet.addAction(UIAlertAction(title: titles.cancel, style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = rect
        top.present(sheet, animated: true)
    }

    private static func topController(of window: UIWindow?) -> UIViewController? {
        let w = window ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var c = w?.rootViewController
        while let next = c?.presentedViewController, !next.isBeingDismissed { c = next }
        return c
    }

    // ---------------------------------------------------------------- 截图 / UI 测试
    private static var opened = 0
    private static var tags: [String: UILabel] = [:]
    private static var watching = false

    /// UI 测试要知道拷到的是什么（自己拷的自己读，系统不弹「允许粘贴」）
    static func watchPasteboardInDemo() {
        guard demo, !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let s = UIPasteboard.general.string, !s.isEmpty { LinkOpener.report("link.pasted", s) }
            }
        }
    }

    private static func report(_ id: String, _ text: String) {
        // 下一拍再贴：菜单、弹层收完了，贴在当时最上面那层（聊天窗升着时，贴在窗口上测试看不见）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let top = LinkOpener.topController(of: nil) else { return }
            let label = LinkOpener.tags[id] ?? UILabel(frame: CGRect(x: id == "link.opened" ? 0 : 4, y: 0, width: 2, height: 2))
            LinkOpener.tags[id] = label
            label.alpha = 0.02
            label.isUserInteractionEnabled = false
            label.accessibilityIdentifier = id
            label.text = text
            label.accessibilityLabel = text
            top.view.addSubview(label)
        }
    }
}

/// 链接菜单上的字（跟着语言走）
struct LinkTitles {
    var open = "Open"
    var copy = "Copy Link"
    var share = "Share…"
    var cancel = "Cancel"

    static func of(_ t: Lang) -> LinkTitles {
        LinkTitles(open: t.t("link.open"), copy: t.t("link.copy"), share: t.t("link.share"), cancel: t.t("common.cancel"))
    }
}

extension UITextView {
    /// 手指下面是哪个链接（连它在哪一块地方）；key 是标链接用的那个属性
    func linkHit(_ key: NSAttributedString.Key, at p: CGPoint) -> (url: URL, rect: CGRect)? {
        let st = textStorage
        var hit: (url: URL, rect: CGRect)?
        st.enumerateAttribute(key, in: NSRange(location: 0, length: st.length), options: []) { v, r, stop in
            guard let url = v as? URL,
                  let a = position(from: beginningOfDocument, offset: r.location),
                  let b = position(from: a, offset: r.length),
                  let range = textRange(from: a, to: b) else { return }
            for s in selectionRects(for: range) where s.rect.width > 1 && s.rect.insetBy(dx: -4, dy: -2).contains(p) {
                hit = (url, s.rect)
                stop.pointee = true
                return
            }
        }
        return hit
    }
}

/// 气泡里那个只读的框：链接上的长按自己接（弹跟写字页一样的菜单——系统自带的那个在聊天窗里长按没弹出来），
/// 别处照系统的（长按拖着选一段）
final class BubbleTextView: UITextView {
    var linkTitles = LinkTitles()
    private let linkHold = UILongPressGestureRecognizer()
    private lazy var linkGate = BubbleLinkGate(self)

    func listenForHeldLinks() {
        linkHold.addTarget(self, action: #selector(heldLink(_:)))
        linkHold.minimumPressDuration = 0.35
        linkHold.delegate = linkGate
        addGestureRecognizer(linkHold)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g !== linkHold, g is UILongPressGestureRecognizer, linkHit(.link, at: g.location(in: self)) != nil { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    @objc private func heldLink(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let l = linkHit(.link, at: g.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        LinkOpener.menu(l.url, from: self, at: l.rect, titles: linkTitles)
    }
}

private final class BubbleLinkGate: NSObject, UIGestureRecognizerDelegate {
    private weak var view: BubbleTextView?

    init(_ view: BubbleTextView) { self.view = view }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        return view.linkHit(.link, at: touch.location(in: view)) != nil
    }
}

/// 一段只读的字：网址是链接，字能选一段
struct LinkText: UIViewRepresentable {
    let text: String
    var size: CGFloat = 16
    var color: UIColor = Ink.text
    var titles = LinkTitles()

    init(_ text: String, size: CGFloat = 16, color: UIColor = Ink.text, titles: LinkTitles = LinkTitles()) {
        self.text = text
        self.size = size
        self.color = color
        self.titles = titles
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var shown = ""

        /// 点链接：交给 LinkOpener（真机开默认浏览器）
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in MainActor.assumeIsolated { LinkOpener.open(url) } }
            }
            return defaultAction
        }

        /// 系统自带的链接菜单关掉：长按归 BubbleTextView，免得弹两个
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            if case .link = textItem.content { return nil }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        LinkOpener.watchPasteboardInDemo()
        let v = BubbleTextView()
        v.listenForHeldLinks()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.dataDetectorTypes = []                       // 链接自己标（跟写字页同一套认法）
        v.delegate = context.coordinator
        v.tintColor = Ink.accent
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.accessibilityIdentifier = "bubble.text"
        fill(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) { fill(v, context.coordinator) }

    /// 字、颜色真变了才重填（重填会丢掉他正选着的那段）
    private func fill(_ v: UITextView, _ c: Coordinator) {
        (v as? BubbleTextView)?.linkTitles = titles
        let key = "\(size)|\(color.resolvedColor(with: v.traitCollection))|\(Ink.accent.resolvedColor(with: v.traitCollection))|\(text)"
        guard key != c.shown else { return }
        c.shown = key
        v.linkTextAttributes = [.foregroundColor: Ink.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        v.attributedText = attributed()
        v.invalidateIntrinsicContentSize()
    }

    private func attributed() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakStrategy = .pushOut
        let s = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color,
                                                                     .paragraphStyle: p])
        for l in Links.find(text) { s.addAttribute(.link, value: l.url, range: l.range) }
        return s
    }

    /// 多宽多高自己量：宽按字实际占的（气泡贴着字），高按这个宽排完的，长网址折行、不撑破、不截
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        var room = proposal.width ?? 10_000
        if !room.isFinite { room = 10_000 }
        room = max(room, 40)
        let natural = uiView.attributedText.boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(room, ceil(natural.width) + 2)
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }
}
