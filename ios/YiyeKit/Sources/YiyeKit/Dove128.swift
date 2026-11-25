import Foundation

// 128 飞鸽传书：API 钥匙从手机经加密信箱直接交给大管家，不走 Telegram；大管家递回来的一次性东西是「特勤局机密文件」，阅后即焚。
// 这里是不碰界面的那部分：钥匙怎么遮、看着像谁家的、请求长什么样、回信怎么读、机密文件那张卡。
// 钥匙本身只在两处出现：手机寄出前的那一下（内存）、大管家的 keys/。别处一律没有：不存便签、不进镜像、不进日志、不进截图。

public enum Dove {
    /// 复制了机密文件以后，剪贴板自己清掉的秒数（系统的 expirationDate，app 被挂起也照清）
    public static let clearAfter: TimeInterval = 120

    /// 粘贴来的字：所有空白（空格、换行、制表）都去掉
    public static func clean(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    /// 屏幕上只露这一行：前后 4 位（短的 2 位），中间一个省略号。比 4 位加 4 位还短的不露，用点代替
    public static func masked(_ pasted: String) -> String {
        let k = clean(pasted)
        if k.isEmpty { return "" }
        let n = k.count >= 16 ? 4 : 2
        guard k.count > n * 2 else { return String(repeating: "•", count: k.count) }
        return "\(k.prefix(n))…\(k.suffix(n))"
    }

    /// 看开头认是哪家的（跟大管家 actions/keys.py 的 PREFIXES 一个意思）。认不出 nil。只是灰字提示，不替他填
    public static func guess(_ pasted: String) -> String? {
        let k = clean(pasted)
        let table: [(String, String)] = [("github_pat_", "GitHub"), ("secret_", "Notion"), ("ghp_", "GitHub"), ("ntn_", "Notion"), ("xai-", "xAI"),
                                         ("AIza", "Gemini"), ("sk-", "OpenAI"), ("sk_", "ElevenLabs"), ("AQ.", "Gemini")]
        for (prefix, name) in table where k.hasPrefix(prefix) { return name }
        if k.range(of: #"^\d{5,}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil { return "Telegram" }
        return nil
    }

    /// 点「发送」要不要放行：有钥匙、没在寄
    public static func canSend(key: String, sending: Bool) -> Bool {
        !sending && !clean(key).isEmpty
    }
}

extension ButlerRequest {
    /// 飞鸽传书的请求（接口 v3.8）：钥匙放 key，text 留空；name 是他打的那行（空的当没有）。note 空：不是任何一条便签
    public static func dove(id: String, key: String, name: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "key", at: at, app: app)
        r.key = Dove.clean(key)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.name = n.isEmpty ? nil : String(n.prefix(40))
        return r
    }
}

extension ButlerRequest {
    /// 「收到」备用信箱配置（130）：大管家收到后记下，不再递
    /// 158：大管家的话收到了（回执）：note 是那封送来的 id
    public static func tellOK(id: String, of tell: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: tell, kind: .text, text: "", images: nil, unsure: nil, ask: "tell-ok", at: at, app: app)
    }

    public static func fbConfigOK(id: String, of cfg: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "fb-config-ok", at: at, app: app)
        r.of = cfg
        return r
    }
}

/// 大管家对一把钥匙的回信：ok = 存了；line 是要显示的那句（ok 时是 text，不 ok 时是 error）
public struct DoveReply: Equatable, Sendable {
    public var ok: Bool
    public var line: String

    public init(ok: Bool, line: String) { self.ok = ok; self.line = line }

    public static func from(_ r: ButlerResult) -> DoveReply {
        if r.ok { return DoveReply(ok: true, line: r.text ?? "") }
        return DoveReply(ok: false, line: r.error ?? "")
    }
}

/// 大管家递来的一次性东西（kind=secret 的 delivery）：只在内存里，弹一张卡，关了就没了
public struct SecretCard: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var hint: String

    public init(id: String, title: String, text: String, hint: String) {
        self.id = id; self.title = title; self.text = text; self.hint = hint
    }

    public static func from(_ d: ButlerDelivery) -> SecretCard? {
        guard d.kind == "secret" else { return nil }
        let t = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return SecretCard(id: d.id, title: d.title ?? "", text: t, hint: d.hint ?? "")
    }
}
