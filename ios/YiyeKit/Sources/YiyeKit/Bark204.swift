import Foundation

// 204 一叶笺关着也有提醒：一叶笺是免费账号侧载的，苹果不给推送，提醒由大管家发给手机上的 Bark（pc-butler handheld/bark.py）。
// 这里是不碰界面的那部分：提醒里点开的链接怎么认、Bark 响过的话手机自己要不要再弹、「提醒里显示内容」那把钥匙怎么生成。接口 v3.20。

/// 提醒里带的链接：yiye://shutong?id=<那封来话的 id>（进小书童、滚到那条）、yiye://todo（进项目待办）、
/// yiye://bot?id= / yiye://group?id=（250：进那个机器人、那个群）；252：bot 后面可带 &msg=（滚到那一句）
public enum YiyeLink: Equatable, Sendable {
    case shutong(id: String?)
    case todo
    case bot(id: String, msg: String? = nil)
    case group(id: String)

    public static let scheme = "yiye"

    public static func parse(_ url: URL) -> YiyeLink? {
        guard url.scheme?.lowercased() == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.host?.lowercased() {
        case "shutong":
            let id = parts.queryItems?.first { $0.name == "id" }?.value ?? ""
            return .shutong(id: id.isEmpty ? nil : id)
        case "todo":
            return .todo
        case "bot", "group":
            guard let id = parts.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { return nil }
            let msg = parts.queryItems?.first(where: { $0.name == "msg" })?.value ?? ""
            return parts.host?.lowercased() == "bot" ? .bot(id: id, msg: msg.isEmpty ? nil : msg) : .group(id: id)
        default:
            return nil
        }
    }
}

/// Bark 响过的话，一叶笺自己的本地通知（158、162）就不再弹，免得一条消息响两回
public enum BarkNotice {
    /// 记在手机上：大管家最近一封来话说没说它同时发了 Bark（那台装着钥匙、开关开着才说）
    public static let key = "yiye.bark.on"

    /// 一封来话（kind=tell）到了：记下大管家这会儿发不发 Bark。返回手机自己要不要弹
    @discardableResult
    public static func heard(bark: Bool?, in d: UserDefaults) -> Bool {
        d.set(bark == true, forKey: key)
        return bark != true
    }

    /// 项目待办 +1 的信里不带这个记号：看上一封来话说的
    public static func todoNeedsLocal(in d: UserDefaults) -> Bool {
        !d.bool(forKey: key)
    }
}

/// 「提醒里显示内容」：手机生成一把 16 个字符的钥匙（AES-128-CBC，Bark 的「加密设置」里照填），经飞鸽传书交给大管家；
/// 关掉就寄一个 off。钥匙只在手机钥匙串、大管家 keys/、Bark 里
public enum BarkSecret {
    /// 飞鸽传书的名字行（大管家认 bark加密）
    public static let name = "bark加密"
    public static let off = "off"
    public static let length = 16
    /// 复制到剪贴板以后留几秒（要切到 Bark 去粘）
    public static let clipboardSeconds: TimeInterval = 600
    /// 没有长得像的（0 O、1 l I）：万一得手抄也认得出
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789")

    public static func make<G: RandomNumberGenerator>(using g: inout G) -> String {
        String((0..<length).map { _ in alphabet.randomElement(using: &g)! })
    }

    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return make(using: &g)
    }
}

extension ButlerRequest {
    /// 把加密钥匙（或者 off）交给大管家：就是一封飞鸽传书
    public static func barkSecret(id: String, key: String, at: String, app: String) -> ButlerRequest {
        dove(id: id, key: key, name: BarkSecret.name, at: at, app: app)
    }
}
