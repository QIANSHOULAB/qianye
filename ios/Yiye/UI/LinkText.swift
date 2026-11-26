import SwiftUI
import UIKit
import YiyeKit

/// 195 网址能点、能单独拷；文字能选一段再拷。
/// 气泡用 LinkText（只读的 UITextView：点链接开浏览器，长按链接是系统那套「拷贝链接 / 分享」，长按别处拖着选一段）；
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

    /// 写字页长按链接：打开 / 拷贝链接 / 分享…
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

/// 写字页链接菜单上的字（跟着语言走，写字页给）
struct LinkTitles {
    var open = "Open"
    var copy = "Copy Link"
    var share = "Share…"
    var cancel = "Cancel"
}

/// 一段只读的字：网址是链接，字能选一段
struct LinkText: UIViewRepresentable {
    let text: String
    var size: CGFloat = 16
    var color: UIColor = Ink.text

    init(_ text: String, size: CGFloat = 16, color: UIColor = Ink.text) {
        self.text = text
        self.size = size
        self.color = color
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var shown = ""

        /// 点链接：交给 LinkOpener（真机开默认浏览器；长按还是系统那套菜单）
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in MainActor.assumeIsolated { LinkOpener.open(url) } }
            }
            return defaultAction
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        LinkOpener.watchPasteboardInDemo()
        let v = UITextView()
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
