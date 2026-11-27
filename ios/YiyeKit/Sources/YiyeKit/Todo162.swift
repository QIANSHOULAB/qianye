import Foundation

/// 162 项目待办：要 Song 做的事（orders 分支 `项目待办/<id>.md`），大管家寄来，手机建成便签放「项目待办」文件夹。
/// 送来 kind=todo（新的 / 改了内容）、kind=todo-done（那边办完了：进废纸篓）；手机回 todo-ok（回执）、todo-done（他扔了）、
/// todo-undo（他放回去了）。接口 v3.15（ios/docs/大管家接口.md）。
///
/// 一个待办 id 只对应一条便签：便签的 UUID 由 id 算出来（同一个 id 永远同一个 UUID），再收到同一个 id 不会多建。
/// 他改过的便签不跟着更新（TodoBook 记着上回写进去的正文，一样才换）。
public enum Todo {
    public static let folder = "项目待办"
    public static let kindNew = "todo"
    public static let kindDone = "todo-done"

    /// 待办 id → 便签 UUID
    public static func noteID(_ todo: String) -> UUID { StableID.uuid("todo:" + todo) }

    /// 便签正文：第一行是标题（# 标题），下面照原样
    public static func markdown(title: String?, text: String) -> String {
        let head = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return body }
        return body.isEmpty ? "# \(head)" : "# \(head)\n\n\(body)"
    }

    /// 信里的待办 id：data.todo，没写退回 data.id
    public static func id(of d: ButlerDelivery) -> String {
        let t = (d.todo ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? d.id : t
    }
}

/// 一串字 → 固定的 UUID（FNV-1a 两轮拼 128 位，版本位写成 5 那样，不依赖 CryptoKit）。待办（162）、看板（234）拿它认便签
enum StableID {
    static func uuid(_ s: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325 ^ seed
            for b in s.utf8 {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
            return h
        }
        let a = fnv(0), b = fnv(0x9e3779b97f4a7c15)
        var x = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            x[i] = UInt8((a >> UInt64(56 - 8 * i)) & 0xff)
            x[8 + i] = UInt8((b >> UInt64(56 - 8 * i)) & 0xff)
        }
        x[6] = (x[6] & 0x0f) | 0x50
        x[8] = (x[8] & 0x3f) | 0x80
        return UUID(uuid: (x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7], x[8], x[9], x[10], x[11], x[12], x[13], x[14], x[15]))
    }
}

/// 手机上一条待办便签现在的样子（app 交进来，规则在这里定）
public struct TodoNow: Equatable, Sendable {
    public var trashed: Bool
    public var markdown: String
    public init(trashed: Bool, markdown: String) { self.trashed = trashed; self.markdown = markdown }
}

/// 记着每个待办 id 对应哪条便签、上回写进去的正文（app 在 UserDefaults 里存一份 JSON）
public struct TodoBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var note: String
        public var written: String
    }

    public enum Step: Equatable, Sendable {
        /// 新建一条（UUID、正文）
        case create(UUID, String)
        /// 换正文（他没改过）
        case update(UUID, String)
        /// 扔进废纸篓（那边办完了）
        case trash(UUID)
        /// 不动，为什么
        case none(String)
    }

    public var items: [String: Entry] = [:]

    public init() {}

    public static func load(_ data: Data?) -> TodoBook {
        guard let data, let b = try? JSONDecoder().decode(TodoBook.self, from: data) else { return TodoBook() }
        return b
    }

    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// 收到 kind=todo。now = 手机上那条现在的样子（没有 = nil）
    public mutating func receive(todo: String, markdown: String, now: TodoNow?) -> Step {
        let nid = Todo.noteID(todo)
        guard let now else {
            items[todo] = Entry(note: nid.uuidString, written: markdown)
            return .create(nid, markdown)
        }
        if items[todo] == nil { items[todo] = Entry(note: nid.uuidString, written: now.markdown) }
        if now.trashed { return .none("他扔了") }
        if now.markdown == markdown { return .none("一样") }
        guard now.markdown == items[todo]?.written else { return .none("他改过") }
        items[todo]?.written = markdown
        return .update(nid, markdown)
    }

    /// 收到 kind=todo-done
    public func done(todo: String, now: TodoNow?) -> Step {
        guard let now else { return .none("手机上没有") }
        if now.trashed { return .none("已经在废纸篓") }
        return .trash(Todo.noteID(todo))
    }

    /// 这条便签是哪个待办的（他扔 / 放回时回请求用）
    public func todo(of note: UUID) -> String? {
        let s = note.uuidString
        return items.first(where: { $0.value.note == s })?.key
    }
}

extension ButlerRequest {
    /// 162：待办的信收到了（回执）：note 是那封送来的 id
    public static func todoOK(id: String, of letter: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: letter, kind: .text, text: "", images: nil, unsure: nil, ask: "todo-ok", at: at, app: app)
    }

    /// 162：他在手机上把这条待办扔了：note 是待办 id
    public static func todoDone(id: String, todo: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: todo, kind: .text, text: "", images: nil, unsure: nil, ask: "todo-done", at: at, app: app)
    }

    /// 162：他撤销、放回去了
    public static func todoUndo(id: String, todo: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: todo, kind: .text, text: "", images: nil, unsure: nil, ask: "todo-undo", at: at, app: app)
    }
}
