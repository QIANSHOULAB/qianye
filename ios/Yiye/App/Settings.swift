import Foundation
import Observation

enum SortMode: String, CaseIterable {
    case modifiedNew, modifiedOld, created
}

/// 设置：字号、排序、当前文件夹、大管家自动交、第一次问过镜像没有
@MainActor @Observable
final class Settings {
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let d = UserDefaults.standard

    /// 0 小、1 中、2 大
    var fontSize: Int { didSet { save("yiye.fontSize", fontSize) } }
    var sort: SortMode { didSet { save("yiye.sort", sort.rawValue) } }
    /// "" = 全部
    var folderID: String { didSet { save("yiye.folder", folderID) } }
    var butlerAutoPhoto: Bool { didSet { save("yiye.butlerAuto", butlerAutoPhoto) } }
    var mirrorAsked: Bool { didSet { save("yiye.mirrorAsked", mirrorAsked) } }
    /// 说话用的语言（录一段转字用）：zh-CN / en-US
    var voiceLang: String { didSet { save("yiye.voiceLang", voiceLang) } }
    /// 文档相机上次没正常关（多半是闪退了）：以后换成自己做的相机
    var useFallbackCamera: Bool { didSet { save("yiye.fallbackCam", useFallbackCamera) } }

    init(persist: Bool) {
        self.persist = persist
        let d = UserDefaults.standard
        fontSize = persist ? (d.object(forKey: "yiye.fontSize") as? Int ?? 1) : 1
        sort = persist ? (SortMode(rawValue: d.string(forKey: "yiye.sort") ?? "") ?? .modifiedNew) : .modifiedNew
        folderID = persist ? (d.string(forKey: "yiye.folder") ?? "") : ""
        butlerAutoPhoto = persist ? (d.object(forKey: "yiye.butlerAuto") as? Bool ?? true) : true
        mirrorAsked = persist ? d.bool(forKey: "yiye.mirrorAsked") : true
        voiceLang = persist ? (d.string(forKey: "yiye.voiceLang") ?? "zh-CN") : "zh-CN"
        useFallbackCamera = persist ? d.bool(forKey: "yiye.fallbackCam") : false
    }

    private func save(_ key: String, _ v: Any) {
        guard persist else { return }
        d.set(v, forKey: key)
    }
}
