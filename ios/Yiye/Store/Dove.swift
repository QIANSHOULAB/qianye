import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers
import YiyeKit

/// 飞鸽传书（128）：钥匙从手机经加密信箱交给大管家，不走 Telegram，不走 iCloud。
/// 钥匙只在这里的 `key` 里待一小会儿（内存）：寄出去、退到后台、关了页面，马上清掉，剪贴板也清掉。
/// 不存便签、不进镜像、不进日志、不进截图、不进 UserDefaults。
/// 反过来：大管家递来的一次性东西（kind=secret）弹成一张「特勤局机密文件」卡，复制了 2 分钟后系统自己清剪贴板，关了就没了。
@MainActor @Observable
final class DoveModel {
    static let shared = DoveModel()

    enum Status: Equatable {
        case idle
        case sending
        /// 信已进信箱：pc 说大管家在不在线（不在线就在信箱里等着，加密的）
        case waiting(pc: Bool)
        case noMailbox
        case failed(String)
        case answered(DoveReply)
    }

    /// 飞鸽传书那一页开着
    var open = false
    private(set) var key = ""
    var name = ""
    private(set) var status: Status = .idle
    /// 机密文件卡（只在内存里）
    var secret: SecretCard?
    /// 刚复制过机密文件
    private(set) var copied = false
    @ObservationIgnored weak var service: ButlerService?
    /// 粘贴那一刻剪贴板的版本号：之后剪贴板还是它才清（他中间复制了别的，别动人家的东西）
    @ObservationIgnored private var pasteCount: Int?

    var masked: String { Dove.masked(key) }
    var looksLike: String? { Dove.guess(key) }
    var canSend: Bool { Dove.canSend(key: key, sending: status == .sending) }
    var hasKey: Bool { !key.isEmpty }

    // ---------------------------------------------------------------- 钥匙出去
    func paste(_ text: String) {
        let k = Dove.clean(text)
        guard !k.isEmpty else { return }
        key = k
        status = .idle
        pasteCount = UIPasteboard.general.changeCount
    }

    func send() {
        guard canSend, let service else { return }
        let k = key, n = name
        status = .sending
        Task {
            switch await service.sendKey(key: k, name: n) {
            case .sent(let pc):
                wipeKey()                                  // 寄出去了：内存里这份、剪贴板里那份都清掉
                if case .answered = status { break }       // 回信比这一句还快：别盖掉
                status = .waiting(pc: pc)
            case .noPair:
                status = .noMailbox
            case .failed(let why):
                status = .failed(why)
            }
        }
    }

    func answered(_ r: DoveReply) {
        status = .answered(r)
    }

    /// 钥匙从内存清掉；剪贴板还是粘贴时那一份就清空
    func wipeKey() {
        key = ""
        if let c = pasteCount, UIPasteboard.general.changeCount == c { UIPasteboard.general.string = "" }
        pasteCount = nil
    }

    /// 关了页面：什么都不留
    func close() {
        wipeKey()
        name = ""
        status = .idle
        open = false
    }

    // ---------------------------------------------------------------- 机密文件进来
    func show(_ d: ButlerDelivery) {
        guard let card = SecretCard.from(d) else { return }
        copied = false
        secret = card
    }

    /// 复制：只在这台手机上（不进通用剪贴板），2 分钟后系统自己清（app 被挂起也照清）
    func copySecret() {
        guard let s = secret else { return }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: s.text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Dove.clearAfter)])
        copied = true
    }

    func closeSecret() {
        secret = nil
        copied = false
    }

    // ---------------------------------------------------------------- 截图用
    /// 截图用：-YiyeScreen dove / dove-done / secret。钥匙是编的，不寄
    func demo(_ screen: String) {
        switch screen {
        case "dove":
            key = "ntn_" + String(repeating: "7f3a", count: 8)
            name = ""
            open = true
        case "dove-done":
            key = ""
            name = "Notion"
            status = .answered(DoveReply(ok: true, line: "鸽子到了：Notion，ntn_ 开头、7f3a 结尾，能用"))
            open = true
        case "secret":
            secret = SecretCard(id: "demo", title: "铁屑江湖配对码", text: "tiexie:eyJ2IjoyLCJyZWxheSI6Imh0dHBzOi8vZXhhbXBsZSIsImJveCI6IjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0",
                                hint: "到铁屑江湖设置里点「粘贴配对码」，认一回管一辈子")
        default: break
        }
    }
}
