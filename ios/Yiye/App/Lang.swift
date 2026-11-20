import Foundation
import Observation

/// 中文 / English：跟 iPhone 系统语言走（Song 的手机是英文，所以默认英文）；设置里切了就记住，立刻生效，不用重启。
/// 字都在 Localizable.xcstrings，编出来是 en.lproj、zh-Hans.lproj，这里按选的语言直接去那个 lproj 里查。
@MainActor @Observable
final class Lang {
    /// 「system」= 跟系统；或者 "zh-Hans" / "en"
    private(set) var choice: String
    /// 现在实际用的：zh-Hans 或 en
    private(set) var code: String
    @ObservationIgnored private var bundles: [String: Bundle] = [:]
    @ObservationIgnored private let persist: Bool

    init(forced: String?) {
        persist = forced == nil
        let saved = forced ?? UserDefaults.standard.string(forKey: "yiye.lang") ?? "system"
        choice = saved
        code = Lang.resolve(saved)
    }

    static func resolve(_ c: String) -> String {
        if c == "zh-Hans" || c == "en" { return c }
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    func set(_ c: String) {
        choice = c
        if persist { UserDefaults.standard.set(c, forKey: "yiye.lang") }
        code = Lang.resolve(c)
    }

    var isZh: Bool { code == "zh-Hans" }
    var locale: Locale { Locale(identifier: isZh ? "zh_Hans_CN" : "en_US") }

    private func bundle(_ c: String) -> Bundle {
        if let b = bundles[c] { return b }
        let b = Bundle.main.path(forResource: c, ofType: "lproj").flatMap { Bundle(path: $0) } ?? Bundle.main
        bundles[c] = b
        return b
    }

    /// 查一条字（读 code，界面跟着语言变）
    func t(_ key: String) -> String {
        let miss = "\u{1}"
        let s = bundle(code).localizedString(forKey: key, value: miss, table: "Localizable")
        if s != miss { return s }
        let e = bundle("en").localizedString(forKey: key, value: miss, table: "Localizable")
        return e == miss ? key : e
    }

    /// 带参数的：%@、%lld
    func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }
}
