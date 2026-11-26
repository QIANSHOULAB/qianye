import Foundation
import SwiftData
import UIKit
import YiyeKit

/// 162 项目待办：大管家寄来的「要 Song 做的事」变成「项目待办」文件夹里的便签；他扔了 / 放回去，告诉大管家。
/// 规则在 YiyeKit Todo162.swift（TodoBook）；这里只管动便签、寄请求。
/// 大管家那头：pc-butler handheld/todo.py（电脑在信箱上电脑寄，电脑掉线掌机接班）。
@MainActor
final class TodoDesk {
    static let shared = TodoDesk()
    static let bookKey = "yiye.todoBook162"
    static let outKey = "yiye.todoOut162"

    weak var app: AppModel?
    weak var service: ButlerService?
    private var book = TodoBook()
    private var loaded = false
    /// 那边办完寄来的 todo-done 正在扔：不再回一封 todo-done
    private var muted = false
    /// 还没寄出去的请求「ask|待办 id」（寄成了才拿掉；重开 app 接着寄）
    private var out: [String] = []
    private var sending: Set<String> = []
    /// 截图 / UI 测试（-YiyeDemo）：寄过的请求，UI 测试从 todo.sent 那行读
    private(set) var demoSent: [String] = []

    private var demo: Bool { app?.demo != nil }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !demo else { return }
        book = TodoBook.load(UserDefaults.standard.data(forKey: Self.bookKey))
        out = UserDefaults.standard.stringArray(forKey: Self.outKey) ?? []
    }

    private func save() {
        guard !demo else { return }
        UserDefaults.standard.set(book.data(), forKey: Self.bookKey)
        UserDefaults.standard.set(out, forKey: Self.outKey)
    }

    // ---------------------------------------------------------------- 收
    /// kind=todo：建 / 更新那条便签；kind=todo-done：进废纸篓
    func receive(_ d: ButlerDelivery) {
        guard let app else { return }
        load()
        let todo = Todo.id(of: d)
        let nid = Todo.noteID(todo)
        let n = app.note(nid)
        let now = n.map { TodoNow(trashed: $0.trashed, markdown: $0.markdown) }
        if d.kind == Todo.kindDone {
            if case .trash(_) = book.done(todo: todo, now: now), let n {
                muted = true
                app.deleteMany([n], quiet: true)
                muted = false
            }
            return
        }
        let md = Todo.markdown(title: d.title, text: d.text)
        let step = book.receive(todo: todo, markdown: md, now: now)
        save()
        switch step {
        case .create(let id, let text):
            let note = Note()
            note.id = id
            note.markdown = text
            let at = d.at.flatMap { ISOTime.date($0) } ?? Date()
            note.createdAt = at
            note.modifiedAt = at
            note.folder = folder()
            app.context.insert(note)
            try? app.context.save()
            app.mirror.saveSoon(note, attachments: app.attachments)
            announce(note.title.isEmpty ? todo : note.title, id: d.id)
        case .update(_, let text):
            guard let n else { return }
            n.markdown = text
            app.changed(n)
        case .trash, .none:
            break
        }
    }

    /// 「项目待办」文件夹：没有就建，排第一个
    private func folder() -> Folder? {
        guard let app else { return nil }
        let all = (try? app.context.fetch(FetchDescriptor<Folder>())) ?? []
        if let f = all.first(where: { $0.name == Todo.folder }) { return f }
        let first = (all.map(\.order).min() ?? 0) - 1
        let f = Folder(name: Todo.folder, order: first)
        app.context.insert(f)
        return f
    }

    /// 在前台：底下一行「项目待办 +1：标题」；在后台：本地通知（跟 158 小书童一样）
    private func announce(_ title: String, id: String) {
        guard let app else { return }
        let zh = app.lang.isZh
        if UIApplication.shared.applicationState == .active {
            app.show(zh ? "项目待办 +1：\(title)" : "To-do +1: \(title)", seconds: 6)
        } else {
            ButlerNotice.post(title: zh ? "项目待办 +1" : "To-do +1", body: title, id: id)
        }
    }

    // ---------------------------------------------------------------- 他动了
    /// 扔进废纸篓的（右滑、批量、写字页、小书童）：是待办的，回 todo-done
    func trashed(_ notes: [Note]) {
        guard !muted else { return }
        load()
        for n in notes {
            if let todo = book.todo(of: n.id) { queue("todo-done", todo) }
        }
    }

    /// 从废纸篓放回去的：回 todo-undo
    func putBack(_ ids: [UUID]) {
        load()
        for id in ids {
            if let todo = book.todo(of: id) { queue("todo-undo", todo) }
        }
    }

    private func queue(_ ask: String, _ todo: String) {
        let other = ask == "todo-done" ? "todo-undo" : "todo-done"
        out.removeAll { $0 == "\(other)|\(todo)" || $0 == "\(ask)|\(todo)" }   // 扔了又放回：只寄最后那个
        out.append("\(ask)|\(todo)")
        save()
        flush()
    }

    /// 寄出去：信箱通了才寄，寄成了拿掉（ButlerService 每 5 秒叫一次）
    func flush() {
        load()
        guard !out.isEmpty else { return }
        if demo {
            demoSent.append(contentsOf: out)
            out = []
            showDemoSent()
            return
        }
        guard let service else { return }
        for item in out where !sending.contains(item) {
            let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            sending.insert(item)
            Task {
                let ok = await service.sendTodo(ask: parts[0], todo: parts[1])
                self.sending.remove(item)
                if ok {
                    self.out.removeAll { $0 == item }
                    self.save()
                }
            }
        }
    }

    // ---------------------------------------------------------------- 截图 / UI 测试
    private static var tag: UILabel?

    private func showDemoSent() {
        let line = demoSent.joined(separator: ",")
        guard let w = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        if Self.tag == nil || Self.tag?.window !== w {
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            l.alpha = 0.02
            l.isUserInteractionEnabled = false
            l.accessibilityIdentifier = "todo.sent"
            w.addSubview(l)
            Self.tag = l
        }
        Self.tag?.text = line
        Self.tag?.accessibilityLabel = line
    }

    /// -YiyeScreen todo：两条待办寄到，6 秒后第二条「那边办完了」
    func demo(zh: Bool) {
        let at = ISOTime.string(Date().addingTimeInterval(86_400))       // 排在 Demo 便签（今天 9:41）前面
        func letter(_ kind: String, _ todo: String, _ title: String, _ text: String) -> ButlerDelivery {
            var d = ButlerDelivery(id: "\(kind)-\(todo)~1", kind: kind, title: title, text: text, audio: nil, marks: nil,
                                   folder: Todo.folder, at: at)
            d.todo = todo
            return d
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.receive(letter("todo", "demo-1", zh ? "真机试新版" : "Try the new build", zh ? "1. 打开\n2. 点一下" : "1. Open it\n2. Tap once"))
            self.receive(letter("todo", "demo-2", zh ? "回 A 还是 B" : "Reply A or B", zh ? "聊天里回一个字" : "One letter in the chat"))
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.receive(letter("todo-done", "demo-2", "", ""))
        }
    }
}
