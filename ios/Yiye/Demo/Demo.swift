import SwiftUI
import UIKit
import AVFoundation
import YiyeKit

/// 截图用：启动参数 -YiyeDemo YES -YiyeScreen list -YiyeLang zh-Hans -YiyeAppearance dark
/// 数据只放在内存里，镜像是一个临时文件夹，大管家的心跳是造的
struct DemoConfig {
    var screen: String
    var lang: String
    var scheme: ColorScheme
    /// 截图用：-YiyeAppearancePref paper|dark，模拟用户在设置里选了外观（有它就不强压 scheme，让设置说了算）
    var appearancePref: String?

    var forcedScheme: ColorScheme? { appearancePref == nil ? scheme : nil }

    var shareTheme: String? {
        switch screen {
        case "share-white": return "white"
        case "share-note": return "note"
        default: return nil
        }
    }

    static func fromLaunch() -> DemoConfig? {
        let d = UserDefaults.standard
        guard d.bool(forKey: "YiyeDemo") else { return nil }
        return DemoConfig(screen: d.string(forKey: "YiyeScreen") ?? "list",
                          lang: d.string(forKey: "YiyeLang") ?? "en",
                          scheme: d.string(forKey: "YiyeAppearance") == "dark" ? .dark : .light,
                          appearancePref: d.string(forKey: "YiyeAppearancePref"))
    }
}

@MainActor
enum Demo {
    /// 截图用：一段没声音的录音（时长对就行）
    static func silence(_ store: AttachmentStore, name: String, seconds: Double) -> String? {
        let url = store.url("\(MirrorFolder.attachName)/\(name)")
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(16_000 * seconds)) else { return nil }
        buf.frameLength = buf.frameCapacity
        do { try file.write(from: buf) } catch { return nil }
        return "\(MirrorFolder.attachName)/\(name)"
    }

    static func seed(_ app: AppModel, _ cfg: DemoConfig) {
        let zh = cfg.lang == "zh-Hans"
        let ctx = app.context
        // 笔记的时间按「今天 9:41」算（列表上显示几点，不显示「昨天」）；心跳按真的现在（显示在线）
        let now = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()

        // 镜像：临时文件夹；心跳：一分钟前来过 → 在线
        let mirrorRoot = FileManager.default.temporaryDirectory.appendingPathComponent("demo-mirror/\(MirrorService.folderName)", isDirectory: true)
        app.mirror.useDemo(mirrorRoot)
        if let ch = app.mirror.channel {
            let hb = #"{ "v": 1, "at": "\#(ISOTime.string(Date().addingTimeInterval(-60)))", "host": "掌机", "model": "claude-opus-5-5" }"#
            try? ch.fs.write(Data(hb.utf8), to: ch.heartbeatURL)
        }
        app.butler.presence = .online

        let work = Folder(name: zh ? "工作" : "Work", order: 0)
        let home = Folder(name: zh ? "家里" : "Home", order: 1)
        ctx.insert(work); ctx.insert(home)

        func add(_ md: String, ago: Double, folder: Folder? = nil, pinned: Bool = false, paper: PaperTint = .white, kind: String = "text") -> Note {
            let n = Note()
            n.markdown = md
            n.createdAt = now.addingTimeInterval(-ago - 3600)
            n.modifiedAt = now.addingTimeInterval(-ago)
            n.folder = folder
            n.pinned = pinned
            n.paper = paper.rawValue
            n.kind = kind
            ctx.insert(n)
            return n
        }

        let groceries = add(zh ? "# 周末采购\n- 牛奶 2盒\n- 鸡蛋 1盒\n- 洗衣液\n- **猫粮** 别忘了"
                               : "# Weekend groceries\n- Milk 2\n- Eggs 12\n- Detergent\n- **Cat food** don't forget",
                            ago: 60 * 40, folder: home, pinned: true, paper: .yellow)
        _ = groceries

        // 拍照的那条：大管家改过了
        let sent = zh ? "# 11月3日交接\nA线早班 128O件\nB线早班 960件\n□班交接完毕，3号机换了刀\n冷却液快没了，晚班记得加"
                      : "# Handover, Nov 3\nLine A morning 128O pcs\nLine B morning 960 pcs\nMorning sh1ft done, new blade on #3\nCoolant is low, night shift top it up"
        let fixed = zh ? "# 11月3日交接\nA线早班 1,280件\nB线早班 960件\n早班交接完毕，3号机换了刀\n冷却液快没了，晚班记得加"
                       : "# Handover, Nov 3\nLine A morning 1,280 pcs\nLine B morning 960 pcs\nMorning shift done, new blade on #3\nCoolant is low, night shift top it up"
        let photo = add(sent, ago: 60 * 12, folder: work, kind: "photo")
        if let url = Bundle.main.url(forResource: "handover", withExtension: "jpg"), let data = try? Data(contentsOf: url),
           let rel = try? app.attachments.save(data, name: "\(MirrorFormat.shortID(photo.id))-原图-1.jpg") {
            photo.originalPaths = [rel]
        }
        var st = ButlerNoteState()
        st.submitted(id: UUID().uuidString, text: sent, at: now.addingTimeInterval(-60 * 12))
        let result = ButlerResult(id: st.requestID ?? "", note: photo.id.uuidString, ok: true, text: fixed,
                                  changes: zh ? "改了 2 处：128O→1,280，□班→早班" : "2 fixes: 128O→1,280, sh1ft→shift", error: nil)
        if let text = st.receive(result, current: sent) { photo.markdown = text }
        photo.butlerState = st

        let mdNote = add(zh ? "# 周会\n## 进度\n- A线 1280件\n- B线 960件\n> 冷却液快没了，晚班记得加\n**周五**之前把报表交上来。\n<center>就这些</center>"
                            : "# Weekly sync\n## Progress\n- Line A 1280 pcs\n- Line B 960 pcs\n> Coolant is low, night shift top it up\nReports due by **Friday**.\n<center>That's it</center>",
                         ago: 60 * 3, folder: work)
        let plain = add(zh ? "明天早上8点开会\n地点：二楼会议室\n带上本周的报表，顺便问问食堂下周换不换菜单。"
                           : "Team lunch Friday 12:30\nPlace: Noodle House\nBring the Q4 numbers and ask about the new menu.",
                        ago: 60 * 60 * 26)
        _ = add(zh ? "读书\n《置身事内》第三章\n地方政府的钱从哪来" : "Reading list\nThe Design of Everyday Things\nChapter 3 tonight",
                ago: 60 * 60 * 24 * 9, folder: home, paper: .green)
        // 录的那条：上面录音，下面字（大管家理过了）
        let voice = add(zh ? "周会安排\n明天上午九点在二楼会议室开周会，记得把上周的报表带上。\n冷却液快没了，晚班记得加。"
                           : "Tomorrow's sync\nTomorrow at nine in room two. Bring last week's report.\nCoolant is low, night shift top it up.",
                        ago: 60 * 5, folder: work, paper: .yellow, kind: "voice")
        if let rel = Demo.silence(app.attachments, name: VoiceText.fileName(note: voice.id, index: 1), seconds: 23) {
            voice.audioPaths = [rel]
        }
        // 米黄纸：深色模式下也是米黄；交给大管家了，横条写着几点交的
        var vst = ButlerNoteState()
        vst.submitted(id: UUID().uuidString, text: voice.markdown, at: now.addingTimeInterval(-60 * 4))
        voice.butlerState = vst
        // 听力：三篇英语新闻（大管家配好音送来的样子），每篇一段没声音的录音 + 每句表。
        // 088 跨两天：今天两篇、昨天一篇，时间照每日简讯（那天 08:00 减第几篇的秒数）
        let english = Folder(name: zh ? "英语" : "English", order: 2)
        ctx.insert(english)
        let stories = [
            "# Bitcoin falls below $62,000\nBitcoin fell below 62,000 dollars on Monday. That is the lowest price since March. Many people sold bitcoin funds this week. A fund is a basket of investments that many people put money into. When people sell the funds, the price can drop fast.",
            "# Spain calls a snap election\nSpain will vote on November 29. A snap election means an early election. The prime minister called it after he lost a key vote. Polymarket gives the opposition leader an 87 percent chance to win.",
            "# Google leads the AI race\nGoogle released Gemini 4 last week. Many testers say it is the best AI model right now. On Polymarket, people give Google an 88 percent chance to have the best model at the end of the year.",
        ]
        var listenFirst: UUID?
        for (k, text) in stories.enumerated() {
            let n = add(text, ago: Double(60 * (20 + k * 30)), folder: english, kind: "listen")
            let eight = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
            n.createdAt = k < 2 ? eight.addingTimeInterval(-Double(k + 1)) : eight.addingTimeInterval(-86_400 - 1)
            n.modifiedAt = n.createdAt
            let sentences = Listen.sentences(text)
            let marks = sentences.enumerated().map { ListenMark(t: Double($0.offset) * 4.5, s: $0.element) }
            if let rel = Demo.silence(app.attachments, name: Listen.deliveryName(note: n.id, ext: "m4a"), seconds: Double(sentences.count) * 4.5) {
                n.audioPaths = [rel]
                app.setMarks(n, path: rel, marks: marks)
            }
            n.inListen = true
            if k == 2 { n.heardAt = Date().addingTimeInterval(-2 * 86_400) }       // 听完的那篇淡一点（112）
            if k == 0 { listenFirst = n.id }
        }
        // 刚放进听力、交给大管家配音还没回来的一篇
        let waiting = add("# Oil prices climb again\nOil prices rose 3 percent on Tuesday. Winter is coming, and people need more fuel to heat their homes.",
                          ago: 60 * 8, folder: english, kind: "listen")
        waiting.createdAt = now.addingTimeInterval(-60 * 8)
        waiting.inListen = true
        waiting.dub = "\(UUID().uuidString)|\(ISOTime.string(now.addingTimeInterval(-60 * 6)))"
        // 没配上音、也没在等配音的一篇（112）：inListen 是 false 也要在听力里，挂「重配」
        let nodub = add("# Gold hits a record high\nGold rose to a record on Tuesday as buyers looked for a safe place for their money.",
                        ago: 60 * 75, folder: english, kind: "listen")
        nodub.createdAt = now.addingTimeInterval(-60 * 75)
        // 思想排泄物（抄一份到电脑，开着）：两条
        let thoughts = Folder(name: "思想排泄物", order: 3)
        ctx.insert(thoughts)
        _ = add(zh ? "# 要是下班路上能把想到的全吐出来\n不整理，先丢在这儿。" : "# What if I could dump every thought on the way home\nNo sorting. Just drop it here.",
                ago: 60 * 50, folder: thoughts)
        _ = add(zh ? "# 工厂的灯为什么总是太白\n换一盏暖的试试。" : "# Why is the factory light always too white\nTry a warmer one.",
                ago: 60 * 60 * 30, folder: thoughts)
        // 废纸篓：三条，剩的天数不一样（后天、明天、今天化掉）
        for (k, hours) in [(0, 20.0), (1, 36.0), (2, 62.0)] {
            let gone = add(zh ? ["# 旧的采购单\n牛奶 3 盒", "# 作废的会议\n改到下周", "# 草稿\n随手写的"][k]
                              : ["# Old shopping list\nMilk x3", "# Cancelled meeting\nMoved to next week", "# Scrap\nJust a doodle"][k],
                           ago: 60 * 60 * 80, folder: home)
            gone.trashed = true
            gone.trashedAt = Date().addingTimeInterval(-hours * 3600)
        }
        try? ctx.save()

        switch cfg.screen {
        case "batch":
            // 批量选：选中前三条（由列表自己读 demo.screen 进入）
            break
        case "editor": app.path = [.editor(plain.id)]
        case "markdown": app.path = [.editor(mdNote.id)]
        case "share-note", "share-white", "butler": app.path = [.editor(photo.id)]
        case "settings": app.path = [.settings]
        case "voice": app.voiceTarget = .new
        case "listen": app.listening = ListenOpen(startNote: listenFirst)
        case "listen-loop":
            app.settings.listenLoopAll = true
            app.listening = ListenOpen(startNote: listenFirst)
        case "listen-text": app.listening = ListenOpen(startNote: listenFirst, showText: true)
        case "voice-note": app.path = [.editor(voice.id)]
        case "ocr":
            let name = zh ? "ocr-demo-zh" : "ocr-demo-en"
            if let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let img = UIImage(contentsOfFile: url.path) {
                app.recognize(img)
            }
        default: break
        }
    }
}
