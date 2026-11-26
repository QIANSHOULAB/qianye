import Foundation

/// 195 网址认出来能点、能单独拷：小书童气泡、便签正文、项目待办（也是便签）用同一套认法。
/// 只认网页：http(s)://、www. 开头，或者常见后缀的裸域名（claude.ai/x）。文件名（app.py、config.local.toml）不认。
public struct FoundLink: Equatable, Sendable {
    /// 在原文里的位置（UTF-16，跟 NSString 一样）
    public let range: NSRange
    public let url: URL

    public init(range: NSRange, url: URL) {
        self.range = range
        self.url = url
    }
}

public enum Links {
    /// 网址里能出现的字（只认英文那套：中文、中文标点一挨上就断）
    static let tail = #"(?::\d+)?(?:[/?#][A-Za-z0-9\-._~:/?#\[\]@!\$\&'()*+,;=%|\{\}\^]*)?"#
    /// http(s):// 开头；www. 开头；常见后缀的裸域名（.py、.app、.md 这些常是文件名，不认）
    static let pattern = #"(?<![A-Za-z0-9@._\-/])(?:https?://[A-Za-z0-9\-._~%]+\#(tail)|www\.[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+\#(tail)|(?:[A-Za-z0-9\-]+\.)+(?:com|cn|net|org|ai|io|dev|me|hk|sg|jp|uk)(?![A-Za-z0-9\-@]|\.[A-Za-z0-9])\#(tail))"#
    private static let finder = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    public static func find(_ text: String) -> [FoundLink] {
        guard text.contains("."), let finder else { return [] }
        let ns = text as NSString
        var out: [FoundLink] = []
        for m in finder.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let piece = trim(ns.substring(with: m.range))
            let lower = piece.lowercased()
            let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
            guard let url = URL(string: hasScheme ? piece : "https://" + piece), url.host?.isEmpty == false else { continue }
            out.append(FoundLink(range: NSRange(location: m.range.location, length: (piece as NSString).length), url: url))
        }
        return out
    }

    /// 句子末尾的标点、多出来的右括号不算网址的
    static func trim(_ raw: String) -> String {
        var s = raw
        while let last = s.last {
            if ".,;:!?'".contains(last) {
                s.removeLast()
                continue
            }
            if let open = ["}": "{", "]": "[", ")": "("][String(last)],
               s.filter({ String($0) == open }).count < s.filter({ $0 == last }).count {
                s.removeLast()
                continue
            }
            break
        }
        return s
    }

    /// 续登那种登录网址（claude.ai 的 /oauth/authorize）：气泡里旁边给一个「打开」
    public static func isSignIn(_ url: URL) -> Bool {
        url.path.contains("/oauth/authorize")
    }

    /// 一段话里的登录网址（同一个只给一次）
    public static func signIns(_ text: String) -> [URL] {
        var seen: Set<URL> = []
        return find(text).map(\.url).filter { isSignIn($0) && seen.insert($0).inserted }
    }
}
