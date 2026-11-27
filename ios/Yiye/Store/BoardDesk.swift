import Foundation
import SwiftData
import UIKit
import YiyeKit

/// 234 看板：大管家写的一条便签（头一块是「游戏记录」），原地更新。接口 v3.24。
/// 规则在 YiyeKit Board234.swift（BoardBook）；这里只管动便签、寄回执。
/// 跟「项目待办」（TodoDesk）两本账：扔了看板便签什么都不寄，下一封另建一条。
@MainActor
final class BoardDesk {
    static let shared = BoardDesk()
    static let bookKey = "yiye.boardBook234"

    weak var app: AppModel?
    weak var service: ButlerService?
    private var book = BoardBook()
    private var loaded = false
    /// 截图 / UI 测试（-YiyeDemo）：寄过的回执，UI 测试从 board.sent 那行读
    private(set) var demoSent: [String] = []

    private var demo: Bool { app?.demo != nil }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !demo else { return }
        book = BoardBook.load(UserDefaults.standard.data(forKey: Self.bookKey))
    }

    private func save() {
        guard !demo else { return }
        UserDefaults.standard.set(book.data(), forKey: Self.bookKey)
    }

    /// 这条便签是大管家现在写着的看板：写字页底下出那行小字
    func owns(_ note: UUID) -> Bool {
        load()
        return book.owns(note)
    }

    // ---------------------------------------------------------------- 收
    /// kind=board：新建 / 原地盖掉那条便签，寄回执（没写 board 的信不认、不回）
    func receive(_ d: ButlerDelivery) {
        guard let app, let board = Board.id(of: d) else { return }
        load()
        let md = Board.markdown(title: d.title, text: d.text)
        let step = book.receive(board: board, markdown: md, at: d.at) { id in
            app.note(id).map { BoardNow(trashed: $0.trashed, markdown: $0.markdown) }
        }
        save()
        switch step {
        case .create(let id, let text):
            let note = Note()
            note.id = id
            note.markdown = text
            let at = d.at.flatMap { ISOTime.date($0) } ?? Date()
            note.createdAt = at
            note.modifiedAt = at
            note.folder = d.folder.flatMap { app.folderNamed($0) }        // 没有这个夹子就建
            app.context.insert(note)
            try? app.context.save()
            app.mirror.saveSoon(note, attachments: app.attachments)
        case .update(let id, let text):
            guard let n = app.note(id) else { break }
            n.markdown = text
            n.unsure = ""
            app.changed(n)
            NotificationCenter.default.post(name: .yiyeNoteReplaced, object: n.id)   // 开着写字页：重新装字，别让旧字盖回去
        case .none:
            break
        }
        ack(d.id)
    }

    private func ack(_ letter: String) {
        if demo {
            demoSent.append("board-ok|\(letter)")
            showDemoSent()
            return
        }
        service?.sendBoardOK(of: letter)
    }

    // ---------------------------------------------------------------- 截图 / UI 测试
    private static var tag: UILabel?

    private func showDemoSent() {
        let line = demoSent.joined(separator: ",")
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        if Self.tag == nil || Self.tag?.window !== w {
            let l = UILabel(frame: CGRect(x: 4, y: 0, width: 2, height: 2))
            l.alpha = 0.02
            l.isUserInteractionEnabled = false
            l.accessibilityIdentifier = "board.sent"
            w.addSubview(l)
            Self.tag = l
        }
        Self.tag?.text = line
        Self.tag?.accessibilityLabel = line
    }

    /// 造一封「游戏记录」（样子照 pc-butler 233）：round 1、2、3…本周时长一版比一版长
    private func demoLetter(_ round: Int, zh: Bool) -> ButlerDelivery {
        let hours = 10 + round
        let text: String
        if zh {
            text = """
            本周为电子事业献出 **\(hours) 小时 30 分**，比上周多 **3 小时**。

            ## 本周
            - **Soulframe**：**6 小时 10 分**
            - **Detroit: Become Human**：**\(hours - 8) 小时 20 分**
            - **Hollow Knight**：**2 小时**

            ## 最近玩的
            - 11月27日 周五 20:15，**Detroit: Become Human**，**1 小时 40 分**
            - 11月26日 周四 22:05，**Soulframe**，**2 小时 10 分**

            ## 总时长
            - **Detroit: Become Human**：**12 小时**（最后玩：11月27日）
            - **Soulframe**：**9 小时 30 分**（最后玩：11月26日）

            还有 7 个
            """
        } else {
            text = """
            **\(hours) h 30 min** donated to gaming this week, **3 h** more than last.

            ## This week
            - **Soulframe**: **6 h 10 min**
            - **Detroit: Become Human**: **\(hours - 8) h 20 min**
            - **Hollow Knight**: **2 h**

            ## Recently played
            - Fri 27 Nov 20:15, **Detroit: Become Human**, **1 h 40 min**
            - Thu 26 Nov 22:05, **Soulframe**, **2 h 10 min**

            ## All time
            - **Detroit: Become Human**: **12 h** (last played 27 Nov)
            - **Soulframe**: **9 h 30 min** (last played 26 Nov)

            And 7 more
            """
        }
        var d = ButlerDelivery(id: "board-game-log~\(round)", kind: Board.kind, title: zh ? "游戏记录" : "Game log", text: text,
                               audio: nil, marks: nil, folder: zh ? "游戏" : "Games",
                               at: ISOTime.string(Date().addingTimeInterval(Double(round) - 10)))
        d.board = "game-log"
        return d
    }

    /// -YiyeScreen board：「游戏」夹子里那条；board-note：点开它；
    /// board-flow（UI 测试）：先第 1 版，8 秒后第 2 版原地换；他扔了以后 2 秒寄第 3 版，另建一条
    func demo(_ screen: String, zh: Bool) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.receive(self.demoLetter(screen == "board-flow" ? 1 : 2, zh: zh))
            guard let app = self.app, let nid = self.book.items["game-log"].flatMap({ UUID(uuidString: $0.note) }),
                  let folder = app.note(nid)?.folder else { return }
            app.settings.folderID = folder.id.uuidString
            if screen == "board-note" { app.path = [.editor(nid)] }
            guard screen == "board-flow" else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.receive(self.demoLetter(2, zh: zh))
            for _ in 0..<240 {                                      // 最多等他两分钟
                try? await Task.sleep(nanoseconds: 500_000_000)
                if app.note(nid)?.trashed == true {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.receive(self.demoLetter(3, zh: zh))
                    return
                }
            }
        }
    }
}
