import Foundation
import Observation
import YiyeKit

enum SortMode: String, CaseIterable {
    case modifiedNew, modifiedOld
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
    /// 听力：每篇放几遍（0 = 一直放）、倍速
    var listenRepeat: Int { didSet { save("yiye.listenRepeat", listenRepeat) } }
    var listenRate: Double { didSet { save("yiye.listenRate", listenRate) } }
    /// 大管家送来的、已经收过的 id（iCloud 偶尔把删掉的文件同步回来，不收第二次）
    var deliveredIDs: [String] { didSet { save("yiye.delivered", deliveredIDs) } }
    /// 文档相机上次没正常关（多半是闪退了）：以后换成自己做的相机
    var useFallbackCamera: Bool { didSet { save("yiye.fallbackCam", useFallbackCamera) } }
    /// 插图上下空一格（默认），还是靠拢（Song 11-22）
    var imageGap: Bool { didSet { save("yiye.imageGap", imageGap) } }
    /// 088：老的听力稿补进听力，跑过了
    var listenBackfilled: Bool { didSet { save("yiye.listenBackfill088", listenBackfilled) } }
    /// 111：老的「思想排泄物」夹子打开「抄一份到电脑」，跑过了
    var deskMigrated: Bool { didSet { save("yiye.deskMigrated111", deskMigrated) } }
    /// 112：整串循环（最后一条放完回到第一条）。默认关，记住
    var listenLoopAll: Bool { didSet { save("yiye.listenLoopAll", listenLoopAll) } }
    /// 144：🔁 开着时哪几天在循环里（"yyyy-MM-dd"，"*" = 全亮）、这套亮法是哪天定的（换一天回到只亮今天）
    var listenLoopDays: [String] { didSet { save("yiye.listenLoopDays", listenLoopDays) } }
    var listenLoopDay: String { didSet { save("yiye.listenLoopDay", listenLoopDay) } }
    /// 222：原文页「跟着放」（正在放的那句自己滚到中间）。默认开，记住
    var listenFollow: Bool { didSet { save("yiye.listenFollow", listenFollow) } }

    /// 144：🔁 和亮着的天，合成一个
    var listenLoop: ListenLoop {
        get { ListenLoop(on: listenLoopAll, lit: Set(listenLoopDays), litDay: listenLoopDay) }
        set {
            if listenLoopAll != newValue.on { listenLoopAll = newValue.on }
            let days = newValue.lit.sorted()
            if listenLoopDays != days { listenLoopDays = days }
            if listenLoopDay != newValue.litDay { listenLoopDay = newValue.litDay }
        }
    }
    /// 139：锁着屏接通过「叫大管家」（锁屏喊得回来）：答完 60 秒没话自己挂才开
    var callLockOK: Bool { didSet { save("yiye.callLockOK", callLockOK) } }
    /// 139：挂了以后才答好的（标题），下次接通先提一句
    var callCarry: [String] { didSet { save("yiye.callCarry", callCarry) } }
    /// 136：书童自己收拾新便签（默认开）
    var shutongAuto: Bool { didSet { save("yiye.shutongAuto", shutongAuto) } }
    /// 136：每周日的清理建议上次是哪一周问的（"2026-W48"）、那张纸条他关了没有
    var shutongSweepWeek: String { didSet { save("yiye.shutongSweepWeek", shutongSweepWeek) } }

    init(persist: Bool) {
        self.persist = persist
        let d = UserDefaults.standard
        fontSize = persist ? (d.object(forKey: "yiye.fontSize") as? Int ?? 1) : 1
        sort = persist ? (SortMode(rawValue: d.string(forKey: "yiye.sort") ?? "") ?? .modifiedNew) : .modifiedNew
        folderID = persist ? (d.string(forKey: "yiye.folder") ?? "") : ""
        butlerAutoPhoto = persist ? (d.object(forKey: "yiye.butlerAuto") as? Bool ?? true) : true
        mirrorAsked = persist ? d.bool(forKey: "yiye.mirrorAsked") : true
        voiceLang = persist ? (d.string(forKey: "yiye.voiceLang") ?? "zh-CN") : "zh-CN"
        listenRepeat = persist ? (d.object(forKey: "yiye.listenRepeat") as? Int ?? 3) : 3
        listenRate = persist ? (d.object(forKey: "yiye.listenRate") as? Double ?? 1) : 1
        deliveredIDs = persist ? (d.stringArray(forKey: "yiye.delivered") ?? []) : []
        useFallbackCamera = persist ? d.bool(forKey: "yiye.fallbackCam") : false
        imageGap = persist ? (d.object(forKey: "yiye.imageGap") as? Bool ?? true) : true
        listenBackfilled = persist ? d.bool(forKey: "yiye.listenBackfill088") : true
        deskMigrated = persist ? d.bool(forKey: "yiye.deskMigrated111") : true
        let loopAll = persist ? d.bool(forKey: "yiye.listenLoopAll") : false
        listenLoopAll = loopAll
        // 144：没存过亮法的（112 的老设置）：整串循环开着的迁成 🔁 开着、全亮
        let today = ListenLoop.key(Date())
        let loaded = ListenLoop.load(loopAll: loopAll,
                                     lit: persist ? d.stringArray(forKey: "yiye.listenLoopDays") : nil,
                                     litDay: persist ? d.string(forKey: "yiye.listenLoopDay") : nil, today: today)
        listenLoopDays = loaded.lit.sorted()
        listenLoopDay = loaded.litDay
        listenFollow = persist ? (d.object(forKey: "yiye.listenFollow") as? Bool ?? true) : true
        callLockOK = persist ? d.bool(forKey: "yiye.callLockOK") : false
        callCarry = persist ? (d.stringArray(forKey: "yiye.callCarry") ?? []) : []
        shutongAuto = persist ? (d.object(forKey: "yiye.shutongAuto") as? Bool ?? true) : true
        shutongSweepWeek = persist ? (d.string(forKey: "yiye.shutongSweepWeek") ?? "") : ""
        // 144：迁过来的亮法当场存下，明天才会照规矩翻回只亮今天
        if persist, d.object(forKey: "yiye.listenLoopDays") == nil {
            d.set(listenLoopDays, forKey: "yiye.listenLoopDays")
            d.set(listenLoopDay, forKey: "yiye.listenLoopDay")
        }
    }

    private func save(_ key: String, _ v: Any) {
        guard persist else { return }
        d.set(v, forKey: key)
    }
}
