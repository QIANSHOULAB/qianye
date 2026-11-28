import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers
import YiyeKit

/// 204 一叶笺这头的 Bark：从提醒点进来开哪儿；「提醒里显示内容」开关（生成钥匙，经飞鸽传书那条加密通道交给大管家，
/// 同时拷一份给他粘进 Bark）。钥匙只在钥匙串里，不进 UserDefaults、不进便签、不进日志、不进截图
@MainActor @Observable
final class BarkModel {
    static let shared = BarkModel()

    private static let onKey = "yiye.bark.content"
    private static let waitingKey = "yiye.bark.waiting"
    private static let account = "bark.content"

    /// 开关开着没有
    private(set) var showContent = false
    /// 开关下面那一行：大管家回的话、信还在路上、没寄出去为什么
    private(set) var said = ""
    private(set) var sending = false
    /// 从提醒点进来要滚到哪条来话（那封的 id）；滚到了、或者小书童收了就清掉
    var focus: String?

    @ObservationIgnored private weak var app: AppModel?
    /// 在等大管家回话的那封："请求 id|on" 或 "请求 id|off"（记着：回信可能在下次打开才到）
    @ObservationIgnored private var waiting: String?

    private var demo: Bool { app?.demo != nil }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }

    func start(_ app: AppModel) {
        self.app = app
        guard app.demo == nil else {
            if app.demo?.screen == "settings-bark" {           // 截图用：开着、大管家回过话的样子
                showContent = true
                said = demoLine
            }
            return
        }
        showContent = UserDefaults.standard.bool(forKey: Self.onKey)
        waiting = UserDefaults.standard.string(forKey: Self.waitingKey)
    }

    // ---------------------------------------------------------------- 截图 / UI 测试
    /// -YiyeScreen link-shutong / link-todo：装作从提醒点进来
    func demoLink(_ screen: String) {
        guard let app, app.demo != nil else { return }
        let zh = app.lang.isZh
        if screen == "link-shutong" {
            ShutongModel.shared.lines = (1...30).map { i in
                var l = ShutongLine(who: "butler", text: zh ? "第 \(i) 条来话" : "Message \(i)")
                l.rid = "demo-204-\(i)"
                l.at = Date().addingTimeInterval(Double(i - 40) * 60)
                return l
            }
            if let u = URL(string: "yiye://shutong?id=demo-204-3") { app.openLink(u) }
        } else {
            TodoDesk.shared.demo(zh: zh)                       // 两条待办寄到
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let u = URL(string: "yiye://todo") { app.openLink(u) }
            }
        }
    }

    // ---------------------------------------------------------------- 开关
    func set(_ on: Bool) {
        guard let app, on != showContent, !sending else { return }
        let id = UUID().uuidString
        let key: String
        if on {
            key = BarkSecret.make()
            if !demo { Keychain.write(Data(key.utf8), Self.account) }
            copy(key)
        } else {
            key = BarkSecret.off
        }
        showContent = on
        sending = true
        said = t("bark.sending")
        waiting = "\(id)|\(on ? "on" : "off")"
        save()
        if demo {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.sending = false
                _ = self.answered(ButlerResult(id: id, note: "", ok: true, text: on ? self.demoLine : self.t("bark.demoOff"),
                                               changes: nil, error: nil, stage: "key"))
            }
            return
        }
        Task {
            let sent = await app.butler.sendKey(key: key, name: BarkSecret.name, id: id)
            self.sending = false
            guard self.waiting?.hasPrefix(id) == true else { return }          // 回信比这一句还快
            switch sent {
            case .sent(let pc):
                self.said = self.t(pc ? "bark.waiting" : "bark.queued")
            case .noPair:
                self.revert(self.t("bark.noPair"))
            case .failed(let why):
                self.revert(app.lang.f("shutong.sendFailed", why))
            }
        }
    }

    /// 大管家的回话：是自己那封就收下（返回 true）；它没收下，开关弹回去
    func answered(_ r: ButlerResult) -> Bool {
        guard let w = waiting, w.hasPrefix("\(r.id)|") else { return false }
        let reply = DoveReply.from(r)
        if reply.ok {
            if w.hasSuffix("|off"), !demo { Keychain.delete(Self.account) }
            waiting = nil
            said = reply.line
            save()
        } else {
            revert(reply.line)
        }
        return true
    }

    /// 没成：开关弹回原样，写一句为什么
    private func revert(_ why: String) {
        guard let w = waiting else { return }
        showContent = w.hasSuffix("|off")
        if !showContent, !demo { Keychain.delete(Self.account) }
        waiting = nil
        said = why
        save()
    }

    /// 再拷一次（粘进 Bark 之前剪贴板被别的顶掉了）
    func copyAgain() {
        if demo {
            app?.show(t("bark.copied"))
            return
        }
        guard let d = Keychain.read(Self.account), let key = String(data: d, encoding: .utf8) else { return }
        copy(key)
        app?.show(t("bark.copied"))
    }

    /// 只在这台手机上（不进通用剪贴板），10 分钟后系统自己清
    private func copy(_ key: String) {
        guard !demo else { return }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(BarkSecret.clipboardSeconds)])
    }

    private var demoLine: String {
        app?.lang.isZh == false ? "Got it: Bark key ending 7f3a. Alerts now show the first line."
                                : "鸽子到了：Bark 加密钥匙，7f3a 结尾，提醒里以后带第一行内容"
    }

    private func save() {
        guard !demo else { return }
        UserDefaults.standard.set(showContent, forKey: Self.onKey)
        UserDefaults.standard.set(waiting, forKey: Self.waitingKey)
    }
}

extension AppModel {
    /// 204：从 Bark 提醒点进来（yiye://shutong?id=… / yiye://todo；250：yiye://bot?id= / yiye://group?id=）。
    /// 挡在前面的页先收，再开要去的那页
    func openLink(_ url: URL) {
        guard let link = YiyeLink.parse(url) else { return }
        started()                                              // 冷启动：链接可能比第一屏先到
        let shutong = ShutongModel.shared
        var covered = DoveModel.shared.open || RemoteModel.shared.open || listening != nil
        DoveModel.shared.open = false
        RemoteModel.shared.open = false
        listening = nil                                        // 声音照放
        let bots = BotsModel.shared
        var scribeStays = false
        if case .shutong = link { scribeStays = true }
        if case .bot(let id, _) = link, id == BotID.shutong { scribeStays = true }
        if shutong.open && !scribeStays {
            shutong.open = false
            covered = true
        }
        var toTodo = false
        if case .todo = link { toTodo = true }
        if bots.open && (scribeStays || toTodo) {
            bots.open = false
            covered = true
        }
        let wait = covered
        Task { @MainActor in
            if wait { try? await Task.sleep(nanoseconds: 700_000_000) }      // 一次只开得出一张：等那张收完
            switch link {
            case .shutong(let id):
                shutong.load()
                BarkModel.shared.focus = id
                shutong.open = true
            case .todo:
                TodoDesk.shared.showFolder()
            case .bot(let id, _) where id == BotID.shutong:
                shutong.load()
                shutong.open = true
            case .bot(let id, let msg):
                bots.openFromLink(id, msg: msg)                     // 252：滚到那一句（定时活的第一条）
            case .group(let id):
                bots.openFromLink(id)
            }
        }
    }
}
