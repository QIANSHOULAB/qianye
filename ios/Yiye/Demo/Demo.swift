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
                          scheme: d.string(forKey: "YiyeAppearance") == "dark" ? .dark : .light)
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
        // 截图每次一样：笔记的时间按固定的「现在」算；心跳按真的现在（显示在线）
        let now = ISOTime.date("2026-11-20T09:41:00+08:00") ?? Date()

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
                        ago: 60 * 5, folder: work, kind: "voice")
        if let rel = Demo.silence(app.attachments, name: VoiceText.fileName(note: voice.id, index: 1), seconds: 23) {
            voice.audioPaths = [rel]
        }
        try? ctx.save()

        switch cfg.screen {
        case "editor": app.path = [.editor(plain.id)]
        case "markdown": app.path = [.editor(mdNote.id)]
        case "share-note", "share-white", "butler": app.path = [.editor(photo.id)]
        case "settings": app.path = [.settings]
        case "voice": app.voiceTarget = .new
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
