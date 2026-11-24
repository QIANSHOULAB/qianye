import Foundation

// 114：网页文章分享进一叶笺（捷径「存进一叶笺」）→ 存成便签 → 大管家扒正文 → 两个按钮：简写、直接配音。
// 这里是不碰界面和数据库的那部分：分享进来的是网址还是文字、页面标题怎么抠、便签正文怎么拼、一条文章便签跟大管家打交道的状态。

// ================================================================ 分享进来的东西
public enum ArticleShare: Equatable, Sendable {
    /// 一个网页地址
    case url(String)
    /// 一段文字（没有网址）：直接存成便签，不扒正文
    case text(String)
    /// 什么都没收到
    case nothing

    /// 捷径可能给网址、给文字，或者两样都给。有网址（参数里的，或者文字里整段就是一个网址）就走网址；文字里夹着网址的（「看这篇 https://…」）
    /// 也取第一个网址、整段文字当备注丢掉——分享菜单里网页分享来的就是这种。别的当文字。
    public static func parse(url: String?, text: String?) -> ArticleShare {
        if let u = clean(url) { return .url(u) }
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .nothing }
        if let u = clean(t) { return .url(u) }
        // 文字很短、里面带一个网址：多半是「标题 + 网址」的分享，取网址
        if t.count <= 300, let u = firstURL(in: t) { return .url(u) }
        return .text(t)
    }

    /// 整段就是一个 http(s) 地址（前后空白不算）才返回
    static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        let low = s.lowercased()
        guard low.hasPrefix("http://") || low.hasPrefix("https://"), let u = URL(string: s), u.host != nil else { return nil }
        return s
    }

    /// 文字里第一个 http(s) 地址：只取网址里合法的那些字符，碰到汉字、全角标点就停；末尾的句号逗号括号不算
    static func firstURL(in s: String) -> String? {
        let pattern = "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range, in: s) else { return nil }
        var u = String(s[r])
        while let last = u.last, ".,;:!?)'".contains(last) { u.removeLast() }
        return clean(u)
    }
}

// ================================================================ 页面标题
public enum PageTitle {
    /// 从网页 HTML 里抠 <title>；没有、空的返回 nil。常见的字符实体换回来，空白压成一格，最长 120 字
    public static func extract(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive, range: gt.upperBound..<html.endIndex) else { return nil }
        var t = String(html[gt.upperBound..<close.lowerBound])
        t = unescape(t)
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        t = String(t.prefix(120)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
                       ("&#x27;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&mdash;", "—"), ("&ndash;", "–")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }
}

// ================================================================ 便签正文怎么拼
public enum ArticleText {
    /// 刚存下来、正文还没扒回来：第一行标题（拿不到就放网址），空一行，网址
    public static func initial(title: String?, url: String) -> String {
        let head = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "# \(head.isEmpty ? url : head)\n\n\(url)"
    }

    /// 大管家扒回来了：标题 + 正文 + 最后一行网址。大管家没给标题就留便签原来的第一行
    public static func compose(title: String?, body: String, url: String, keepingHeadOf old: String) -> String {
        var head = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty {
            let first = old.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            head = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        }
        if head.isEmpty { head = url }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "# \(head)\n\n\(b)\n\n\(url)"
    }
}

// ================================================================ 信
extension ButlerRequest {
    /// 扒正文：给网址，大管家回标题 + 干净正文
    public static func article(id: String, note: String, url: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: note, kind: .text, text: "", images: nil, unsure: nil, ask: "article", at: at, app: app)
        r.url = url
        return r
    }

    /// 简写：给便签全文，大管家写成一到三篇听力稿（带录音）从「送来」回来，每篇的 request 是这封信的 id
    public static func simplify(id: String, note: String, text: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: note, kind: .text, text: text, images: nil, unsure: nil, ask: "simplify", at: at, app: app)
    }
}

// ================================================================ 一条文章便签跟大管家打交道的状态（存进便签，JSON）
public struct ArticleState: Codable, Equatable, Sendable {
    public enum Fetch: String, Codable, Sendable { case none, fetching, ready, failed }
    public enum Simplify: String, Codable, Sendable { case none, working, done, failed }

    public var url: String = ""
    public var fetch: Fetch = .none
    public var fetchID: String?
    public var fetchSentAt: Date?
    public var fetchError: String?
    public var simplify: Simplify = .none
    public var simplifyID: String?
    public var simplifySentAt: Date?
    public var simplifyError: String?
    /// 简写出来的第一篇听力（便签 id）：栏上点了跳过去
    public var simplifiedNote: String?

    /// 扒正文最多等这么久；简写（写稿 + 配音）最多等这么久。过了就当没回话，按钮放开
    public static let fetchWait: TimeInterval = 600
    public static let simplifyWait: TimeInterval = 1800

    public init() {}

    public func fetching(now: Date) -> Bool {
        guard fetch == .fetching, let t = fetchSentAt else { return false }
        return now.timeIntervalSince(t) < ArticleState.fetchWait
    }

    public func simplifying(now: Date) -> Bool {
        guard simplify == .working, let t = simplifySentAt else { return false }
        return now.timeIntervalSince(t) < ArticleState.simplifyWait
    }

    /// 栏上的两个按钮能不能点：正文还在扒的时候灰着；别的时候（扒失败、没回话也一样）能点，用便签里现有的字
    public func canPress(now: Date) -> Bool { !fetching(now: now) && !simplifying(now: now) }

    /// 栏上那一行字该说什么
    public enum Line: Equatable, Sendable {
        case none
        case fetching
        case fetchFailed(String)
        case fetchSilent
        case simplifying
        case simplified(note: String)
        case simplifyFailed(String)
        case simplifySilent
    }

    public func line(now: Date) -> Line {
        if fetching(now: now) { return .fetching }
        if simplifying(now: now) { return .simplifying }
        if simplify == .done, let n = simplifiedNote { return .simplified(note: n) }
        if simplify == .failed { return .simplifyFailed(simplifyError ?? "") }
        if simplify == .working { return .simplifySilent }
        if fetch == .failed { return .fetchFailed(fetchError ?? "") }
        if fetch == .fetching { return .fetchSilent }
        return .none
    }

    public mutating func startFetch(id: String, now: Date) {
        fetch = .fetching; fetchID = id; fetchSentAt = now; fetchError = nil
    }

    /// 扒正文的回信。id 不是最新那次的忽略。返回要不要换正文
    @discardableResult
    public mutating func fetchReply(id: String, ok: Bool, error: String?) -> Bool {
        guard fetch == .fetching, fetchID == id else { return false }
        if ok { fetch = .ready; fetchError = nil } else { fetch = .failed; fetchError = (error ?? "").isEmpty ? "大管家没扒成" : error }
        return ok
    }

    public mutating func startSimplify(id: String, now: Date) {
        simplify = .working; simplifyID = id; simplifySentAt = now; simplifyError = nil; simplifiedNote = nil
    }

    public mutating func simplifyReply(id: String, ok: Bool, error: String?) {
        guard simplify == .working, simplifyID == id else { return }
        if ok { simplify = .done } else { simplify = .failed; simplifyError = (error ?? "").isEmpty ? "大管家没简写成" : error }
    }

    /// 简写出来的一篇听力送到了（request 是简写那封信的 id）：记第一篇，栏上变成「简写好了」
    public mutating func pieceArrived(request: String, note: String) {
        guard simplifyID == request else { return }
        if simplifiedNote == nil { simplifiedNote = note }
        simplify = .done
        simplifyError = nil
    }

    public func encoded() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    public static func decode(_ s: String) -> ArticleState {
        guard !s.isEmpty, let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(ArticleState.self, from: d) else { return ArticleState() }
        return v
    }
}
